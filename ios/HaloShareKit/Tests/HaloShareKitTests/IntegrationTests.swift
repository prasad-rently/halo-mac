import Testing
import Foundation
import CryptoKit
@testable import HaloShareKit

// MARK: - Rig

/// Collects server events so a test can wait for them.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []
    func append(_ e: ServerEvent) { lock.withLock { events.append(e) } }
    var all: [ServerEvent] { lock.withLock { events } }

    func count(where match: (ServerEvent) -> Bool) -> Int { all.filter(match).count }
    var fileNames: [String] { all.compactMap { if case .fileReceived(_, _, let u) = $0 { return u.lastPathComponent } else { return nil } } }
    var completed: Int { count { if case .sessionCompleted = $0 { return true } else { return false } } }
    var cancelled: Int { count { if case .sessionCancelled = $0 { return true } else { return false } } }
    var offers: [IncomingOffer] { all.compactMap { if case .offer(let o) = $0 { return o } else { return nil } } }
}

struct Rig {
    let server: HaloShareServer
    let port: Int
    let dir: URL
    let log: EventLog
    let client: HaloShareClient
    let peer: Peer

    static func make(decision: ConsentDecision = .accept, idleTimeout: TimeInterval = 30,
                     maxSessions: Int = 4, consentDelay: TimeInterval = 0,
                     sessionTimeout: TimeInterval = 600) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hsk-rx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let receiverIdentity = DeviceIdentity(alias: "Receiver", fingerprint: DeviceIdentity.randomFingerprint(), deviceType: "desktop")
        let server = HaloShareServer(configuration: .init(identity: receiverIdentity, receiveDirectory: dir,
                                                         idleTimeout: idleTimeout, maxConcurrentSessions: maxSessions,
                                                         sessionTimeout: sessionTimeout)) { _ in
            if consentDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(consentDelay * 1_000_000_000)) }
            return decision
        }
        let log = EventLog()
        Task { for await e in server.events { log.append(e) } }
        let port = Int(try await server.start(port: 0))

        let sender = DeviceIdentity(alias: "Sender", fingerprint: DeviceIdentity.randomFingerprint())
        let client = HaloShareClient(identity: sender)
        let peer = try #require(await client.probe(host: "127.0.0.1", port: port, timeout: 5), "the server did not answer /info")
        return Rig(server: server, port: port, dir: dir, log: log, client: client, peer: peer)
    }

    func stop() async { await server.stop() }

    /// Files actually on disk (recursive), excluding nothing — so a leftover `.halopart` shows up.
    var filesOnDisk: [String] {
        // macOS reports /private/var/… for a /var/… temp dir; compare resolved paths.
        let root = dir.resolvingSymlinksInPath().path
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        return (e?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root + "/", with: "") }
            .sorted()
    }
}

func makeFile(named name: String, bytes: Int, in dir: URL? = nil, pattern: (Int) -> UInt8 = { UInt8(truncatingIfNeeded: $0 &* 31 &+ 129) }) throws -> URL {
    let base = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("hsk-src-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let url = base.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var written = 0
    let chunk = 1 << 20
    while written < bytes {
        let n = min(chunk, bytes - written)
        h.write(Data((0..<n).map { pattern(written + $0) }))
        written += n
    }
    return url
}

func sha256(of url: URL) throws -> String {
    var hasher = SHA256()
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

// MARK: - Raw HTTP (an independent client: one write, our framing, no URLSession)

struct Raw {
    /// Sends one request and returns (status, body). `splitAfterHead` writes the head and body
    /// separately (the URLSession shape); otherwise it is ONE write (the curl/OkHttp/Dart shape).
    static func post(port: Int, path: String, body: Data, contentType: String = "application/octet-stream",
                     declaredLength: Int? = nil, splitAfterHead: Bool = false,
                     extraHeaders: String = "") throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }

        let head = Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: \(contentType)\r\nContent-Length: \(declaredLength ?? body.count)\r\n\(extraHeaders)Connection: close\r\n\r\n".utf8)
        if splitAfterHead {
            _ = head.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            usleep(150_000)
            _ = body.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        } else {
            var all = head; all.append(body)
            _ = all.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        }
        if let d = declaredLength, d > body.count { shutdown(fd, SHUT_WR) }

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            reply.append(buf, count: n)
        }
        let text = String(decoding: reply, as: UTF8.self)
        let status = text.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? -1
        return (status, text)
    }
}

