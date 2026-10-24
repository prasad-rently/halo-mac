import Testing
import Foundation
import CryptoKit
@testable import Halo

// MARK: - Cloud foundation tests  (F-044 Phase 0)

/// PBKDF2 at the 600 000-round default costs ~1 s a derivation; the suite runs dozens.
/// Everything that is not *about* the iteration count uses the enforced floor instead,
/// which is the same code path at a sixth of the price.
private let fastIterations = CryptoService.minimumIterations

@Suite("CryptoService")
struct CryptoServiceTests {

    private let salt = try! CryptoService.generateSalt()

    private func svc(_ pass: String, salt: Data? = nil) throws -> CryptoService {
        try CryptoService(passphrase: pass, salt: salt ?? self.salt, iterations: fastIterations)
    }

    @Test("Encrypt → decrypt round-trips")
    func roundTrip() throws {
        let s = try svc("correct horse battery staple")
        let plaintext = "Your OTP is 192699 — do not share. A/C XX3833 debited ₹12,185.00"
        let ct = try s.encrypt(plaintext)
        #expect(ct != plaintext)                       // it's actually encrypted
        #expect(ct.hasPrefix(CryptoService.envelopePrefix))
        #expect(Data(base64Encoded: String(ct.dropFirst(3))) != nil)   // base64 combined box
        #expect(try s.decrypt(ct) == plaintext)
    }

    @Test("Key is deterministic — a second device derives the same key")
    func deterministicKey() throws {
        let a = try svc("shared-pass")
        let b = try svc("shared-pass")                 // e.g. the phone
        let ct = try a.encrypt("cross-device message")
        #expect(try b.decrypt(ct) == "cross-device message")
    }

    @Test("Wrong passphrase fails to decrypt")
    func wrongPassphrase() throws {
        let good = try svc("right"), bad = try svc("wrong")
        let ct = try good.encrypt("secret")
        #expect(throws: CryptoError.decryptionFailed) { _ = try bad.decrypt(ct) }
    }

    @Test("Different salt → different key → cannot decrypt")
    func differentSalt() throws {
        let a = try svc("same", salt: try CryptoService.generateSalt())
        let b = try svc("same", salt: try CryptoService.generateSalt())
        let ct = try a.encrypt("secret")
        #expect(throws: CryptoError.decryptionFailed) { _ = try b.decrypt(ct) }
    }

    @Test("Malformed ciphertext throws badCiphertext")
    func malformed() throws {
        let s = try svc("p")
        #expect(throws: CryptoError.badCiphertext) { _ = try s.decrypt("not base64 @@@") }
        #expect(throws: CryptoError.badCiphertext) { _ = try s.decrypt("YWJj") }      // valid b64, too short
        #expect(throws: CryptoError.badCiphertext) { _ = try s.decrypt("v1:@@@") }
        #expect(throws: CryptoError.badCiphertext) { _ = try s.decrypt("v1:YWJj") }
    }

    @Test("Empty + unicode round-trip")
    func edgeStrings() throws {
        let s = try svc("p")
        for text in ["", "🔐 emoji ✅", String(repeating: "x", count: 5000)] {
            #expect(try s.decrypt(try s.encrypt(text)) == text)
        }
    }

    @Test("Salt + random bytes are unique and correctly sized")
    func randomness() throws {
        #expect(try CryptoService.generateSalt().count == 16)
        #expect(try CryptoService.generateSalt() != CryptoService.generateSalt())
        #expect(try CryptoService.randomBytes(32).count == 32)
    }

    // MARK: Review finding 1 — a zero salt must be unrepresentable

    @Test("A generated salt is never all zeros (SecRandomCopyBytes status is checked)")
    func saltNeverZero() throws {
        // 16 random bytes are all-zero with probability 2^-128: if this ever fails the
        // RNG result is being discarded again, which is exactly the regression.
        for _ in 0..<64 {
            let salt = try CryptoService.generateSalt()
            #expect(salt.contains(where: { $0 != 0 }))
        }
        #expect(try CryptoService.randomBytes(256).contains(where: { $0 != 0 }))
    }

