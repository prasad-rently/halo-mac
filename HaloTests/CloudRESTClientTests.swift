import Testing
import Foundation
@testable import Halo

// MARK: - FirebaseRTDBClient over REST  (F-044)
//
// The client talks to two documented Google REST surfaces instead of firebase-ios-sdk
// (see the header of FirebaseRTDBClient.swift for why). Nothing here needs a Firebase
// project: a `URLProtocol` stands in for the network, routed *per test* so the suites can
// run in parallel — the auth endpoints are fixed Google hosts, so a test is identified by
// its unique API key (`?key=`) and a database request by its unique host label.

// MARK: Stub network

final class StubURLProtocol: URLProtocol {

    struct Req: @unchecked Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        var bodyString: String { String(decoding: body, as: UTF8.self) }
        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        var isStream: Bool { headers["Accept"] == "text/event-stream" }
    }

    struct Reply: @unchecked Sendable {
        var status = 200
        var body = Data()
        /// Deliver the body in pieces with a pause between (a live SSE stream).
        var chunks: [Data]? = nil
        var chunkDelay: TimeInterval = 0.02
        /// Leave the connection open after the last chunk until the client hangs up.
        var keepOpen = false

        static func json(_ object: Any?, status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object ?? NSNull(), options: [.fragmentsAllowed])) ?? Data())
        }
        static func text(_ s: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(s.utf8)) }
    }

    typealias Handler = @Sendable (Req) -> Reply

    private static let lock = NSLock()
    private static var routes: [String: Handler] = [:]
    private static var logs: [String: [Req]] = [:]
    private static var hangups: [String: Int] = [:]

    static func install(_ tenant: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        routes[tenant] = handler; logs[tenant] = []; hangups[tenant] = 0
    }
    static func requests(_ tenant: String) -> [Req] {
        lock.lock(); defer { lock.unlock() }; return logs[tenant] ?? []
    }
    static func hangupCount(_ tenant: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return hangups[tenant] ?? 0
    }

    /// A request belongs to the test whose API key it carries, or whose host label it targets.
    static func tenant(of url: URL) -> String {
        if (url.host ?? "").hasSuffix("googleapis.com") {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "key" }?.value ?? ""
        }
        return (url.host ?? "").split(separator: ".").first.map(String.init) ?? ""
    }

    private var tenant = ""
    private let stateLock = NSLock()
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func readBody(_ request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let req = Req(method: request.httpMethod ?? "GET", url: url,
                      headers: request.allHTTPHeaderFields ?? [:], body: Self.readBody(request))
        tenant = Self.tenant(of: url)
        Self.lock.lock()
        Self.logs[tenant, default: []].append(req)
        let handler = Self.routes[tenant]
        Self.lock.unlock()

        let reply = handler?(req) ?? Reply.text("no stub installed for \(tenant)", status: 599)
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)

        guard let chunks = reply.chunks else {
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().async { [self] in
            for chunk in chunks {
                Thread.sleep(forTimeInterval: reply.chunkDelay)
                if isCancelled { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            if !reply.keepOpen { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    private var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }

    override func stopLoading() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
        Self.lock.lock(); Self.hangups[tenant, default: 0] += 1; Self.lock.unlock()
    }
}

// MARK: Per-test harness

private struct Tenant {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    var config: FirebaseConfig {
        FirebaseConfig(apiKey: id, projectID: "p", googleAppID: "1:1:ios:a", gcmSenderID: "1",
                       databaseURL: "https://\(id).firebaseio.com", storageBucket: nil)
    }
    var dbHost: String { "\(id).firebaseio.com" }

    func client() -> FirebaseRTDBClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        c.timeoutIntervalForRequest = 10
        let s = URLSession(configuration: c)
        return FirebaseRTDBClient(session: s, streamSession: s)
    }

    func install(_ handler: @escaping StubURLProtocol.Handler) { StubURLProtocol.install(id, handler) }
    var requests: [StubURLProtocol.Req] { StubURLProtocol.requests(id) }
    var dbRequests: [StubURLProtocol.Req] { requests.filter { $0.url.host == dbHost } }
}

private func signInReply(token: String = "ID1", refresh: String = "RF1", uid: String = "uid-1",
                         expiresIn: String = "3600") -> StubURLProtocol.Reply {
    .json(["idToken": token, "refreshToken": refresh, "localId": uid, "expiresIn": expiresIn])
}

private func refreshReply(token: String, refresh: String = "RF2", uid: String = "uid-1") -> StubURLProtocol.Reply {
    .json(["id_token": token, "refresh_token": refresh, "user_id": uid, "expires_in": "3600"])
}

/// Thread-safe collector for `child_added` callbacks.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(key: String, value: String)] = []
    func add(_ key: String, _ value: Any?) {
        let json = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? "nil"
        lock.lock(); items.append((key, json)); lock.unlock()
    }
    var all: [(key: String, value: String)] { lock.lock(); defer { lock.unlock() }; return items }
    var keys: [String] { all.map(\.key) }

    /// Poll until `count` callbacks have arrived (or time out and let the assertion fail).
    func wait(count: Int, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while all.count < count, Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

private func sse(_ event: String, _ path: String, _ data: Any?) -> Data {
    let payload = try! JSONSerialization.data(withJSONObject: ["path": path, "data": data ?? NSNull()],
                                              options: [.sortedKeys, .fragmentsAllowed])
    return Data("event: \(event)\ndata: \(String(decoding: payload, as: UTF8.self))\n\n".utf8)
}

// MARK: - Pure helpers

@Suite("RTDB REST — URLs and configuration")
struct RTDBRestURLTests {

    @Test("Only https database URLs are accepted; slashes and queries are normalised")
    func normalisation() {
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("https://x-default-rtdb.firebaseio.com")?.absoluteString
                == "https://x-default-rtdb.firebaseio.com")
        #expect(FirebaseRTDBClient.normalizedDatabaseURL(" https://x.firebaseio.com/// ")?.absoluteString
                == "https://x.firebaseio.com")
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("https://x.firebaseio.com/?auth=leak#frag")?.absoluteString
                == "https://x.firebaseio.com")
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("http://x.firebaseio.com") == nil)   // token rides in the URL
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("x.firebaseio.com") == nil)
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("") == nil)
        #expect(FirebaseRTDBClient.normalizedDatabaseURL("https://") == nil)
    }

    @Test("Request URLs are <base>/<path>.json?auth=…, with each component encoded on its own")
    func requestURLs() throws {
        let base = URL(string: "https://x.firebaseio.com")!
        #expect(FirebaseRTDBClient.requestURL(base: base, path: "sms/u1/devA", token: "T")?.absoluteString
                == "https://x.firebaseio.com/sms/u1/devA.json?auth=T")
        #expect(FirebaseRTDBClient.requestURL(base: base, path: "", token: "T")?.absoluteString
                == "https://x.firebaseio.com/.json?auth=T")
        #expect(FirebaseRTDBClient.requestURL(base: base, path: "/a//b/", token: "T")?.absoluteString
                == "https://x.firebaseio.com/a/b.json?auth=T")
        // A space or '?' in a key must not escape its path component.
        let odd = try #require(FirebaseRTDBClient.requestURL(base: base, path: "a b/c?d", token: "T"))
        #expect(odd.absoluteString == "https://x.firebaseio.com/a%20b/c%3Fd.json?auth=T")
        #expect(URLComponents(url: odd, resolvingAgainstBaseURL: false)?.queryItems?.count == 1)
    }

    @Test("Identity Toolkit errors map to plain-language messages")
    func authMessages() {
        func msg(_ code: String) -> String { FirebaseRTDBClient.authMessage(from: ["error": ["message": code]]) }
        #expect(msg("INVALID_LOGIN_CREDENTIALS").contains("Wrong email or password"))
        #expect(msg("EMAIL_NOT_FOUND").contains("Wrong email or password"))
        #expect(msg("OPERATION_NOT_ALLOWED").contains("Email/Password"))
        #expect(msg("TOO_MANY_ATTEMPTS_TRY_LATER").contains("Too many"))
        #expect(msg("API_KEY_INVALID").contains("API key"))
        #expect(msg("USER_DISABLED").contains("disabled"))
        #expect(msg("SOMETHING_NEW : with detail").contains("SOMETHING_NEW"))
        #expect(FirebaseRTDBClient.authMessage(from: [:]) == "Sign-in failed.")
    }

    @Test("RTDB HTTP errors map to actionable messages")
    func statusMessages() {
        #expect(FirebaseRTDBClient.message(forStatus: 401, body: Data()).contains("rules"))
        #expect(FirebaseRTDBClient.message(forStatus: 403, body: Data()).contains("rules"))
        #expect(FirebaseRTDBClient.message(forStatus: 404, body: Data()).contains("URL"))
        #expect(FirebaseRTDBClient.message(forStatus: 400, body: Data(#"{"error":"bad path"}"#.utf8)).contains("bad path"))
        #expect(FirebaseRTDBClient.message(forStatus: 500, body: Data()).contains("500"))
    }
}

