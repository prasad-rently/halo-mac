import XCTest
@testable import HaloCloudKit

/// A scriptable transport: per-path-root behaviour, so every outcome (including the failures) is exercised with no network.
final class ScriptedProbe: DatabaseProbeTransport, @unchecked Sendable {
    var signIn: DatabaseCheckSignIn = .ok(uid: "u1")
    var deny: Set<String> = []            // top-level roots whose writes are refused
    var denyRead: Set<String> = []        // writes ok, read-back refused
    var noDelete: Set<String> = []        // delete refused
    var anonStatus: [String: Int] = ["": 401]
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private(set) var leftover: [String] = []
    func signIn() async throws -> DatabaseCheckSignIn { signIn }
    func request(method: String, path: String, body: String?) async throws -> DatabaseProbeResponse {
        let root = String(path.split(separator: "/").first ?? "")
        return lock.withLock {
            switch method {
            case "PUT": if deny.contains(root) { return DatabaseProbeResponse(status: 401, body: "") }; store[path] = body; return DatabaseProbeResponse(status: 200, body: body ?? "")
            case "GET": if denyRead.contains(root) { return DatabaseProbeResponse(status: 403, body: "") }; return DatabaseProbeResponse(status: 200, body: store[path] ?? "null")
            default: if noDelete.contains(root) { return DatabaseProbeResponse(status: 403, body: "") }; store[path] = nil; return DatabaseProbeResponse(status: 200, body: "null")
            }
        }
    }
    func unauthenticatedStatus(path: String) async throws -> Int { anonStatus[path] ?? 401 }
    var remaining: Int { lock.withLock { store.count } }
}

final class DatabaseCheckTests: XCTestCase {
    func run(_ p: ScriptedProbe, url: String = "https://p.firebaseio.com") async -> DatabaseCheckReport {
        await DatabaseCheckEngine(transport: p, databaseURL: url, nonce: { "abcdef123456" }).run()
    }

    func testAllGoodPassesAndLeavesNothingBehind() async {
        let p = ScriptedProbe(); let r = await run(p)
        XCTAssertEqual(r.overall, .pass)
        XCTAssertEqual(p.remaining, 0)
    }

    /// THE v2.5 defect: rules that cover sms/devices/meta but not clipboard. "Test connection" said fine.
    func testRulesMissingClipboardAreNamedAsClipboard() async {
        let p = ScriptedProbe(); p.deny = ["clipboard"]
        let r = await run(p)
        XCTAssertEqual(r.overall, .fail)
        XCTAssertEqual(r.item(.clipboard).problem, .permissionDenied)
        XCTAssertEqual(r.item(.sms).status, .pass); XCTAssertEqual(r.item(.devices).status, .pass); XCTAssertEqual(r.item(.meta).status, .pass)
        XCTAssertNotNil(r.item(.clipboard).fix)
    }

    func testReadBackDeniedAndCleanupFailureAreDistinct() async {
        let p = ScriptedProbe(); p.denyRead = ["sms"]; p.noDelete = ["devices"]
        let r = await run(p)
        XCTAssertEqual(r.item(.sms).problem, .readDenied)
        XCTAssertEqual(r.item(.devices).problem, .cleanupFailed)
        XCTAssertTrue(r.item(.devices).detail.contains("_haloCheck_abcdef123456"), "says where the leftover is")
    }

    func testBadAddressSkipsTheRest() async {
        let r = await run(ScriptedProbe(), url: "http://insecure.example")
        XCTAssertEqual(r.item(.databaseURL).problem, .invalidURL)
        XCTAssertEqual(r.item(.clipboard).status, .skipped)
    }

    func testSignInFailuresMapToSpecificFixes() async {
        for (code, problem) in [("OPERATION_NOT_ALLOWED", DatabaseCheckProblem.emailPasswordDisabled), ("INVALID_LOGIN_CREDENTIALS", .badCredentials), ("API_KEY_INVALID", .badAPIKey), ("USER_DISABLED", .accountDisabled), ("WHATEVER", .unexpected)] {
            let p = ScriptedProbe(); p.signIn = .rejected(code: code)
            let r = await run(p)
            XCTAssertEqual(r.item(.signIn).problem, problem, code)
            XCTAssertEqual(r.item(.meta).status, .skipped)
        }
    }

    func testOpenRulesAreFlaggedEvenWhenOnlyOneFolderIsOpen() async {
        let all = ScriptedProbe(); all.anonStatus = ["": 200]
        let ra = await run(all)
        XCTAssertEqual(ra.item(.publicAccess).problem, .openRules)
        let one = ScriptedProbe(); one.anonStatus = ["": 401, "clipboard": 200]
        let r = await run(one)
        XCTAssertEqual(r.item(.publicAccess).problem, .openRules)
        XCTAssertTrue(r.item(.publicAccess).detail.contains("clipboard/"))
    }

    func testReportTextNeverContainsSecretsOrURLs() async {
        let p = ScriptedProbe(); p.deny = ["clipboard"]; p.denyRead = ["sms"]
        let r = await run(p)
        let text = r.items.map { $0.title + $0.detail + ($0.fix ?? "") }.joined()
        XCTAssertFalse(text.contains("auth=")); XCTAssertFalse(text.contains("https://p.firebaseio.com"))
    }

    func testSignInErrorCodeParsing() {
        XCTAssertEqual(LiveDatabaseProbeTransport.signInErrorCode(json(#"{"error":{"message":"WEAK : x"}}"#).objectValue), "WEAK")
        XCTAssertEqual(LiveDatabaseProbeTransport.signInErrorCode(json(#"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#).objectValue), "API_KEY_INVALID")
    }
}
