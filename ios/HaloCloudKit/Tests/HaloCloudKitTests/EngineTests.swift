import XCTest
@testable import HaloCloudKit

final class SmsViewerEngineTests: XCTestCase {
    let uid = "uid-contract"

    /// A database seeded with the REAL Kotlin writer's nodes from the wire-contract fixture.
    func seeded() async throws -> (InMemoryRTDB, CryptoService, JSONValue) {
        let n = try Fixture.json("phone-nodes.v1.json")
        let c = n["crypto"]!
        let crypto = try CryptoService(passphrase: c["passphrase"]!.stringValue!, salt: Data(base64Encoded: c["saltBase64"]!.stringValue!)!, iterations: c["iterations"]!.intValue!)
        let db = InMemoryRTDB(uid: uid)
        await db.seed("devices/\(uid)/dev-A", n["device"]!["node"]!)
        for l in n.arrayValue("lines") { await db.seed("sms/\(uid)/dev-A/lines/\(l["key"]!.stringValue!)", l["node"]!) }
        for m in n.arrayValue("messages") { await db.seed("sms/\(uid)/dev-A/messages/\(m["key"]!.stringValue!)", m["node"]!) }
        return (db, crypto, n)
    }

    /// First snapshot satisfying `until`, or nil after `timeout` — a regression fails fast instead of hanging the suite.
    func firstSnapshot(_ e: SmsViewerEngine, timeout: TimeInterval = 5, until: @escaping @Sendable (SmsSnapshot) -> Bool) async -> SmsSnapshot? {
        let box = Box<SmsSnapshot>()
        let t = Task { for await s in e.snapshots() where until(s) { box.set(s); return } }
        _ = await eventually(timeout: timeout) { box.get() != nil }
        t.cancel()
        return box.get()
    }

