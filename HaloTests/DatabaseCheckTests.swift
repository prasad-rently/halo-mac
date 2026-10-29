import Testing
import Foundation
@testable import Halo

// F-057 — the Cloud setup assistant: FR-S1 (database check), FR-S3 (pairing code hides), FR-S4 (devices / retire).
// Everything here is stubbed: NOT verified against real Firebase.

// MARK: - Scripted transport

private final class StubTransport: DatabaseProbeTransport, @unchecked Sendable {
    private let lock = NSLock()
    let uid = "uid-1"
    var signInResult: () throws -> DatabaseCheckSignIn = { .ok(uid: "uid-1") }
    var denyWrite: Set<String> = [], denyRead: Set<String> = [], denyDelete: Set<String> = []
    var mismatchOnRead = false
    var notFound = false
    var publicStatus = 401
    var dropOn: String?
    var dropFromRoot: String?
    private var store: [String: String] = [:]
    private var logged: [String] = []

    var log: [String] { lock.lock(); defer { lock.unlock() }; return logged }
    var leftover: [String: String] { lock.lock(); defer { lock.unlock() }; return store }

    func signIn() async throws -> DatabaseCheckSignIn { try signInResult() }
    func unauthenticatedStatus() async throws -> Int { publicStatus }

    func request(method: String, path: String, body: String?) async throws -> DatabaseProbeResponse {
        lock.lock(); defer { lock.unlock() }
        logged.append("\(method) \(path)")
        let root = String(path.split(separator: "/").first ?? "")
        if dropOn == method, dropFromRoot == nil || dropFromRoot == root {
            if method == "PUT" { store[path] = body }          // the request landed, the response didn't
            throw DatabaseProbeNetworkError()
        }
        if notFound { return .init(status: 404, body: "{\"error\":\"Not found\"}") }
        switch method {
        case "PUT":
            if denyWrite.contains(root) { return .init(status: 401, body: "{\"error\":\"Permission denied\"}") }
            store[path] = body; return .init(status: 200, body: body ?? "")
        case "GET":
            if denyRead.contains(root) { return .init(status: 401, body: "{\"error\":\"Permission denied\"}") }
            return .init(status: 200, body: mismatchOnRead ? "\"other\"" : (store[path] ?? "null"))
        case "DELETE":
            if denyDelete.contains(root) { return .init(status: 401, body: "{\"error\":\"Permission denied\"}") }
            store[path] = nil; return .init(status: 200, body: "null")
        default: return .init(status: 400, body: "")
        }
    }
}

private func check(_ t: StubTransport, url: String = "https://demo-default-rtdb.firebaseio.com") async -> DatabaseCheckReport {
    await DatabaseCheckEngine(transport: t, databaseURL: url, nonce: { "n0nce" }).run()
}

@Suite("F-057 FR-S1 — database check engine")
struct DatabaseCheckEngineTests {

    @Test("A healthy database passes every path and leaves nothing behind")
    func healthy() async {
        let t = StubTransport()
        let r = await check(t)
        #expect(r.overall == .pass)
        for root in ["meta", "devices", "sms", "clipboard"] {
            #expect(t.log.contains { $0.hasPrefix("PUT \(root)/uid-1/_haloCheck_") })
            #expect(t.log.contains { $0.hasPrefix("GET \(root)/uid-1/_haloCheck_") })
            #expect(t.log.contains { $0.hasPrefix("DELETE \(root)/uid-1/_haloCheck_") })
        }
        #expect(t.leftover.isEmpty)
    }

    @Test("The real v2.5 defect: clipboard rules missing is reported on clipboard alone, with the fix")
    func clipboardDenied() async {
        let t = StubTransport(); t.denyWrite = ["clipboard"]; t.denyRead = ["clipboard"]
        let r = await check(t)
        #expect(r.overall == .fail)
        #expect(r.item(.meta).status == .pass)
        #expect(r.item(.devices).status == .pass)
        #expect(r.item(.sms).status == .pass)
        let clip = r.item(.clipboard)
        #expect(clip.status == .fail)
        #expect(clip.problem == .permissionDenied)
        #expect(clip.detail.contains("clipboard/{uid}"))
        #expect(clip.fix?.contains("docs/specs/firebase-rules.json") == true)
        #expect(t.leftover.isEmpty)
    }

