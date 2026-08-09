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
// Canonical vectors the Android Kotlin CryptoService must reproduce byte-for-byte.
// KDF vectors are deterministic (re-derivable). Decrypt vectors pin the AES-GCM wire
// format (nonce12 || ct || tag16, base64) — Kotlin must DECRYPT Swift-sealed ciphertext
// (the random nonce means we validate by decrypt, not by re-encrypting). Regenerate
// with HALO_GEN_VECTORS=1; the committed JSON is the source of truth for both platforms.

@Suite("CryptoParity")
struct CryptoParityTests {

    struct ParityFile: Codable {
        struct Algo: Codable {
            let kdf, cipher, wireFormat, passwordNormalization, passwordEncoding: String
            let iterations, keyBytes: Int
            let aad: String?
        }
        struct KDFVector: Codable { let name, passphrase, saltB64: String; let iterations: Int; let derivedKeyB64: String }
        struct DecryptVector: Codable { let name, passphrase, saltB64, plaintext, ciphertextB64: String; let iterations: Int }
        let version: Int
        let algorithm: Algo
        let kdfVectors: [KDFVector]
        let decryptVectors: [DecryptVector]
    }

    // Deterministic inputs (fixed salts) so the KDF outputs are stable + pinnable.
    private static let inputs: [(name: String, pass: String, salt: Data, text: String)] = [
        ("ascii", "correct horse battery staple", Data((0..<16).map { UInt8($0) }), "Hello, Halo"),
        ("bank-sms", "p@ssw0rd!", Data("halo-salt-1234!!".utf8), "A/C *XX3833 debited by Rs 1250.00 via UPI"),
        ("unicode", "café☕", Data((0..<16).map { UInt8(0xA0 &+ $0) }), "Unicode: café ☕ 日本語 — clipboard")
    ]

    private var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)              // <repo>/HaloTests/CloudFoundationTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/specs/crypto-parity-vectors.v1.json")
    }

    private func keyB64(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0).base64EncodedString() } }

    @Test("KDF + decrypt vectors verify against CryptoService (the cross-language contract)")
    func verify() throws {
        let data = try Data(contentsOf: vectorsURL)
        let file = try JSONDecoder().decode(ParityFile.self, from: data)
        #expect(file.algorithm.iterations == CryptoService.defaultIterations)

        for v in file.kdfVectors {
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let key = try CryptoService.deriveKey(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            #expect(keyB64(key) == v.derivedKeyB64)          // deterministic KDF parity
        }
        for v in file.decryptVectors {
            let salt = try #require(Data(base64Encoded: v.saltB64))
            let svc = try CryptoService(passphrase: v.passphrase, salt: salt, iterations: v.iterations)
            let pt = try svc.decrypt(v.ciphertextB64)
            #expect(pt == v.plaintext)                       // wire-format parity
        }
    }
}
