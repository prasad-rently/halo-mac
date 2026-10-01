import Foundation
import Security

// MARK: - CloudConfigStore  (F-044 cloud foundation)
//
// Keychain-backed storage for the BYOB Firebase config, the Email/Password auth
// credential, the E2E salt, and (optionally) the E2E passphrase for convenience.
// Never plaintext prefs, never logged (docs/specs/00-foundations.md security).
//
// Everything is stored as generic-password Keychain items under one service so
// it is easy to wipe on "disconnect".

final class CloudConfigStore: @unchecked Sendable {

    static let shared = CloudConfigStore()

    private let service = "com.halo.mac.cloud"

    // Keychain account keys
    private enum Key: String {
        case firebaseConfig
        case authCredential
        case salt
        case passphrase        // optional convenience cache (device-local only)
    }

    private init() {}

    // MARK: - Public API

    var firebaseConfig: FirebaseConfig? {
        get { decode(FirebaseConfig.self, .firebaseConfig) }
        set { encode(newValue, .firebaseConfig) }
    }

    var authCredential: CloudAuthCredential? {
        get { decode(CloudAuthCredential.self, .authCredential) }
        set { encode(newValue, .authCredential) }
    }

    /// The non-secret KDF salt.
    var salt: Data? {
        get { read(.salt) }
        set { write(newValue, .salt) }
    }

    /// Optional device-local passphrase cache (user opts in). Storing it here is
    /// a convenience; the security model never *requires* it (F-044 D24 re-key).
    var cachedPassphrase: String? {
        get { read(.passphrase).flatMap { String(data: $0, encoding: .utf8) } }
        set { write(newValue.map { Data($0.utf8) }, .passphrase) }
    }

    var isConfigured: Bool { (firebaseConfig?.isComplete ?? false) }

    /// Apply a scanned pairing payload: store config + auth + salt (not the passphrase).
    func apply(pairing: CloudPairingPayload) {
        firebaseConfig = pairing.firebaseConfig
        authCredential = pairing.auth
        salt = pairing.salt
    }

    /// Build a `CryptoService` from the stored salt + a supplied passphrase.
    func makeCryptoService(passphrase: String) throws -> CryptoService {
        guard let salt = salt else { throw CryptoError.kdfFailed }
        return try CryptoService(passphrase: passphrase, salt: salt)
    }

    /// Wipe everything (disconnect / re-key). Removes all cloud Keychain items.
    func wipe() {
        [Key.firebaseConfig, .authCredential, .salt, .passphrase].forEach { delete($0) }
    }

    // MARK: - Codable helpers

    private func encode<T: Encodable>(_ value: T?, _ key: Key) {
        guard let value = value else { delete(key); return }
        write(try? JSONEncoder().encode(value), key)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let data = read(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Keychain primitives

    private func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    private func write(_ data: Data?, _ key: Key) {
        guard let data = data else { delete(key); return }
        delete(key)
        var attrs = query(key)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func read(_ key: Key) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(_ key: Key) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