@Suite("RTDB REST — streaming event model")
struct RTDBStreamModelTests {

    private func apply(_ event: String, _ path: String, _ data: Any?, _ model: inout [String: Any]) -> FirebaseRTDBClient.StreamOutcome {
        let payload = String(decoding: sse(event, path, data), as: UTF8.self)
            .components(separatedBy: "data: ")[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return FirebaseRTDBClient.apply(event: event, payload: payload, to: &model)
    }

    @Test("A root put becomes the model; a null root empties it")
    func rootPut() {
        var m: [String: Any] = [:]
        #expect(apply("put", "/", ["a": 1, "b": 2], &m) == .changed)
        #expect(Set(m.keys) == ["a", "b"])
        _ = apply("put", "/", nil, &m)
        #expect(m.isEmpty)
    }

    @Test("A put at /child adds, replaces and (with null) removes a child")
    func childPut() {
        var m: [String: Any] = ["a": 1]
        _ = apply("put", "/b", ["x": 1], &m)
        #expect(Set(m.keys) == ["a", "b"])
        _ = apply("put", "/a", 9, &m)
        #expect(m["a"] as? Int == 9)
        _ = apply("put", "/a", nil, &m)
        #expect(m["a"] == nil)
    }

    @Test("A deep put creates the missing parents; deleting the last leaf removes them")
    func deepPut() {
        var m: [String: Any] = [:]
        _ = apply("put", "/dev/lines/1", ["on": true], &m)
        #expect(((m["dev"] as? [String: Any])?["lines"] as? [String: Any])?["1"] != nil)
        _ = apply("put", "/dev/lines/1", nil, &m)
        #expect(m["dev"] == nil)                                   // empty objects don't exist in RTDB
    }

    @Test("A patch merges its keys under the path")
    func patch() {
        var m: [String: Any] = ["c": ["n": 1]]
        _ = apply("patch", "/c", ["n": 2, "m": 3], &m)
        let c = m["c"] as? [String: Any]
        #expect(c?["n"] as? Int == 2)
        #expect(c?["m"] as? Int == 3)
    }

    @Test("Control events: keep-alive is inert; cancel and auth_revoked are surfaced")
    func control() {
        var m: [String: Any] = ["a": 1]
        #expect(FirebaseRTDBClient.apply(event: "keep-alive", payload: "null", to: &m) == .unchanged)
        #expect(FirebaseRTDBClient.apply(event: "cancel", payload: "null", to: &m) == .cancelled)
        #expect(FirebaseRTDBClient.apply(event: "auth_revoked", payload: "\"x\"", to: &m) == .reauthenticate)
        #expect(FirebaseRTDBClient.apply(event: "put", payload: "garbage{", to: &m) == .unchanged)
        #expect(FirebaseRTDBClient.apply(event: "who-knows", payload: "{}", to: &m) == .unchanged)
        #expect(m["a"] as? Int == 1)
    }
}

// MARK: - Client against the stub network

@Suite("RTDB REST — auth and data")
struct RTDBRestClientTests {

