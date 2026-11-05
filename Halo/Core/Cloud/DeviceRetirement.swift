import Foundation

// MARK: - Devices list helpers  (F-057 FR-S4)
//
// The Mac's Devices list shows each phone with when it last synced, and lets the user retire one
// (wipe its subtree). The removal itself already existed as `SMSSyncClient.wipeDevice`; this holds the
// two pieces that deserve a test of their own:
//
//  * `DeviceLastSeen.text` — the label. A phone writes `lastSeen` (epoch ms) on each sync.
//  * `DeviceRetirement.retire` — what is removed, with a guard on the device id. The id is spliced into
//    a path; an empty one would turn "retire this phone" into "delete the whole `sms/{uid}` tree", and
//    one containing "/" would reach into a sibling. Both are refused before anything is removed.

enum DeviceLastSeen {
    /// Phones sync periodically, so "a few hours" is normal; a week of silence is worth saying out loud.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    static func text(lastSeen: Date?, now: Date = Date()) -> String {
        guard let lastSeen else { return "Never seen" }
        let s = now.timeIntervalSince(lastSeen)
        if s < 90 { return "Just now" }                     // includes negative: clock skew between phone and Mac
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { let h = Int(s / 3600); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int(s / 86_400)
        return d == 1 ? "Yesterday" : "\(d) days ago"
    }

    static func isStale(lastSeen: Date?, now: Date = Date()) -> Bool {
        guard let lastSeen else { return true }
        return now.timeIntervalSince(lastSeen) > staleAfter
    }

    /// `devices/{uid}/{id}.lastSeen` is epoch milliseconds (Android) — accept seconds too (be lenient).
    static func date(fromRaw raw: Any?) -> Date? {
        guard let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }     // `true` is not a timestamp
        let n = num.doubleValue
        guard n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }
}

enum DeviceRetirementError: Error, Equatable { case invalidDeviceID }

enum DeviceRetirement {
    /// The two subtrees a phone owns, in the order they are removed (messages first, so a half-finished
    /// retire never leaves messages without their device row to explain them).
    static func nodes(uid: String, deviceId: String) -> [String] {
        ["sms/\(uid)/\(deviceId)", "devices/\(uid)/\(deviceId)"]
    }

    /// Firebase keys cannot contain `. $ # [ ] /` or ASCII control characters, and are at most 768 bytes — so a
    /// real device id never has any of them. Refusing them (and whitespace-only ids) keeps the id a single
    /// path segment. A literal `%2F` is fine: the request builder percent-encodes `%`, so it stays one segment.
    static func isSafeDeviceID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 768 else { return false }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let illegal = CharacterSet(charactersIn: "./$#[]").union(.controlCharacters)
        return id.rangeOfCharacter(from: illegal) == nil
    }

    /// Remove a phone's subtrees through `remove`. Throws `invalidDeviceID` — removing nothing — for an id
    /// that would address anything other than one device.
    static func retire(uid: String, deviceId: String, remove: (String) async throws -> Void) async throws {
        guard !uid.isEmpty, isSafeDeviceID(deviceId) else { throw DeviceRetirementError.invalidDeviceID }
        for node in nodes(uid: uid, deviceId: deviceId) { try await remove(node) }
    }
}
