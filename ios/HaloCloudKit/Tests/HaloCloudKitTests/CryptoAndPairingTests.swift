import XCTest
import CryptoKit
@testable import HaloCloudKit

final class CryptoTests: XCTestCase {
    let salt = Data((1...16).map(UInt8.init))
    func make(_ p: String = "contract test passphrase 1") throws -> CryptoService { try CryptoService(passphrase: p, salt: salt, iterations: 100_000) }

    func testRoundTripIncludingUnicodeAndSlash() throws {
        let c = try make()
        for s in ["", "hello", "Rs 500 ✅ café / ok https://x.y/z?a=b", String(repeating: "é", count: 5000)] {
            XCTAssertEqual(try c.decrypt(try c.encrypt(s)), s)
        }
    }

    func testEnvelopeShapeAndFreshNonce() throws {
        let c = try make()
        let a = try c.encrypt("same"), b = try c.encrypt("same")
        XCTAssertTrue(a.hasPrefix("v1:"))
        XCTAssertNotEqual(a, b, "a random nonce per message")
        XCTAssertEqual(Data(base64Encoded: String(a.dropFirst(3)))!.count, 12 + 4 + 16)
    }

    // SECURITY: wrong key must fail (mutation-checked: see PR).
    func testWrongKeyCannotDecrypt() throws {
        let ct = try make().encrypt("secret body")
        XCTAssertThrowsError(try make("a different passphrase 2").decrypt(ct)) { XCTAssertEqual($0 as? CloudError, .decryptionFailed) }
    }

    // SECURITY: a single flipped bit anywhere in nonce, ciphertext or tag must be rejected.
    func testTamperedCiphertextIsRejectedAtEveryByte() throws {
        let c = try make()
        let raw = Data(base64Encoded: String(try c.encrypt("hello halo").dropFirst(3)))!
        for i in 0..<raw.count {
            var t = raw; t[i] ^= 0x01
            XCTAssertThrowsError(try c.decrypt("v1:" + t.base64EncodedString()), "byte \(i)")
        }
    }

    // SECURITY: the prefix is authenticated — a v1 body with the prefix stripped (v0 read) must not open.
    func testPrefixStrippedV1BodyDoesNotOpen() throws {
        let c = try make()
        let body = String(try c.encrypt("x").dropFirst(3))
        XCTAssertThrowsError(try c.decrypt(body))
    }

    func testKdfRefusesUnsafeInputs() {
        XCTAssertThrowsError(try CryptoService.deriveKey(passphrase: "", salt: salt, iterations: 100_000))
        XCTAssertThrowsError(try CryptoService.deriveKey(passphrase: "x", salt: Data([1]), iterations: 100_000))
        XCTAssertThrowsError(try CryptoService.deriveKey(passphrase: "x", salt: salt, iterations: 99_999))
        XCTAssertThrowsError(try CryptoService.deriveKey(passphrase: "x", salt: salt, iterations: 2_000_000_000), "a hostile code must not pin the CPU")
    }

    func testRandomBytesFailureIsNotZeroBytes() {
        XCTAssertThrowsError(try CryptoService.randomBytes(16, fill: { _, _ in errSecParam })) { XCTAssertEqual($0 as? CloudError, .randomGenerationFailed) }
    }

    func testExportedKeyRebuildsAnInteroperableService() throws {
        let a = try make()
        let b = try CryptoService(keyData: a.exportKey())
        XCTAssertEqual(try b.decrypt(try a.encrypt("persisted key")), "persisted key")
        XCTAssertThrowsError(try CryptoService(keyData: Data(count: 5)))
    }
}

final class PairingTests: XCTestCase {
    static let config = FirebaseConfig(apiKey: "test-api-key", projectID: "p", googleAppID: "1:2:ios:3", gcmSenderID: "2",
                                       databaseURL: "https://p-default-rtdb.firebaseio.com")
    static let auth = CloudAuthCredential(email: "a@b.test", password: "pw-test-only")
    let salt = Data((1...16).map(UInt8.init))

    func code(config: FirebaseConfig = config, iterations: Int = 100_000) throws -> String {
        try PairingPayload(firebaseConfig: config, auth: Self.auth, salt: salt, iterations: iterations).encoded()
    }

    func testRoundTrip() throws {
        let p = try PairingCode.parse(try code())
        XCTAssertEqual(p.firebaseConfig, Self.config); XCTAssertEqual(p.auth, Self.auth); XCTAssertEqual(p.salt, salt); XCTAssertEqual(p.schema, 2)
    }