    @Test("Sign-in posts the credential to Identity Toolkit only, and returns the uid")
    func signIn() async throws {
        let t = Tenant()
        t.install { req in req.url.host == "identitytoolkit.googleapis.com" ? signInReply(uid: "U-42") : .json(nil) }
        let c = t.client()
        try await c.configure(t.config)
        let uid = try await c.signIn(email: "me@example.com", password: "s3cret!")
        #expect(uid == "U-42")
        #expect(await c.uid == "U-42")

        let r = try #require(t.requests.first)
        #expect(r.method == "POST")
        #expect(r.url.path == "/v1/accounts:signInWithPassword")
        #expect(r.query("key") == t.id)
        let body = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        #expect(body["email"] as? String == "me@example.com")
        #expect(body["password"] as? String == "s3cret!")
        #expect(body["returnSecureToken"] as? Bool == true)
        // The password must never be sent anywhere but Google's identity host.
        #expect(t.dbRequests.isEmpty)
    }

    @Test("A bad password surfaces a plain-language auth error")
    func signInFailure() async throws {
        let t = Tenant()
        t.install { _ in .json(["error": ["code": 400, "message": "INVALID_LOGIN_CREDENTIALS"]], status: 400) }
        let c = t.client()
        try await c.configure(t.config)
        await #expect(throws: RTDBError.authFailed("Wrong email or password for this Firebase project.")) {
            try await c.signIn(email: "a@b.c", password: "nope")
        }
        #expect(await c.uid == nil)
    }

