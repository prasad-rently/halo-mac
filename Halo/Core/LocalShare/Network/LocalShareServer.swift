import Foundation
import Network

actor LocalShareServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var activeSessions: [String: ServerSession] = [:]
    private var onPrepareUpload: ((PrepareUploadRequest, String) async -> PrepareUploadResponse?)?
    private var onFileReceived: ((String, String, URL) -> Void)?
    private var onCancel: ((String) -> Void)?
    private var onProgress: ((String, String, Int64) -> Void)?

    struct ServerSession {
        var sessionId: String
        var tokens: [String: String] // fileId -> token
        var files: [String: ShareFile] // fileId -> file info
        var destDirectory: URL
        var completed: Set<String>
    }

    // MARK: - Lifecycle

    func start(
        port: UInt16 = 53317,
        parameters: NWParameters,
        onPrepareUpload: @escaping (PrepareUploadRequest, String) async -> PrepareUploadResponse?,
        onFileReceived: @escaping (String, String, URL) -> Void,
        onCancel: @escaping (String) -> Void,
        onProgress: @escaping (String, String, Int64) -> Void
    ) async throws {
        self.onPrepareUpload = onPrepareUpload
        self.onFileReceived = onFileReceived
        self.onCancel = onCancel
        self.onProgress = onProgress

        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("[LocalShareServer] Listener failed: \(error)")
            default: break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleConnection(connection) }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
    }

    func registerSession(id: String, tokens: [String: String], files: [String: ShareFile], destDirectory: URL) {
        activeSessions[id] = ServerSession(
            sessionId: id,
            tokens: tokens,
            files: files,
            destDirectory: destDirectory,
            completed: []
        )
    }

    func isSessionComplete(_ sessionId: String) -> Bool {
        guard let session = activeSessions[sessionId] else { return false }
        return session.completed.count == session.files.count
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, let data = content, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task { await self.processHTTPData(data, connection: connection) }
        }
    }

    private func processHTTPData(_ data: Data, connection: NWConnection) async {
        guard let request = parseHTTPRequest(data) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad Request\"}")
            return
        }

        let path = request.path
        let method = request.method

        if method == "GET" && path == "/api/localsend/v2/info" {
            handleInfo(connection: connection)
        } else if method == "POST" && path == "/api/localsend/v2/register" {
            await handleRegister(connection: connection, body: request.body, sourceIP: request.sourceIP(from: connection))
        } else if method == "POST" && path == "/api/localsend/v2/prepare-upload" {
            await handlePrepareUpload(connection: connection, body: request.body, sourceIP: request.sourceIP(from: connection))
        } else if method == "POST" && path.hasPrefix("/api/localsend/v2/upload") {
            await handleUpload(connection: connection, request: request)
        } else if method == "POST" && path.hasPrefix("/api/localsend/v2/cancel") {
            handleCancelRequest(connection: connection, request: request)
        } else {
            sendResponse(connection: connection, status: 404, body: "{\"error\":\"Not Found\"}")
        }
    }

    // MARK: - Route Handlers

    private func handleInfo(connection: NWConnection) {
        let info = TLSManager.shared.deviceInfoDTO()
        guard let json = try? JSONEncoder().encode(info) else {
            sendResponse(connection: connection, status: 500, body: "{\"error\":\"Internal\"}")
            return
        }
        sendResponse(connection: connection, status: 200, body: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func handleRegister(connection: NWConnection, body: Data?, sourceIP: String) async {
        guard let body, let dto = try? JSONDecoder().decode(DeviceInfoDTO.self, from: body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid body\"}")
            return
        }
        // Reply with our info
        let info = TLSManager.shared.deviceInfoDTO()
        guard let json = try? JSONEncoder().encode(info) else {
            sendResponse(connection: connection, status: 500, body: "{\"error\":\"Internal\"}")
            return
        }
        sendResponse(connection: connection, status: 200, body: String(data: json, encoding: .utf8) ?? "{}")

        // Notify discovery about this device
        let device = ShareDevice(
            alias: dto.alias,
            version: dto.version,
            deviceModel: dto.deviceModel,
            deviceType: dto.deviceType.flatMap { DeviceType(rawValue: $0) },
            fingerprint: dto.fingerprint,
            port: dto.port,
            protocol_: TransportProtocol(rawValue: dto.protocol_) ?? .http,
            download: dto.download,
            ipAddress: sourceIP,
            lastSeen: Date()
        )
        _ = device // will be handled via callback
    }

    private func handlePrepareUpload(connection: NWConnection, body: Data?, sourceIP: String) async {
        guard let body, let request = try? JSONDecoder().decode(PrepareUploadRequest.self, from: body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid body\"}")
            return
        }

        // Delegate to manager for consent flow
        guard let response = await onPrepareUpload?(request, sourceIP) else {
            sendResponse(connection: connection, status: 403, body: "{\"error\":\"Transfer rejected\"}")
            return
        }

        guard let json = try? JSONEncoder().encode(response) else {
            sendResponse(connection: connection, status: 500, body: "{\"error\":\"Internal\"}")
            return
        }
        sendResponse(connection: connection, status: 200, body: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func handleUpload(connection: NWConnection, request: HTTPParsedRequest) async {
        let query = request.queryParams
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"] else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing params\"}")
            return
        }

        guard var session = activeSessions[sessionId] else {
            sendResponse(connection: connection, status: 404, body: "{\"error\":\"Session not found\"}")
            return
        }

        guard session.tokens[fileId] == token else {
            sendResponse(connection: connection, status: 403, body: "{\"error\":\"Invalid token\"}")
            return
        }

        guard let fileInfo = session.files[fileId] else {
            sendResponse(connection: connection, status: 404, body: "{\"error\":\"File not found\"}")
            return
        }

        // Determine destination
        let destURL = destinationURL(for: fileInfo, base: session.destDirectory)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write body to file (streaming for larger payloads)
        if let body = request.body {
            do {
                try body.write(to: destURL)
                onProgress?(sessionId, fileId, Int64(body.count))
            } catch {
                sendResponse(connection: connection, status: 500, body: "{\"error\":\"Write failed\"}")
                return
            }
        } else {
            // Stream from connection for large files
            await receiveFileStream(connection: connection, destURL: destURL, expectedSize: fileInfo.size, sessionId: sessionId, fileId: fileId)
        }

        session.completed.insert(fileId)
        activeSessions[sessionId] = session
        onFileReceived?(sessionId, fileId, destURL)
        sendResponse(connection: connection, status: 200, body: "{\"message\":\"OK\"}")
    }

    private func handleCancelRequest(connection: NWConnection, request: HTTPParsedRequest) {
        let sessionId = request.queryParams["sessionId"] ?? ""
        activeSessions.removeValue(forKey: sessionId)
        onCancel?(sessionId)
        sendResponse(connection: connection, status: 200, body: "{\"message\":\"OK\"}")
    }

    // MARK: - File Streaming

    private func receiveFileStream(connection: NWConnection, destURL: URL, expectedSize: Int64, sessionId: String, fileId: String) async {
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else { return }
        defer { try? handle.close() }

        var received: Int64 = 0
        let chunkSize = 256 * 1024 // 256 KB

        while received < expectedSize {
            let remaining = Int(min(Int64(chunkSize), expectedSize - received))
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            handle.write(chunk)
            received += Int64(chunk.count)
            if received % (1024 * 1024) < Int64(chunkSize) {
                onProgress?(sessionId, fileId, received)
            }
        }
    }

    // MARK: - Helpers

    private func destinationURL(for file: ShareFile, base: URL) -> URL {
        base.appendingPathComponent(file.fileName)
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(response.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP Parser

    struct HTTPParsedRequest {
        var method: String
        var path: String
        var queryParams: [String: String]
        var headers: [String: String]
        var body: Data?
        var rawConnection: NWConnection?

        func sourceIP(from connection: NWConnection) -> String {
            if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
                switch host {
                case .ipv4(let addr): return "\(addr)"
                case .ipv6(let addr): return "\(addr)"
                default: break
                }
            }
            return "unknown"
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPParsedRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let parts = str.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let fullPath = String(requestParts[1])

        // Parse path and query
        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = String(pathComponents[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    queryParams[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let hParts = line.split(separator: ":", maxSplits: 1)
            if hParts.count == 2 {
                headers[String(hParts[0]).lowercased()] = String(hParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Body
        var body: Data?
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = Data(bodyString.utf8)
            }
        }

        return HTTPParsedRequest(method: method, path: path, queryParams: queryParams, headers: headers, body: body)
    }
}
