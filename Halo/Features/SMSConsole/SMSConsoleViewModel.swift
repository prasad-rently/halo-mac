import SwiftUI

// MARK: - SMSConsoleViewModel  (F-044)
//
// Drives the desktop SMS console. In this preview it loads mock data; the real
// implementation will read F-044's decrypted local cache (Halo/Core/Cloud).

@MainActor
final class SMSConsoleViewModel: ObservableObject {
    @Published var devices: [SMSDevice]
    @Published var lines: [SMSLine]
    @Published private(set) var allThreads: [SMSThread]

    @Published var selectedLineID: String?          // nil = "All lines"
    @Published var selectedThreadID: String?
    @Published var search = ""
    @Published var categoryFilter: SMSCategory?      // nil = all categories

    /// Whether this is showing mock preview data (no cloud connected yet).
    let isPreview: Bool

    init(preview: Bool = true) {
        self.isPreview = preview
        self.devices = MockSMSData.devices
        self.lines = MockSMSData.lines
        self.allThreads = MockSMSData.threads()
        self.selectedThreadID = allThreads.first?.id
    }

    // MARK: Derived

    var filteredThreads: [SMSThread] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allThreads.filter { thread in
            if let lineID = selectedLineID, thread.lineId != lineID { return false }
            if let cat = categoryFilter, thread.category != cat { return false }
            if !q.isEmpty {
                let inContact = thread.contactNumber.lowercased().contains(q)
                let inBody = thread.messages.contains { $0.body.lowercased().contains(q) }
                if !inContact && !inBody { return false }
            }
            return true
        }
        .sorted { $0.lastDate > $1.lastDate }
    }

    var selectedThread: SMSThread? {
        allThreads.first { $0.id == selectedThreadID }
    }

    func line(_ id: String) -> SMSLine? { lines.first { $0.id == id } }
    func device(_ id: String) -> SMSDevice? { devices.first { $0.id == id } }

    func unread(forLine id: String) -> Int {
        allThreads.filter { $0.lineId == id }.reduce(0) { $0 + $1.unreadCount }
    }
    var totalUnread: Int { allThreads.reduce(0) { $0 + $1.unreadCount } }

    /// "Pixel 8 · Personal · +91 98765 43210 · Airtel"
    func lineTitle(_ line: SMSLine) -> String {
        let dev = device(line.deviceId)?.name ?? "Device"
        return "\(dev) · \(line.label)"
    }
    func lineSubtitle(_ line: SMSLine) -> String {
        "\(line.ownNumber) · \(line.carrier)"
    }

    /// Categories present, for the filter chips.
    var presentCategories: [SMSCategory] {
        let set = Set(filteredThreadsIgnoringCategory.map { $0.category })
        return SMSCategory.allCases.filter { set.contains($0) }
    }
    private var filteredThreadsIgnoringCategory: [SMSThread] {
        allThreads.filter { selectedLineID == nil || $0.lineId == selectedLineID }
    }

    func markThreadRead(_ id: String) {
        guard let idx = allThreads.firstIndex(where: { $0.id == id }) else { return }
        allThreads[idx].messages = allThreads[idx].messages.map {
            var m = $0; m.read = true; return m
        }
    }
}

// MARK: - Relative time

enum SMSTime {
    static func short(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        switch secs {
        case ..<60: return "now"
        case ..<3600: return "\(secs/60)m"
        case ..<86_400: return "\(secs/3600)h"
        case ..<604_800: return "\(secs/86_400)d"
        default:
            let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: date)
        }
    }
    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f.string(from: date)
    }
}