    @Test("Using the client before configure/sign-in throws notConfigured")
    func unconfigured() async {
        let c = Tenant().client()
        await #expect(throws: RTDBError.notConfigured) { try await c.signIn(email: "a", password: "b") }
        await #expect(throws: RTDBError.notConfigured) { _ = try await c.getValue(at: "x") }
        await #expect(throws: RTDBError.notConfigured) { try await c.setValue(1, at: "x") }
        await #expect(throws: RTDBError.notConfigured) { _ = try await c.observeChildAdded(at: "x") { _, _ in } }
    }

    @Test("configure rejects a plain-http or empty database URL / missing API key")
    func configureValidation() async {
        let c = Tenant().client()
        var cfg = Tenant().config
        cfg.databaseURL = "http://insecure.firebaseio.com"
        await #expect(throws: RTDBError.configureFailed) { try await c.configure(cfg) }
        cfg.databaseURL = "https://ok.firebaseio.com"; cfg.apiKey = ""
        await #expect(throws: RTDBError.configureFailed) { try await c.configure(cfg) }
    }

    @Test("set / get / remove hit <db>/<path>.json with the ID token and the right verbs")
    func crud() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply(token: "TOK") }
            switch req.method {
            case "GET":    return .json(["n": 7])
            default:       return .json(nil)
            }
        }
        let c = t.client()
        try await c.configure(t.config)
        try await c.signIn(email: "a", password: "b")

        try await c.setValue(["addressEnc": "v1:abc", "ts": 5], at: "sms/u1/devA/messages/m1")
        let got = try await c.getValue(at: "sms/u1/devA")
        try await c.removeValue(at: "sms/u1")

        #expect((got as? [String: Any])?["n"] as? Int == 7)
        let calls = t.dbRequests
        #expect(calls.map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(calls[0].url.path == "/sms/u1/devA/messages/m1.json")
        #expect(calls.allSatisfy { $0.query("auth") == "TOK" })
        let body = try #require(try JSONSerialization.jsonObject(with: calls[0].body) as? [String: Any])
        #expect(body["addressEnc"] as? String == "v1:abc")
        #expect(calls[0].headers["Content-Type"] == "application/json")
    }

    @Test("A missing node reads as nil; a scalar reads as a scalar")
    func readsNullAndScalars() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            return req.url.path.hasSuffix("missing.json") ? .text("null") : .text("\"hello\"")
        }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        #expect(try await c.getValue(at: "missing") == nil)
        #expect(try await c.getValue(at: "greeting") as? String == "hello")
    }

    @Test("Permission-denied is reported with the rules hint, after one token renewal")
    func permissionDenied() async throws {
        let t = Tenant()
        t.install { req in
            switch req.url.host {
            case "identitytoolkit.googleapis.com": return signInReply(token: "OLD")
            case "securetoken.googleapis.com":     return refreshReply(token: "NEW")
            default:                               return .json(["error": "Permission denied"], status: 401)
            }
        }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        do { _ = try await c.getValue(at: "x"); Issue.record("expected a throw") }
        catch let e as RTDBError { #expect(e.errorDescription?.contains("rules") == true) }

        // First try with OLD, renew, one retry with NEW — then give up (no infinite loop).
        #expect(t.dbRequests.compactMap { $0.query("auth") } == ["OLD", "NEW"])
    }

    @Test("A 401 from a token that just expired is renewed and retried transparently")
    func renewOn401() async throws {
        let t = Tenant()
        t.install { req in
            switch req.url.host {
            case "identitytoolkit.googleapis.com": return signInReply(token: "OLD")
            case "securetoken.googleapis.com":     return refreshReply(token: "NEW")
            default: return req.query("auth") == "NEW" ? .json(["ok": true]) : .json(["error": "Auth token is expired"], status: 401)
            }
        }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        let v = try await c.getValue(at: "x")
        #expect((v as? [String: Any])?["ok"] as? Bool == true)
        let refresh = try #require(t.requests.first { $0.url.host == "securetoken.googleapis.com" })
        #expect(refresh.bodyString == "grant_type=refresh_token&refresh_token=RF1")
        #expect(refresh.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test("A token near expiry is renewed before the request, not after a failure")
    func proactiveRenewal() async throws {
        let t = Tenant()
        t.install { req in
            switch req.url.host {
            case "identitytoolkit.googleapis.com": return signInReply(token: "SHORT", expiresIn: "60")   // inside the 120 s skew
            case "securetoken.googleapis.com":     return refreshReply(token: "FRESH")
            default:                               return .json(["ok": true])
            }
        }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        _ = try await c.getValue(at: "x")
        #expect(t.dbRequests.compactMap { $0.query("auth") } == ["FRESH"])      // SHORT was never used
    }

    @Test("If the refresh token is refused, the client signs in again from the in-memory credential")
    func reSignInFallback() async throws {
        let t = Tenant()
        let signIns = Counter()
        t.install { req in
            switch req.url.host {
            case "identitytoolkit.googleapis.com":
                return signInReply(token: signIns.next() == 1 ? "FIRST" : "SECOND", expiresIn: "60")
            case "securetoken.googleapis.com":
                return .json(["error": ["message": "TOKEN_EXPIRED"]], status: 400)
            default:
                return .json(["ok": true])
            }
        }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        _ = try await c.getValue(at: "x")
        #expect(t.dbRequests.compactMap { $0.query("auth") } == ["SECOND"])
        #expect(signIns.value == 2)
    }

    @Test("Re-configuring with the same config keeps the session; a different config drops it")
    func reconfigure() async throws {
        let t = Tenant()
        t.install { _ in signInReply(uid: "U1") }
        let c = t.client()
        try await c.configure(t.config)
        try await c.signIn(email: "a", password: "b")
        try await c.configure(t.config)                       // SMSSync and ClipboardSync both do this
        #expect(await c.uid == "U1")

        var other = t.config; other.databaseURL = "https://other-\(t.id).firebaseio.com"
        try await c.configure(other)
        #expect(await c.uid == nil)
        #expect(await c.isConfigured)
    }

    @Test("signOut forgets the session but stays configured")
    func signOut() async throws {
        let t = Tenant()
        t.install { _ in signInReply() }
        let c = t.client()
        try await c.configure(t.config); try await c.signIn(email: "a", password: "b")
        await c.signOut()
        #expect(await c.uid == nil)
        #expect(await c.isConfigured)
        await #expect(throws: RTDBError.notConfigured) { _ = try await c.getValue(at: "x") }
    }

    @Test("testConnection round-trips a probe under meta/{uid}, cleans up, and leaves the live client untouched")
    func connectionTestHappyPath() async throws {
        let t = Tenant()
        let stored = Box()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply(uid: "U9") }
            switch req.method {
            case "PUT":    stored.set(req.bodyString); return .json(nil)
            case "GET":    return .text(stored.get())
            default:       stored.set("null"); return .json(nil)
            }
        }
        let c = t.client()
        try await c.testConnection(t.config, email: "a", password: "b")
        let db = t.dbRequests
        #expect(db.map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(db.allSatisfy { $0.url.path == "/meta/U9/_haloTest.json" })
        #expect(await c.uid == nil)                          // the probe used a throwaway client
        #expect(await !c.isConfigured)
    }

    @Test("testConnection fails clearly when the rules swallow the write")
    func connectionTestRulesProblem() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            return req.method == "GET" ? .text("null") : .json(nil)        // write 'succeeds', read-back is empty
        }
        let c = t.client()
        do { try await c.testConnection(t.config, email: "a", password: "b"); Issue.record("expected a throw") }
        catch let e as RTDBError { #expect(e.errorDescription?.contains("Round-trip mismatch") == true) }
    }

    @Test("testConnection surfaces a credential failure before touching the database")
    func connectionTestBadCredential() async throws {
        let t = Tenant()
        t.install { _ in .json(["error": ["message": "INVALID_LOGIN_CREDENTIALS"]], status: 400) }
        let c = t.client()
        await #expect(throws: RTDBError.self) { try await c.testConnection(t.config, email: "a", password: "x") }
        #expect(t.dbRequests.isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var s = "null"
    func set(_ v: String) { lock.lock(); s = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return s }
}