    @Test("An RNG failure throws — it never returns a zero-filled buffer that looks valid")
    func rngFailureThrows() {
        // The regression: the old code ignored the status and handed back `count` zeros.
        #expect(throws: CryptoError.randomGenerationFailed) {
            _ = try CryptoService.randomBytes(16, fill: { _, _ in errSecAllocate })
        }
        // And a "successful" fill is returned as written, not replaced.
        let filled = try? CryptoService.randomBytes(8, fill: { n, p in
            memset(p, 0xAB, n); return errSecSuccess
        })
        #expect(filled == Data(repeating: 0xAB, count: 8))
    }

    @Test("A salt shorter than the floor is refused, not used")
    func shortSaltRefused() {
        #expect(throws: CryptoError.self) {
            _ = try CryptoService.deriveKey(passphrase: "a long enough passphrase",
                                            salt: Data([1]), iterations: fastIterations)
        }
        #expect(throws: CryptoError.self) {
            _ = try CryptoService.deriveKey(passphrase: "a long enough passphrase",
                                            salt: Data(repeating: 7, count: 15), iterations: fastIterations)
        }
    }

    // MARK: Review finding 5/6 — KDF preconditions and cost

    @Test("Empty passphrase and sub-floor iterations are refused")
    func kdfPreconditions() {
        #expect(throws: CryptoError.self) {
            _ = try CryptoService.deriveKey(passphrase: "", salt: Data(repeating: 1, count: 16), iterations: fastIterations)
        }
        #expect(throws: CryptoError.self) {
            _ = try CryptoService.deriveKey(passphrase: "x", salt: Data(repeating: 1, count: 16),
                                            iterations: CryptoService.minimumIterations - 1)
        }
        #expect(throws: CryptoError.self) {
            _ = try CryptoService.deriveKey(passphrase: "x", salt: Data(repeating: 1, count: 16), iterations: 0)
        }
    }

    @Test("New keys default to the OWASP 600 000; the legacy 200 000 still derives")
    func iterationConstants() throws {
        #expect(CryptoService.defaultIterations == 600_000)
        #expect(CryptoService.legacyIterations == 200_000)
        #expect(CryptoService.legacyIterations >= CryptoService.minimumIterations)
        // The legacy count must remain *acceptable* input, or old keys would be stranded.
        _ = try CryptoService.deriveKey(passphrase: "legacy key", salt: Data(repeating: 9, count: 16),
                                        iterations: CryptoService.legacyIterations)
    }

    @Test("Different iteration counts derive different keys")
    func iterationsMatter() throws {
        let s = Data(repeating: 3, count: 16)
        let a = try CryptoService(passphrase: "same passphrase", salt: s, iterations: 100_000)
        let b = try CryptoService(passphrase: "same passphrase", salt: s, iterations: 100_001)
        #expect(throws: CryptoError.decryptionFailed) { _ = try b.decrypt(try a.encrypt("x")) }
    }

    // MARK: Review finding 4 — versioned envelope

    @Test("Ciphertext is a v1 envelope; the plain-base64 form is no longer written")
    func envelopeIsVersioned() throws {
        let ct = try svc("p").encrypt("hello")
        #expect(ct.hasPrefix("v1:"))
        #expect(!ct.dropFirst(3).contains(":"))
    }

    @Test("A legacy (v0) box — no prefix, no AAD — still decrypts")
    func legacyBoxStillReads() throws {
        let key = try CryptoService.deriveKey(passphrase: "old passphrase", salt: salt, iterations: fastIterations)
        let legacy = try AES.GCM.seal(Data("from the old branch".utf8), using: key).combined!.base64EncodedString()
        let s = try svc("old passphrase")
        #expect(try s.decrypt(legacy) == "from the old branch")
    }

    @Test("The version prefix cannot be stripped or forged to downgrade a message")
    func prefixIsAuthenticated() throws {
        let s = try svc("p")
        let v1 = try s.encrypt("secret")
        // v1 body presented as v0: AAD mismatch → authentication failure.
        #expect(throws: CryptoError.decryptionFailed) { _ = try s.decrypt(String(v1.dropFirst(3))) }
        // v0 body wearing a v1 prefix: never sealed with the AAD → failure.
        let key = try CryptoService.deriveKey(passphrase: "p", salt: salt, iterations: fastIterations)
        let v0 = try AES.GCM.seal(Data("secret".utf8), using: key).combined!.base64EncodedString()
        #expect(throws: CryptoError.decryptionFailed) { _ = try s.decrypt("v1:" + v0) }
    }

    @Test("Each encryption uses a fresh nonce")
    func freshNonce() throws {
        let s = try svc("p")
        #expect(try s.encrypt("same") != s.encrypt("same"))
    }

    @Test("Encrypt failures are reported as encryption, not decryption (finding 8)")
    func errorsAreDistinct() {
        #expect(CryptoError.encryptionFailed != CryptoError.decryptionFailed)
        #expect(CryptoError.encryptionFailed.errorDescription?.lowercased().contains("encrypt") == true)
        #expect(CryptoError.decryptionFailed.errorDescription?.lowercased().contains("decrypt") == true)
    }
}

