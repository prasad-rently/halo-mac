import Foundation

/// Errors surfaced by the cloud layer. None of the messages may contain a URL, token, password,
/// passphrase or message text: URLError descriptions embed the request URL, and the URL carries `?auth=<token>`.
public enum CloudError: LocalizedError, Equatable, Sendable {
    case badCiphertext
    case decryptionFailed
    case encryptionFailed
    case kdfFailed
    case randomGenerationFailed
    case invalidParameters(String)
    case malformedPairingCode
    case pairingChecksumMismatch
    case unsupportedPairingSchema(Int)
    case notConfigured
    case configureFailed
    case authFailed(String)
    case operationFailed(String)
    case network
    case secretStore(String)

    public var errorDescription: String? {
        switch self {
        case .badCiphertext: return "The encrypted payload is malformed."
        case .decryptionFailed: return "Couldn't decrypt — wrong key or corrupted data."
        case .encryptionFailed: return "Couldn't encrypt the payload."
        case .kdfFailed: return "Key derivation failed."
        case .randomGenerationFailed: return "The system couldn't produce secure random bytes."
        case .invalidParameters(let why): return "Unsafe key-derivation settings: \(why)"
        case .malformedPairingCode: return "That isn't a Halo pairing code. Copy the whole code from Halo on your Mac (Settings → Cloud → Show pairing code)."
        case .pairingChecksumMismatch: return "The pairing code is damaged or was altered — copy it again from your Mac."
        case .unsupportedPairingSchema(let s): return "This pairing code is from a newer Halo (format \(s)). Update the Halo app."
        case .notConfigured: return "Cloud is not configured yet."
        case .configureFailed: return "The database address must be a valid https:// URL."
        case .authFailed(let m): return m
        case .operationFailed(let m): return m
        case .network: return "Couldn't reach the network."
        case .secretStore(let m): return m
        }
    }
}