    @Test("A refused write issues no delete (nothing landed)")
    func refusedWriteNoDelete() async {
        let t = StubTransport(); t.denyWrite = ["meta"]
        _ = await check(t)
        #expect(!t.log.contains { $0.hasPrefix("DELETE meta/") })
    }

    @Test("Write allowed but read denied: fails, and the probe is cleaned up")
    func readDeniedCleansUp() async {
        let t = StubTransport(); t.denyRead = ["sms"]
        let r = await check(t)
        #expect(r.item(.sms).problem == .readDenied)
        #expect(t.leftover.isEmpty)
    }

    @Test("Read-back mismatch fails and the probe is cleaned up")
    func mismatchCleansUp() async {
        let t = StubTransport(); t.mismatchOnRead = true
        let r = await check(t)
        #expect(r.item(.meta).problem == .readBackMismatch)
        #expect(t.leftover.isEmpty)
    }

    @Test("A network drop while reading still deletes the probe, and later paths are skipped")
    func dropWhileReadingCleansUp() async {
        let t = StubTransport(); t.dropOn = "GET"; t.dropFromRoot = "devices"
        let r = await check(t)
        #expect(r.item(.devices).problem == .network)
        #expect(t.log.contains { $0.hasPrefix("DELETE devices/") })
        #expect(t.leftover.isEmpty)
        #expect(r.item(.sms).status == .skipped)
        #expect(r.item(.clipboard).status == .skipped)
    }

    @Test("A network drop while writing tries to remove a probe that may have landed")
    func dropWhileWriting() async {
        let t = StubTransport(); t.dropOn = "PUT"; t.dropFromRoot = "meta"
        _ = await check(t)
        #expect(t.log.contains { $0.hasPrefix("DELETE meta/") })
        #expect(t.leftover.isEmpty)
    }

    @Test("A probe that cannot be deleted is a warning that names it")
    func cleanupFailed() async {
        let t = StubTransport(); t.denyDelete = ["clipboard"]
        let r = await check(t)
        let clip = r.item(.clipboard)
        #expect(clip.status == .warn)
        #expect(clip.problem == .cleanupFailed)
        #expect(clip.detail.contains("_haloCheck_n0nce"))
        #expect(r.overall == .warn)
    }

    @Test("404 means wrong URL or region; the rest is skipped")
    func wrongRegion() async {
        let t = StubTransport(); t.notFound = true
        let r = await check(t)
        #expect(r.item(.databaseURL).problem == .databaseNotFound)
        #expect(r.item(.databaseURL).fix?.contains("firebasedatabase.app") == true)
        #expect(r.item(.clipboard).status == .skipped)
        #expect(r.item(.publicAccess).status == .skipped)
        #expect(t.log.filter { $0.hasPrefix("PUT") }.count == 1)
    }

    @Test("Email/Password disabled is named, no path is tried, open rules are still detected")
    func emailPasswordDisabled() async {
        let t = StubTransport(); t.signInResult = { .rejected(code: "OPERATION_NOT_ALLOWED") }; t.publicStatus = 200
        let r = await check(t)
        #expect(r.item(.signIn).problem == .emailPasswordDisabled)
        #expect(r.item(.signIn).fix?.contains("Sign-in method") == true)
        #expect(r.item(.meta).status == .skipped)
        #expect(t.log.isEmpty)
        #expect(r.item(.publicAccess).problem == .openRules)
    }

