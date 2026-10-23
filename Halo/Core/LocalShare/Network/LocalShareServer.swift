import Foundation
import Network
import CryptoKit

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
        Task { await self.serve(connection) }
    }

    /// One request per connection (`Connection: close`).
    ///
    /// **Framing is done on bytes, not on a `String`.** The previous version made one
    /// `receive`, turned whatever arrived into a UTF-8 `String`, and split it on a blank
    /// line. That works only by accident: it needs the headers and the body to arrive in
    /// *separate* reads (URLSession happens to write them that way) and it answers
    /// `400 Bad Request` the moment a binary body shares a read with the headers — which
    /// is what curl, OkHttp and Dart's HTTP stack do for a small file, and so what a phone
    /// or the official LocalSend app sends. `HaloShareServerBinaryTests` reproduces it.
    ///
    /// Now: read until the head terminator is seen (bytes), parse the head, then read the
    /// body by `Content-Length` — in memory for the small JSON endpoints, streamed to disk
    /// for uploads — keeping whatever body bytes arrived with the head.
    private func serve(_ connection: NWConnection) async {
        guard let (head, bodyPrefix) = await readHead(from: connection) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad Request\"}")
            return
        }
        if head.isChunked {
            // Not supported (LocalSend sends Content-Length). Say so rather than misread it.
            sendResponse(connection: connection, status: 411, body: "{\"error\":\"Content-Length required\"}")
            return
        }
        if head.expectsContinue {
            await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
        }

        let sourceIP = Self.sourceIP(of: connection)
        switch (head.method, head.path) {
        case ("GET", "/api/localsend/v2/info"):
            handleInfo(connection: connection)

        case ("POST", "/api/localsend/v2/register"):
            guard let body = await readBody(from: connection, head: head, prefix: bodyPrefix) else {
                sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid body\"}"); return
            }
            await handleRegister(connection: connection, body: body, sourceIP: sourceIP)

        case ("POST", "/api/localsend/v2/prepare-upload"):
            guard let body = await readBody(from: connection, head: head, prefix: bodyPrefix) else {
                sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid body\"}"); return
            }
            await handlePrepareUpload(connection: connection, body: body, sourceIP: sourceIP)

        case ("POST", let path) where path.hasPrefix("/api/localsend/v2/upload"):
            await handleUpload(connection: connection, head: head, bodyPrefix: bodyPrefix)

        case ("POST", let path) where path.hasPrefix("/api/localsend/v2/cancel"):
            handleCancelRequest(connection: connection, head: head)

        default:
            sendResponse(connection: connection, status: 404, body: "{\"error\":\"Not Found\"}")
        }
    }

    /// Largest request head accepted. A real one is a few hundred bytes.
    static let maxHeadBytes = 32 * 1024
    /// Largest JSON body accepted on the non-upload endpoints (a prepare-upload for
    /// thousands of files is still well under this).
    static let maxJSONBodyBytes = 4 * 1024 * 1024

    private func readHead(from connection: NWConnection) async -> (HTTPRequestHead, Data)? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count <= Self.maxHeadBytes {
            if let range = buffer.range(of: terminator) {
                let headData = buffer[buffer.startIndex..<range.lowerBound]
                let prefix = Data(buffer[range.upperBound...])
                guard let head = HTTPRequestHead.parse(headData) else { return nil }
                return (head, prefix)
            }
            guard let chunk = await receive(on: connection, maximum: 16 * 1024) else { return nil }
            buffer.append(chunk)
        }
        return nil
    }

    /// The whole body of a small JSON request, or `nil` if it is missing, oversized, or the
    /// connection closes early.
    private func readBody(from connection: NWConnection, head: HTTPRequestHead, prefix: Data) async -> Data? {
        let length = head.contentLength
        guard length > 0, length <= Self.maxJSONBodyBytes else { return nil }
        var body = prefix
        while body.count < length {
            guard let chunk = await receive(on: connection, maximum: min(64 * 1024, length - body.count)) else {
                return nil
            }
            body.append(chunk)
        }
        return Data(body.prefix(length))
    }

    private func receive(on connection: NWConnection, maximum: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, _, _ in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
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

    private func handleUpload(connection: NWConnection, head: HTTPRequestHead, bodyPrefix: Data) async {
        let query = head.queryParams
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

        let destURL = destinationURL(for: fileInfo, base: session.destDirectory)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Trust `Content-Length`; fall back to the size announced in prepare-upload.
        let expected = head.contentLength > 0 ? head.contentLength : Int(fileInfo.size)
        let wantedDigest = fileInfo.sha256?.lowercased().trimmingCharacters(in: .whitespaces)
        let outcome = await receiveFileStream(connection: connection, prefix: bodyPrefix, destURL: destURL,
                                              expectedSize: expected, sessionId: sessionId, fileId: fileId,
                                              computeDigest: wantedDigest?.isEmpty == false)
        switch outcome {
        case .failed:
            // A short or failed transfer must not leave a truncated file that looks like
            // the real one (FR-6).
            try? FileManager.default.removeItem(at: destURL)
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Incomplete upload\"}")
            return

        case .complete(let digest):
            // The sender told us what the file should hash to; take it at its word. A file
            // that arrived whole but damaged (flaky Wi-Fi, a buggy sender) is worse than one
            // that failed loudly, because nothing about it looks wrong. `422` is the
            // protocol's answer (docs/HALOSHARE_PROTOCOL.md §3), and the file is not kept.
            if let wantedDigest, !wantedDigest.isEmpty, let digest, digest != wantedDigest {
                try? FileManager.default.removeItem(at: destURL)
                sendResponse(connection: connection, status: 422, body: "{\"error\":\"Checksum mismatch\"}")
                return
            }
        }

        session.completed.insert(fileId)
        activeSessions[sessionId] = session
        onFileReceived?(sessionId, fileId, destURL)
        sendResponse(connection: connection, status: 200, body: "{\"message\":\"OK\"}")
    }

    private func handleCancelRequest(connection: NWConnection, head: HTTPRequestHead) {
        let sessionId = head.queryParams["sessionId"] ?? ""
        activeSessions.removeValue(forKey: sessionId)
        onCancel?(sessionId)
        sendResponse(connection: connection, status: 200, body: "{\"message\":\"OK\"}")
    }

    // MARK: - File Streaming

    private enum StreamOutcome {
        case complete(sha256: String?)
        case failed
    }

    /// Writes `prefix` (body bytes that arrived with the head) and then reads the rest from
    /// the connection until `expectedSize` bytes are on disk, hashing as it goes when asked
    /// (one pass, no re-read of a file that may be gigabytes). `.failed` if the peer closes
    /// early or the file can't be written.
    private func receiveFileStream(connection: NWConnection, prefix: Data, destURL: URL,
                                   expectedSize: Int, sessionId: String, fileId: String,
                                   computeDigest: Bool) async -> StreamOutcome {
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else { return .failed }
        defer { try? handle.close() }

        var hasher = SHA256()
        var received = 0
        func write(_ data: Data) {
            handle.write(data)
            if computeDigest { hasher.update(data: data) }
            received += data.count
        }

        let first = prefix.prefix(expectedSize)
        if !first.isEmpty { write(Data(first)) }

        let chunkSize = 256 * 1024
        var lastReported = 0
        while received < expectedSize {
            guard let chunk = await receive(on: connection, maximum: min(chunkSize, expectedSize - received)) else {
                return .failed
            }
            write(chunk)
            if received - lastReported >= 1024 * 1024 {
                lastReported = received
                onProgress?(sessionId, fileId, Int64(received))
            }
        }
        onProgress?(sessionId, fileId, Int64(received))
        let digest = computeDigest ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
        return .complete(sha256: digest)
    }

    // MARK: - Helpers

    /// Where an incoming file is written. **The file name is chosen by the sender**, so it
    /// is untrusted: it used to be appended to the destination as-is, which let a name like
    /// `../../.zshrc` write outside the folder the user approved, and silently overwrote
    /// anything already there. `ShareFileName` confines it to `base` and picks a free name.
    private func destinationURL(for file: ShareFile, base: URL) -> URL {
        ShareFileName.uniqueDestination(for: file.fileName, in: base)
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

    static func sourceIP(of connection: NWConnection) -> String {
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

// MARK: - HTTPRequestHead

/// A parsed HTTP/1.1 request line and headers — **no body**. Pure and byte-oriented, so the
/// framing rules can be tested without a socket.
struct HTTPRequestHead: Equatable {
    var method: String
    var path: String
    var queryParams: [String: String]
    /// Header names are lower-cased.
    var headers: [String: String]

    /// 0 when absent or unparseable.
    var contentLength: Int { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0 }
    var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
    var expectsContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }

    /// `head` is everything before the blank line. Headers are ASCII in practice; decoding
    /// is lossy rather than failing, so a stray high byte in a header value cannot turn a
    /// valid request into a `400`.
    static func parse(_ head: Data) -> HTTPRequestHead? {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        guard path.hasPrefix("/") else { return nil }

        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = kv.first, !name.isEmpty else { continue }
                let rawValue = kv.count > 1 ? String(kv[1]) : ""
                let decodedName = String(name).removingPercentEncoding ?? String(name)
                query[decodedName] = rawValue.removingPercentEncoding ?? rawValue
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequestHead(method: String(parts[0]).uppercased(), path: path,
                               queryParams: query, headers: headers)
    }
}


// MARK: - ShareFileName

/// Turning a sender-supplied file name into a path that is safe to write.
///
/// LocalSend lets a sender include folders (`photos/2026/a.jpg`), so a relative sub-path is
/// legitimate and is kept. What is refused is anything that could leave the destination
/// directory: `..` components, absolute paths, and NUL bytes. Windows senders use `\`, which
/// is treated as a separator rather than as part of a name.
enum ShareFileName {

    /// A relative path made only of safe components, or `nil` if nothing usable remains.
    /// `..` and `.` and empty components are dropped rather than honoured.
    static func safeRelativePath(_ raw: String) -> String? {
        guard !raw.contains("\0") else { return nil }
        let normalised = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = normalised.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// `base/<safe path>`, with ` (1)`, ` (2)` … inserted before the extension if it already
    /// exists, and guaranteed to be inside `base`.
    ///
    /// Containment is **lexical**. An earlier version compared `standardizedFileURL` paths,
    /// but that strips a `/private` prefix only for paths that *exist* — the destination
    /// directory does, the file about to be written doesn't — so the check failed and every
    /// received file was saved as "file". `safeRelativePath` has already removed `.`, `..`
    /// and empty components, so containment holds by construction.
    static func uniqueDestination(for rawName: String, in base: URL,
                                  fileManager: FileManager = .default) -> URL {
        func build(_ relative: String) -> URL {
            var url = base
            for component in relative.split(separator: "/") { url.appendPathComponent(String(component)) }
            return url
        }
        var candidate = build(safeRelativePath(rawName) ?? "file")
        let root = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if !candidate.path.hasPrefix(root) { candidate = build("file") }

        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let dir = candidate.deletingLastPathComponent()
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let next = dir.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}