// MARK: - PassphrasePolicy (review finding 3)

@Suite("PassphrasePolicy")
struct PassphrasePolicyTests {

    @Test("A one-character passphrase — the review's example — is rejected")
    func singleCharacter() {
        #expect(PassphrasePolicy.evaluate("a") == .tooShort(have: 1))
        #expect(!PassphrasePolicy.evaluate("a").isAcceptable)
        #expect(PassphrasePolicy.evaluate("").message != nil)
    }

    @Test("Length floor is exactly 12")
    func lengthFloor() {
        #expect(PassphrasePolicy.evaluate("abcdefghijk") == .tooShort(have: 11))
        #expect(PassphrasePolicy.evaluate("abcdefghijkl") == .ok)
    }

    @Test("Long but repetitive passphrases are rejected")
    func repetitive() {
        #expect(PassphrasePolicy.evaluate(String(repeating: "a", count: 40)) == .tooRepetitive)
        #expect(PassphrasePolicy.evaluate("abcabcabcabc") == .tooRepetitive)
        #expect(PassphrasePolicy.evaluate("abcdefabcdef") == .ok)      // exactly 6 distinct
    }

    @Test("Characters are counted after NFC normalisation, so combining marks are not double-counted")
    func nfcCounting() {
        // Six "é" written as e + U+0301 is 12 code points but 6 characters.
        let decomposed = String(repeating: "e\u{0301}", count: 6)
        #expect(PassphrasePolicy.evaluate(decomposed) == .tooShort(have: 6))
    }

    @Test("Messages are shown only when there is something to fix")
    func messages() {
        #expect(PassphrasePolicy.evaluate("correct horse battery staple").message == nil)
        #expect(PassphrasePolicy.evaluate("short").message?.contains("12") == true)
    }

