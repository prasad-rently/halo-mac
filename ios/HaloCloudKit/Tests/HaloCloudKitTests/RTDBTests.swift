import XCTest
@testable import HaloCloudKit

final class RTDBTests: XCTestCase {
    func cfg(_ url: String = "https://p-default-rtdb.firebaseio.com") -> FirebaseConfig {
        FirebaseConfig(apiKey: "k", projectID: "p", googleAppID: "a", gcmSenderID: "g", databaseURL: url)
    }
    let cred = CloudAuthCredential(email: "e@x.test", password: "pw")

    // MARK: SSE model

    func testPutAndPatchFoldIntoTheModel() {
        var m: [String: JSONValue] = [:]
        XCTAssertEqual(FirebaseRTDB.apply(event: "put", payload: #"{"path":"/","data":{"a":{"v":1},"b":{"v":2}}}"#, to: &m), .changed)
        XCTAssertEqual(Set(m.keys), ["a", "b"])
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/a/v","data":9}"#, to: &m)
        XCTAssertEqual(m["a"]?["v"]?.intValue, 9)
        _ = FirebaseRTDB.apply(event: "patch", payload: #"{"path":"/b","data":{"w":3}}"#, to: &m)
        XCTAssertEqual(m["b"]?["w"]?.intValue, 3)
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/a","data":null}"#, to: &m)
        XCTAssertNil(m["a"])
        XCTAssertEqual(FirebaseRTDB.apply(event: "keep-alive", payload: "null", to: &m), .unchanged)
        XCTAssertEqual(FirebaseRTDB.apply(event: "auth_revoked", payload: "\"x\"", to: &m), .reauthenticate)
        XCTAssertEqual(FirebaseRTDB.apply(event: "cancel", payload: "null", to: &m), .cancelled)
    }

    /// Real Firebase renders {"1":…,"2":…} as an ARRAY with a null hole — a reader that only takes objects loses
    /// every SIM line on a two-SIM phone. (The stand-in always returns objects, so only a unit test can see this.)
    func testArrayShapedSnapshotsKeepIntegerKeyedChildren() {
        var m: [String: JSONValue] = [:]
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/","data":[null,{"label":"Personal"},{"label":"Work"}]}"#, to: &m)
        XCTAssertEqual(Set(m.keys), ["1", "2"])
        XCTAssertEqual(m["2"]?["label"]?.stringValue, "Work")
        let l = SMSWire.decodeLine(deviceId: "d", key: "2", node: m["2"], crypto: try! CryptoService(passphrase: "x", salt: Data(count: 16).map { _ in 1 }.withUnsafeBytes { Data($0) }, iterations: 100_000))
        XCTAssertEqual(l.subscriptionId, 2)
    }

    // MARK: Requests

    func testRequestURLEncodesEachComponentAndCarriesAuth() {
        let u = FirebaseRTDB.requestURL(base: URL(string: "https://h.example")!, path: "sms/u1/d 1/messages/4201_17", token: "T")!
        XCTAssertEqual(u.absoluteString, "https://h.example/sms/u1/d%201/messages/4201_17.json?auth=T")
        XCTAssertEqual(FirebaseRTDB.requestURL(base: URL(string: "https://h.example")!, path: "", token: "T")!.absoluteString, "https://h.example/.json?auth=T")
        // a "/" smuggled inside a key cannot become a path separator
        XCTAssertEqual(FirebaseRTDB.requestURL(base: URL(string: "https://h.example")!, path: "a/..%2Fb", token: "T")!.path, "/a/..%2Fb.json")
    }

    func testPlainHTTPDatabaseIsRefusedByTheClient() {
        XCTAssertThrowsError(try FirebaseRTDB(config: cfg("http://p.firebaseio.com"), credential: cred))
        XCTAssertThrowsError(try FirebaseRTDB(config: cfg("http://127.0.0.1:1"), credential: cred), "loopback http only with the debug opt-in")
        XCTAssertNoThrow(try FirebaseRTDB(config: cfg("http://127.0.0.1:1"), credential: cred, allowLoopbackHTTP: true))
    }

    func testExpiredTokenIsRenewedOnceThenRetried() async throws {
        let n = Counter()
        let t = StubTransport { req in
            if req.url!.path.hasSuffix("accounts:signInWithPassword") { return (Data(#"{"idToken":"id-a","refreshToken":"r","localId":"u","expiresIn":"3600"}"#.utf8), 200) }
            if req.url!.path.hasSuffix("/token") { return (Data(#"{"id_token":"id-b","refresh_token":"r2","user_id":"u","expires_in":"3600"}"#.utf8), 200) }
            let tok = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "auth" }!.value!
            if tok == "id-a" { n.bump(); return (Data("{}".utf8), 401) }
            return (Data(#"{"ok":true}"#.utf8), 200)
        }
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: t)
        let v = try await db.get("x/y")
        XCTAssertEqual(v["ok"]?.boolValue, true)
        XCTAssertEqual(n.value, 1, "one 401, one renewal, one retry")
    }

    // SECURITY: a failure must never put a URL, token or password in the message shown to the user.
    func testErrorsNeverCarryTokensOrURLs() async throws {
        let t = StubTransport { req in
            if req.url!.path.hasSuffix("accounts:signInWithPassword") { return (Data(#"{"idToken":"SECRET-ID-TOKEN","refreshToken":"r","localId":"u","expiresIn":"3600"}"#.utf8), 200) }
            return (Data(#"{"error":"Permission denied https://p.firebaseio.com/x.json?auth=SECRET-ID-TOKEN"}"#.utf8), 403)
        }
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: t)
        do { _ = try await db.get("a"); XCTFail() } catch {
            let m = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(m.contains("SECRET-ID-TOKEN")); XCTAssertFalse(m.contains("auth=")); XCTAssertFalse(m.contains("https://"))
            XCTAssertTrue(m.contains("Permission denied"))
        }
        XCTAssertEqual(FirebaseRTDB.authMessage(from: ["error": .object(["message": .string("INVALID_LOGIN_CREDENTIALS")])]), "Wrong email or password for this Firebase project.")
    }

    func testTransportErrorIsOpaqueNetworkError() async throws {
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: StubTransport { _ in throw CloudError.network })
        do { _ = try await db.uid(); XCTFail() } catch { XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("reach Google") == true) }
    }

    // MARK: Stream (stubbed SSE)

    func testStreamDeliversAddsChangesAndRemovalsAndReconnectsWithoutRedelivering() async throws {
        let t = StubTransport { _ in (Data(#"{"idToken":"id-a","refreshToken":"r","localId":"u","expiresIn":"3600"}"#.utf8), 200) }
        let attempts = Counter()
        t.streamHandler = { _ in
            let n = attempts.bump()
            if n == 1 {
                return (200, ["event: put", #"data: {"path":"/","data":{"a":{"v":1}}}"#,
                              "event: put", #"data: {"path":"/b","data":{"v":2}}"#,
                              "event: put", #"data: {"path":"/a/v","data":5}"#,
                              "event: put", #"data: {"path":"/b","data":null}"#])      // then the connection ends
            }
            return (200, ["event: put", #"data: {"path":"/","data":{"a":{"v":5},"c":{"v":3}}}"#])   // after the reconnect: a unchanged, c new
        }
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: t, minBackoff: 0.01, maxBackoff: 0.02)
        var events: [ChildEvent] = []
        for await e in db.observeChildren("x") {
            events.append(e)
            if events.contains(.added(key: "c", value: json(#"{"v":3}"#))) { break }
        }
        XCTAssertEqual(events.filter { if case .added(let k, _) = $0 { return k == "a" } else { return false } }.count, 2, "a added, then changed 1 -> 5; NOT re-delivered after reconnect")
        XCTAssertTrue(events.contains(.removed(key: "b")))
        XCTAssertTrue(events.contains(.disconnected))
        XCTAssertGreaterThanOrEqual(attempts.value, 2)
    }

    func testStreamEndsWhenTheConsumerStopsAndDoesNotKeepRetrying() async throws {
        let t = StubTransport { _ in (Data(#"{"idToken":"id-a","refreshToken":"r","localId":"u","expiresIn":"3600"}"#.utf8), 200) }
        let attempts = Counter()
        t.streamHandler = { _ in _ = attempts.bump(); return (200, ["event: keep-alive", "data: null"]) }
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: t, minBackoff: 0.01, maxBackoff: 0.01)
        let task = Task { for await _ in db.observeChildren("x") {} }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        _ = await task.value
        try await Task.sleep(nanoseconds: 80_000_000)      // let the in-flight attempt (if any) settle
        let after = attempts.value
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts.value, after, "cancelled: no further reconnect attempts")
    }

    func testRefusedStreamBacksOffAndRetries() async throws {
        let t = StubTransport { _ in (Data(#"{"idToken":"id-a","refreshToken":"r","localId":"u","expiresIn":"3600"}"#.utf8), 200) }
        let attempts = Counter()
        t.streamHandler = { _ in let n = attempts.bump(); return n < 3 ? (403, []) : (200, ["event: put", #"data: {"path":"/","data":{"k":{"v":1}}}"#]) }
        let db = try FirebaseRTDB(config: cfg(), credential: cred, transport: t, minBackoff: 0.01, maxBackoff: 0.02)
        for await e in db.observeChildren("x") { if case .added = e { break } }
        XCTAssertGreaterThanOrEqual(attempts.value, 3)
    }
}

final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    @discardableResult func bump() -> Int { l.withLock { n += 1; return n } }
    var value: Int { l.withLock { n } }
}