/// `curl` — a third-party HTTP stack, the strongest independent check we have.
func curl(_ args: [String]) throws -> (status: Int, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-o", "/dev/stdout", "-w", "\n%{http_code}", "--max-time", "30"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let status = Int(lines.last ?? "") ?? -1
    return (status, lines.dropLast().joined(separator: "\n"))
}

func prepareBody(files: [FileDescriptor], from alias: String = "RawSender") throws -> Data {
    let info = DeviceInfo(alias: alias, fingerprint: "raw-\(UUID().uuidString)")
    return try JSONEncoder().encode(PrepareUploadRequest(info: info, files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })))
}

// MARK: - StallingReceiver

/// A minimal receiver that accepts an offer and then **stops reading the upload**, so a client
/// upload blocks on TCP backpressure — the deterministic way to hold a transfer mid-flight.
/// Counts `/cancel` requests.
final class StallingReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var _uploadStarted = false
    private var _cancelRequests = 0
    private var open: [Int32] = []
    private var listenFD: Int32 = -1
    let port: Int

    var uploadStarted: Bool { lock.withLock { _uploadStarted } }
    var cancelRequests: Int { lock.withLock { _cancelRequests } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        DispatchQueue.global().async { [self] in acceptLoop() }
    }

    func stop() {
        lock.withLock { for fd in open { close(fd) }; open.removeAll() }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            lock.withLock { open.append(fd) }
            DispatchQueue.global().async { [self] in handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(chunk, count: n)
        }
        let range = buffer.range(of: terminator)!
        guard let head = HTTPRequestHead.parse(buffer[buffer.startIndex..<range.lowerBound]) else { return }
        var body = Data(buffer[range.upperBound...])

        func reply(_ status: Int, _ json: String) {
            let d = HTTPResponse.data(status: status, json: json)
            _ = d.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            close(fd)
        }

        switch head.path {
        case "/api/localsend/v2/info":
            let info = DeviceInfo(alias: "Stalled", fingerprint: "stalled-\(UUID().uuidString)", port: port)
            reply(200, String(decoding: (try? JSONEncoder().encode(info)) ?? Data(), as: UTF8.self))
        case "/api/localsend/v2/prepare-upload":
            while body.count < head.contentLength {
                let n = recv(fd, &chunk, min(chunk.count, head.contentLength - body.count), 0)
                if n <= 0 { return }
                body.append(chunk, count: n)
            }
            guard let req = try? JSONDecoder().decode(PrepareUploadRequest.self, from: body) else { reply(400, "{}"); return }
            let tokens = Dictionary(uniqueKeysWithValues: req.files.keys.map { ($0, "tok-\($0)") })
            reply(200, String(decoding: (try? JSONEncoder().encode(PrepareUploadResponse(sessionId: "stalled-session", files: tokens))) ?? Data(), as: UTF8.self))
        case "/api/localsend/v2/upload":
            lock.withLock { _uploadStarted = true }
            // Stop reading. The client blocks on a full send buffer until it is cancelled.
            while true { sleep(1); var b: UInt8 = 0; if recv(fd, &b, 0, MSG_PEEK | MSG_DONTWAIT) < 0, errno != EAGAIN { return } }
        case "/api/localsend/v2/cancel":
            lock.withLock { _cancelRequests += 1 }
            reply(200, "{\"message\":\"OK\"}")
        default:
            reply(404, "{}")
        }
    }
}

// MARK: - Send / receive with our own client

@Suite("HaloShare loopback", .serialized)
struct LoopbackTests {

