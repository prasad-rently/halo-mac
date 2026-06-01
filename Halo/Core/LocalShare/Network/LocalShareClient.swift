import Foundation

final class LocalShareClient: NSObject, @unchecked Sendable {
    static let shared = LocalShareClient()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: (Int64, Int64) -> Void] = [:]
    private let lock = NSLock()

    // MARK: - Prepare Upload

    func prepareUpload(to device: ShareDevice, files: [ShareFile]) async throws -> PrepareUploadResponse {
        let info = TLSManager.shared.deviceInfoDTO()
        var fileDTOs: [String: FileDTOUpload] = [:]
        for file in files {
            fileDTOs[file.id] = FileDTOUpload(
                id: file.id,
                fileName: file.fileName,
                fileType: file.fileType,
                size: file.size,
                sha256: file.sha256,
                preview: file.preview,
                metadata: file.metadata
            )
        }

        let requestBody = PrepareUploadRequest(info: info, files: fileDTOs)
        let url = buildURL(device: device, path: "/api/localsend/v2/prepare-upload")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalShareError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(PrepareUploadResponse.self, from: data)
        case 403:
            throw LocalShareError.transferRejected
        default:
            throw LocalShareError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Upload File

    func uploadFile(_ file: ShareFile, sessionId: String, to device: ShareDevice, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let sourceURL = file.sourceURL else { return }
        guard let token = file.token else { return }

        var urlComponents = URLComponents()
        urlComponents.scheme = device.protocol_.rawValue
        urlComponents.host = device.ipAddress
        urlComponents.port = device.port
        urlComponents.path = "/api/localsend/v2/upload"
        urlComponents.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "fileId", value: file.id),
            URLQueryItem(name: "token", value: token)
        ]

        guard let url = urlComponents.url else { throw LocalShareError.connectionFailed("Invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")

        let task = session.uploadTask(with: request, fromFile: sourceURL)
        let taskId = task.taskIdentifier

        lock.lock()
        progressHandlers[taskId] = progress
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            task.resume()
            // We use a completion observation
            Task {
                var done = false
                while !done {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    if task.state == .completed {
                        done = true
                        self.lock.lock()
                        self.progressHandlers.removeValue(forKey: taskId)
                        self.lock.unlock()
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    } else if task.state == .canceling {
                        done = true
                        self.lock.lock()
                        self.progressHandlers.removeValue(forKey: taskId)
                        self.lock.unlock()
                        continuation.resume(throwing: LocalShareError.transferCancelled)
                    }
                }
            }
        }
    }

    // MARK: - Send All (Parallel)

    func sendAll(files: [ShareFile], sessionId: String, to device: ShareDevice, progress: @escaping (String, Int64, Int64) -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            for file in files {
                if active >= 4 { try await group.next(); active -= 1 }
                group.addTask {
                    try await self.uploadFile(file, sessionId: sessionId, to: device) { sent, total in
                        progress(file.id, sent, total)
                    }
                }
                active += 1
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Cancel Session

    func cancelSession(_ sessionId: String, on device: ShareDevice) async {
        var urlComponents = URLComponents()
        urlComponents.scheme = device.protocol_.rawValue
        urlComponents.host = device.ipAddress
        urlComponents.port = device.port
        urlComponents.path = "/api/localsend/v2/cancel"
        urlComponents.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]

        guard let url = urlComponents.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    // MARK: - Get Device Info

    func getDeviceInfo(ip: String, port: Int) async -> ShareDevice? {
        guard let url = URL(string: "http://\(ip):\(port)/api/localsend/v2/info") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, _) = try await session.data(for: request)
            let dto = try JSONDecoder().decode(DeviceInfoDTO.self, from: data)
            return ShareDevice(
                alias: dto.alias,
                version: dto.version,
                deviceModel: dto.deviceModel,
                deviceType: dto.deviceType.flatMap { DeviceType(rawValue: $0) },
                fingerprint: dto.fingerprint,
                port: dto.port,
                protocol_: TransportProtocol(rawValue: dto.protocol_) ?? .http,
                download: dto.download,
                ipAddress: ip,
                lastSeen: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Register with device

    func register(with device: ShareDevice) async {
        let info = TLSManager.shared.deviceInfoDTO()
        let url = buildURL(device: device, path: "/api/localsend/v2/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(info)
        _ = try? await session.data(for: request)
    }

    // MARK: - Private

    private func buildURL(device: ShareDevice, path: String) -> URL {
        var components = URLComponents()
        components.scheme = device.protocol_.rawValue
        components.host = device.ipAddress
        components.port = device.port
        components.path = path
        return components.url!
    }
}

// MARK: - URLSessionTaskDelegate

extension LocalShareClient: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Trust all self-signed certs for local network transfers
        let (disposition, credential) = TLSManager.shared.shouldTrustServer(challenge: challenge)
        completionHandler(disposition, credential)
    }
}
