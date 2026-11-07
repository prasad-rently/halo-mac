import Foundation
import CryptoKit
import CommonCrypto

// Swift port of Halo/Core/Cloud/CryptoService.swift for the iOS client. The wire contract is
// docs/specs/crypto-parity.md; the executable proof is crypto-parity-vectors.v2.json (this package's
// ConformanceTests decrypt every ciphertext in it and reproduce every KDF vector).
//
//   key = PBKDF2-HMAC-SHA256(NFC(passphrase) as UTF-8, salt, iterations) -> 32 bytes
//   v1  = "v1:" + base64(nonce12 || ciphertext || tag16), AAD = "halo.cloud.v1"
//   v0  = base64(nonce12 || ciphertext || tag16), no AAD — legacy, read-only

/// The strength floor for a *new* end-to-end passphrase. Counted in grapheme clusters after NFC
/// (Swift's `String.count`) exactly like the desktop; see the "é" × 6 vector.
public enum PassphrasePolicy {
    public static let minimumLength = 12
    public static let minimumDistinctCharacters = 6

    public enum Verdict: Equatable, Sendable {
        case ok
        case tooShort(have: Int)
        case tooRepetitive
        public var isAcceptable: Bool { self == .ok }
        public var message: String? {
            switch self {
            case .ok: return nil
            case .tooShort(let have): return "Use at least \(PassphrasePolicy.minimumLength) characters (you have \(have))."
            case .tooRepetitive: return "That passphrase repeats too few distinct characters."
            }
        }
    }

    public static func evaluate(_ passphrase: String) -> Verdict {
        let n = passphrase.precomposedStringWithCanonicalMapping
        guard n.count >= minimumLength else { return .tooShort(have: n.count) }
        guard Set(n).count >= minimumDistinctCharacters else { return .tooRepetitive }
        return .ok
    }
}

public final class CryptoService: @unchecked Sendable {
    public static let defaultIterations = 600_000
    public static let legacyIterations = 200_000
    public static let minimumIterations = 100_000
    /// An upper bound too: a hostile pairing code asking for 2^31 rounds would pin the phone's CPU for minutes.
    public static let maximumIterations = 10_000_000
    public static let minimumSaltBytes = 16
    public static let envelopePrefix = "v1:"
    public static let envelopeAAD = Data("halo.cloud.v1".utf8)

    private let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    /// Rebuild from a key previously derived and stored (Keychain) — the passphrase is never kept.
    public convenience init(keyData: Data) throws {
        guard keyData.count == 32 else { throw CloudError.invalidParameters("stored key is not 32 bytes") }
        self.init(key: SymmetricKey(data: keyData))
    }

    public convenience init(passphrase: String, salt: Data, iterations: Int = CryptoService.defaultIterations) throws {
        self.init(key: try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations))
    }

    /// The raw key, for storing in the Keychain instead of the passphrase.
    public func exportKey() -> Data { key.withUnsafeBytes { Data($0) } }

    // MARK: KDF

    public static func deriveKey(passphrase: String, salt: Data, iterations: Int = defaultIterations) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw CloudError.invalidParameters("the passphrase is empty") }
        guard salt.count >= minimumSaltBytes else {
            throw CloudError.invalidParameters("the salt is \(salt.count) bytes; need at least \(minimumSaltBytes)")
        }
        guard iterations >= minimumIterations, iterations <= maximumIterations else {
            throw CloudError.invalidParameters("\(iterations) iterations is outside \(minimumIterations)…\(maximumIterations)")
        }
        let pass = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                pass.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        p.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw CloudError.kdfFailed }
        return SymmetricKey(data: derived)
    }

    public static func randomBytes(_ count: Int,
                                   fill: (Int, UnsafeMutableRawPointer) -> Int32 = { SecRandomCopyBytes(kSecRandomDefault, $0, $1) }) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { b -> Int32 in
            guard let base = b.baseAddress else { return errSecParam }
            return fill(count, base)
        }
        guard status == errSecSuccess else { throw CloudError.randomGenerationFailed }
        return data
    }

    // MARK: Encrypt / decrypt

    public func encrypt(_ plaintext: String) throws -> String {
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Self.envelopeAAD) }
        catch { throw CloudError.encryptionFailed }
        guard let combined = box.combined else { throw CloudError.encryptionFailed }
        return Self.envelopePrefix + combined.base64EncodedString()
    }

    public func decrypt(_ ciphertext: String) throws -> String {
        let isV1 = ciphertext.hasPrefix(Self.envelopePrefix)
        let body = isV1 ? String(ciphertext.dropFirst(Self.envelopePrefix.count)) : ciphertext
        guard let combined = Data(base64Encoded: body) else { throw CloudError.badCiphertext }
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: combined) } catch { throw CloudError.badCiphertext }
        let opened: Data
        do {
            // v1 binds the AAD; v0 never had one — the prefix is authenticated, so it cannot be stripped or forged.
            opened = isV1 ? try AES.GCM.open(box, using: key, authenticating: Self.envelopeAAD)
                          : try AES.GCM.open(box, using: key)
        } catch { throw CloudError.decryptionFailed }
        guard let s = String(data: opened, encoding: .utf8) else { throw CloudError.decryptionFailed }
        return s
    }

    /// HMAC-SHA256 under a sub-key derived from the data key, hex-encoded — the SMS `threadKey`
    /// (mirrors CryptoService.keyedHash in Kotlin). A plain hash of a phone number would be reversible.
    public func keyedHash(context: String, data: String) -> String {
        let sub = HMAC<SHA256>.authenticationCode(for: Data(context.utf8), using: key)
        let sk = SymmetricKey(data: Data(sub))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: sk)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
