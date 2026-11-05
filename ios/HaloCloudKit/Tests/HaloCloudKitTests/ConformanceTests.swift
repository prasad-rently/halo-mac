import XCTest
import CryptoKit
@testable import HaloCloudKit

/// The cross-implementation contract. Every ciphertext in these fixtures was sealed by ANOTHER implementation
/// (Swift desktop for the parity vectors; the real Kotlin writers for the phone nodes), so passing here proves
/// interoperability, not self-consistency.
final class ConformanceTests: XCTestCase {

    private func vectors() throws -> JSONValue { try Fixture.json("crypto-parity-vectors.v2.json") }

    func list(_ v: JSONValue, _ key: String) -> [JSONValue] {
        if case .array(let a)? = v[key] { return a }
        return []
    }

    // MARK: crypto-parity-vectors.v2.json

    func testFixtureIsInSyncWithTheRepoSpec() throws {
        // The package carries a copy (a SwiftPM resource must live inside the package). If the spec changes and the
        // copy is not refreshed, this fails rather than letting the conformance tests go stale.
        guard let root = Repo.root else { throw XCTSkip("not running from inside the repo") }
        let spec = try Data(contentsOf: root.appendingPathComponent("docs/specs/crypto-parity-vectors.v2.json"))
        XCTAssertEqual(try Fixture.data("crypto-parity-vectors.v2.json"), spec, "refresh ios/HaloCloudKit/Tests/HaloCloudKitTests/Fixtures from docs/specs")
    }

    func testKdfVectorsReproduceExactly() throws {
        let vs = list(try vectors(), "kdfVectors")
        XCTAssertEqual(vs.count, 8)
        for v in vs {
            let key = try CryptoService.deriveKey(passphrase: v["passphrase"]!.stringValue!,
                                                  salt: Data(base64Encoded: v["saltB64"]!.stringValue!)!,
                                                  iterations: v["iterations"]!.intValue!)
            let got = key.withUnsafeBytes { Data($0) }.base64EncodedString()
            XCTAssertEqual(got, v["derivedKeyB64"]!.stringValue!, "KDF vector \(v["name"]!.stringValue!)")
        }
    }

    func testEveryV1CiphertextFromAnotherImplementationDecrypts() throws {
        let vs = list(try vectors(), "decryptVectors")
        XCTAssertEqual(vs.count, 4)
        for v in vs {
            let c = try CryptoService(passphrase: v["passphrase"]!.stringValue!, salt: Data(base64Encoded: v["saltB64"]!.stringValue!)!, iterations: v["iterations"]!.intValue!)
            XCTAssertEqual(try c.decrypt(v["ciphertext"]!.stringValue!), v["plaintext"]!.stringValue!, v["name"]!.stringValue!)
        }
    }

    func testLegacyV0BoxesStillDecrypt() throws {
        let vs = list(try vectors(), "legacyDecryptVectors")
        XCTAssertEqual(vs.count, 4)
        for v in vs {
            let c = try CryptoService(passphrase: v["passphrase"]!.stringValue!, salt: Data(base64Encoded: v["saltB64"]!.stringValue!)!, iterations: v["iterations"]!.intValue!)
            XCTAssertEqual(try c.decrypt(v["ciphertext"]!.stringValue!), v["plaintext"]!.stringValue!, v["name"]!.stringValue!)
        }
    }

    func testRejectVectorsFailAuthentication() throws {
        let vs = list(try vectors(), "rejectVectors")
        XCTAssertEqual(vs.count, 5)
        for v in vs {
            let c = try CryptoService(passphrase: v["passphrase"]!.stringValue!, salt: Data(base64Encoded: v["saltB64"]!.stringValue!)!, iterations: v["iterations"]!.intValue!)
            XCTAssertThrowsError(try c.decrypt(v["ciphertext"]!.stringValue!), v["name"]!.stringValue!) { e in
                XCTAssertEqual(e as? CloudError, .decryptionFailed, v["name"]!.stringValue!)
            }
        }
    }

