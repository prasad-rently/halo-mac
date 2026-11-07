import XCTest
@testable import HaloCloudKit

/// Cross-implementation end to end: reads what the REAL Kotlin engines (SmsSyncEngine, ClipboardSyncEngine) wrote to
/// the stand-in, and publishes a clipboard item for the Kotlin engine to decode. Driven by scripts/e2e-kotlin-ios.sh;
/// skipped unless HALO_E2E_PORT is set (so a plain `swift test` never needs a JVM).
final class InteropE2ETests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func session() throws -> CloudSession {
        guard let port = env["HALO_E2E_PORT"], env["HALO_E2E_MODE"] != nil else { throw XCTSkip("HALO_E2E_PORT not set (run scripts/e2e-kotlin-ios.sh)") }
        let salt = Data(base64Encoded: env["HALO_E2E_SALT_B64"]!)!
        let crypto = try CryptoService(passphrase: env["HALO_E2E_PASSPHRASE"]!, salt: salt, iterations: Int(env["HALO_E2E_ITERATIONS"]!)!)
        let profile = CloudProfile(config: FirebaseConfig(apiKey: "any", projectID: "p", googleAppID: "a", gcmSenderID: "g", databaseURL: "http://127.0.0.1:\(port)"),
                                   auth: CloudAuthCredential(email: "me@halo.test", password: "halo-test-password"), saltBase64: env["HALO_E2E_SALT_B64"]!,
                                   iterations: Int(env["HALO_E2E_ITERATIONS"]!)!, keyBase64: crypto.exportKey().base64EncodedString(),
                                   deviceId: "ios-e2e-device", deviceName: "iPhone (HaloCloudKit)")
        return try CloudSession(profile: profile, transport: URLSessionTransport(), allowLoopbackHTTP: true, minBackoff: 0.05)
    }

    /// Kotlin wrote (SmsSyncEngine + ClipboardSyncEngine) -> Swift reads and decrypts.
    func testSwiftReadsWhatTheKotlinEnginesWrote() async throws {
        guard env["HALO_E2E_MODE"] == "read" || env["HALO_E2E_PORT"] == nil else { throw XCTSkip("mode") }
        let s = try session()
        let box = Box<SmsSnapshot>()
        let t = Task { for await x in s.sms.snapshots() { box.set(x) } }
        defer { t.cancel() }
        let ok = await eventually(timeout: 15) { box.get()?.messages.count == 2 && box.get()?.lines.count == 2 }
        XCTAssertTrue(ok, "viewer did not converge")
        let snap = try XCTUnwrap(box.get())
        XCTAssertEqual(Set(snap.messages.values.map(\.body)), ["Rs 500.00 debited from a/c XX1234. Avl bal Rs 9,500.", "Kotlin says hi ✅ café / ok"])
        XCTAssertEqual(Set(snap.messages.values.map(\.address)), ["VM-HDFCBK", "+91 98765 43210"])
        XCTAssertEqual(snap.lines["kotlin-dev-1"]?.ownNumber, "+919876543210")
        XCTAssertEqual(snap.lines["kotlin-dev-2"]?.ownNumber, "Unknown", "a blank own number is stored as Unknown by the Kotlin writer")
        XCTAssertEqual(snap.devices["kotlin-dev"]?.name, "Pixel (Kotlin engine)")
        XCTAssertEqual(snap.undecryptableCount, 0)
        // the threadKey the Kotlin writer computed equals ours, for every message
        for m in snap.messages.values {
            XCTAssertEqual(m.threadKey, SMSWire.threadKey(crypto: s.crypto, deviceId: m.deviceId, subscriptionId: m.subscriptionId, address: m.address))
        }

        let got = Box<[RemoteClip]>(); got.set([])
        let ct = Task { for await ev in s.clipboard.incoming() { if case .item(let c) = ev { got.set(got.get()! + [c]) } } }
        defer { ct.cancel() }
        let ok2 = await eventually(timeout: 15) { got.get()?.count == 1 }
        XCTAssertTrue(ok2)
        XCTAssertEqual(got.get()?.first?.text, "hello from Kotlin ✨ https://example.com/x?y=1")
        XCTAssertEqual(got.get()?.first?.kind, "text", "contains a space, so not `url`")
        XCTAssertEqual(got.get()?.first?.deviceName, "Pixel (Kotlin engine)")
    }

    /// Swift writes -> the Kotlin engine (separate test run) decodes it. The expected text is handed over via a file.
    func testSwiftPublishesAClipboardItemForKotlin() async throws {
        guard env["HALO_E2E_MODE"] == "write" else { throw XCTSkip("mode") }
        let s = try session()
        let text = "from the iPhone ✨ https://example.com/ü?q=1\nsecond line"
        guard case .sent = await s.clipboard.publish(text) else { return XCTFail("publish failed") }
        try text.write(toFile: env["HALO_E2E_EXPECT_FILE"]!, atomically: true, encoding: .utf8)
    }
}
