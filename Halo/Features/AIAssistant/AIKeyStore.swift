import Foundation
import Security

// MARK: - AIKeyStore  (F-046 D2)
//
// Per-provider API keys in the Keychain — never logged, never committed, never
// leave the machine except to the provider's own endpoint (US-5). One generic-
// password item per provider under a single service.

final class AIKeyStore: @unchecked Sendable {
    static let shared = AIKeyStore()
    private let service = "com.halo.mac.ai"
    private init() {}

    func key(for provider: AIProviderKind) -> String? {
        read(provider.rawValue).flatMap { String(data: $0, encoding: .utf8) }
    }
    func setKey(_ key: String?, for provider: AIProviderKind) {
        write(key.map { Data($0.utf8) }, provider.rawValue)
    }
    func hasKey(for provider: AIProviderKind) -> Bool {
        !(key(for: provider)?.isEmpty ?? true)
    }
    func clear(_ provider: AIProviderKind) { delete(provider.rawValue) }

    // MARK: Keychain primitives

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func write(_ data: Data?, _ account: String) {
        guard let data else { delete(account); return }
        delete(account)
        var attrs = query(account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    private func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    private func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