    @Test("Existing weak keys can still be derived — the floor is for choosing, not unlocking")
    func derivationDoesNotEnforcePolicy() throws {
        _ = try CryptoService(passphrase: "p", salt: Data(repeating: 1, count: 16), iterations: fastIterations)
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
                                          salt: try CryptoService.generateSalt())
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
                                          salt: try CryptoService.generateSalt())
        payload.auth.password = "attacker-changed"   // checksum no longer matches
        #expect(!payload.isValid)
    }

    @Test("A new payload is schema 2 and carries the KDF cost")
    func carriesIterations() throws {
        let payload = CloudPairingPayload(firebaseConfig: sampleConfig(), auth: .init(email: "u", password: "p"),
                                          salt: try CryptoService.generateSalt())
        #expect(payload.schema == 2)
        #expect(payload.iterations == CryptoService.defaultIterations)
        let decoded = try CloudPairingPayload.decode(try payload.encoded())
        #expect(decoded.iterations == CryptoService.defaultIterations)
        #expect(decoded.isValid)
    }

    @Test("The iteration count is covered by the checksum — it cannot be downgraded in transit")
    func iterationsAreChecksummed() throws {
        var payload = CloudPairingPayload(firebaseConfig: sampleConfig(), auth: .init(email: "u", password: "p"),
                                          salt: try CryptoService.generateSalt())
        payload.iterations = CryptoService.minimumIterations
        #expect(!payload.isValid)
    }

    @Test("A schema-1 payload (no iterations field) still decodes, validates and means 200 000")
    func schemaOneStillReads() throws {
        let cfg = sampleConfig(), auth = CloudAuthCredential(email: "u@halo", password: "pw")
        let salt = Data(repeating: 5, count: 16).base64EncodedString()
        let checksum = CloudPairingPayload.checksum(config: cfg, auth: auth, saltBase64: salt,
                                                    schema: 1, iterations: 123 /* ignored by schema 1 */)
        let json: [String: Any] = [
            "firebaseConfig": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cfg)),
            "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth)),
            "saltBase64": salt, "schema": 1, "checksum": checksum]
        let b64 = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        let decoded = try CloudPairingPayload.decode(b64)
        #expect(decoded.schema == 1)
        #expect(decoded.iterations == CryptoService.legacyIterations)
        #expect(decoded.isValid)
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

        let salt = try CryptoService.generateSalt()
        let pairing = CloudPairingPayload(
            firebaseConfig: FirebaseConfig(apiKey: "k", projectID: "p", googleAppID: "a",
                                           gcmSenderID: "s", databaseURL: "https://x-rtdb.firebaseio.com",
                                           storageBucket: nil),
            auth: .init(email: "u@halo", password: "pw"),
            salt: salt, iterations: fastIterations)

        store.apply(pairing: pairing)

        // Keychain may be unavailable in some CI/unsigned contexts — only assert
        // the derived-key contract when the write actually persisted.
        guard store.salt == salt else { return }   // Keychain not writable here → skip
        #expect(store.isConfigured)

        #expect(store.kdfIterations == fastIterations)       // the cost travels with the salt
        let desktop = try CryptoService(passphrase: "user-pass", salt: salt, iterations: fastIterations)
        let mobile = try store.makeCryptoService(passphrase: "user-pass")  // same salt + cost from store
        let ct = try desktop.encrypt("shared")
        #expect(try mobile.decrypt(ct) == "shared")
    }

    @Test("A salt stored before iterations were recorded derives at the legacy cost, not the new default")
    func legacySaltKeepsLegacyCost() throws {
        let store = CloudConfigStore.shared
        store.wipe()
        defer { store.wipe() }

        let salt = Data(repeating: 0x42, count: 16)
        store.salt = salt                                    // as an old install left it: no kdfIterations
        guard store.salt == salt else { return }             // Keychain not writable here → skip
        #expect(store.kdfIterations == nil)

        let old = try CryptoService(passphrase: "old key", salt: salt, iterations: CryptoService.legacyIterations)
        let viaStore = try store.makeCryptoService(passphrase: "old key")
        #expect(try viaStore.decrypt(try old.encrypt("still readable")) == "still readable")
    }

    @Test("wipe() removes the stored iteration count too")
    func wipeClearsIterations() {
        let store = CloudConfigStore.shared
        store.wipe()
        store.salt = Data(repeating: 1, count: 16)
        store.kdfIterations = 600_000
        guard store.kdfIterations == 600_000 else { store.wipe(); return }   // Keychain not writable
        store.wipe()
        #expect(store.kdfIterations == nil)
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
    func generation() throws {
        let p = try PKCE.generate()
        #expect((43...128).contains(p.verifier.count))
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(p.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(p.challenge == PKCE.challenge(for: p.verifier))
        #expect(!p.challenge.contains("=") && !p.challenge.contains("+") && !p.challenge.contains("/"))
    }

    @Test("A generated verifier is never the constant a failed RNG would produce (finding 2)")
    func verifierIsNotTheZeroConstant() throws {
        let zeroVerifier = PKCE.base64url(Data(repeating: 0, count: 32))
        let a = try PKCE.generate(), b = try PKCE.generate()
        #expect(a.verifier != zeroVerifier)
        #expect(a.verifier != b.verifier)
        #expect(a.challenge != b.challenge)
    }

    @Test("State values are random, url-safe, and validated in constant time")
    func stateRoundTrip() throws {
        let s1 = try PKCE.generateState(), s2 = try PKCE.generateState()
        #expect(s1 != s2)
        #expect(s1.count >= 22)
        #expect(!s1.contains("=") && !s1.contains("+") && !s1.contains("/"))
        #expect(PKCE.validate(state: s1, against: s1))
        #expect(!PKCE.validate(state: s1, against: s2))
        #expect(!PKCE.validate(state: String(s1.dropLast()), against: s1))   // length mismatch
        #expect(!PKCE.validate(state: "", against: ""))                      // empty is never valid
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
    @Test("Git SHAs and MD5s are not secrets; 256-bit hex key material is (finding 10)")
    func hexRule() {
        #expect(!ClipboardSensitiveFilter.isSensitive("9fceb02d0ae598e95dc970b74767f19372d61af8"))      // git SHA-1, 40
        #expect(!ClipboardSensitiveFilter.isSensitive("d41d8cd98f00b204e9800998ecf8427e"))              // MD5, 32
        #expect(ClipboardSensitiveFilter.isSensitive(String(repeating: "a1", count: 32)))               // 64 hex
        #expect(ClipboardSensitiveFilter.isSensitive(String(repeating: "0f", count: 40)))               // 80 hex
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
        let crypto = try CryptoService(passphrase: "pw", salt: try CryptoService.generateSalt(),
                                       iterations: fastIterations)
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

// MARK: - Expenditure parser + pipeline (F-048 — Hamza corpus)

@Suite("TransactionParser")
struct TransactionParserTests {
    let pack = PatternPack.indiaDefault

    private func ok(_ sender: String, _ body: String) -> ParsedTransaction? {
        if case let .ok(t) = TransactionParser.parse(sender: sender, body: body,
            messageId: "m", date: Date(), pack: pack) { return t }
        return nil
    }

    @Test("Debit with UPI; balance without a currency token is ignored")
    func basicDebit() {
        let t = ok("CP-INDUSB-S", "A/C *XX3833 debited by Rs 1250.00 via UPI. Avl Bal:8420.10 -IndusInd")
        #expect(t?.direction == .debit)
        #expect(t?.amount == 1250.00)
        #expect(t?.accountHint == "3833")
    }

    @Test("Balance amount WITH a currency token is dropped (nearest-to-verb wins)")
    func dropsBalance() {
        let t = ok("VK-HDFCBK-T", "Rs.1250.00 debited from A/C. Avl Bal Rs.8420.10")
        #expect(t?.amount == 1250.00)
    }

    @Test("Nearest-to-verb chooses the transaction amount over an earlier one")
    func nearestToVerb() {
        let t = ok("VK-HDFCBK-T", "Rs.8420.10 is your reward. Rs.1250 debited for purchase")
        #expect(t?.amount == 1250)
    }

    @Test("Credit is income")
    func credit() {
        let t = ok("VK-SBIINB-T", "Rs.5,000.00 credited to A/C XX1234")
        #expect(t?.direction == .credit)
        #expect(t?.amount == 5000)
    }

    @Test("Promotional -P sender is not a transaction")
    func promoSender() {
        #expect(ok("VM-AXISBK-P", "Rs.999 debited") == nil)
    }

    @Test("Non-bank sender is rejected (merchant in body from a bank still counts)")
    func nonBankSender() {
        #expect(ok("AMAZON", "Rs.500 debited") == nil)
        #expect(ok("VK-HDFCBK-T", "Rs.500 spent at AMAZON on card")?.amount == 500)
    }

    @Test("Future-autopay announcement is excluded; actual execution counts")
    func autopay() {
        #expect(ok("VK-HDFCBK-T", "Rs.500 will be debited on 5th for SIP") == nil)
        #expect(ok("VK-HDFCBK-T", "Rs.500 debited for SIP e-mandate")?.amount == 500)
    }

    @Test("Bug A: a fraud-report URL does not reject a real UPI debit")
    func urlNotReject() {
        let t = ok("VK-KOTAKB-T", "Rs.500 sent via UPI. Report fraud at http://kotak.com/x")
        #expect(t?.direction == .debit)
        #expect(t?.amount == 500)
    }

    @Test("Bug B: TXN RS is a debit verb for verb-less card txns")
    func txnRsVerb() {
        let t = ok("VK-HDFCBK-T", "Txn Rs.522 On Card XX11 At paytm")
        #expect(t?.direction == .debit)
        #expect(t?.amount == 522)
    }

    @Test("Verb but no currency amount → Unreadable")
    func unreadable() {
        if case .unreadable = TransactionParser.parse(sender: "VK-HDFCBK-T",
            body: "Your account was debited today", messageId: "m", date: Date(), pack: pack) {} 
        else { Issue.record("expected .unreadable") }
    }

    @Test("Category resolves from merchant/keyword")
    func category() {
        #expect(pack.category(merchant: "ZOMATO", body: "spent at zomato", direction: .debit) == "Food & Dining")
        #expect(pack.category(merchant: nil, body: "credited salary", direction: .credit) == "Income")
    }
}

@Suite("TransactionPipeline")
@MainActor
struct TransactionPipelineTests {
    let pack = PatternPack.indiaDefault

    private func msg(_ id: String, _ body: String, _ date: Date, sender: String = "VK-HDFCBK-T") -> SMSMessage {
        SMSMessage(id: id, lineId: "L", contactNumber: sender, body: body, date: date,
                   category: .transactional, read: true)
    }

    @Test("Self-transfer: same-day same-amount debit+credit is excluded from totals")
    func selfTransfer() {
        let day = Date()
        let r = TransactionPipeline.run(messages: [
            msg("a", "Rs.1000 debited via UPI", day),
            msg("b", "Rs.1000 credited to A/C", day.addingTimeInterval(60))
        ], pack: pack, overrides: .init())
        let allTransfers = r.transactions.allSatisfy(\.isTransfer)
        let noneCount = r.transactions.filter(\.countsTowardTotals).count
        #expect(allTransfers)
        #expect(noneCount == 0)
    }

    @Test("Near-duplicate: same amount+direction within window collapses to one")
    func dedup() {
        let day = Date()
        let r = TransactionPipeline.run(messages: [
            msg("a", "Rs.750 debited via UPI", day, sender: "VK-HDFCBK-T"),
            msg("b", "Rs.750 debited via UPI", day.addingTimeInterval(30), sender: "VK-ICICIB-T")
        ], pack: pack, overrides: .init())
        let dupCount = r.transactions.filter(\.isDuplicate).count
        let countable = r.transactions.filter(\.countsTowardTotals).count
        #expect(dupCount == 1)
        #expect(countable == 1)
    }

    @Test("Override: force-exclude removes a transaction")
    func overrideExclude() {
        var ov = ExpenditureOverrides(); ov.excludedIds = ["a"]
        let r = TransactionPipeline.run(messages: [msg("a", "Rs.100 debited", Date())],
                                        pack: pack, overrides: ov)
        let isEmpty = r.transactions.isEmpty
        #expect(isEmpty)
    }
}

// MARK: - Cross-language crypto parity vectors (F-049 D5/D27)
//
// The contract the Android Kotlin CryptoService must reproduce. v2 pins:
//   - the KDF at the 600 000 default AND the 200 000 legacy cost,
//   - the "v1:" envelope with its AAD (Kotlin must DECRYPT Swift-sealed text; the random
//     nonce means we validate by decrypting, not by re-encrypting),
//   - legacy (v0) boxes still opening,
//   - rejection cases — a stripped or forged prefix must fail authentication,
//   - PassphrasePolicy verdicts, including the NFC-before-counting case.
// Regenerate with `swift scripts/gen_crypto_vectors.swift`; the committed JSON is the
// source of truth for both platforms, and this suite re-checks it against the REAL code.

@Suite("CryptoParity")
struct CryptoParityTests {

    struct ParityFile: Decodable {
        struct Algo: Decodable {
            let kdf, cipher, envelope, aad, passwordNormalization, passwordEncoding: String
            let defaultIterations, legacyIterations, minimumIterations, minimumSaltBytes, keyBytes: Int
            let passphraseMinimumLength, passphraseMinimumDistinct: Int
        }
        struct KDFVector: Decodable { let name, passphrase, saltB64: String; let iterations: Int; let derivedKeyB64: String }
        struct SealedVector: Decodable { let name, passphrase, saltB64, plaintext, ciphertext: String; let iterations: Int }
        struct RejectVector: Decodable { let name, passphrase, saltB64, ciphertext, expect: String; let iterations: Int }
        struct PassphraseVector: Decodable { let passphrase, verdict: String }
        let version: Int
        let algorithm: Algo
        let kdfVectors: [KDFVector]
        let decryptVectors: [SealedVector]
        let legacyDecryptVectors: [SealedVector]
        let rejectVectors: [RejectVector]
        let passphraseVectors: [PassphraseVector]
    }

    private var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)              // <repo>/HaloTests/CloudFoundationTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/specs/crypto-parity-vectors.v2.json")
    }

    private func load() throws -> ParityFile {
        try JSONDecoder().decode(ParityFile.self, from: try Data(contentsOf: vectorsURL))
    }

    private func keyB64(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0).base64EncodedString() } }

    @Test("The file's constants match CryptoService — drift on either side fails here")
    func constants() throws {
        let a = try load().algorithm
        #expect(try load().version == 2)
        #expect(a.defaultIterations == CryptoService.defaultIterations)
        #expect(a.legacyIterations == CryptoService.legacyIterations)
        #expect(a.minimumIterations == CryptoService.minimumIterations)
        #expect(a.minimumSaltBytes == CryptoService.minimumSaltBytes)
        #expect(a.aad == String(decoding: CryptoService.envelopeAAD, as: UTF8.self))
        #expect(a.passphraseMinimumLength == PassphrasePolicy.minimumLength)
        #expect(a.passphraseMinimumDistinct == PassphrasePolicy.minimumDistinctCharacters)
        #expect(a.keyBytes == 32)
    }

    @Test("KDF vectors reproduce byte-for-byte")
    func kdf() throws {
        for v in try load().kdfVectors {
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let key = try CryptoService.deriveKey(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            #expect(keyB64(key) == v.derivedKeyB64, "\(v.name)")
        }
    }

    @Test("v1 envelopes decrypt; every one carries the prefix")
    func decryptV1() throws {
        for v in try load().decryptVectors {
            #expect(v.ciphertext.hasPrefix(CryptoService.envelopePrefix), "\(v.name)")
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let svc = try CryptoService(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            #expect(try svc.decrypt(v.ciphertext) == v.plaintext, "\(v.name)")
        }
    }

    @Test("Legacy v0 boxes (200 000 rounds, no prefix, no AAD) still decrypt")
    func decryptLegacy() throws {
        for v in try load().legacyDecryptVectors {
            #expect(!v.ciphertext.hasPrefix(CryptoService.envelopePrefix), "\(v.name)")
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let svc = try CryptoService(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            #expect(try svc.decrypt(v.ciphertext) == v.plaintext, "\(v.name)")
        }
    }

    @Test("Stripped or forged prefixes are rejected")
    func rejects() throws {
        for v in try load().rejectVectors {
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let svc = try CryptoService(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            #expect(v.expect == "decryptionFailed")
            #expect(throws: CryptoError.decryptionFailed, "\(v.name)") { _ = try svc.decrypt(v.ciphertext) }
        }
    }

    @Test("Passphrase-policy verdicts match, including the NFC-before-counting case")
    func policy() throws {
        for v in try load().passphraseVectors {
            let got: String
            switch PassphrasePolicy.evaluate(v.passphrase) {
            case .ok: got = "ok"
            case .tooShort(let have): got = "tooShort:\(have)"
            case .tooRepetitive: got = "tooRepetitive"
            }
            #expect(got == v.verdict, "\(v.passphrase.debugDescription)")
        }
    }
}


// MARK: - New-SMS notification privacy (found while verifying P3)

@Suite("SMS notifications never carry message text")
@MainActor
struct SMSNotificationPrivacyTests {

    @Test("The notification names the sender and nothing from the body")
    func noBodyText() {
        let n = SMSSyncClient.newMessageNotification(sender: "HDFCBK")
        #expect(n.title == "New SMS")
        #expect(n.body == "From HDFCBK")
    }

    @Test("Long or empty senders are bounded and never produce an empty body")
    func edgeSenders() {
        #expect(SMSSyncClient.newMessageNotification(sender: String(repeating: "A", count: 200)).body.count <= 50)
        #expect(SMSSyncClient.newMessageNotification(sender: "   ").body == "A new message arrived.")
    }

    @Test("sms_new has its own icon and colour in the alert history, not the generic bell")
    func hasIconAndColour() {
        let e = AlertEntry(title: "New SMS", body: "From X", kindRaw: "sms_new")
        #expect(e.icon != "bell.fill")
        #expect(e.accentColor != .haloAccent)       // .haloAccent is the "no arm was written" sentinel
    }
}


// MARK: - CloudTelemetryScrubber

@Suite("CloudTelemetryScrubber")
struct CloudTelemetryScrubberTests {

    private let jwt = "eyJhbGciOiJSUzI1NiIsImtpZCI6IjEyMyJ9.eyJ1aWQiOiJhYmMxMjMiLCJpYXQiOjE3MDAwMDAwMDB9.c2lnbmF0dXJlLWJ5dGVzLWhlcmU"

    @Test("An ID token in a request URL's query is redacted, the rest of the URL kept")
    func authQuery() {
        let url = "https://x-default-rtdb.firebaseio.com/sms/u1/devA.json?auth=\(jwt)"
        let out = CloudTelemetryScrubber.scrub(url)
        #expect(!out.contains("eyJ"))
        #expect(out == "https://x-default-rtdb.firebaseio.com/sms/u1/devA.json?auth=[cloud-redacted]")
    }

    @Test("API keys and refresh tokens in query strings are redacted, other parameters survive")
    func otherQueryParams() {
        let out = CloudTelemetryScrubber.scrub("POST https://securetoken.googleapis.com/v1/token?key=AIzaSyFAKEKEY123&foo=bar&refresh_token=RT-secret")
        #expect(!out.contains("AIzaSyFAKEKEY123"))
        #expect(!out.contains("RT-secret"))
        #expect(out.contains("foo=bar"))
    }

    @Test("A bare JWT anywhere in text is redacted")
    func bareJWT() {
        let out = CloudTelemetryScrubber.scrub("Failed with token \(jwt) for user")
        #expect(!out.contains("eyJhbGci"))
        #expect(out.hasPrefix("Failed with token [cloud-redacted]"))
    }

    @Test("Credential fields in a JSON body are redacted, their names kept")
    func jsonFields() {
        let body = #"{"email":"me@example.com","password":"hunter2-long","returnSecureToken":true,"idToken":"abc.def.ghi","refreshToken":"RTOK"}"#
        let out = CloudTelemetryScrubber.scrub(body)
        #expect(!out.contains("hunter2-long"))
        #expect(!out.contains("abc.def.ghi"))
        #expect(!out.contains("RTOK"))
        #expect(out.contains(#""password":"[cloud-redacted]""#))
        #expect(out.contains("me@example.com"))                 // not a secret; keeps the report useful
    }

    @Test("Ordinary text and numbers pass through untouched")
    func benign() {
        let text = "Network error: The Internet connection appears to be offline. (code -1009)"
        #expect(CloudTelemetryScrubber.scrub(text) == text)
        #expect(CloudTelemetryScrubber.scrub("keyboard=us&author=me") == "keyboard=us&author=me")   // not key=/auth=
    }

    @Test("Nested dictionaries and arrays are scrubbed recursively")
    func nested() throws {
        let value: [String: Any] = ["url": "https://h/x.json?auth=SECRET1", "list": ["?token=SECRET2", 3], "n": 1]
        let out = try #require(CloudTelemetryScrubber.scrub(value) as? [String: Any])
        #expect((out["url"] as? String)?.contains("SECRET1") == false)
        #expect(((out["list"] as? [Any])?.first as? String)?.contains("SECRET2") == false)
        #expect(out["n"] as? Int == 1)
    }

    @Test("The Sentry hooks' combined scrub covers both Lethe and cloud secrets")
    func combined() {
        let out = HaloApp.scrubTelemetry("join lethe://room/KEYMATERIAL via https://h/x.json?auth=SECRET")
        #expect(!out.contains("KEYMATERIAL"))
        #expect(!out.contains("SECRET"))
    }
}