// MARK: - Live streaming

@Suite("RTDB REST — child_added streaming")
struct RTDBRestStreamingTests {

    private func connected(_ t: Tenant) async throws -> FirebaseRTDBClient {
        let c = t.client()
        try await c.configure(t.config)
        try await c.signIn(email: "a", password: "b")
        return c
    }

    @Test("Existing children are delivered first, then new ones as they appear")
    func deliversExistingThenNew() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply(token: "TOK") }
            return StubURLProtocol.Reply(chunks: [
                sse("put", "/", ["a": ["v": 1], "b": ["v": 2]]),
                sse("keep-alive", "/", nil),
                sse("put", "/c", ["v": 3]),
                sse("patch", "/c", ["v": 4]),            // an update to a known child: no new callback
                sse("put", "/a/v", 10),                  // same
            ], keepOpen: true)
        }
        let c = try await connected(t)
        let seen = Seen()
        let h = try await c.observeChildAdded(at: "sms/u1") { k, v in seen.add(k, v) }
        await seen.wait(count: 3)
        // Give any wrongly-emitted duplicate a moment to show up.
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(seen.keys == ["a", "b", "c"])
        #expect(seen.all[0].value == #"{"v":1}"#)
        #expect(seen.all[2].value == #"{"v":3}"#)

        let req = try #require(t.dbRequests.first { $0.isStream })
        #expect(req.method == "GET")
        #expect(req.url.path == "/sms/u1.json")
        #expect(req.query("auth") == "TOK")
        await c.removeObserver(at: "sms/u1", handle: h)
    }

    @Test("A child removed and then re-added fires again; one that merely changed does not")
    func removeAndReadd() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            return StubURLProtocol.Reply(chunks: [
                sse("put", "/", ["a": 1]),
                sse("put", "/a", nil),                   // removed
                sse("put", "/a", 2),                     // back
                sse("put", "/a", 3),                     // changed in place
            ], keepOpen: true)
        }
        let c = try await connected(t)
        let seen = Seen()
        let h = try await c.observeChildAdded(at: "p") { k, v in seen.add(k, v) }
        await seen.wait(count: 2)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(seen.all.map(\.key) == ["a", "a"])
        #expect(seen.all.map(\.value) == ["1", "2"])
        await c.removeObserver(at: "p", handle: h)
    }

    @Test("After a dropped connection it reconnects and does not re-deliver what it already reported")
    func reconnectDoesNotRedeliver() async throws {
        let t = Tenant()
        let streams = Counter()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            if streams.next() == 1 {
                return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1])], keepOpen: false)   // server hangs up
            }
            return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1, "b": 2])], keepOpen: true)
        }
        let c = try await connected(t)
        let seen = Seen()
        let h = try await c.observeChildAdded(at: "p") { k, v in seen.add(k, v) }
        await seen.wait(count: 2, timeout: 8)               // includes the ~1 s reconnect backoff
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(seen.keys == ["a", "b"])                    // "a" exactly once
        #expect(streams.value >= 2)
        await c.removeObserver(at: "p", handle: h)
    }

    @Test("auth_revoked renews the session and reconnects with a fresh token")
    func authRevoked() async throws {
        let t = Tenant()
        let streams = Counter()
        t.install { req in
            switch req.url.host {
            case "identitytoolkit.googleapis.com": return signInReply(token: "OLD")
            case "securetoken.googleapis.com":     return refreshReply(token: "NEW")
            default:
                if streams.next() == 1 {
                    return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1]), sse("auth_revoked", "/", "expired")], keepOpen: true)
                }
                return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1, "b": 2])], keepOpen: true)
            }
        }
        let c = try await connected(t)
        let seen = Seen()
        let h = try await c.observeChildAdded(at: "p") { k, v in seen.add(k, v) }
        await seen.wait(count: 2, timeout: 8)
        #expect(seen.keys == ["a", "b"])
        #expect(t.dbRequests.filter(\.isStream).compactMap { $0.query("auth") } == ["OLD", "NEW"])
        await c.removeObserver(at: "p", handle: h)
    }

    @Test("removeObserver hangs up the connection and stops delivery")
    func removeObserverStops() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1]), sse("put", "/b", 2)],
                                         chunkDelay: 0.3, keepOpen: true)
        }
        let c = try await connected(t)
        let seen = Seen()
        let h = try await c.observeChildAdded(at: "p") { k, v in seen.add(k, v) }
        await seen.wait(count: 1)
        await c.removeObserver(at: "p", handle: h)

        let end = Date().addingTimeInterval(3)
        while StubURLProtocol.hangupCount(t.id) == 0, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(StubURLProtocol.hangupCount(t.id) >= 1)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(seen.keys == ["a"])                         // "b" was still in flight when we hung up
    }

    @Test("signOut tears down every live subscription")
    func signOutStopsObservers() async throws {
        let t = Tenant()
        t.install { req in
            if req.url.host == "identitytoolkit.googleapis.com" { return signInReply() }
            return StubURLProtocol.Reply(chunks: [sse("put", "/", ["a": 1])], keepOpen: true)
        }
        let c = try await connected(t)
        let seen = Seen()
        _ = try await c.observeChildAdded(at: "p") { k, v in seen.add(k, v) }
        _ = try await c.observeChildAdded(at: "q") { k, v in seen.add(k, v) }
        await seen.wait(count: 2)
        await c.signOut()
        let end = Date().addingTimeInterval(3)
        while StubURLProtocol.hangupCount(t.id) < 2, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(StubURLProtocol.hangupCount(t.id) >= 2)
    }
}