    @Test("Other sign-in refusals map to distinct problems; a network failure is not 'wrong password'")
    func otherSignInRefusals() async {
        func problem(_ code: String) async -> DatabaseCheckProblem {
            let t = StubTransport(); t.signInResult = { .rejected(code: code) }
            return await check(t).item(.signIn).problem
        }
        #expect(await problem("INVALID_LOGIN_CREDENTIALS") == .badCredentials)
        #expect(await problem("API_KEY_INVALID") == .badAPIKey)
        #expect(await problem("USER_DISABLED") == .accountDisabled)
        #expect(await problem("SOMETHING_NEW") == .unexpected)
        let t = StubTransport(); t.signInResult = { throw DatabaseProbeNetworkError() }
        #expect(await check(t).item(.signIn).problem == .network)
    }

    @Test("Open rules are a warning with the fix")
    func openRules() async {
        let t = StubTransport(); t.publicStatus = 200
        let r = await check(t)
        #expect(r.item(.publicAccess).problem == .openRules)
        #expect(r.overall == .warn)
        #expect(r.item(.publicAccess).fix?.contains("firebase-rules.json") == true)
    }

    @Test("A malformed or plain-http URL stops before any network use")
    func malformedURL() async {
        let t = StubTransport()
        let r = await check(t, url: "http://insecure.example.com")
        #expect(r.item(.databaseURL).problem == .invalidURL)
        #expect(t.log.isEmpty)
    }

    @Test("The report never contains the password, API key, token, email or the concrete uid")
    func noSecrets() async {
        let t = StubTransport(); t.denyWrite = ["clipboard"]; t.publicStatus = 200
        let r = await check(t)
        let text = "\(r)" + r.items.map { $0.title + $0.detail + ($0.fix ?? "") }.joined()
        for secret in ["hunter2-pass", "API-KEY-SECRET", "ID-TOKEN-SECRET", "me@x.io", "passphrase", "uid-1"] {
            #expect(!text.localizedCaseInsensitiveContains(secret), "\(secret)")
        }
    }
}

// MARK: - Live transport over a stubbed URLSession

@Suite("F-057 FR-S1 — live transport (stubbed URLSession)")
struct DatabaseCheckLiveTransportTests {

    @Test("Finds the clipboard rule gap over HTTP; password only goes to the Google host; the anonymous probe carries no token")
    func clipboardGapOverHTTP() async throws {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let dbHost = "\(id).firebaseio.com"
        let config = FirebaseConfig(apiKey: id, projectID: "p", googleAppID: "1:1:ios:a", gcmSenderID: "1", databaseURL: "https://\(dbHost)", storageBucket: nil)
        final class Data_: @unchecked Sendable { let lock = NSLock(); var data: [String: String] = [:] }
        let box = Data_()
        StubURLProtocol.install(id) { req in
            if req.url.host?.hasSuffix("googleapis.com") == true {
                return .json(["idToken": "ID-TOKEN-SECRET", "refreshToken": "r", "localId": "uid-9", "expiresIn": "3600"])
            }
            guard let token = req.query("auth") else { return .json(["error": "Permission denied"], status: 401) }
            guard token == "ID-TOKEN-SECRET" else { return .json([:], status: 401) }
            let path = String(req.url.path.dropFirst().dropLast(5))     // strip leading "/" and ".json"
            if path.hasPrefix("clipboard/") { return .json(["error": "Permission denied"], status: 401) }
            box.lock.lock(); defer { box.lock.unlock() }
            switch req.method {
            case "PUT": box.data[path] = req.bodyString; return .text(req.bodyString)
            case "GET": return .text(box.data[path] ?? "null")
            case "DELETE": box.data[path] = nil; return .text("null")
            default: return .text("", status: 405)
            }
        }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        let transport = LiveDatabaseProbeTransport(config: config, credential: CloudAuthCredential(email: "me@x.io", password: "hunter2-pass"), session: URLSession(configuration: c))
        let r = await DatabaseCheckEngine(transport: transport, databaseURL: config.databaseURL).run()

        #expect(r.item(.meta).status == .pass)
        #expect(r.item(.sms).status == .pass)
        #expect(r.item(.clipboard).problem == .permissionDenied)
        #expect(r.item(.publicAccess).status == .pass)
        box.lock.lock(); #expect(box.data.isEmpty); box.lock.unlock()

        let all = StubURLProtocol.requests(id)
        let anonymous = all.filter { $0.url.host == dbHost && $0.query("auth") == nil }
        #expect(anonymous.count == 1 && anonymous[0].query("shallow") == "true")
        #expect(all.filter { $0.url.host?.hasSuffix("googleapis.com") == true }.allSatisfy { $0.bodyString.contains("hunter2-pass") })
        #expect(!all.filter { $0.url.host == dbHost }.contains { $0.bodyString.contains("hunter2") || $0.url.absoluteString.contains("hunter2") })
    }
}

