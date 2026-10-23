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

// MARK: - HistoryKeyStore

/// The key that encrypts the on-disk message history (`rooms.enc`).
///
/// One random 256-bit key per install, in the Keychain with the same protection as
/// the room keys (`WhenUnlockedThisDeviceOnly`, never iCloud-synced). It is stored
/// under its **own service name**: `RoomKeyStore.allRoomIds()` lists every account
/// under `com.halo.mac.lethe`, and this item must never show up there as a "room".
///
/// What this protects: the history file copied off the Mac, swept into a backup, or
/// read by a process that has file access but not Keychain access. What it does not:
/// malware that can already read this app's Keychain items.
enum HistoryKeyStore {

    private static let service = "com.halo.mac.lethe.history"
    private static let account = "history-key"

    /// The existing key, or a freshly generated one saved first. `nil` when the
    /// Keychain refuses — callers must then **not write history at all** rather than
    /// fall back to plaintext.
    static func loadOrCreate() -> Data? {
        if let existing = load() { return existing }
        let key = LetheCrypto.generateRoomKey()
        let add: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            return load()       // lost a race with another launch; use theirs
        default:
            return nil
        }
    }

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == LetheCrypto.keyLength
        else { return nil }
        return data
    }
}
