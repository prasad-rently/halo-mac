import Foundation
import Security

/// Where secrets live. The app uses `KeychainSecretStore`; tests use `InMemorySecretStore`.
/// Nothing in this package ever writes a secret to UserDefaults, a file or a log.
public protocol SecretStore: Sendable {
    func set(_ data: Data, for account: String) throws
    func get(_ account: String) throws -> Data?
    func remove(_ account: String) throws
    /// Remove every item this store owns (unpair).
    func removeAll() throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func set(_ data: Data, for account: String) throws { lock.lock(); items[account] = data; lock.unlock() }
    public func get(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func remove(_ account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public func removeAll() throws { lock.lock(); items.removeAll(); lock.unlock() }
    /// Test hook: every account currently stored.
    public var accounts: [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

/// Generic-password Keychain items, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never iCloud-synced
/// (`kSecAttrSynchronizable = false`). `WhenUnlockedThisDeviceOnly` also keeps the item out of backups
/// restored to a different device.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public let service: String
    public init(service: String = "com.halo.mobile.cloud") { self.service = service }

    private func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: false]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func set(_ data: Data, for account: String) throws {
        let query = base(account)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudError.secretStore("Keychain write failed (\(status)).") }
    }

    public func get(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw CloudError.secretStore("Keychain read failed (\(status)).") }
        return d
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.secretStore("Keychain delete failed (\(status)).") }
    }

    public func removeAll() throws {
        let status = SecItemDelete(base() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.secretStore("Keychain wipe failed (\(status)).") }
    }
}

// MARK: - The paired profile

/// Everything the phone keeps after pairing. Stored as ONE Keychain item (so it is written/erased atomically).
/// It holds the Firebase password and the *derived* data key — never the passphrase.
public struct CloudProfile: Codable, Equatable, Sendable {
    public var config: FirebaseConfig
    public var auth: CloudAuthCredential
    public var saltBase64: String
    public var iterations: Int
    /// The derived AES key, base64. Persisted so the passphrase need not be kept or re-entered each launch.
    public var keyBase64: String
    /// Stable per-install id used for clipboard echo suppression. Not secret.
    public var deviceId: String
    public var deviceName: String
}

public struct CloudProfileStore: Sendable {
    public static let account = "cloud.profile.v1"
    private let secrets: SecretStore
    public init(secrets: SecretStore) { self.secrets = secrets }

    public func load() throws -> CloudProfile? {
        guard let d = try secrets.get(Self.account) else { return nil }
        return try? JSONDecoder().decode(CloudProfile.self, from: d)
    }
    public func save(_ p: CloudProfile) throws { try secrets.set(try JSONEncoder().encode(p), for: Self.account) }
    /// Unpair: erase the profile (and anything else this store owns).
    public func wipe() throws { try secrets.removeAll() }
}