    @Test("A text file arrives intact")
    func text() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "hello.txt", bytes: 0)
        try Data("hello, halo".utf8).write(to: src)
        let outcome = try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer)
        #expect(outcome == .completed)
        #expect(try String(contentsOf: rig.dir.appendingPathComponent("hello.txt"), encoding: .utf8) == "hello, halo")
        #expect(await waitUntil { rig.log.completed == 1 })
    }

    @Test("A binary file that is not valid UTF-8 arrives byte-for-byte (3 MB)")
    func binary() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "blob.bin", bytes: 3 << 20)
        #expect(String(data: try Data(contentsOf: src).prefix(512), encoding: .utf8) == nil, "fixture must not be valid UTF-8")
        #expect(try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer) == .completed)
        #expect(try sha256(of: rig.dir.appendingPathComponent("blob.bin")) == sha256(of: src))
    }

    @Test("A 96 MB file streams through intact")
    func large() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "big.bin", bytes: 96 << 20)
        #expect(try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer) == .completed)
        #expect(try sha256(of: rig.dir.appendingPathComponent("big.bin")) == sha256(of: src))
    }

    @Test("Several files in one session; the session completes once")
    func multiple() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hsk-multi-" + UUID().uuidString)
        let files = try ["a.bin", "b.bin", "c.bin"].enumerated().map { try OutgoingFile(url: try makeFile(named: $1, bytes: 100_000 + $0 * 777, in: dir)) }
        #expect(try await rig.client.send(files, to: rig.peer) == .completed)
        #expect(rig.filesOnDisk == ["a.bin", "b.bin", "c.bin"])
        #expect(await waitUntil { rig.log.completed == 1 })
    }

    @Test("Progress ends at the full size on both sides, and never goes backwards")
    func progress() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let size = 6 << 20
        let src = try makeFile(named: "p.bin", bytes: size)
        final class Box: @unchecked Sendable { var seen: [SendProgress] = []; let l = NSLock() }
        let box = Box()
        _ = try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer) { p in box.l.withLock { box.seen.append(p) } }

        // Sender side. How often URLSession calls back on loopback is its business; what we
        // own is that the figures are right and monotonic.
        let seen = box.l.withLock { box.seen }
        #expect(seen.last?.sent == Int64(size))
        #expect(seen.last?.overallTotal == Int64(size))
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.sent <= $1.sent }, "progress went backwards")

        // Receiver side: reported every 512 KB, so a 6 MB file gives many updates.
        #expect(await waitUntil { rig.log.completed == 1 })
        let received: [Int64] = rig.log.all.compactMap { if case .progress(_, _, let r, _) = $0 { return r } else { return nil } }
        #expect(received.count >= 3, "only \(received.count) progress events")
        #expect(received.last == Int64(size))
        #expect(zip(received, received.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A sub-folder in the file name is preserved, inside the destination")
    func subfolder() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "x.txt", bytes: 10)
        let out = try OutgoingFile(url: src, name: "trip/2026/x.txt")
        #expect(try await rig.client.send([out], to: rig.peer) == .completed)
        #expect(rig.filesOnDisk == ["trip/2026/x.txt"])
    }

    @Test("A file that already exists is not overwritten")
    func collision() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        try Data("original".utf8).write(to: rig.dir.appendingPathComponent("doc.txt"))
        let src = try makeFile(named: "doc.txt", bytes: 5)
        #expect(try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer) == .completed)
        #expect(try String(contentsOf: rig.dir.appendingPathComponent("doc.txt"), encoding: .utf8) == "original")
        #expect(rig.filesOnDisk == ["doc (1).txt", "doc.txt"])
    }

    @Test("A hostile file name cannot escape the destination folder")
    func traversal() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("hsk-parent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let victim = parent.appendingPathComponent("victim.txt")
        try Data("do not touch".utf8).write(to: victim)

        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        // The rig's receive dir is itself a fresh temp dir; put the victim one level above it.
        let outside = rig.dir.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString.prefix(6)).txt")
        try Data("do not touch".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let src = try makeFile(named: "s.txt", bytes: 5)
        let evil = try OutgoingFile(url: src, name: "../\(outside.lastPathComponent)")
        #expect(try await rig.client.send([evil], to: rig.peer) == .completed)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "do not touch", "the sender wrote outside the folder")
        #expect(rig.filesOnDisk == [outside.lastPathComponent])
    }

    @Test("Declining writes nothing, creates no session, and reports `declined` — not an error")
    func decline() async throws {
        let rig = try await Rig.make(decision: .decline); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "no.bin", bytes: 1000)
        #expect(try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer) == .declined)
        #expect(rig.filesOnDisk.isEmpty)
        #expect(await waitUntil { rig.log.offers.count == 1 })
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=x&fileId=y&token=z", body: Data("x".utf8))
        #expect(r.status == 404, "no session may exist after a decline")
    }

    @Test("The consent handler sees who is sending what")
    func offerContents() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let a = try makeFile(named: "a.jpg", bytes: 1000), b = try makeFile(named: "b.pdf", bytes: 2000)
        _ = try await rig.client.send([try OutgoingFile(url: a), try OutgoingFile(url: b)], to: rig.peer)
        let offer = try #require(rig.log.offers.first)
        #expect(offer.sender.alias == "Sender")
        #expect(offer.files.map(\.fileName) == ["a.jpg", "b.pdf"])
        #expect(offer.totalBytes == 3000)
    }

    @Test("Cancelling the send stops the upload and tells the receiver — deterministically, against a receiver that stalls")
    func clientCancel() async throws {
        // A loopback upload is too fast to cancel reliably (100 MB takes ~0.1 s), so the
        // receiver here accepts the offer and then simply stops reading: TCP backpressure
        // holds the client mid-upload for as long as the test likes.
        let slow = try StallingReceiver()
        defer { slow.stop() }
        let sender = DeviceIdentity(alias: "Sender", fingerprint: DeviceIdentity.randomFingerprint())
        let client = HaloShareClient(identity: sender)
        let peer = try #require(await client.probe(host: "127.0.0.1", port: slow.port, timeout: 5))

        let src = try makeFile(named: "huge.bin", bytes: 64 << 20)
        let task = Task { try await client.send([try OutgoingFile(url: src)], to: peer) }

        #expect(await waitUntil(timeout: 15) { slow.uploadStarted }, "the upload never reached the receiver")
        try await Task.sleep(nanoseconds: 300_000_000)      // genuinely mid-upload, blocked on the stalled reader
        task.cancel()

        do { _ = try await task.value; Issue.record("the cancelled send reported success") }
        catch { #expect((error as? HaloShareError) == .cancelled, "got \(error)") }
        #expect(await waitUntil(timeout: 10) { slow.cancelRequests == 1 }, "the receiver was never told to discard the session")
    }

    @Test("A /cancel arriving mid-upload discards the partial file and ends the session")
    func serverCancelMidUpload() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let d = FileDescriptor(id: "f", fileName: "half.bin", size: 4 << 20, fileType: "x")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))

        // Start an upload that declares 4 MB, delivers 300 KB, and then holds the connection open.
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(rig.port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let head = Data("POST /api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!) HTTP/1.1\r\nHost: x\r\nContent-Length: \(4 << 20)\r\n\r\n".utf8)
        var out = head; out.append(Data(repeating: 9, count: 300_000))
        _ = out.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        #expect(await waitUntil { rig.filesOnDisk.contains { $0.hasSuffix(".halopart") } }, "the upload never started streaming")

        let cancel = try Raw.post(port: rig.port, path: "/api/localsend/v2/cancel?sessionId=\(resp.sessionId)", body: Data())
        #expect(cancel.status == 200)
        #expect(await waitUntil { rig.filesOnDisk.isEmpty }, "partial survived the cancel: \(rig.filesOnDisk)")
        #expect(await waitUntil { rig.log.cancelled == 1 })
    }

    @Test("A sender cannot stream more than the size the user approved")
    func oversizedUploadRefused() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let desc = FileDescriptor(id: "f1", fileName: "t.bin", size: 10, fileType: "application/octet-stream")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [desc]), contentType: "application/json")
        let json = String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(json.utf8))
        let url = "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f1&token=\(resp.files["f1"]!)"
        let big = try Raw.post(port: rig.port, path: url, body: Data(repeating: 1, count: 4096))
        #expect(big.status == 413, "answered \(big.status)")
        #expect(rig.filesOnDisk.isEmpty, "bytes beyond the approved size reached the disk")
        #expect(try Raw.post(port: rig.port, path: url, body: Data(repeating: 1, count: 10)).status == 200)
    }

    @Test("A wrong token is refused and writes nothing")
    func wrongToken() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let desc = FileDescriptor(id: "f1", fileName: "t.bin", size: 10, fileType: "application/octet-stream")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [desc]), contentType: "application/json")
        #expect(prep.status == 200)
        let json = String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(json.utf8))
        let bad = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f1&token=WRONG", body: Data(repeating: 1, count: 10))
        #expect(bad.status == 403)
        #expect(rig.filesOnDisk.isEmpty)
        let good = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f1&token=\(resp.files["f1"]!)", body: Data(repeating: 1, count: 10))
        #expect(good.status == 200)
    }

    @Test("Tokens are unique per file and per session")
    func tokensUnique() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let descs = (1...3).map { FileDescriptor(id: "f\($0)", fileName: "f\($0)", size: 1, fileType: "x") }
        var all: [String] = []
        for _ in 0..<2 {
            let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: descs), contentType: "application/json")
            let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(r.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
            all.append(contentsOf: resp.files.values)
        }
        #expect(Set(all).count == 6)
        #expect(all.allSatisfy { $0.count >= 24 })
    }

    @Test("A file uploaded twice in one session is refused the second time")
    func doubleUpload() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let descs = [FileDescriptor(id: "a", fileName: "a", size: 3, fileType: "x"), FileDescriptor(id: "b", fileName: "b", size: 3, fileType: "x")]
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: descs), contentType: "application/json")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(r.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
        let path = "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=a&token=\(resp.files["a"]!)"
        #expect(try Raw.post(port: rig.port, path: path, body: Data("abc".utf8)).status == 200)
        #expect(try Raw.post(port: rig.port, path: path, body: Data("xyz".utf8)).status == 409)
        #expect(try String(contentsOf: rig.dir.appendingPathComponent("a"), encoding: .utf8) == "abc")
    }

    @Test("sha256 is verified when the sender supplies it — a mismatch is 422 and deletes the file")
    func checksum() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let payload = Data("checksummed".utf8)
        let good = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        for (name, digest, expected) in [("ok.txt", good, 200), ("bad.txt", String(repeating: "0", count: 64), 422)] {
            let d = FileDescriptor(id: "f", fileName: name, size: Int64(payload.count), fileType: "text/plain", sha256: digest)
            let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json")
            let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(r.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
            let up = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)", body: payload)
            #expect(up.status == expected, "\(name): \(up.status)")
        }
        #expect(rig.filesOnDisk == ["ok.txt"], "a corrupt file was kept: \(rig.filesOnDisk)")
    }

    @Test("A session cap returns 429 rather than accepting without limit")
    func sessionCap() async throws {
        let rig = try await Rig.make(maxSessions: 1); defer { Task { await rig.stop() } }
        let d = [FileDescriptor(id: "f", fileName: "f", size: 1, fileType: "x")]
        #expect(try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: d), contentType: "application/json").status == 200)
        #expect(try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: d), contentType: "application/json").status == 429)
    }

    private func prepare(_ rig: Rig, size: Int64 = 1) throws -> (status: Int, response: PrepareUploadResponse?) {
        let d = [FileDescriptor(id: "f", fileName: "f.bin", size: size, fileType: "application/octet-stream")]
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: d), contentType: "application/json")
        guard r.status == 200 else { return (r.status, nil) }
        let json = String(r.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "")
        return (200, try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(json.utf8)))
    }

    /// Blocking raw upload: head + `firstPart` bytes, pause, then the rest. Returns the HTTP status.
    private func slowUpload(port: Int, sessionId: String, token: String, total: Int, firstPart: Int, pause: TimeInterval) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        var first = Data("POST /api/localsend/v2/upload?sessionId=\(sessionId)&fileId=f&token=\(token) HTTP/1.1\r\nHost: x\r\nContent-Length: \(total)\r\nConnection: close\r\n\r\n".utf8)
        first.append(Data(repeating: 5, count: firstPart))
        _ = first.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        Thread.sleep(forTimeInterval: pause)
        let rest = Data(repeating: 5, count: total - firstPart)
        _ = rest.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var reply = Data(); var buf = [UInt8](repeating: 0, count: 2048)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; reply.append(buf, count: n) }
        return String(decoding: reply, as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? -1
    }

    @Test("An abandoned session expires: its token stops working and its slot is freed")
    func abandonedSessionExpires() async throws {
        let rig = try await Rig.make(maxSessions: 1, sessionTimeout: 1); defer { Task { await rig.stop() } }
        let first = try prepare(rig)
        #expect(first.status == 200)
        #expect(try prepare(rig).status == 429, "precondition: the single slot is taken")

        try await Task.sleep(nanoseconds: 2_200_000_000)

        #expect(await rig.server.sessionCount == 0, "the abandoned session was never forgotten")
        #expect(rig.log.cancelled == 1, "the app was not told the session ended")
        let r = try #require(first.response)
        let up = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(r.sessionId)&fileId=f&token=\(r.files["f"]!)", body: Data([1]))
        #expect(up.status == 404, "an expired session's token still worked (\(up.status))")
        #expect(try prepare(rig).status == 200, "a new sender is still locked out (429)")
    }

    @Test("A session is not expired while an upload is streaming")
    func sessionSurvivesAnUploadInFlight() async throws {
        let rig = try await Rig.make(sessionTimeout: 1); defer { Task { await rig.stop() } }
        let r = try #require(try prepare(rig, size: 3000).response)
        let port = rig.port, token = r.files["f"]!, sid = r.sessionId
        // 2.5 s of silence mid-body: longer than the 1 s session timeout, shorter than the 30 s idle timeout.
        let status = try await Task.detached { try self.slowUpload(port: port, sessionId: sid, token: token, total: 3000, firstPart: 100, pause: 2.5) }.value
        #expect(status == 200, "a live upload was cut by session expiry (\(status))")
        #expect(rig.filesOnDisk == ["f.bin"])
        #expect(rig.log.cancelled == 0)
    }

    @Test("The client reports a busy receiver as such")
    func busyReceiver() async throws {
        let rig = try await Rig.make(maxSessions: 1); defer { Task { await rig.stop() } }
        let d = [FileDescriptor(id: "f", fileName: "f", size: 1, fileType: "x")]
        _ = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: d), contentType: "application/json")
        let src = try makeFile(named: "late.txt", bytes: 10)
        await #expect(throws: HaloShareError.receiverBusy) {
            _ = try await rig.client.send([try OutgoingFile(url: src)], to: rig.peer)
        }
    }

    @Test("Probing an address nobody listens on fails fast, and probing yourself finds nothing")
    func probe() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let nobody = await rig.client.probe(host: "127.0.0.1", port: 1, timeout: 1)
        #expect(nobody == nil)
        // A client whose identity equals the server's must not "discover" itself.
        let selfClient = HaloShareClient(identity: DeviceIdentity(alias: "Receiver", fingerprint: rig.peer.info.fingerprint))
        #expect(await selfClient.probe(host: "127.0.0.1", port: rig.port, timeout: 2) == nil)
    }
}

