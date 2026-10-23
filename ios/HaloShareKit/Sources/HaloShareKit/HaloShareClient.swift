import Foundation
import CryptoKit

// MARK: - Outgoing files

public struct OutgoingFile: Sendable, Equatable {
    public var id: String
    public var url: URL
    public var name: String
    public var size: Int64
    public var mimeType: String

    public init(id: String = UUID().uuidString, url: URL, name: String? = nil, size: Int64? = nil, mimeType: String? = nil) throws {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        if let size {
            self.size = size
        } else {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let s = values.fileSize else { throw HaloShareError.fileUnreadable(url.lastPathComponent) }
            self.size = Int64(s)
        }
        self.mimeType = mimeType ?? OutgoingFile.mimeType(forExtension: url.pathExtension)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "zip": return "application/zip"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    var descriptor: FileDescriptor { FileDescriptor(id: id, fileName: name, size: size, fileType: mimeType) }
}

public struct SendProgress: Sendable, Equatable {
    public var fileId: String
    public var fileName: String
    public var sent: Int64
    public var total: Int64
    public var overallSent: Int64
    public var overallTotal: Int64
}

public enum SendOutcome: Equatable, Sendable {
    case completed
    /// The receiver's user said no (`403`). Not an error to retry.
    case declined
    /// `204`: nothing needed transferring.
    case nothingToSend
}

// MARK: - HaloShareClient

/// The send side: probe a peer, `prepare-upload`, stream each file, cancel.
///
/// Uploads stream **from disk** (`uploadTask(fromFile:)`), so memory use is independent of
/// file size (MR-TX-5). For `https` peers the certificate's SHA-256 must equal the
/// fingerprint the peer announced — unlike desktop's delegate, which trusts everything
/// (protocol doc §6).
public final class HaloShareClient: NSObject, @unchecked Sendable {

    private let identity: DeviceIdentity
    private var session: URLSession!
    private let lock = NSLock()
    private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
    private var pins: [String: String] = [:]     // "host:port" → expected sha256 hex

    public init(identity: DeviceIdentity) {
        self.identity = identity
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 3600
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    // MARK: Probe

    /// `GET /info`. Returns the peer, or `nil` if nothing (Halo/LocalSend) answered in time.
    public func probe(host: String, port: Int = Int(HaloShare.defaultPort),
                      scheme: TransportScheme = .http, timeout: TimeInterval = 2) async -> Peer? {
        var c = URLComponents()
        c.scheme = scheme.rawValue; c.host = host; c.port = port; c.path = "\(HaloShare.apiPrefix)/info"
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              var info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else { return nil }
        // The responder may omit port/protocol (protocol doc §2); we know how we reached it.
        info.port = port
        info.protocol = scheme
        if info.fingerprint == identity.fingerprint { return nil }   // that's us
        return Peer(info: info, host: host)
    }

    // MARK: Send

    /// Sends `files` to `peer`.
    ///
    /// Cancelling the calling `Task` stops the uploads and tells the receiver
    /// (`POST /cancel`) so it deletes any partial file (MR-TX-4).
    public func send(_ files: [OutgoingFile], to peer: Peer,
                     progress: @escaping @Sendable (SendProgress) -> Void = { _ in }) async throws -> SendOutcome {
        guard !files.isEmpty else { return .nothingToSend }

        if peer.scheme == .https { lock.withLock { pins["\(peer.host):\(peer.port)"] = peer.info.fingerprint } }

        let request = PrepareUploadRequest(info: identity.deviceInfo(),
                                           files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.descriptor) }))
        var prepare = URLRequest(url: url(peer, "/prepare-upload"))
        prepare.httpMethod = "POST"
        prepare.setValue("application/json", forHTTPHeaderField: "Content-Type")
        prepare.httpBody = try JSONEncoder().encode(request)
        // The receiver is waiting on a *person*; don't give up after the default 30 s.
        prepare.timeoutInterval = 10 * 60

        let (data, response) = try await perform(prepare)
        switch response.statusCode {
        case 200: break
        case 204: return .nothingToSend
        case 403: return .declined
        case 409, 429: throw HaloShareError.receiverBusy
        default: throw HaloShareError.http(status: response.statusCode)
        }
        guard let accepted = try? JSONDecoder().decode(PrepareUploadResponse.self, from: data) else {
            throw HaloShareError.invalidResponse
        }

