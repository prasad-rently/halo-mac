import Foundation
@testable import HaloCloudKit

/// Where the repo's spec files live, found by walking up from this file.
enum Repo {
    static var root: URL? {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("docs/specs/crypto-parity.md").path) { return u }
        }
        return nil
    }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }
    static func json(_ name: String) throws -> JSONValue { try JSONValue.parse(try data(name)) }
}

/// An in-memory Realtime Database: same surface as the real client, no network. Observers get the same
/// added/removed/connected semantics the SSE client gives.
actor InMemoryRTDB: RealtimeDatabase {
    private let theUID: String
    private var root: [String: JSONValue] = [:]
    private struct Obs { let id = UUID(); let path: [String]; let cont: AsyncStream<ChildEvent>.Continuation; var delivered: [String: JSONValue] }
    private var observers: [UUID: Obs] = [:]
    private(set) var writes: [String] = []
    var failWrites = false
    var failReads = false

    init(uid: String = "uid-1") { theUID = uid }

    func uid() async throws -> String { theUID }
    func setFailWrites(_ b: Bool) { failWrites = b }
    func setFailReads(_ b: Bool) { failReads = b }

    private func parts(_ p: String) -> [String] { p.split(separator: "/").map(String.init) }

    private func node(_ path: [String]) -> JSONValue {
        var cur: JSONValue = .object(root)
        for p in path { guard let c = cur.children?[p] else { return .null }; cur = c }
        return cur
    }

    private func set(_ path: [String], _ value: JSONValue) {
        func go(_ m: [String: JSONValue], _ path: ArraySlice<String>) -> [String: JSONValue] {
            var m = m
            guard let head = path.first else { return value.children ?? [:] }
            if path.count == 1 { if value.isNull { m[head] = nil } else { m[head] = value }; return m }
            let child = go(m[head]?.children ?? [:], path.dropFirst())
            if child.isEmpty { m[head] = nil } else { m[head] = .object(child) }
            return m
        }
        root = go(root, path[...])
    }

    func get(_ path: String) async throws -> JSONValue {
        if failReads { throw CloudError.network }
        return node(parts(path))
    }

    func put(_ path: String, _ value: JSONValue) async throws {
        if failWrites { throw CloudError.network }
        writes.append("PUT \(path)")
        set(parts(path), value); notify()
    }

    func delete(_ path: String) async throws {
        if failWrites { throw CloudError.network }
        writes.append("DELETE \(path)")
        set(parts(path), .null); notify()
    }

    func shallowKeys(_ path: String) async throws -> Set<String> {
        if failReads { throw CloudError.network }
        return Set(node(parts(path)).children?.keys.map { $0 } ?? [])
    }

    /// Test seeding without recording a "write".
    func seed(_ path: String, _ value: JSONValue) { set(parts(path), value); notify() }

    nonisolated func observeChildren(_ path: String) -> AsyncStream<ChildEvent> {
        AsyncStream { cont in
            let id = UUID()
            Task { await self.attach(id: id, path: path, cont: cont) }
            cont.onTermination = { _ in Task { await self.detach(id) } }
        }
    }

    private func attach(id: UUID, path: String, cont: AsyncStream<ChildEvent>.Continuation) {
        var o = Obs(path: parts(path), cont: cont, delivered: [:])
        cont.yield(.connected)
        for (k, v) in (node(o.path).children ?? [:]).sorted(by: { $0.key < $1.key }) { o.delivered[k] = v; cont.yield(.added(key: k, value: v)) }
        observers[id] = o
    }
    private func detach(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for (id, var o) in observers {
            let now = node(o.path).children ?? [:]
            for (k, v) in now.sorted(by: { $0.key < $1.key }) where o.delivered[k] != v { o.delivered[k] = v; o.cont.yield(.added(key: k, value: v)) }
            for k in o.delivered.keys.sorted() where now[k] == nil { o.delivered[k] = nil; o.cont.yield(.removed(key: k)) }
            observers[id] = o
        }
    }
    func observerCount() -> Int { observers.count }
}