// MARK: - FR-S3 pairing code

/// A clock the test advances by hand. Fires due timers in order; honours cancellation.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    private var timers: [(id: Int, at: Date, action: @MainActor () -> Void, cancelled: Bool)] = []
    private var nextID = 0

    var schedule: PairingCodeSession.Schedule {
        { [self] after, action in
            lock.lock(); let id = nextID; nextID += 1
            timers.append((id, now.addingTimeInterval(after), action, false)); lock.unlock()
            return { [self] in lock.lock(); if let i = timers.firstIndex(where: { $0.id == id }) { timers[i].cancelled = true }; lock.unlock() }
        }
    }

    @MainActor func advance(_ seconds: TimeInterval) {
        lock.lock(); now = now.addingTimeInterval(seconds)
        let due = timers.filter { !$0.cancelled && $0.at <= now }
        for d in due { if let i = timers.firstIndex(where: { $0.id == d.id }) { timers[i].cancelled = true } }
        lock.unlock()
        for d in due.sorted(by: { $0.at < $1.at }) { d.action() }
    }
}

@MainActor
@Suite("F-057 FR-S3 — pairing code auto-hide")
struct PairingCodeSessionTests {

    private func make(_ clock: ManualClock, generated: @escaping () -> String? = { "CODE-A" }) -> PairingCodeSession {
        PairingCodeSession(lifetime: 60, generate: generated, schedule: clock.schedule, now: { clock.now })
    }

    @Test("Hides itself after 60 seconds, not before")
    func hidesAfter60() {
        let clock = ManualClock(); let s = make(clock)
        s.show()
        #expect(s.code == "CODE-A")
        clock.advance(59)
        #expect(s.code == "CODE-A")
        #expect(s.secondsRemaining(at: clock.now) == 1)
        clock.advance(1)
        #expect(s.code == nil)
        #expect(s.expired)
        #expect(s.hidesAt == nil)
    }

    @Test("Regenerated on demand: a new code is built each time and the old timer cannot hide the new one")
    func regenerates() {
        let clock = ManualClock(); var n = 0
        let s = make(clock) { n += 1; return "CODE-\(n)" }
        s.show(); #expect(s.code == "CODE-1")
        clock.advance(40)
        s.show(); #expect(s.code == "CODE-2")           // rebuilt, not cached
        clock.advance(30)                                // 70 s after the first show, 30 s after the second
        #expect(s.code == "CODE-2")
        clock.advance(30)
        #expect(s.code == nil)
        s.show(); #expect(s.code == "CODE-3"); #expect(!s.expired)
    }

    @Test("Hide cancels the timer and is not reported as an expiry")
    func manualHide() {
        let clock = ManualClock(); let s = make(clock)
        s.show(); s.hide()
        #expect(s.code == nil); #expect(!s.expired)
        clock.advance(120)
        #expect(!s.expired)
    }

    @Test("Nothing to pair yet: no code, flagged unavailable, no timer")
    func unavailable() {
        let clock = ManualClock(); let s = make(clock) { nil }
        s.show()
        #expect(s.code == nil); #expect(s.unavailable)
        clock.advance(120)
        #expect(!s.expired)
    }

