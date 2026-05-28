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
        default:                  return "bell.fill"
        }
    }

    var accentColor: Color {
        switch kindRaw {
        case "cpu_high", "ram_high":         return .haloRed
        case "disk_low", "battery_low":      return .haloAmber
        case "battery_critical":             return .haloRed
        case "charging_done":                return .haloGreen
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
