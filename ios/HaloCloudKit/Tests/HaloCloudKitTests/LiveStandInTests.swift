import XCTest
import Darwin
@testable import HaloCloudKit

/// Runs the REAL network path (URLSession, real SSE) against android/tools/fake-firebase.py on loopback — the same
/// stand-in the Android app was driven against. Spawns its own instance on a free port, so `swift test` is
/// self-contained. NOT real Firebase: it proves the wire handling and engines end to end, not Google's behaviour.
final class LiveStandInTests: XCTestCase {
    static let email = "me@halo.test", password = "halo-test-password", uid = "uid-test-1"
    static let passphrase = "live standin passphrase 1"
    let salt = Data((1...16).map { UInt8($0 + 40) })
    var process: Process?
    var port = 0

    override func setUpWithError() throws {
        guard let root = Repo.root else { throw XCTSkip("not inside the repo") }
        let script = root.appendingPathComponent("android/tools/fake-firebase.py").path
        guard FileManager.default.fileExists(atPath: script) else { throw XCTSkip("fake-firebase.py not found") }
        port = try Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, String(port)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); process = p
        // wait for it to listen
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.canConnect(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("stand-in did not start (python3 missing?)")
    }

    override func tearDown() { process?.terminate(); process?.waitUntilExit() }

    static func freePort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw XCTSkip("no free port") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
    static func canConnect(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = UInt16(port).bigEndian
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    func payload() -> PairingPayload {
        PairingPayload(firebaseConfig: FirebaseConfig(apiKey: "any", projectID: "p", googleAppID: "a", gcmSenderID: "g", databaseURL: "http://127.0.0.1:\(port)"),
                       auth: CloudAuthCredential(email: Self.email, password: Self.password), salt: salt, iterations: 100_000)
    }

    func newSetup(_ store: SecretStore = InMemorySecretStore()) -> CloudSetup {
        CloudSetup(secrets: store, allowLoopbackHTTP: true, deviceName: "iPhone", minBackoff: 0.05)
    }

    func testFullPairingSmsViewerAndClipboardRoundTripOverTheRealNetworkPath() async throws {
        let store = InMemorySecretStore()
        let setup = newSetup(store)
        let p = try setup.parse(try payload().encoded())

        // 1. empty database -> cannot verify -> type it twice (D-01) -> paired unverified
        let first = try await setup.connect(payload: p, passphrase: Self.passphrase, confirmation: nil)
        XCTAssertEqual(first, .needsConfirmation)
        let paired = try await setup.connect(payload: p, passphrase: Self.passphrase, confirmation: Self.passphrase)
        XCTAssertEqual(paired, .paired(deviceName: "iPhone", verified: false))
        let session = try XCTUnwrap(try setup.openSession())

        // 2. an "Android phone" (here: the same client, another writer) syncs a device, a line and two messages
        let crypto = session.crypto
        let db = session.db
        try await db.put("devices/\(Self.uid)/dev-A", json(#"{"name":"Pixel 8","platform":"android","lastSeen":1800000000000}"#))
        try await db.put("sms/\(Self.uid)/dev-A/lines/1", json(#"{"subscriptionId":1,"label":"Personal","carrier":"Airtel","ownNumberEnc":"\#(try crypto.encrypt("+919876543210"))"}"#))
        for (i, (addr, body, read)) in [("VM-HDFCBK", "Rs 500.00 debited from a/c XX1234", false), ("+91 98765 43210", "See you at 7 ✅ café / ok", true)].enumerated() {
            try await db.put("sms/\(Self.uid)/dev-A/messages/\(4201 + i)_\(1799996400000 + i * 1000)",
                             json(#"{"addressEnc":"\#(try crypto.encrypt(addr))","bodyEnc":"\#(try crypto.encrypt(body))","subscriptionId":1,"date":\#(1799996400000 + i * 1000),"read":\#(read),"type":1,"schema":1}"#))
        }

        // 3. the viewer reads + decrypts it over real SSE
        let box = Box<SmsSnapshot>()
        let t = Task { for await s in session.sms.snapshots() { box.set(s) } }
        defer { t.cancel() }
        let ok = await eventually(timeout: 10) { box.get()?.messages.count == 2 && box.get()?.lines.count == 1 }
        XCTAssertTrue(ok, "viewer did not converge: \(String(describing: box.get()?.connection))")
        XCTAssertEqual(box.get()?.connection, .live)
        XCTAssertEqual(Set(box.get()!.messages.values.map(\.body)), ["Rs 500.00 debited from a/c XX1234", "See you at 7 ✅ café / ok"])
        XCTAssertEqual(box.get()?.lines.values.first?.ownNumber, "+919876543210")

        // 4. clipboard: iPhone publishes; a second device (the "Mac") receives and decrypts it; and the reverse
        let mac = ClipboardSyncEngine(db: db, crypto: crypto, deviceId: "mac-1", deviceName: "Mac")
        let got = Box<[String]>(); got.set([])
        let ct = Task { for await ev in mac.incoming() { if case .item(let c) = ev { got.set(got.get()! + [c.text]) } } }
        defer { ct.cancel() }
        guard case .sent = await session.clipboard.publish("from the iPhone ✨ https://example.com") else { return XCTFail("publish failed") }
        let ok2 = await eventually(timeout: 10) { got.get() == ["from the iPhone ✨ https://example.com"] }
        XCTAssertTrue(ok2)

        let phoneGot = Box<[String]>(); phoneGot.set([])
        let pt = Task { for await ev in session.clipboard.incoming() { if case .item(let c) = ev { phoneGot.set(phoneGot.get()! + [c.text]) } } }
        defer { pt.cancel() }
        guard case .sent = await mac.publish("from the Mac") else { return XCTFail() }
        let ok3 = await eventually(timeout: 10) { phoneGot.get() == ["from the Mac"] }
        XCTAssertTrue(ok3, "the iPhone's own item must not echo back: \(String(describing: phoneGot.get()))")

        // 5. what is on the "wire" (the stand-in's tree) is opaque: no plaintext anywhere
        let (dump, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/_dump")!)
        let text = String(decoding: dump, as: UTF8.self)
        for secret in ["debited", "from the iPhone", "from the Mac", "98765", "HDFCBK", Self.passphrase] { XCTAssertFalse(text.contains(secret), "plaintext on the wire: \(secret)") }

        // 6. Check my database passes against the stand-in
        let report = await session.checkDatabase()
        for item in report.items where item.kind != .publicAccess { XCTAssertEqual(item.status, .pass, "\(item.kind): \(item.detail)") }
        XCTAssertEqual(report.item(.publicAccess).status, .pass, "an unauthenticated read must be refused")

        // 7. unpair wipes
        try setup.unpair()
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testWrongPassphraseIsRefusedAgainstRealCiphertext() async throws {
        let setup = newSetup()
        let p = payload()
        _ = try await setup.connect(payload: p, passphrase: Self.passphrase, confirmation: Self.passphrase)
        let db = try XCTUnwrap(try setup.openSession()).db
        let crypto = try CryptoService(passphrase: Self.passphrase, salt: salt, iterations: 100_000)
        try await db.put("clipboard/\(Self.uid)/items/q", ClipboardEnvelope(itemId: "q", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: try crypto.encrypt("x"), createdAtMs: 1).node())
        let other = newSetup()
        do { _ = try await other.connect(payload: p, passphrase: "not the right passphrase", confirmation: nil); XCTFail() }
        catch { XCTAssertEqual(error as? PairingFailure, .passphraseMismatch) }
        let ok = try await other.connect(payload: p, passphrase: Self.passphrase, confirmation: nil)
        XCTAssertEqual(ok, .paired(deviceName: "iPhone", verified: true))
    }

    func testWrongPasswordIsAFriendlyError() async throws {
        var p = payload(); p.auth.password = "nope"
        p.checksum = PairingPayload.checksum(config: p.firebaseConfig, auth: p.auth, saltBase64: p.saltBase64, schema: p.schema, iterations: p.iterations)
        do { _ = try await newSetup().connect(payload: p, passphrase: Self.passphrase, confirmation: nil); XCTFail() }
        catch { XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").contains("Wrong email or password")) }
    }

    func testReleaseConfigurationRefusesTheStandInEntirely() throws {
        let release = CloudSetup(secrets: InMemorySecretStore(), allowLoopbackHTTP: false)
        XCTAssertThrowsError(try release.parse(try payload().encoded())) { XCTAssertEqual($0 as? CloudError, .configureFailed) }
    }
}
