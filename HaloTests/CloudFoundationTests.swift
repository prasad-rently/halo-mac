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

// MARK: - GoogleOAuthPKCE (F-044 S2 spike — loopback + PKCE provisioning flow)

@Suite("GoogleOAuthPKCE")
struct GoogleOAuthPKCETests {

    // RFC 7636 Appendix B known-answer vector for the S256 challenge.
    @Test("PKCE S256 challenge matches the RFC 7636 test vector")
    func rfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated verifier is url-safe and correctly sized; challenge is derived")
    func generation() {
        let p = PKCE.generate()
        #expect((43...128).contains(p.verifier.count))
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(p.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(p.challenge == PKCE.challenge(for: p.verifier))
        #expect(!p.challenge.contains("=") && !p.challenge.contains("+") && !p.challenge.contains("/"))
    }

    @Test("Authorization URL carries the PKCE + native-flow query params")
    func authURL() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(
            clientID: "cid.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:53127/callback",
            scopes: [GoogleOAuth.cloudPlatformScope],
            pkce: pkce, state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(val("response_type") == "code")
        #expect(val("code_challenge") == pkce.challenge)
        #expect(val("code_challenge_method") == "S256")
        #expect(val("scope") == GoogleOAuth.cloudPlatformScope)
        #expect(val("client_id") == "cid.apps.googleusercontent.com")
        #expect(val("state") == "xyz")
    }

    @Test("Token exchange request is a form POST with the verifier")
    func tokenRequest() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let req = GoogleOAuth.tokenExchangeRequest(
            clientID: "cid", clientSecret: nil, code: "abc",
            redirectURI: "http://127.0.0.1:53127/callback", pkce: pkce)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        #expect(body.contains("code=abc"))
        #expect(!body.contains("client_secret"))   // omitted when nil
    }
}

// MARK: - Clipboard sync (F-045)

@Suite("ClipboardSensitiveFilter")
struct ClipboardSensitiveFilterTests {
    @Test("Flags likely secrets")
    func flagsSecrets() {
        #expect(ClipboardSensitiveFilter.isSensitive("password: hunter2"))
        #expect(ClipboardSensitiveFilter.isSensitive("ghp_1234567890abcdefghij12345"))
        #expect(ClipboardSensitiveFilter.isSensitive("AKIAIOSFODNN7EXAMPLE"))
        #expect(ClipboardSensitiveFilter.isSensitive("-----BEGIN RSA PRIVATE KEY-----"))
    }
    @Test("Passes ordinary content")
    func passesNormal() {
        #expect(!ClipboardSensitiveFilter.isSensitive("Hello, world"))
        #expect(!ClipboardSensitiveFilter.isSensitive("https://example.com/page"))
        #expect(!ClipboardSensitiveFilter.isSensitive(""))
    }
}

@Suite("ClipboardSyncEnvelope")
struct ClipboardSyncEnvelopeTests {
    @Test("node() → from() round-trips")
    func nodeRoundTrip() {
        let env = ClipboardSyncEnvelope(itemId: "id1", deviceId: "devA", deviceName: "Phone",
                                        kind: "code", contentEnc: "CIPHER", language: "swift",
                                        createdAt: 1_720_000_000_000)
        #expect(ClipboardSyncEnvelope.from(env.node()) == env)
    }
    @Test("Rejects malformed nodes")
    func rejectsBad() {
        #expect(ClipboardSyncEnvelope.from(["itemId": "x"]) == nil)
        #expect(ClipboardSyncEnvelope.from("nope") == nil)
    }
}

@Suite("ClipboardSync serialize/deserialize")
@MainActor
struct ClipboardSyncCodecTests {
    @Test("Encrypt → envelope → decrypt reproduces a code item with provenance")
    func encryptRoundTrip() throws {
        let crypto = try CryptoService(passphrase: "pw", salt: CryptoService.generateSalt())
        let original = ClipboardItem(content: .code("let x = 1", language: "swift"))
        let s = try #require(ClipboardSyncService.serialize(original.content))
        let env = ClipboardSyncEnvelope(
            itemId: original.id.uuidString, deviceId: "devA", deviceName: "Phone",
            kind: s.kind, contentEnc: try crypto.encrypt(s.text), language: s.lang,
            createdAt: original.copiedDate.timeIntervalSince1970 * 1000)
        let parsed = try #require(ClipboardSyncEnvelope.from(env.node()))
        let item = ClipboardSyncService.makeItem(parsed, text: try crypto.decrypt(parsed.contentEnc))
        #expect(item.syncedFrom == "Phone")
        if case let .code(c, lang) = item.content { #expect(c == "let x = 1"); #expect(lang == "swift") }
        else { Issue.record("expected .code content") }
    }
    @Test("Images and colors are not syncable (v1)")
    func nonSyncable() {
        #expect(ClipboardSyncService.serialize(.image(Data(), metadata: nil)) == nil)
        #expect(ClipboardSyncService.serialize(.color(hex: "#ffffff")) == nil)
    }
    @Test("URL kind reconstructs a .url item")
    func urlKind() {
        let env = ClipboardSyncEnvelope(itemId: UUID().uuidString, deviceId: "d", deviceName: "Mac",
                                        kind: "url", contentEnc: "x", language: nil, createdAt: 0)
        let item = ClipboardSyncService.makeItem(env, text: "https://halo.mac")
        if case let .url(u) = item.content { #expect(u.absoluteString == "https://halo.mac") }
        else { Issue.record("expected .url content") }
    }
}
