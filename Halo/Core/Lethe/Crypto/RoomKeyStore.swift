// ──────────────────────────────────────────────────────────────────────────────
// RoomKeyStore.swift — F-052
//
// Room keys live in the Keychain, never in UserDefaults and never in the JSON
// message store. A room key is the same class of secret as the AI API key
// (`AIKeyStore`) and the LocalShare TLS identity (`TLSManager`), both of which
// already use the Keychain — this follows that precedent rather than inventing
// a third answer.
//
// Losing a key is unrecoverable: there is no server copy and no reset flow, by
// design. `delete` is therefore only ever called from a confirmed "leave room".
// ──────────────────────────────────────────────────────────────────────────────

import Foundation
import Security

enum RoomKeyStore {

    /// Matches the `com.halo.mac.*` service naming used by AIKeyStore.
    private static let service = "com.halo.mac.lethe"

    // MARK: - CRUD

    @discardableResult
    static func save(_ key: Data, roomId: String) -> Bool {
        // Delete-then-add rather than SecItemUpdate: one code path, and it
        // cannot leave a stale duplicate if a previous add half-failed.
        delete(roomId: roomId)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomId,
            kSecValueData as String:   key,
            // The Mac must be unlocked, and the item must never sync to iCloud
            // Keychain — a room key leaving this device would defeat the point.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(roomId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomId,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              data.count == LetheCrypto.keyLength
        else { return nil }
        return data
    }

    @discardableResult
    static func delete(roomId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Room ids this device holds a key for. Used to reconcile the persisted
    /// room list against reality — a room whose key is gone cannot be entered,
    /// so listing it would be a lie.
    static func allRoomIds() -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]]
        else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }
}