        let overallTotal = files.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0

        do {
            for file in files {
                try Task.checkCancellation()
                guard let token = accepted.files[file.id] else { throw HaloShareError.invalidResponse }
                let base = completedBytes
                try await upload(file, token: token, sessionId: accepted.sessionId, to: peer) { sent, total in
                    progress(SendProgress(fileId: file.id, fileName: file.name, sent: sent, total: total,
                                          overallSent: base + sent, overallTotal: overallTotal))
                }
                completedBytes += file.size
            }
        } catch is CancellationError {
            await cancelSession(accepted.sessionId, on: peer)
            throw HaloShareError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            await cancelSession(accepted.sessionId, on: peer)
            throw HaloShareError.cancelled
        } catch {
            await cancelSession(accepted.sessionId, on: peer)
            throw error
        }
        return .completed
    }

    private func upload(_ file: OutgoingFile, token: String, sessionId: String, to peer: Peer,
                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var c = URLComponents(url: url(peer, "/upload"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "sessionId", value: sessionId),
                        URLQueryItem(name: "fileId", value: file.id),
                        URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")

        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            throw HaloShareError.fileUnreadable(file.name)
        }

        let task = session.uploadTask(with: request, fromFile: file.url)
        lock.withLock { progressHandlers[task.taskIdentifier] = progress }
        defer { lock.withLock { progressHandlers[task.taskIdentifier] = nil } }

        let (_, response): (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let box = UploadBox(cont)
                lock.withLock { completions[task.taskIdentifier] = box }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        guard let http = response as? HTTPURLResponse else { throw HaloShareError.invalidResponse }
        switch http.statusCode {
        case 200: return
        case 409, 429: throw HaloShareError.receiverBusy
        case 422: throw HaloShareError.checksumMismatch
        default: throw HaloShareError.http(status: http.statusCode)
        }
    }

    // MARK: Cancel

    /// Best-effort: tells the receiver to discard the session and its partial files.
    public func cancelSession(_ sessionId: String, on peer: Peer) async {
        var c = URLComponents(url: url(peer, "/cancel"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        // Completion-handler form, deliberately. This runs *because* the caller's Task was
        // cancelled, and the async `session.data(for:)` throws immediately when its Task is
        // already cancelled — so the request would never leave the device and the receiver
        // would keep a dead session and its partial file. A plain data task is not tied to
        // the caller's cancellation.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.dataTask(with: request) { _, _, _ in continuation.resume() }.resume()
        }
    }

    // MARK: Plumbing

    private final class UploadBox: @unchecked Sendable {
        let cont: CheckedContinuation<(Data, URLResponse), Error>
        var data = Data()
        var response: URLResponse?
        init(_ c: CheckedContinuation<(Data, URLResponse), Error>) { cont = c }
    }
    private var completions: [Int: UploadBox] = [:]

    private func url(_ peer: Peer, _ path: String) -> URL {
        peer.baseURL.appendingPathComponent("\(HaloShare.apiPrefix)\(path)")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HaloShareError.invalidResponse }
            return (data, http)
        } catch let error as HaloShareError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw HaloShareError.cancelled
        } catch let error as URLError {
            throw HaloShareError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - URLSession delegates

extension HaloShareClient: URLSessionDataDelegate, URLSessionTaskDelegate {

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let handler = progressHandlers[task.taskIdentifier]; lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); completions[dataTask.taskIdentifier]?.response = response; lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); completions[dataTask.taskIdentifier]?.data.append(data); lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let box = completions.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let box else { return }
        if let error { box.cont.resume(throwing: error) }
        else if let response = box.response { box.cont.resume(returning: (box.data, response)) }
        else { box.cont.resume(throwing: HaloShareError.invalidResponse) }
    }

    /// `https` peers: the presented certificate's SHA-256 must equal the fingerprint that
    /// peer announced. There is no CA to consult — the announced fingerprint *is* the
    /// identity — so anything else is refused.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let key = "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        lock.lock(); let expected = pins[key]; lock.unlock()

        guard let expected, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let presented = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        if presented.caseInsensitiveCompare(expected) == .orderedSame {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
