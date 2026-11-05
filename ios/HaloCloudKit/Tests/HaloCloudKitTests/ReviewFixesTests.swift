import XCTest
@testable import HaloCloudKit

/// Regressions found in the independent review of PR #72 (clipboard restart, hostile JSON, host classification).
final class ReviewFixesTests: XCTestCase {
    let salt = Data((1...16).map { UInt8($0) })
    func crypto() throws -> CryptoService { try CryptoService(passphrase: "contract test passphrase 1", salt: salt, iterations: 100_000) }

    /// The app keeps ONE CloudSession across background -> foreground (CloudModel.startSync reuses it) and calls
    /// `incoming()` again. The remote history is re-streamed from the database, so it must be re-delivered.
    func testIncomingRedeliversExistingItemsAfterAStopAndRestart() async throws {
        let db = InMemoryRTDB(uid: "u"); let c = try crypto()
        let e = ClipboardSyncEngine(db: db, crypto: c, deviceId: "iphone", deviceName: "iPhone")
        await db.seed("clipboard/u/items/Z", ClipboardEnvelope(itemId: "Z", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: try c.encrypt("hello phone"), createdAtMs: 5).node())

        for round in 1...2 {
            let box = Box<[String]>(); box.set([])
            let t = Task { for await ev in e.incoming() { if case .item(let c) = ev { box.set(box.get()! + [c.text]) } } }
            let ok = await eventually { box.get() == ["hello phone"] }
            XCTAssertTrue(ok, "round \(round): the existing remote item must be delivered")
            t.cancel()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testHostileJSONDoesNotCrash() throws {
        for depth in [10, 100, 400, 600, 5_000, 100_000] {
            let s = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            _ = try? JSONValue.parse(Data(s.utf8))
            let o = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
            _ = try? JSONValue.parse(Data(o.utf8))
        }
        for n in ["1e999", "-1e999", "1e-999", "123456789012345678901234567890", "9223372036854775807", "-9223372036854775808", "1.7976931348623157e308", "0.1e400"] {
            let v = try? JSONValue.parse(Data("{\"date\":\(n),\"subscriptionId\":\(n)}".utf8))
            _ = v?["date"]?.doubleValue; _ = v?["subscriptionId"]?.intValue
            _ = SMSWire.decodeMessage(deviceId: "d", key: "k", node: v, crypto: try crypto())
            var m: [String: JSONValue] = [:]
            _ = FirebaseRTDB.apply(event: "put", payload: "{\"path\":\"/\",\"data\":{\"x\":\(n)}}", to: &m)
            if let vv = v { _ = try? vv.serialized() }
        }
        // sparse array shapes
        let sparse = json(#"[null,null,{"a":1},null,[null,{"b":2}]]"#)
        XCTAssertEqual(sparse.children?.keys.sorted(), ["2", "4"])
        // SSE shapes
        var m: [String: JSONValue] = [:]
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/","data":[null,{"x":1}]}"#, to: &m)
        XCTAssertEqual(Array(m.keys), ["1"])
        _ = FirebaseRTDB.apply(event: "patch", payload: #"{"path":"/1","data":{"x":null,"y/z":2}}"#, to: &m)
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"////","data":5}"#, to: &m)
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/a/b/c","data":{"q":1}}"#, to: &m)
        _ = FirebaseRTDB.apply(event: "put", payload: #"{"path":"/a/b/c","data":null}"#, to: &m)
    }

    func testFirebaseHostClassification() {
        for ok in ["https://x-default-rtdb.firebaseio.com", "https://x.europe-west1.firebasedatabase.app/", " HTTPS://X.FIREBASEIO.COM "] {
            XCTAssertTrue(DatabaseURLPolicy.isFirebaseHosted(ok), ok)
        }
        for bad in ["https://evil.example", "https://firebaseio.com.evil.example", "https://evilfirebaseio.com", "https://x.firebaseio.com@evil.example",
                    "https://evil.example/x.firebaseio.com", "https://evil.example?h=.firebaseio.com", "not a url", ""] {
            XCTAssertFalse(DatabaseURLPolicy.isFirebaseHosted(bad), bad)
        }
    }

    func testMessageTimestampExtremes() throws {
        let c = try crypto()
        for ms in ["1e308", "-1e308", "1e20", "0", "-1"] {
            let node = json("{\"addressEnc\":\"\(try c.encrypt("+1"))\",\"bodyEnc\":\"\(try c.encrypt("hi"))\",\"date\":\(ms),\"subscriptionId\":99999999999999999999}")
            if case .message(let m) = SMSWire.decodeMessage(deviceId: "d", key: "k", node: node, crypto: c) {
                _ = m.date.formatted(date: .abbreviated, time: .shortened)
                _ = m.date.formatted(.relative(presentation: .named))
            } else { XCTFail() }
        }
    }
}
