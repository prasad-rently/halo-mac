import SwiftUI
import Combine

// MARK: - SMSConsoleViewModel  (F-044)
//
// Filter/selection state over the real cloud source (SMSSyncClient). No mock —
// data comes from the user's own Firebase, decrypted locally.

@MainActor
final class SMSConsoleViewModel: ObservableObject {
    let client = SMSSyncClient()

    @Published var selectedLineID: String?          // nil = "All lines"
    @Published var selectedThreadID: String?
    @Published var search = ""
    @Published var categoryFilter: SMSCategory?

    private var bag = Set<AnyCancellable>()

    init() {
        // Re-publish the client's changes so the view updates on new cloud data.
        client.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.ensureSelection()
            }
            .store(in: &bag)
    }

    // MARK: Pass-through cloud state

    var state: SMSSyncClient.State { client.state }
    var isConfigured: Bool { client.isConfigured }
    var devices: [SMSDevice] { client.devices }
    var lines: [SMSLine] { client.lines }
    var allThreads: [SMSThread] { client.threads }

    func connect(passphrase: String) async { await client.connect(passphrase: passphrase) }
    func refresh() async { await client.refresh() }

    private func ensureSelection() {
        if selectedThreadID == nil || !allThreads.contains(where: { $0.id == selectedThreadID }) {
            selectedThreadID = filteredThreads.first?.id
        }
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

    var selectedThread: SMSThread? { allThreads.first { $0.id == selectedThreadID } }

    func line(_ id: String) -> SMSLine? { lines.first { $0.id == id } }
    func device(_ id: String) -> SMSDevice? { devices.first { $0.id == id } }

    func unread(forLine id: String) -> Int {
        allThreads.filter { $0.lineId == id }.reduce(0) { $0 + $1.unreadCount }
    }
    var totalUnread: Int { allThreads.reduce(0) { $0 + $1.unreadCount } }

    func lineTitle(_ line: SMSLine) -> String {
        "\(device(line.deviceId)?.name ?? "Device") · \(line.label)"
    }
    func lineSubtitle(_ line: SMSLine) -> String { "\(line.ownNumber) · \(line.carrier)" }

    var presentCategories: [SMSCategory] {
        let scoped = allThreads.filter { selectedLineID == nil || $0.lineId == selectedLineID }
        let set = Set(scoped.map { $0.category })
        return SMSCategory.allCases.filter { set.contains($0) }
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