    func testPassphraseVectors() throws {
        let vs = list(try vectors(), "passphraseVectors")
        XCTAssertEqual(vs.count, 11)
        for v in vs {
            let verdict = PassphrasePolicy.evaluate(v["passphrase"]!.stringValue!)
            let code: String
            switch verdict { case .ok: code = "ok"; case .tooShort(let n): code = "tooShort:\(n)"; case .tooRepetitive: code = "tooRepetitive" }
            XCTAssertEqual(code, v["verdict"]!.stringValue!, "passphrase vector \(v["passphrase"]!.stringValue!)")
        }
    }

    func testPairingVectors() throws {
        let vs = list(try vectors(), "pairingVectors")
        XCTAssertEqual(vs.count, 3)
        for v in vs {
            let name = v["name"]!.stringValue!
            let wantValid = v["valid"]!.boolValue!
            let b64 = v["payloadB64"]!.stringValue!
            if wantValid {
                let p = try PairingCode.parse(b64)
                XCTAssertTrue(p.isValid, name)
                XCTAssertEqual(p.schema, v["schema"]!.intValue!, name)
                XCTAssertEqual(p.iterations, v["iterations"]!.intValue!, name)
                XCTAssertEqual(p.salt, Data(base64Encoded: v["saltB64"]!.stringValue!), name)
            } else {
                XCTAssertThrowsError(try PairingCode.parse(b64), name) { XCTAssertEqual($0 as? CloudError, .pairingChecksumMismatch, name) }
            }
        }
    }

    // MARK: phone-nodes.v1.json — what the real Kotlin writers produce

    private struct Phone {
        let crypto: CryptoService
        let nodes: JSONValue
        let uid: String
        let deviceId: String
    }

    private func phone() throws -> Phone {
        let n = try Fixture.json("phone-nodes.v1.json")
        let c = n["crypto"]!
        let crypto = try CryptoService(passphrase: c["passphrase"]!.stringValue!, salt: Data(base64Encoded: c["saltBase64"]!.stringValue!)!, iterations: c["iterations"]!.intValue!)
        return Phone(crypto: crypto, nodes: n, uid: n["uid"]!.stringValue!, deviceId: n["deviceId"]!.stringValue!)
    }

    func testAndroidDeviceNode() throws {
        let p = try phone()
        let d = SMSWire.decodeDevice(id: p.deviceId, node: p.nodes["device"]!["node"])
        let e = p.nodes["device"]!["expect"]!
        XCTAssertEqual(d.id, e["id"]!.stringValue); XCTAssertEqual(d.name, e["name"]!.stringValue); XCTAssertEqual(d.platform, e["platform"]!.stringValue)
        XCTAssertNotNil(d.lastSeen)
    }

    func testAndroidLineNodes() throws {
        let p = try phone()
        for item in p.nodes.arrayValue("lines") {
            let l = SMSWire.decodeLine(deviceId: p.deviceId, key: item["key"]!.stringValue!, node: item["node"], crypto: p.crypto)
            let e = item["expect"]!
            XCTAssertEqual(l.subscriptionId, e["subscriptionId"]!.intValue)
            XCTAssertEqual(l.label, e["label"]!.stringValue); XCTAssertEqual(l.carrier, e["carrier"]!.stringValue)
            XCTAssertEqual(l.ownNumber, e["ownNumber"]!.stringValue, "decrypted own number")
            XCTAssertEqual(l.syncEnabled, e["syncEnabled"]!.boolValue)
        }
    }