    func testViewerShowsDecryptedThreadsGroupedByLineAndContact() async throws {
        let (db, crypto, _) = try await seeded()
        let e = SmsViewerEngine(db: db, crypto: crypto, discoveryInterval: 60)
        let snap = await firstSnapshot(e) { $0.messages.count == 2 && $0.lines.count == 2 && $0.devices.count == 1 }
        let s = try XCTUnwrap(snap)
        XCTAssertEqual(s.devices["dev-A"]?.name, "Pixel 8")
        XCTAssertEqual(s.lines["dev-A-1"]?.ownNumber, "+919876543210")
        XCTAssertEqual(s.lines["dev-A-2"]?.syncEnabled, false)
        let threads = s.threads
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0].last.body, "See you at 7 ✅ café à la carte / ok", "newest thread first")
        XCTAssertEqual(threads[1].contact, "VM-HDFCBK")
        XCTAssertEqual(threads[1].unreadCount, 1)
        XCTAssertEqual(s.undecryptableCount, 0)
    }

    // SECURITY: messages sealed under another key are NOT shown, and are counted so the UI can say why.
    func testWrongKeyShowsNothingAndCountsUndecryptable() async throws {
        let (db, _, _) = try await seeded()
        let wrong = try CryptoService(passphrase: "a different passphrase", salt: Data((1...16).map(UInt8.init)), iterations: 100_000)
        let e = SmsViewerEngine(db: db, crypto: wrong, discoveryInterval: 60)
        let snap = await firstSnapshot(e) { $0.undecryptableCount == 2 }
        let s = try XCTUnwrap(snap)
        XCTAssertTrue(s.messages.isEmpty)
        XCTAssertTrue(s.threads.isEmpty)
    }

    func testLiveUpdatesAndRemovalsStream() async throws {
        let (db, crypto, n) = try await seeded()
        let e = SmsViewerEngine(db: db, crypto: crypto, discoveryInterval: 60)
        let box = Box<SmsSnapshot>()
        let task = Task { for await s in e.snapshots() { box.set(s) } }
        defer { task.cancel() }
        let ok1 = await eventually { box.get()?.messages.count == 2 }
        XCTAssertTrue(ok1)
        // a new message arrives from the phone
        let fresh = try crypto.encrypt("Your OTP is 123456"), who = try crypto.encrypt("AX-OTP")
        await db.seed("sms/\(uid)/dev-A/messages/9_1800000009000", json(#"{"addressEnc":"\#(who)","bodyEnc":"\#(fresh)","subscriptionId":1,"date":1800000009000,"read":false,"schema":1}"#))
        let ok2 = await eventually { box.get()?.messages.count == 3 }
        XCTAssertTrue(ok2)
        // the Mac wipes the device
        await db.seed("sms/\(uid)/dev-A/messages", .null)
        let ok3 = await eventually { box.get()?.messages.isEmpty == true }
        XCTAssertTrue(ok3)
        _ = n
    }

    func testProbeEntriesFromTheDatabaseCheckNeverBecomeDevices() async throws {
        let (db, crypto, _) = try await seeded()
        await db.seed("devices/\(uid)/_haloCheck_ab12", .string("tok"))
        await db.seed("sms/\(uid)/_haloCheck_ab12", .string("tok"))
        let e = SmsViewerEngine(db: db, crypto: crypto, discoveryInterval: 60)
        let snap = await firstSnapshot(e) { $0.messages.count == 2 }
        let s = try XCTUnwrap(snap)
        XCTAssertEqual(Set(s.devices.keys), ["dev-A"])
    }

    func testDeviceWithoutRegistryEntryIsStillDiscovered() async throws {
        let (db, crypto, n) = try await seeded()
        await db.seed("devices/\(uid)", .null)
        let e = SmsViewerEngine(db: db, crypto: crypto, discoveryInterval: 60)
        let snap = await firstSnapshot(e) { $0.messages.count == 2 }
        let s = try XCTUnwrap(snap)
        XCTAssertTrue(s.devices.isEmpty); _ = n
    }

    func testCancellingTheConsumerDetachesEveryObserver() async throws {
        let (db, crypto, _) = try await seeded()
        let e = SmsViewerEngine(db: db, crypto: crypto, discoveryInterval: 60)
        let box = Box<SmsSnapshot>()
        let task = Task { for await s in e.snapshots() { box.set(s) } }
        let ok = await eventually { box.get()?.messages.count == 2 }
        XCTAssertTrue(ok)
        let attached = await db.observerCount()
        XCTAssertGreaterThanOrEqual(attached, 3)
        task.cancel(); _ = await task.value
        let gone = await eventually { await db.observerCount() == 0 }
        XCTAssertTrue(gone, "observers still attached after cancel")
    }

    func testOfflineDatabaseSurfacesAsFailedNotACrash() async throws {
        final class Dead: RealtimeDatabase, @unchecked Sendable {
            func uid() async throws -> String { throw CloudError.authFailed("nope") }
            func get(_ p: String) async throws -> JSONValue { .null }
            func put(_ p: String, _ v: JSONValue) async throws {}
            func delete(_ p: String) async throws {}
            func shallowKeys(_ p: String) async throws -> Set<String> { [] }
            func observeChildren(_ p: String) -> AsyncStream<ChildEvent> { AsyncStream { $0.finish() } }
        }
        let crypto = try CryptoService(passphrase: "x", salt: Data((1...16).map(UInt8.init)), iterations: 100_000)
        let snap = await firstSnapshot(SmsViewerEngine(db: Dead(), crypto: crypto)) { if case .failed = $0.connection { return true } else { return false } }
        let s = try XCTUnwrap(snap)
        XCTAssertTrue(s.messages.isEmpty)
    }
}

final class ClipboardSyncEngineTests: XCTestCase {
    let salt = Data((1...16).map(UInt8.init))
    func crypto() throws -> CryptoService { try CryptoService(passphrase: "contract test passphrase 1", salt: salt, iterations: 100_000) }
    func engine(_ db: InMemoryRTDB, id: String = "iphone-1", clock: @escaping @Sendable () -> Date = { Date() }) throws -> ClipboardSyncEngine {
        ClipboardSyncEngine(db: db, crypto: try crypto(), deviceId: id, deviceName: "iPhone", clock: clock)
    }

    func testPublishWritesAnEncryptedKotlinCompatibleEnvelope() async throws {
        let db = InMemoryRTDB(uid: "u")
        let e = try engine(db)
        guard case .sent(let id) = await e.publish("https://example.com/a?b=c") else { return XCTFail() }
        let node = try await db.get("clipboard/u/items/\(id)")
        let env = try XCTUnwrap(ClipboardEnvelope.from(node))
        XCTAssertEqual(env.kind, "url"); XCTAssertEqual(env.deviceId, "iphone-1"); XCTAssertEqual(node["schema"]?.intValue, 1)
        XCTAssertEqual(try crypto().decrypt(env.contentEnc), "https://example.com/a?b=c")
        XCTAssertFalse(String(decoding: try node.serialized(), as: UTF8.self).contains("example.com"), "plaintext never on the wire")
    }

    func testDuplicateEmptyAndTooLarge() async throws {
        let db = InMemoryRTDB(uid: "u"); let e = try engine(db)
        let r1 = await e.publish("  \n"), r2 = await e.publish("one"), r3 = await e.publish("one")
        let r4 = await e.publish(String(repeating: "x", count: ClipboardSyncEngine.maxCharacters + 1))
        XCTAssertEqual(r1, .empty)
        guard case .sent = r2 else { return XCTFail() }
        XCTAssertEqual(r3, .duplicate)
        XCTAssertEqual(r4, .tooLarge)
        let writes = await db.writes
        XCTAssertEqual(writes.filter { $0.hasPrefix("PUT") }.count, 1)
    }

    func testFailedPublishCanBeRetried() async throws {
        let db = InMemoryRTDB(uid: "u"); let e = try engine(db)
        await db.setFailWrites(true)
        guard case .failed = await e.publish("retry me") else { return XCTFail() }
        await db.setFailWrites(false)
        guard case .sent = await e.publish("retry me") else { return XCTFail("a failed send must not poison dedup") }
    }

    func testReceiveDropsOwnEchoAndShowsOtherDevicesDecrypted() async throws {
        let db = InMemoryRTDB(uid: "u"); let c = try crypto()
        let e = try engine(db)
        await db.seed("clipboard/u/items/A", ClipboardEnvelope(itemId: "A", deviceId: "iphone-1", deviceName: "iPhone", kind: "text", contentEnc: try c.encrypt("mine"), createdAtMs: 1).node())
        await db.seed("clipboard/u/items/B", ClipboardEnvelope(itemId: "B", deviceId: "mac", deviceName: "Mac", kind: "code", contentEnc: try c.encrypt("let x = 1"), language: "swift", createdAtMs: 2000).node())
        await db.seed("clipboard/u/items/C", ClipboardEnvelope(itemId: "C", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: "v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==", createdAtMs: 3).node())
        let clipBox = Box<[RemoteClip]>(); clipBox.set([]); let badBox = Counter()
        let t = Task { for await ev in e.incoming() {
            switch ev {
            case .item(let c): clipBox.set(clipBox.get()! + [c])
            case .undecryptable: badBox.bump()
            default: break
            }
        } }
        _ = await eventually { clipBox.get()!.count >= 1 && badBox.value >= 1 }
        try await Task.sleep(nanoseconds: 150_000_000)      // long enough for a wrongly-delivered echo to show up
        t.cancel()
        let clips = clipBox.get()!, bad = badBox.value
        XCTAssertEqual(clips.map(\.text), ["let x = 1"]); XCTAssertEqual(clips[0].language, "swift"); XCTAssertEqual(clips[0].createdAt.timeIntervalSince1970, 2)
        XCTAssertEqual(bad, 1, "a clip sealed under another key is reported, never shown")
    }

    func testRemoteItemArrivingLiveAndIsDeliveredOnce() async throws {
        let db = InMemoryRTDB(uid: "u"); let c = try crypto(); let e = try engine(db)
        let box = Box<[String]>(); box.set([])
        let t = Task { for await ev in e.incoming() { if case .item(let c) = ev { box.set(box.get()! + [c.text]) } } }
        defer { t.cancel() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let env = ClipboardEnvelope(itemId: "Z", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: try c.encrypt("hello phone"), createdAtMs: 5).node()
        await db.seed("clipboard/u/items/Z", env)
        let ok = await eventually { box.get() == ["hello phone"] }
        XCTAssertTrue(ok)
        await db.seed("clipboard/u/items/Z", env)       // re-delivery
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.get(), ["hello phone"])
    }

    func testCapSweepDeletesOldestBeyond500() async throws {
        let db = InMemoryRTDB(uid: "u"); let c = try crypto()
        for i in 0..<503 { await db.seed("clipboard/u/items/k\(String(format: "%04d", i))", ClipboardEnvelope(itemId: "k\(i)", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: try c.encrypt("x"), createdAtMs: Double(i)).node()) }
        let e = try engine(db, clock: { Date(timeIntervalSince1970: 100_000) })
        _ = await e.publish("new one")
        let left = try await db.shallowKeys("clipboard/u/items")
        XCTAssertEqual(left.count, 500)
        XCTAssertFalse(left.contains("k0000")); XCTAssertFalse(left.contains("k0003")); XCTAssertTrue(left.contains("k0004"))
    }

    func testPurgeRemovesEverything() async throws {
        let db = InMemoryRTDB(uid: "u"); let e = try engine(db)
        _ = await e.publish("a"); _ = await e.publish("b")
        try await e.purge()
        let left = try await db.shallowKeys("clipboard/u/items")
        XCTAssertTrue(left.isEmpty)
    }

    func testSensitiveFilterMirrorsTheDesktopRules() {
        for s in ["my password is hunter2", "AKIAABCDEFGHIJKLMNOP", "ghp_abcdefghijklmnopqrstuvwx", "-----BEGIN PRIVATE KEY-----", "eyJhbGciOi.eyJzdWIi.sig_x", String(repeating: "a", count: 64), "Authorization: Bearer abc"] {
            XCTAssertTrue(ClipboardSensitiveFilter.isSensitive(s), s)
        }
        for s in ["hello world", "https://example.com", "d41d8cd98f00b204e9800998ecf8427e" /* md5 */, "a3f5c1d9e8b7a6f5e4d3c2b1a09f8e7d6c5b4a39" /* git sha */, ""] {
            XCTAssertFalse(ClipboardSensitiveFilter.isSensitive(s), s)
        }
    }

    func testKindDetection() {
        XCTAssertEqual(ClipboardSyncEngine.kind(of: "https://a.b/c"), "url")
        XCTAssertEqual(ClipboardSyncEngine.kind(of: "see https://a.b/c"), "text")
        XCTAssertEqual(ClipboardSyncEngine.kind(of: "https://"), "text")
        XCTAssertEqual(ClipboardSyncEngine.kind(of: "plain"), "text")
    }
}

final class Box<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T?
    func set(_ x: T) { l.withLock { v = x } }
    func get() -> T? { l.withLock { v } }
}

final class OTPCodeTests: XCTestCase {
    func testExtractsTheCodeFromOTPMessages() {
        XCTAssertEqual(OTPCode.extract(from: "998231 is the OTP for your transaction. Do not share."), "998231")
        XCTAssertEqual(OTPCode.extract(from: "Your verification code is 4821. Valid for 10 minutes."), "4821")
        XCTAssertEqual(OTPCode.extract(from: "Use 123456 as your login code"), "123456")
    }
    func testNoCodeWhenItIsNotAnOTPMessageOrTheNumberIsSomethingElse() {
        XCTAssertNil(OTPCode.extract(from: "Rs 500.00 debited from a/c XX1234. Avl bal Rs 9,500."), "a bank alert is not an OTP")
        XCTAssertNil(OTPCode.extract(from: "See you at 7 ✅"))
        XCTAssertNil(OTPCode.extract(from: "Your OTP is sent to +919876543210"), "a phone number is not a code")
        XCTAssertNil(OTPCode.extract(from: "OTP request id 123456789012"), "a long number is not a 4-8 digit code")
        XCTAssertNil(OTPCode.extract(from: "OTP: pay Rs 5000 now"), "an amount is not a code")
    }
}
