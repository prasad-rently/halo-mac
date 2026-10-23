import Foundation
import Network
import CryptoKit

// MARK: - Consent

/// What the receiver is being asked to accept (protocol doc §7.1).
public struct IncomingOffer: Equatable, Sendable {
    public var sender: DeviceInfo
    public var senderAddress: String
    public var files: [FileDescriptor]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ConsentDecision: Sendable {
    case accept
    case decline
}

/// Asked once per `prepare-upload`. Nothing is written and no session exists until it
/// answers `.accept`. May take as long as the user takes.
public typealias ConsentHandler = @Sendable (IncomingOffer) async -> ConsentDecision

// MARK: - Events

public enum ServerEvent: Sendable {
    case listening(port: UInt16)
    case offer(IncomingOffer)
    case declined(sender: String)
    case progress(sessionId: String, fileId: String, received: Int64, total: Int64)
    case fileReceived(sessionId: String, fileId: String, url: URL)
    case sessionCompleted(sessionId: String)
    case sessionCancelled(sessionId: String)
}

// MARK: - HaloShareServer

/// The receive side of HaloShare: an HTTP server speaking the LocalSend v2 receiver API.
///
/// - **Framing is on bytes** (protocol doc §1): the head is read up to `\r\n\r\n`, then the
///   body by `Content-Length`, whatever the network does to the packet boundaries.
/// - **Consent first**, **untrusted file names confined**, **never overwrite**, **partials
///   don't survive** (§7). Uploads stream into a hidden `.halopart` temp file and are
///   renamed into place only when complete and (if the sender gave one) checksum-verified.
public actor HaloShareServer {

    public struct Configuration: Sendable {
        public var identity: DeviceIdentity
        public var receiveDirectory: URL
        /// An upload that goes quiet for this long is abandoned.
        public var idleTimeout: TimeInterval
        public var maxConcurrentSessions: Int

        public init(identity: DeviceIdentity, receiveDirectory: URL,
                    idleTimeout: TimeInterval = 60, maxConcurrentSessions: Int = 4) {
            self.identity = identity
            self.receiveDirectory = receiveDirectory
            self.idleTimeout = idleTimeout
            self.maxConcurrentSessions = maxConcurrentSessions
        }
    }

    private struct Session {
        let id: String
        let sender: DeviceInfo
        let files: [String: FileDescriptor]
        let tokens: [String: String]
        var received: Set<String> = []
        var inFlight: [String: URL] = [:]       // fileId → partial path
    }

    private let config: Configuration
    private let consent: ConsentHandler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: Session] = [:]
    private var continuation: AsyncStream<ServerEvent>.Continuation?

    public nonisolated let events: AsyncStream<ServerEvent>
    private var boundPort: UInt16 = 0

    public init(configuration: Configuration, consent: @escaping ConsentHandler) {
        self.config = configuration
        self.consent = consent
        var cont: AsyncStream<ServerEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: Lifecycle

    /// Starts listening. Pass `0` for an ephemeral port (tests). Returns the bound port.
    @discardableResult
    public func start(port: UInt16 = HaloShare.defaultPort) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in
            let box = ResumeOnce(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: HaloShareError.unreachable("listener cancelled"))
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        boundPort = bound
        continuation?.yield(.listening(port: bound))
        return bound
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        for s in sessions.values { discardPartials(of: s) }
        sessions.removeAll()
        continuation?.finish()
    }