    func testAndroidMessageNodesDecryptToTheExpectedText() throws {
        let p = try phone()
        let items = p.nodes.arrayValue("messages")
        XCTAssertEqual(items.count, 2)
        for item in items {
            guard case .message(let m) = SMSWire.decodeMessage(deviceId: p.deviceId, key: item["key"]!.stringValue!, node: item["node"], crypto: p.crypto) else { return XCTFail("did not decode") }
            let e = item["expect"]!
            XCTAssertEqual(m.address, e["address"]!.stringValue)
            XCTAssertEqual(m.body, e["body"]!.stringValue)            // includes ✅ é and a "/"
            XCTAssertEqual(m.date.timeIntervalSince1970 * 1000, e["dateMs"]!.doubleValue!, accuracy: 0.5)
            XCTAssertEqual(m.subscriptionId, e["subscriptionId"]!.intValue)
            XCTAssertEqual(m.read, e["read"]!.boolValue)
        }
    }

    /// The Android `threadKey` is an HMAC under a sub-key of the data key. Reproducing it in Swift from the same
    /// inputs proves the keyed-hash construction matches byte for byte.
    func testSwiftReproducesTheAndroidThreadKey() throws {
        let p = try phone()
        for item in p.nodes.arrayValue("messages") {
            guard case .message(let m) = SMSWire.decodeMessage(deviceId: p.deviceId, key: item["key"]!.stringValue!, node: item["node"], crypto: p.crypto) else { return XCTFail() }
            let ours = SMSWire.threadKey(crypto: p.crypto, deviceId: p.deviceId, subscriptionId: m.subscriptionId, address: m.address)
            XCTAssertEqual(ours, item["node"]!["threadKey"]!.stringValue, "threadKey for \(m.address)")
        }
    }

    func testAndroidClipboardNodes() throws {
        let p = try phone()
        let items = p.nodes.arrayValue("clipboard")
        XCTAssertEqual(items.count, 3)
        for item in items {
            let env = try XCTUnwrap(ClipboardEnvelope.from(item["node"]))
            let e = item["expect"]!
            XCTAssertEqual(try p.crypto.decrypt(env.contentEnc), e["text"]!.stringValue)
            XCTAssertEqual(env.kind, e["kind"]!.stringValue)
            XCTAssertEqual(env.language, e["language"]!.stringValue)
            XCTAssertEqual(env.deviceName, e["deviceName"]!.stringValue)
            XCTAssertEqual(env.createdAtMs, e["createdAt"]!.doubleValue)
        }
    }

    /// The reverse direction at the fixture level: what THIS package writes has the exact key set the Kotlin
    /// writer's `node()` produces, so the Kotlin/desktop parsers accept it. (The live Kotlin<->Swift round trip is
    /// scripts/e2e-kotlin-ios.sh.)
    func testOurClipboardNodeHasExactlyTheKotlinWriterKeys() throws {
        let p = try phone()
        let kotlinKeys = Set(p.nodes.arrayValue("clipboard")[1]["node"]!.objectValue!.keys)   // the `code` item carries `language`
        let ours = ClipboardEnvelope(itemId: "I", deviceId: "d", deviceName: "iPhone", kind: "code", contentEnc: try p.crypto.encrypt("x"), language: "swift", createdAtMs: 1)
        XCTAssertEqual(Set(ours.node().objectValue!.keys), kotlinKeys)
        let plain = ClipboardEnvelope(itemId: "I", deviceId: "d", deviceName: "iPhone", kind: "text", contentEnc: "v1:x", createdAtMs: 1)
        XCTAssertEqual(Set(plain.node().objectValue!.keys), Set(p.nodes.arrayValue("clipboard")[0]["node"]!.objectValue!.keys))
    }

    func testPhoneNodeFixtureIsInSyncWithTheRepoWhenPresent() throws {
        guard let root = Repo.root else { throw XCTSkip("not inside the repo") }
        let url = root.appendingPathComponent("docs/specs/wire-contract/phone-nodes.v1.json")
        guard let spec = try? Data(contentsOf: url) else { throw XCTSkip("phone-nodes.v1.json is not on this branch yet (it lives on feat/v2.6-desktop-hardening)") }
        XCTAssertEqual(try Fixture.data("phone-nodes.v1.json"), spec)
    }
}

extension JSONValue {
    func arrayValue(_ key: String) -> [JSONValue] { if case .array(let a)? = self[key] { return a } else { return [] } }
}
