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
//   key        = PBKDF2-HMAC-SHA256(passphrase, salt)      → 256-bit AES key
//   ciphertext = AES-GCM(key, plaintext)                    → nonce|ct|tag, base64
//
// PBKDF2 (CommonCrypto) is used for the KDF because it is built into the
// platform — no third-party dependency. Argon2id is a documented later hardening
// upgrade (F-044 §7.1); the salt + parameters are stored so a future migration
// can re-derive.
//
// The passphrase itself is NEVER stored or transmitted (only the non-secret salt
// travels in the pairing QR). Losing it is recoverable by re-key (F-044 D24),
// because the phone is the source of truth.

/// Errors surfaced by the crypto layer.
enum CryptoError: LocalizedError, Equatable {
    case badCiphertext
    case decryptionFailed
    case kdfFailed

    var errorDescription: String? {
        switch self {
        case .badCiphertext:    return "The encrypted payload is malformed."
        case .decryptionFailed: return "Couldn't decrypt — wrong key or corrupted data."
        case .kdfFailed:        return "Key derivation failed."
        }
    }
}

/// Stateless-after-init crypto helper. Holds the derived symmetric key and
/// seals/opens payloads. Not an actor — it is a pure transform with no shared
/// mutable state (per CLAUDE.md, stateless generators use `final class`).
final class CryptoService: @unchecked Sendable {

    /// Default PBKDF2 round count. Tuned to be meaningfully expensive while
    /// staying responsive on a phone. Stored alongside the salt for migration.
    static let defaultIterations = 200_000

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
    static func deriveKey(passphrase: String,
                          salt: Data,
                          iterations: Int = CryptoService.defaultIterations) throws -> SymmetricKey {
        let passphraseData = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32) // 256-bit
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
    /// carried in the pairing QR.
    static func generateSalt(_ count: Int = 16) -> Data {
        randomBytes(count)
    }

    /// Cryptographically secure random bytes.
    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    // MARK: - Encrypt / decrypt

    /// Seal a UTF-8 string → base64 of the AES-GCM combined box (nonce|ct|tag).
    func encrypt(_ plaintext: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else { throw CryptoError.decryptionFailed }
        return combined.base64EncodedString()
    }

    /// Open a base64 combined box → UTF-8 string. Throws on wrong key / tamper.
    func decrypt(_ ciphertextBase64: String) throws -> String {
        guard let combined = Data(base64Encoded: ciphertextBase64) else {
            throw CryptoError.badCiphertext
        }
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: combined) }
        catch { throw CryptoError.badCiphertext }

        let opened: Data
        do { opened = try AES.GCM.open(box, using: key) }
        catch { throw CryptoError.decryptionFailed }

        guard let string = String(data: opened, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        return string
    }
}
