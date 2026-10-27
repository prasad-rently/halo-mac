import Foundation
import CryptoKit
import CommonCrypto

// MARK: - CryptoService  (F-044 cloud foundation)
//
// Client-side end-to-end encryption for the BYOB cloud features (F-044 SMS,
// F-045 clipboard, F-048 reads). The user's data is encrypted on-device with a
// key derived from a passphrase; the cloud (their own Firebase) only ever stores
// ciphertext.
//
// Design (per docs/specs/00-foundations.md + F-044 §7.1):
//   key        = PBKDF2-HMAC-SHA256(passphrase, salt, iterations) → 256-bit AES key
//   ciphertext = "v1:" + base64( AES-GCM(key, plaintext, aad) )   → nonce|ct|tag
//
// PBKDF2 (CommonCrypto) is used for the KDF because it is built into the
// platform — no third-party dependency. Argon2id is a documented later hardening
// upgrade (F-044 §7.1). The iteration count is persisted with the salt
// (`CloudConfigStore.kdfIterations`, and the pairing payload) so raising the
// default never orphans an existing key.
//
// The passphrase itself is NEVER stored or transmitted (only the non-secret salt
// travels in the pairing QR). Losing it is recoverable by re-key (F-044 D24),
// because the phone is the source of truth.
//
// WIRE FORMAT — this is a contract with the Android port (docs/specs/crypto-parity.md,
// crypto-parity-vectors.v2.json). Changing any byte of it is a coordinated change:
//   v1:  "v1:" + base64(nonce12 || ciphertext || tag16), AAD = "halo.cloud.v1"
//   v0:  base64(nonce12 || ciphertext || tag16), no AAD — legacy, READ-ONLY.
//        Written by the pre-v2.5 branch; still decrypts so nothing already in a
//        user's database is stranded, but nothing writes it any more.

/// Errors surfaced by the crypto layer.
enum CryptoError: LocalizedError, Equatable {
    case badCiphertext
    case decryptionFailed
    case encryptionFailed
    case kdfFailed
    /// `SecRandomCopyBytes` reported a failure. Never papered over with zero
    /// bytes: a zero salt makes the key a pure function of the passphrase.
    case randomGenerationFailed
    /// A KDF input was unacceptable (empty passphrase, short salt, weak iterations).
    case invalidParameters(String)

    var errorDescription: String? {
        switch self {
        case .badCiphertext:           return "The encrypted payload is malformed."
        case .decryptionFailed:        return "Couldn't decrypt — wrong key or corrupted data."
        case .encryptionFailed:        return "Couldn't encrypt the payload."
        case .kdfFailed:               return "Key derivation failed."
        case .randomGenerationFailed:  return "The system couldn't produce secure random bytes."
        case .invalidParameters(let why): return "Unsafe key-derivation settings: \(why)"
        }
    }
}

// MARK: - PassphrasePolicy

/// The strength floor for a *new* end-to-end passphrase (review finding 3).
///
/// The ciphertext lives in the user's own Firebase, reachable by anyone holding the
/// API key plus an account, and the salt travels with the QR — so an attacker can
/// brute-force offline at KDF speed. A one-character passphrase falls in
/// milliseconds whatever the iteration count. This is deliberately a floor, not a
/// strength meter: long enough that guessing is not trivial, with no composition
/// rules (those push people toward predictable substitutions).
///
/// Enforced where a passphrase is **chosen or entered** (every UI that creates or
/// connects), not inside `deriveKey`, so a key that already exists can still be
/// derived and read.
enum PassphrasePolicy {
    static let minimumLength = 12
    static let minimumDistinctCharacters = 6

    enum Verdict: Equatable {
        case ok
        case tooShort(have: Int)
        case tooRepetitive

        var isAcceptable: Bool { self == .ok }

        /// One line for the UI under the field; nil when acceptable.
        var message: String? {
            switch self {
            case .ok: return nil
            case .tooShort(let have):
                return "Use at least \(PassphrasePolicy.minimumLength) characters (you have \(have)). A few unrelated words works well."
            case .tooRepetitive:
                return "That passphrase repeats too few distinct characters — make it less predictable."
            }
        }
    }

    static func evaluate(_ passphrase: String) -> Verdict {
        // Count what the KDF will see: NFC-normalised characters, so "é" typed as
        // two code points is not double-counted.
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        let count = normalized.count
        guard count >= minimumLength else { return .tooShort(have: count) }
        guard Set(normalized).count >= minimumDistinctCharacters else { return .tooRepetitive }
        return .ok
    }
}

/// Stateless-after-init crypto helper. Holds the derived symmetric key and
/// seals/opens payloads. Not an actor — it is a pure transform with no shared
/// mutable state (per CLAUDE.md, stateless generators use `final class`).
final class CryptoService: @unchecked Sendable {

    /// PBKDF2 rounds for *new* keys. OWASP 2023 guidance for PBKDF2-HMAC-SHA256 is
    /// 600 000. Derivation happens on pairing and re-key, not per message, so a
    /// one-off ~1 s cost buys a 3x brute-force margin. Persisted with the salt.
    static let defaultIterations = 600_000