    public var port: UInt16 { boundPort }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            await self.serve(connection)
            self.connections[key] = nil
        }
    }

    /// Cancels the connection if nothing arrives for `idleTimeout`. `connection.cancel()`
    /// makes a pending `receive` complete, which ends the upload loop.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var task: Task<Void, Never>?
        func start(timeout: TimeInterval, connection: NWConnection) {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.2, timeout / 4) * 1_000_000_000))
                    guard let self else { return }
                    let idle = self.idleSeconds()
                    if idle > timeout { connection.cancel(); return }
                }
            }
        }
        func touch() { lock.withLock { last = Date() } }
        private func idleSeconds() -> TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        func stop() { task?.cancel() }
    }

    private func serve(_ connection: NWConnection) async {
        let watchdog = Watchdog()
        watchdog.start(timeout: config.idleTimeout, connection: connection)
        defer { watchdog.stop() }

        guard let (head, prefix) = await readHead(connection, watchdog: watchdog) else {
            await respond(connection, HTTPResponse.error(400, "Bad Request"))
            return
        }
        if head.isChunked {
            await respond(connection, HTTPResponse.error(411, "Content-Length required"))
            return
        }
        if head.expectsContinue {
            await send(connection, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let api = HaloShare.apiPrefix
        let address = Self.address(of: connection)
        switch (head.method, head.path) {
        case ("GET", "\(api)/info"):
            await respond(connection, HTTPResponse.data(encoding: infoResponse()))

        case ("POST", "\(api)/register"):
            guard let body = await readBody(connection, head: head, prefix: prefix, watchdog: watchdog),
                  (try? JSONDecoder().decode(DeviceInfo.self, from: body)) != nil else {
                await respond(connection, HTTPResponse.error(400, "Invalid body")); return
            }
            await respond(connection, HTTPResponse.data(encoding: infoResponse()))

        case ("POST", "\(api)/prepare-upload"):
            guard let body = await readBody(connection, head: head, prefix: prefix, watchdog: watchdog),
                  let request = try? JSONDecoder().decode(PrepareUploadRequest.self, from: body) else {
                await respond(connection, HTTPResponse.error(400, "Invalid body")); return
            }
            await respond(connection, await prepareUpload(request, address: address))

        case ("POST", "\(api)/upload"):
            await respond(connection, await upload(connection, head: head, prefix: prefix, watchdog: watchdog))

        case ("POST", "\(api)/cancel"):
            await respond(connection, cancel(sessionId: head.query["sessionId"] ?? ""))

        default:
            await respond(connection, HTTPResponse.error(404, "Not Found"))
        }
    }

    // MARK: Routes

    /// `info`/`register` responses carry no `port`/`protocol` in the reference clients; we
    /// include ours, which every decoder (lenient or not) accepts.
    private func infoResponse() -> DeviceInfo {
        config.identity.deviceInfo(port: Int(boundPort == 0 ? HaloShare.defaultPort : boundPort))
    }

    private func prepareUpload(_ request: PrepareUploadRequest, address: String) async -> Data {
        guard !request.files.isEmpty else { return HTTPResponse.error(400, "No files") }
        guard sessions.count < config.maxConcurrentSessions else {
            return HTTPResponse.error(429, "Too many sessions")
        }

        let offer = IncomingOffer(sender: request.info, senderAddress: address,
                                  files: request.files.values.sorted { $0.fileName < $1.fileName })
        continuation?.yield(.offer(offer))

        switch await consent(offer) {
        case .decline:
            continuation?.yield(.declined(sender: request.info.alias))
            // Declined ⇒ 403, no session, nothing on disk (protocol doc §3).
            return HTTPResponse.error(403, "Rejected")
        case .accept:
            break
        }

        let id = UUID().uuidString
        var tokens: [String: String] = [:]
        for fileId in request.files.keys { tokens[fileId] = Self.randomToken() }
        sessions[id] = Session(id: id, sender: request.info, files: request.files, tokens: tokens)
        return HTTPResponse.data(encoding: PrepareUploadResponse(sessionId: id, files: tokens))
    }

    private func upload(_ connection: NWConnection, head: HTTPRequestHead, prefix: Data,
                        watchdog: Watchdog) async -> Data {
        guard let sessionId = head.query["sessionId"], let fileId = head.query["fileId"],
              let token = head.query["token"] else { return HTTPResponse.error(400, "Missing params") }
        guard var session = sessions[sessionId] else { return HTTPResponse.error(404, "Session not found") }
        guard let expectedToken = session.tokens[fileId], Self.constantTimeEqual(expectedToken, token) else {
            return HTTPResponse.error(403, "Invalid token")
        }
        guard let descriptor = session.files[fileId] else { return HTTPResponse.error(404, "File not found") }
        guard !session.received.contains(fileId), session.inFlight[fileId] == nil else {
            return HTTPResponse.error(409, "Already uploaded")
        }

        let directory = config.receiveDirectory
        let destination = SafeFileName.uniqueDestination(for: descriptor.fileName, in: directory)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).halopart")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch { return HTTPResponse.error(500, "Cannot create folder") }

        session.inFlight[fileId] = partial
        sessions[sessionId] = session

        // Trust Content-Length; fall back to the size announced in prepare-upload.
        let expected = head.contentLength > 0 ? head.contentLength : Int(descriptor.size)
        let outcome = await stream(connection, prefix: prefix, to: partial, expected: expected,
                                   checksum: descriptor.sha256 != nil, watchdog: watchdog) { received in
            await self.reportProgress(sessionId: sessionId, fileId: fileId, received: received, total: Int64(expected))
        }

        // Re-read: a cancel may have removed the session while we were streaming.
        guard var current = sessions[sessionId] else {
            try? FileManager.default.removeItem(at: partial)
            return HTTPResponse.error(404, "Session cancelled")
        }
        current.inFlight[fileId] = nil

        switch outcome {
        case .failed:
            try? FileManager.default.removeItem(at: partial)
            sessions[sessionId] = current
            return HTTPResponse.error(400, "Incomplete upload")

        case .complete(let digest):
            if let wanted = descriptor.sha256?.lowercased(), let digest, wanted != digest {
                try? FileManager.default.removeItem(at: partial)
                sessions[sessionId] = current
                return HTTPResponse.error(422, "Checksum mismatch")
            }
            // Re-resolve now, so a name taken while this file streamed isn't overwritten.
            let final = SafeFileName.uniqueDestination(for: descriptor.fileName, in: directory)
            do {
                try FileManager.default.moveItem(at: partial, to: final)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                sessions[sessionId] = current
                return HTTPResponse.error(500, "Cannot store file")
            }
            current.received.insert(fileId)
            let done = current.received.count == current.files.count
            if done { sessions[sessionId] = nil } else { sessions[sessionId] = current }
            continuation?.yield(.fileReceived(sessionId: sessionId, fileId: fileId, url: final))
            if done { continuation?.yield(.sessionCompleted(sessionId: sessionId)) }
            return HTTPResponse.data(status: 200, json: "{\"message\":\"OK\"}")
        }
    }

    private func cancel(sessionId: String) -> Data {
        if let session = sessions.removeValue(forKey: sessionId) {
            discardPartials(of: session)
            continuation?.yield(.sessionCancelled(sessionId: sessionId))
        }
        return HTTPResponse.data(status: 200, json: "{\"message\":\"OK\"}")
    }

    private func discardPartials(of session: Session) {
        for url in session.inFlight.values { try? FileManager.default.removeItem(at: url) }
    }

    private func reportProgress(sessionId: String, fileId: String, received: Int64, total: Int64) {
        continuation?.yield(.progress(sessionId: sessionId, fileId: fileId, received: received, total: total))
    }

    // MARK: Streaming

    private enum StreamOutcome { case complete(sha256: String?), failed }

    private func stream(_ connection: NWConnection, prefix: Data, to url: URL, expected: Int,
                        checksum: Bool, watchdog: Watchdog,
                        progress: @Sendable (Int64) async -> Void) async -> StreamOutcome {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return .failed }
        defer { try? handle.close() }

        var hasher = SHA256()
        var received = 0
        func write(_ data: Data) {
            handle.write(data)
            if checksum { hasher.update(data: data) }
            received += data.count
        }

        let first = prefix.prefix(expected)
        if !first.isEmpty { write(Data(first)) }

        var lastReport = 0
        while received < expected {
            guard let chunk = await receive(connection, maximum: min(256 * 1024, expected - received)) else {
                return .failed
            }
            watchdog.touch()
            write(chunk)
            if received - lastReport >= 512 * 1024 {
                lastReport = received
                await progress(Int64(received))
            }
        }
        await progress(Int64(received))
        let digest = checksum ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
        return .complete(sha256: digest)
    }

    // MARK: Wire helpers

    static let maxHeadBytes = 32 * 1024
    static let maxJSONBodyBytes = 4 * 1024 * 1024

    private func readHead(_ connection: NWConnection, watchdog: Watchdog) async -> (HTTPRequestHead, Data)? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count <= Self.maxHeadBytes {
            if let range = buffer.range(of: terminator) {
                guard let head = HTTPRequestHead.parse(buffer[buffer.startIndex..<range.lowerBound]) else { return nil }
                return (head, Data(buffer[range.upperBound...]))
            }
            guard let chunk = await receive(connection, maximum: 16 * 1024) else { return nil }
            watchdog.touch()
            buffer.append(chunk)
        }
        return nil
    }

    private func readBody(_ connection: NWConnection, head: HTTPRequestHead, prefix: Data,
                          watchdog: Watchdog) async -> Data? {
        let length = head.contentLength
        guard length > 0, length <= Self.maxJSONBodyBytes else { return nil }
        var body = prefix
        while body.count < length {
            guard let chunk = await receive(connection, maximum: min(64 * 1024, length - body.count)) else { return nil }
            watchdog.touch()
            body.append(chunk)
        }
        return Data(body.prefix(length))
    }

    private nonisolated func receive(_ connection: NWConnection, maximum: Int) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, _, _ in
                if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(returning: nil) }
            }
        }
    }

    private nonisolated func send(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private nonisolated func respond(_ connection: NWConnection, _ data: Data) async {
        await send(connection, data)
        connection.cancel()
    }

    static func address(of connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            default: break
            }
        }
        return "unknown"
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - ResumeOnce

/// A continuation that tolerates being resumed more than once (NWListener state updates can
/// repeat); only the first resume counts.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Error>
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }
    func resume(returning value: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true; cont.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true; cont.resume(throwing: error)
    }
}