/// A canned HTTP transport for RTDB/auth tests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Call { let method: String; let url: URL; let body: String? }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var handler: @Sendable (URLRequest) throws -> (Data, Int)
    var streamHandler: (@Sendable (URLRequest) throws -> (Int, [String]))?

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        lock.withLock { calls.append(Call(method: request.httpMethod ?? "GET", url: request.url!, body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) })) }
        return try handler(request)
    }

    func openLines(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.withLock { calls.append(Call(method: "STREAM", url: request.url!, body: nil)) }
        guard let sh = streamHandler else { throw CloudError.network }
        let (status, lines) = try sh(request)
        return (status, AsyncThrowingStream { c in for l in lines { c.yield(l) }; c.finish() })
    }
    var allCalls: [Call] { lock.withLock { calls } }
}

func json(_ s: String) -> JSONValue { try! JSONValue.parse(Data(s.utf8)) }

/// Poll until `cond` holds or the deadline passes (async-friendly, no fixed sleeps).
func eventually(timeout: TimeInterval = 5, _ cond: @escaping () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await cond()
}

/// An HTTP-level emulation of Firebase over an `InMemoryRTDB`: sign-in, then GET/PUT/DELETE (+ shallow) on
/// `<path>.json?auth=`. Lets CloudSetup/FirebaseRTDB run through their real request code with no network.
final class RTDBStubTransport: HTTPTransport, @unchecked Sendable {
    let db: InMemoryRTDB
    let email = "me@halo.test", password = "halo-test-password"
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    private(set) var bodies: [String] = []
    var rejectSignIn: String?     // an Identity Toolkit error code to answer with
    var denyPaths: Set<String> = []   // first path component refused with 401 (locked rules)

    init(db: InMemoryRTDB) { self.db = db }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let url = request.url!
        lock.withLock { urls.append(url); if let b = request.httpBody { bodies.append(String(decoding: b, as: UTF8.self)) } }
        if url.path.hasSuffix("accounts:signInWithPassword") {
            if let code = rejectSignIn { return (Data(#"{"error":{"message":"\#(code)"}}"#.utf8), 400) }
            let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
            guard body["email"]?.stringValue == email, body["password"]?.stringValue == password else {
                return (Data(#"{"error":{"message":"INVALID_LOGIN_CREDENTIALS"}}"#.utf8), 400)
            }
            return (Data(#"{"idToken":"id-1","refreshToken":"r","localId":"uid-1","expiresIn":"3600"}"#.utf8), 200)
        }
        guard url.path.hasSuffix(".json") else { return (Data(), 404) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        guard comps.queryItems?.first(where: { $0.name == "auth" })?.value == "id-1" else { return (Data(#"{"error":"Permission denied"}"#.utf8), 401) }
        let path = String(url.path.dropFirst().dropLast(5)).removingPercentEncoding ?? ""
        if let first = path.split(separator: "/").first, denyPaths.contains(String(first)) { return (Data(#"{"error":"Permission denied"}"#.utf8), 401) }
        switch request.httpMethod ?? "GET" {
        case "PUT":
            try await db.put(path, try JSONValue.parse(request.httpBody ?? Data()))
            return (request.httpBody ?? Data(), 200)
        case "DELETE":
            try await db.delete(path); return (Data("null".utf8), 200)
        default:
            if comps.queryItems?.contains(where: { $0.name == "shallow" }) == true {
                let keys = try await db.shallowKeys(path)
                return (try JSONValue.object(Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.bool(true)) })).serialized(), 200)
            }
            return (try await db.get(path).serialized(), 200)
        }
    }

    func openLines(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) { throw CloudError.network }
    var allURLs: [URL] { lock.withLock { urls } }
    var allBodies: [String] { lock.withLock { bodies } }
}
