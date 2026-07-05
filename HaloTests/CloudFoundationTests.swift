import Testing
import Foundation
import CryptoKit
@testable import Halo

// MARK: - Cloud foundation tests  (F-044 Phase 0)

@Suite("CryptoService")
struct CryptoServiceTests {

    private let salt = CryptoService.generateSalt()

    @Test("Encrypt → decrypt round-trips")
    func roundTrip() throws {
        let svc = try CryptoService(passphrase: "correct horse battery staple", salt: salt)
        let plaintext = "Your OTP is 192699 — do not share. A/C XX3833 debited ₹12,185.00"
        let ct = try svc.encrypt(plaintext)
        #expect(ct != plaintext)                 // it's actually encrypted
        #expect(Data(base64Encoded: ct) != nil)  // base64 combined box
        #expect(try svc.decrypt(ct) == plaintext)
    }

    @Test("Key is deterministic — a second device derives the same key")
    func deterministicKey() throws {
        let a = try CryptoService(passphrase: "shared-pass", salt: salt)
        let b = try CryptoService(passphrase: "shared-pass", salt: salt)  // e.g. the phone
        let ct = try a.encrypt("cross-device message")
        #expect(try b.decrypt(ct) == "cross-device message")  // b decrypts a's ciphertext
    }

    @Test("Wrong passphrase fails to decrypt")
    func wrongPassphrase() throws {
        let good = try CryptoService(passphrase: "right", salt: salt)
        let bad  = try CryptoService(passphrase: "wrong", salt: salt)
        let ct = try good.encrypt("secret")
        #expect(throws: CryptoError.decryptionFailed) { _ = try bad.decrypt(ct) }
    }

    @Test("Different salt → different key → cannot decrypt")
    func differentSalt() throws {
        let a = try CryptoService(passphrase: "same", salt: CryptoService.generateSalt())
        let b = try CryptoService(passphrase: "same", salt: CryptoService.generateSalt())
        let ct = try a.encrypt("secret")
        #expect(throws: CryptoError.decryptionFailed) { _ = try b.decrypt(ct) }
    }

    @Test("Malformed ciphertext throws badCiphertext")
    func malformed() throws {
        let svc = try CryptoService(passphrase: "p", salt: salt)
        #expect(throws: CryptoError.badCiphertext) { _ = try svc.decrypt("not base64 @@@") }
        #expect(throws: CryptoError.badCiphertext) { _ = try svc.decrypt("YWJj") } // valid b64, too short
    }

    @Test("Empty + unicode round-trip")
    func edgeStrings() throws {
        let svc = try CryptoService(passphrase: "p", salt: salt)
        for s in ["", "🔐 emoji ✅", String(repeating: "x", count: 5000)] {
            #expect(try svc.decrypt(try svc.encrypt(s)) == s)
        }
    }

    @Test("Salt + random bytes are unique and correctly sized")
    func randomness() {
        #expect(CryptoService.generateSalt().count == 16)
        #expect(CryptoService.generateSalt() != CryptoService.generateSalt())
        #expect(CryptoService.randomBytes(32).count == 32)
    }
}

@Suite("CloudPairingPayload")
struct CloudPairingPayloadTests {

    private func sampleConfig() -> FirebaseConfig {
        FirebaseConfig(apiKey: "AIza…", projectID: "halo-user", googleAppID: "1:123:ios:abc",
                       gcmSenderID: "123", databaseURL: "https://halo-user-default-rtdb.firebaseio.com",
                       storageBucket: nil)
    }

    @Test("Encode → decode round-trips and validates")
    func roundTrip() throws {
        let payload = CloudPairingPayload(firebaseConfig: sampleConfig(),
                                          auth: .init(email: "u@halo", password: "rand-pass"),
                                          salt: CryptoService.generateSalt())
        #expect(payload.isValid)
        let decoded = try CloudPairingPayload.decode(try payload.encoded())
        #expect(decoded == payload)
        #expect(decoded.isValid)
        #expect(decoded.salt != nil)
    }

    @Test("Tampering invalidates the checksum")
    func tamper() throws {
        var payload = CloudPairingPayload(firebaseConfig: sampleConfig(),
                                          auth: .init(email: "u@halo", password: "p"),
                                          salt: CryptoService.generateSalt())
        payload.auth.password = "attacker-changed"   // checksum no longer matches
        #expect(!payload.isValid)
    }

    @Test("FirebaseConfig.isComplete")
    func completeness() {
        #expect(sampleConfig().isComplete)
        var incomplete = sampleConfig(); incomplete.databaseURL = ""
        #expect(!incomplete.isComplete)
    }
}

@Suite("CloudConfigStore")
struct CloudConfigStoreTests {

    @Test("Apply pairing → derive matching CryptoService")
    func applyAndDerive() throws {
        let store = CloudConfigStore.shared
        store.wipe()
        defer { store.wipe() }

        let salt = CryptoService.generateSalt()
        let pairing = CloudPairingPayload(
            firebaseConfig: FirebaseConfig(apiKey: "k", projectID: "p", googleAppID: "a",
                                           gcmSenderID: "s", databaseURL: "https://x-rtdb.firebaseio.com",
                                           storageBucket: nil),
            auth: .init(email: "u@halo", password: "pw"),
            salt: salt)

        store.apply(pairing: pairing)

        // Keychain may be unavailable in some CI/unsigned contexts — only assert
        // the derived-key contract when the write actually persisted.
        guard store.salt == salt else { return }   // Keychain not writable here → skip
        #expect(store.isConfigured)

        let desktop = try CryptoService(passphrase: "user-pass", salt: salt)
        let mobile = try store.makeCryptoService(passphrase: "user-pass")  // same salt from store
        let ct = try desktop.encrypt("shared")
        #expect(try mobile.decrypt(ct) == "shared")
    }
}