    /// What the pre-v2.5 branch used. Still accepted so existing keys derive.
    static let legacyIterations = 200_000

    /// Floor for any stored/supplied count: a corrupted or downgraded stored
    /// value must fail loudly, not silently weaken derivation.
    static let minimumIterations = 100_000

    /// A 1-byte salt "works" but gives effectively no salting.
    static let minimumSaltBytes = 16

    static let envelopePrefix = "v1:"
    /// Domain separation for v1 envelopes. Part of the wire contract.
    static let envelopeAAD = Data("halo.cloud.v1".utf8)

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Convenience: derive the key from a passphrase + salt and build a service.
    convenience init(passphrase: String, salt: Data, iterations: Int = CryptoService.defaultIterations) throws {
        let key = try CryptoService.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        self.init(key: key)
    }

    // MARK: - Key derivation

    /// PBKDF2-HMAC-SHA256 → 256-bit `SymmetricKey`. Deterministic for a given
    /// (passphrase, salt, iterations) so every device derives the same key.
    ///
    /// Throws `invalidParameters` for an empty passphrase, a salt under
    /// `minimumSaltBytes`, or iterations under `minimumIterations` — checked here
    /// rather than left to CommonCrypto's own validation, which accepts a 1-byte salt.
    static func deriveKey(passphrase: String,
                          salt: Data,
                          iterations: Int = CryptoService.defaultIterations) throws -> SymmetricKey {
        guard !passphrase.isEmpty else {
            throw CryptoError.invalidParameters("the passphrase is empty")
        }
        guard salt.count >= minimumSaltBytes else {
            throw CryptoError.invalidParameters("the salt is \(salt.count) bytes; need at least \(minimumSaltBytes)")
        }
        guard iterations >= minimumIterations, iterations <= Int(UInt32.max) else {
            throw CryptoError.invalidParameters("\(iterations) iterations is below the \(minimumIterations) floor")
        }

        let passphraseData = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32) // 256-bit
        // `SymmetricKey(data:)` copies, so the source buffer would otherwise be left
        // holding a plaintext key in the heap until reuse. Wipe it on every exit.
        defer { derived.resetBytes(in: 0..<derived.count) }

        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passphraseData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self), passphraseData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.kdfFailed }
        return SymmetricKey(data: derived)
    }

    /// A fresh random salt (16 bytes). Not secret — stored in `meta/{uid}` and
    /// carried in the pairing QR. Throws rather than ever returning zeros.
    static func generateSalt(_ count: Int = CryptoService.minimumSaltBytes) throws -> Data {
        try randomBytes(count)
    }

    /// Cryptographically secure random bytes. The `SecRandomCopyBytes` status is
    /// checked: `Data(count:)` is zero-filled, so ignoring a failure would hand back
    /// `count` zero bytes that look perfectly valid to every caller.
    ///
    /// `fill` is the RNG; it exists only so a test can make it fail — the real
    /// `SecRandomCopyBytes` cannot be coaxed into failing, and a test that never
    /// exercises the failure path would pass just as happily on the buggy code.
    static func randomBytes(_ count: Int,
                            fill: (Int, UnsafeMutableRawPointer) -> Int32 = { SecRandomCopyBytes(kSecRandomDefault, $0, $1) }) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return fill(count, base)
        }
        guard status == errSecSuccess else { throw CryptoError.randomGenerationFailed }
        return data
    }

    // MARK: - Encrypt / decrypt

    /// Seal a UTF-8 string → `"v1:" + base64(nonce|ct|tag)`.
    func encrypt(_ plaintext: String) throws -> String {
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Self.envelopeAAD) }
        catch { throw CryptoError.encryptionFailed }
        guard let combined = box.combined else { throw CryptoError.encryptionFailed }
        return Self.envelopePrefix + combined.base64EncodedString()
    }

    /// Open a `v1:` envelope, or a legacy unprefixed (v0) box. Throws on wrong key / tamper.
    func decrypt(_ ciphertext: String) throws -> String {
        let isV1 = ciphertext.hasPrefix(Self.envelopePrefix)
        let body = isV1 ? String(ciphertext.dropFirst(Self.envelopePrefix.count)) : ciphertext

        guard let combined = Data(base64Encoded: body) else {
            throw CryptoError.badCiphertext
        }
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: combined) }
        catch { throw CryptoError.badCiphertext }

        let opened: Data
        do {
            // v1 binds the AAD; v0 never had one. A v1 body opened as v0 (or the
            // reverse) fails authentication, so the prefix cannot be stripped to
            // downgrade a message.
            opened = isV1 ? try AES.GCM.open(box, using: key, authenticating: Self.envelopeAAD)
                          : try AES.GCM.open(box, using: key)
        } catch { throw CryptoError.decryptionFailed }

        guard let string = String(data: opened, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        return string
    }
}
