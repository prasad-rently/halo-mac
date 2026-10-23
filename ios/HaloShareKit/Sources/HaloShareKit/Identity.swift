import Foundation

// MARK: - DeviceIdentity

/// This device's stable identity: a user-visible alias and a random fingerprint.
///
/// The fingerprint is generated **once and persisted**. For `http` peers it is only a
/// de-duplication identity — not a credential (protocol doc §6).
public struct DeviceIdentity: Equatable, Sendable {
    public var alias: String
    public var fingerprint: String
    public var deviceModel: String?
    public var deviceType: String

    public init(alias: String, fingerprint: String, deviceModel: String? = nil, deviceType: String = "mobile") {
        self.alias = alias
        self.fingerprint = fingerprint
        self.deviceModel = deviceModel
        self.deviceType = deviceType
    }

    public static func randomFingerprint() -> String {
        // 128 random bits, hex. The official apps use an arbitrary random string for http.
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func deviceInfo(port: Int = Int(HaloShare.defaultPort), announce: Bool? = nil) -> DeviceInfo {
        DeviceInfo(alias: alias, deviceModel: deviceModel, deviceType: deviceType,
                   fingerprint: fingerprint, port: port, protocol: .http, download: false, announce: announce)
    }
}

/// Where the identity lives. `UserDefaults` in the app; in-memory in tests.
public protocol IdentityStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

extension UserDefaults: IdentityStore {
    public func set(_ value: String, forKey key: String) { set(value as Any?, forKey: key) }
}

public final class InMemoryIdentityStore: IdentityStore {
    private var values: [String: String] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { values[key] }
    public func set(_ value: String, forKey key: String) { values[key] = value }
}

public enum DeviceIdentityStore {
    static let aliasKey = "haloshare.alias"
    static let fingerprintKey = "haloshare.fingerprint"

    /// Loads the persisted identity, creating and saving one on first run.
    public static func loadOrCreate(in store: IdentityStore, defaultAlias: String,
                                    deviceModel: String? = nil, deviceType: String = "mobile") -> DeviceIdentity {
        let alias = store.string(forKey: aliasKey) ?? defaultAlias
        let fingerprint: String
        if let existing = store.string(forKey: fingerprintKey), !existing.isEmpty {
            fingerprint = existing
        } else {
            fingerprint = DeviceIdentity.randomFingerprint()
            store.set(fingerprint, forKey: fingerprintKey)
        }
        if store.string(forKey: aliasKey) == nil { store.set(alias, forKey: aliasKey) }
        return DeviceIdentity(alias: alias, fingerprint: fingerprint, deviceModel: deviceModel, deviceType: deviceType)
    }

    public static func setAlias(_ alias: String, in store: IdentityStore) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.set(String(trimmed.prefix(40)), forKey: aliasKey)
    }
}
