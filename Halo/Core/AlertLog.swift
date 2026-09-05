import Foundation
import SwiftUI

// MARK: - AlertEntry (F-011)

struct AlertEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let title: String
    let body: String
    let kindRaw: String          // AlertManager.AlertKind.rawValue
    var isRead: Bool

    init(id: UUID = UUID(), date: Date = Date(), title: String, body: String, kindRaw: String) {
        self.id      = id
        self.date    = date
        self.title   = title
        self.body    = body
        self.kindRaw = kindRaw
        self.isRead  = false
    }

    var icon: String {
        switch kindRaw {
        case "cpu_high":          return "cpu"
        case "ram_high":          return "memorychip"
        case "disk_low":          return "internaldrive.fill"
        case "battery_low":       return "battery.25"
        case "battery_critical":  return "battery.0"
        case "charging_done":     return "bolt.fill"
        // Severity-shaped rather than drive-shaped, deliberately. The obvious
        // pick is `internaldrive.badge.exclamationmark` / `.badge.xmark` — but
        // neither exists in SF Symbols, and an unresolvable name renders as a
        // blank, not an error. The disk-shaped alternatives that do exist are
        // all `externaldrive.*`, and F-020 monitors internal drives too: an
        // "external drive" glyph on a failing internal SSD is a misleading
        // signal on precisely the alert a user must not misread. The drive is
        // named in the alert title.
        case "disk_smart_warning": return "exclamationmark.triangle.fill"   // F-020
        case "disk_smart_failing": return "xmark.octagon.fill"              // F-020
        case "backup_stale":      return "clock.badge.exclamationmark"   // F-022
        case "backup_never":      return "externaldrive.badge.questionmark"  // F-022
        case "app_memory_high":   return "memorychip.fill"   // F-023
        default:                  return "bell.fill"
        }
    }

    var accentColor: Color {
        switch kindRaw {
        case "cpu_high", "ram_high":         return .haloRed
        case "disk_low", "battery_low":      return .haloAmber
        case "battery_critical":             return .haloRed
        case "charging_done":                return .haloGreen
        case "disk_smart_warning":           return .haloAmber   // F-020
        case "disk_smart_failing":           return .haloRed     // F-020
        case "backup_stale", "backup_never": return .haloAmber   // F-022
        case "app_memory_high":              return .haloAmber   // F-023
        default:                             return .haloAccent
        }
    }
}

// MARK: - AlertLog (F-011)
//
// Singleton observable store for system alert history.
// • Maximum 50 entries (oldest dropped when cap exceeded).
// • Persisted to UserDefaults so history survives app restarts.
// • Exposes unreadCount for badges in sidebar / dashboard.

@MainActor
final class AlertLog: ObservableObject {

    static let shared = AlertLog()
    private init() { loadFromDefaults() }

    // MARK: - State

    @Published private(set) var entries: [AlertEntry] = []

    var unreadCount: Int { entries.filter { !$0.isRead }.count }

    private static let defaultsKey = "haloAlertLog"
    private static let cap = 50

    // MARK: - Mutations

    func append(title: String, body: String, kindRaw: String) {
        let entry = AlertEntry(title: title, body: body, kindRaw: kindRaw)
        entries.insert(entry, at: 0)   // newest first
        if entries.count > Self.cap {
            entries = Array(entries.prefix(Self.cap))
        }
        persistToDefaults()
    }

    func markAllRead() {
        for idx in entries.indices where !entries[idx].isRead {
            entries[idx].isRead = true
        }
        persistToDefaults()
    }

    func markRead(_ entry: AlertEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].isRead = true
        persistToDefaults()
    }

    func clearAll() {
        entries.removeAll()
        persistToDefaults()
    }

    // MARK: - Persistence

    private func persistToDefaults() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([AlertEntry].self, from: data) else { return }
        entries = saved
    }
}