    @Test("The code reaches no log, UserDefaults, AppStorage or AlertLog sink (source audit)")
    func noSinks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Halo/Core/Cloud/PairingCodeSession.swift", "Halo/Features/SMSConsole/CloudSettingsPane.swift"]
        let sinks = ["print(", "NSLog(", "os_log", "Logger(", "UserDefaults", "@AppStorage", "AlertLog", "AlertManager", "SentrySDK"]
        for f in files {
            let url = root.appendingPathComponent(f)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { Issue.record("cannot read \(f)"); continue }
            // Strip comments so the audit is about code, not about the header explaining the rule.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for s in sinks {
                // The pane's notifications toggle legitimately uses @AppStorage; it has nothing to do with the code.
                if f.hasSuffix("CloudSettingsPane.swift"), s == "@AppStorage" { continue }
                #expect(!code.contains(s), "\(f) mentions \(s)")
            }
        }
    }
}

// MARK: - FR-S4 devices

private final class Removed: @unchecked Sendable { var nodes: [String] = [] }

@Suite("F-057 FR-S4 — devices list and retire")
struct DeviceRetirementTests {

    @Test("Last-seen wording")
    func lastSeen() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DeviceLastSeen.text(lastSeen: nil, now: now) == "Never seen")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(-30), now: now) == "Just now")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(-7200), now: now) == "2 hours ago")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(-86_400 * 1.2), now: now) == "Yesterday")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(-86_400 * 9), now: now) == "9 days ago")
        #expect(DeviceLastSeen.text(lastSeen: now.addingTimeInterval(500), now: now) == "Just now")      // clock skew
        #expect(DeviceLastSeen.isStale(lastSeen: now.addingTimeInterval(-86_400 * 9), now: now))
        #expect(!DeviceLastSeen.isStale(lastSeen: now.addingTimeInterval(-3600), now: now))
    }

    @Test("lastSeen is read as milliseconds (what the phone writes) or seconds")
    func rawDate() {
        #expect(DeviceLastSeen.date(fromRaw: NSNumber(value: 1_700_000_000_000))?.timeIntervalSince1970 == 1_700_000_000)
        #expect(DeviceLastSeen.date(fromRaw: NSNumber(value: 1_700_000_000))?.timeIntervalSince1970 == 1_700_000_000)
        #expect(DeviceLastSeen.date(fromRaw: nil) == nil)
        #expect(DeviceLastSeen.date(fromRaw: "x") == nil)
    }

    @Test("Retiring a phone removes its messages and its device row, in that order, and nothing else")
    func retireRemovesBothSubtrees() async throws {
        let box = Removed()
        try await DeviceRetirement.retire(uid: "u1", deviceId: "phone-1") { box.nodes.append($0) }
        #expect(box.nodes == ["sms/u1/phone-1", "devices/u1/phone-1"])
    }

    @Test("An empty, slash-bearing or dot id removes NOTHING (an empty id would wipe the account's whole sms tree)")
    func unsafeIdsRefused() async {
        for bad in ["", "a/b", "..", ".", "/"] {
            let box = Removed()
            await #expect(throws: DeviceRetirementError.invalidDeviceID) {
                try await DeviceRetirement.retire(uid: "u1", deviceId: bad) { box.nodes.append($0) }
            }
            #expect(box.nodes.isEmpty, "id \(bad.debugDescription)")
        }
    }

    @Test("A failing removal stops the retire (the device row is not removed if the messages were not)")
    func failureStops() async {
        struct Boom: Error {}
        let box = Removed()
        await #expect(throws: Boom.self) {
            try await DeviceRetirement.retire(uid: "u1", deviceId: "p") { node in
                if node.hasPrefix("sms/") { throw Boom() }
                box.nodes.append(node)
            }
        }
        #expect(box.nodes.isEmpty)
    }
}