    func testPastedCodeSurvivesWrappingWhitespaceAndQuotes() throws {
        let c = try code()
        let wrapped = "  \"" + stride(from: 0, to: c.count, by: 60).map { String(c.dropFirst($0).prefix(60)) }.joined(separator: "\n") + "\"\n"
        XCTAssertNoThrow(try PairingCode.parse(wrapped))
    }

    func testGarbageAndOversizeAreMalformed() {
        for bad in ["", "   ", "hello world", "!!!!", "e30=", String(repeating: "A", count: 9000)] {
            XCTAssertThrowsError(try PairingCode.parse(bad), bad.prefix(10).description) { XCTAssertEqual($0 as? CloudError, .malformedPairingCode) }
        }
    }

    func testTamperedFieldFailsChecksum() throws {
        var p = try PairingCode.parse(try code())
        p.auth.password = "other"
        XCTAssertThrowsError(try PairingCode.parse(try p.encoded())) { XCTAssertEqual($0 as? CloudError, .pairingChecksumMismatch) }
    }

    func testIterationDowngradeIsRefused() throws {
        var p = try PairingCode.parse(try code(iterations: 600_000))
        p.iterations = 100_000      // downgraded after the checksum was made
        XCTAssertThrowsError(try PairingCode.parse(try p.encoded())) { XCTAssertEqual($0 as? CloudError, .pairingChecksumMismatch) }
    }

    func testWeakOrExcessiveIterationsAndShortSaltAreRefusedEvenWithAValidChecksum() throws {
        for it in [1_000, 50_000_000] {
            let c = try PairingPayload(firebaseConfig: Self.config, auth: Self.auth, salt: salt, iterations: it).encoded()
            XCTAssertThrowsError(try PairingCode.parse(c), "\(it)")
        }
        let short = try PairingPayload(firebaseConfig: Self.config, auth: Self.auth, salt: Data([1, 2, 3])).encoded()
        XCTAssertThrowsError(try PairingCode.parse(short))
    }

    func testNewerSchemaIsRefusedWithAClearError() throws {
        var p = PairingPayload(firebaseConfig: Self.config, auth: Self.auth, salt: salt, iterations: 100_000)
        p.schema = 3
        p.checksum = PairingPayload.checksum(config: p.firebaseConfig, auth: p.auth, saltBase64: p.saltBase64, schema: 3, iterations: p.iterations)
        XCTAssertThrowsError(try PairingCode.parse(try p.encoded())) { XCTAssertEqual($0 as? CloudError, .unsupportedPairingSchema(3)) }
    }

    // SECURITY: credentials must only ever go to https (or an explicitly allowed loopback stand-in).
    func testPlainHTTPAndLANDatabasesAreRefused() throws {
        for url in ["http://p.firebaseio.com", "http://192.168.1.5:9199", "ftp://x.y", "p.firebaseio.com", "http://127.0.0.1.evil.com"] {
            var c = Self.config; c.databaseURL = url
            XCTAssertThrowsError(try PairingCode.parse(try code(config: c)), url) { XCTAssertEqual($0 as? CloudError, .configureFailed, url) }
        }
        var lo = Self.config; lo.databaseURL = "http://127.0.0.1:9199"
        XCTAssertThrowsError(try PairingCode.parse(try code(config: lo)), "loopback http is off by default")
        XCTAssertNoThrow(try PairingCode.parse(try code(config: lo), allowLoopbackHTTP: true))
        lo.databaseURL = "http://192.168.1.5:9199"
        XCTAssertThrowsError(try PairingCode.parse(try code(config: lo), allowLoopbackHTTP: true), "only loopback, never a LAN host")
    }

    func testStandInAuthEndpointsOnlyForLoopbackInDebug() {
        XCTAssertEqual(AuthEndpoints.forDatabase("https://p.firebaseio.com", allowLoopbackHTTP: true), .google)
        XCTAssertEqual(AuthEndpoints.forDatabase("http://127.0.0.1:9199", allowLoopbackHTTP: false), .google, "release never redirects credentials")
        XCTAssertEqual(AuthEndpoints.forDatabase("http://127.0.0.1:9199", allowLoopbackHTTP: true).identityToolkit.absoluteString, "http://127.0.0.1:9199/identitytoolkit/v1")
    }

    func testPassphraseConfirmationRules() {
        XCTAssertTrue(PairingConfirmation.matches("café passphrase", "cafe\u{301} passphrase"), "NFC-equal")
        XCTAssertFalse(PairingConfirmation.matches("pass phrase 1", "pass phrase 1 "))
        XCTAssertFalse(PairingConfirmation.matches("Passphrase", "passphrase"))
        XCTAssertTrue(PairingConfirmation.required(for: .noSample))
        XCTAssertFalse(PairingConfirmation.required(for: .match))
        XCTAssertFalse(PairingConfirmation.required(for: .mismatch))
    }
}