// MARK: - Independent clients (the V1 regression class)

@Suite("HaloShare independent clients", .serialized)
struct IndependentClientTests {

    @Test("Headers and a binary body in ONE write (curl/OkHttp/Dart shape) are accepted")
    func oneWrite() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let payload = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 129) })
        #expect(String(data: payload, encoding: .utf8) == nil)
        let d = FileDescriptor(id: "f", fileName: "one.bin", size: Int64(payload.count), fileType: "application/octet-stream")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json")
        #expect(prep.status == 200, "prepare-upload JSON sharing a write with its headers: \(prep.status)")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
        let up = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)", body: payload)
        #expect(up.status == 200)
        #expect(try Data(contentsOf: rig.dir.appendingPathComponent("one.bin")) == payload)
    }

    @Test("Headers and body in separate writes (URLSession shape) are accepted")
    func twoWrites() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let payload = Data(repeating: 0xC3, count: 5000)
        let d = FileDescriptor(id: "f", fileName: "two.bin", size: Int64(payload.count), fileType: "x")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json", splitAfterHead: true)
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
        let up = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)", body: payload, splitAfterHead: true)
        #expect(up.status == 200)
        #expect(try Data(contentsOf: rig.dir.appendingPathComponent("two.bin")) == payload)
    }

    @Test("A truncated upload is not acknowledged and leaves no file or partial")
    func truncated() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let d = FileDescriptor(id: "f", fileName: "cut.bin", size: 5000, fileType: "x")
        let prep = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(prep.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
        let up = try Raw.post(port: rig.port, path: "/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)",
                              body: Data(repeating: 7, count: 1200), declaredLength: 5000)
        #expect(up.status != 200)
        #expect(await waitUntil { rig.filesOnDisk.isEmpty }, "left behind: \(rig.filesOnDisk)")
    }

    @Test("Chunked transfer encoding is refused with 411, not misread")
    func chunked() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: Data("{}".utf8),
                             contentType: "application/json", extraHeaders: "Transfer-Encoding: chunked\r\n")
        #expect(r.status == 411)
    }

    @Test("curl: GET /info returns the receiver's identity")
    func curlInfo() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let r = try curl(["http://127.0.0.1:\(rig.port)/api/localsend/v2/info"])
        #expect(r.status == 200)
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(r.out.utf8))
        #expect(info.alias == "Receiver")
        #expect(info.fingerprint == rig.peer.info.fingerprint)
    }

    @Test("curl: a full prepare-upload + binary upload round trip")
    func curlUpload() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let src = try makeFile(named: "curl.bin", bytes: 40_000)
        let d = FileDescriptor(id: "f", fileName: "curl.bin", size: 40_000, fileType: "application/octet-stream")
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("hsk-prep-\(UUID().uuidString).json")
        try prepareBody(files: [d]).write(to: bodyFile)

        let prep = try curl(["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@\(bodyFile.path)",
                             "http://127.0.0.1:\(rig.port)/api/localsend/v2/prepare-upload"])
        #expect(prep.status == 200)
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(prep.out.utf8))

        let up = try curl(["-X", "POST", "-H", "Content-Type: application/octet-stream", "--data-binary", "@\(src.path)",
                           "http://127.0.0.1:\(rig.port)/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)"])
        #expect(up.status == 200)
        #expect(try sha256(of: rig.dir.appendingPathComponent("curl.bin")) == sha256(of: src))
    }

    @Test("curl: a 3 MB upload with `Expect: 100-continue` is honoured")
    func curlExpectContinue() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let size = 3 << 20
        let src = try makeFile(named: "expect.bin", bytes: size)
        let d = FileDescriptor(id: "f", fileName: "expect.bin", size: Int64(size), fileType: "application/octet-stream")
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: try prepareBody(files: [d]), contentType: "application/json")
        let resp = try JSONDecoder().decode(PrepareUploadResponse.self, from: Data(String(r.body.split(separator: "\r\n\r\n", maxSplits: 1).last ?? "").utf8))
        let up = try curl(["-X", "POST", "-H", "Expect: 100-continue", "-H", "Content-Type: application/octet-stream", "--data-binary", "@\(src.path)",
                           "http://127.0.0.1:\(rig.port)/api/localsend/v2/upload?sessionId=\(resp.sessionId)&fileId=f&token=\(resp.files["f"]!)"])
        #expect(up.status == 200)
        #expect(try sha256(of: rig.dir.appendingPathComponent("expect.bin")) == sha256(of: src))
    }

    @Test("Unknown routes are 404 and a garbage request is 400")
    func routing() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        #expect(try curl(["http://127.0.0.1:\(rig.port)/nope"]).status == 404)
        #expect(try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload", body: Data("not json".utf8), contentType: "application/json").status == 400)
    }

    @Test("The idle timeout does not cut a connection while the user is still deciding")
    func slowConsentIsNotCut() async throws {
        // The user takes 3 s to answer; the idle timeout is 1 s. The sender is rightly waiting.
        let rig = try await Rig.make(idleTimeout: 1, consentDelay: 3); defer { Task { await rig.stop() } }
        let d = FileDescriptor(id: "f", fileName: "a.bin", size: 3, fileType: "application/octet-stream")
        let r = try Raw.post(port: rig.port, path: "/api/localsend/v2/prepare-upload",
                             body: try prepareBody(files: [d]), contentType: "application/json")
        #expect(r.status == 200, "the connection was cut while waiting for the user (status \(r.status))")
    }

    @Test("A connection that stalls mid-request is dropped after the idle timeout")
    func idleTimeout() async throws {
        let rig = try await Rig.make(idleTimeout: 1); defer { Task { await rig.stop() } }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(rig.port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let partial = Data("POST /api/localsend/v2/upload?sess".utf8)   // never finishes
        _ = partial.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 64)
        let started = Date()
        let n = recv(fd, &buf, buf.count, 0)
        #expect(n <= 0, "the server should have closed the stalled connection")
        #expect(Date().timeIntervalSince(started) < 5, "took \(Date().timeIntervalSince(started)) s")
    }
}

@Suite("HaloShare discovery", .serialized)
struct DiscoveryTests {

    @Test("Scanning an explicit host list finds the peer once, however many addresses reach it")
    func scan() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.stop() } }
        let scanner = SubnetScanner(client: rig.client, port: rig.port, concurrency: 8, timeout: 2)
        // 127.0.0.1/.2/.3 all reach the same listener: one device, three addresses.
        let peers = await scanner.scan(hosts: ["127.0.0.1", "127.0.0.2", "127.0.0.3", "127.0.0.4"])
        #expect(peers.count == 1)
        #expect(peers.first?.alias == "Receiver")
    }

    @Test("An empty or dead host list finds nothing and returns promptly")
    func scanNothing() async throws {
        let client = HaloShareClient(identity: DeviceIdentity(alias: "S", fingerprint: "s"))
        let started = Date()
        let peers = await SubnetScanner(client: client, port: 1, concurrency: 16, timeout: 0.5).scan(hosts: (1...20).map { "127.0.0.\($0)" })
        #expect(peers.isEmpty)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
