import Foundation
import SwiftUI

// MARK: - LuckyDrawStore

/// Owns every roster and all persistence for the Lucky Draw module.
///
/// Persisted as a JSON file in Application Support rather than `UserDefaults` —
/// following `MemoryTrendTracker`'s precedent rather than `AlertLog`'s. Several
/// rosters × up to 500 entries × 200 history rows is past what belongs in a plist
/// that is loaded into memory whole.
@MainActor
final class LuckyDrawStore: ObservableObject {
    static let shared = LuckyDrawStore()

    @Published private(set) var rosters: [DrawRoster] = []
    @Published var selectedRosterID: UUID?

    private static let directoryName = "Halo"
    private static let fileName = "luckyDraw.json"

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        loadFromDisk()
        if rosters.isEmpty {
            rosters = [DrawRoster.starter()]
        }
        selectedRosterID = rosters.first?.id
    }

    // MARK: - Selection

    var selected: DrawRoster? {
        guard let id = selectedRosterID else { return rosters.first }
        return rosters.first { $0.id == id } ?? rosters.first
    }

    private func mutateSelected(_ body: (inout DrawRoster) -> Void) {
        guard let id = selected?.id,
              let index = rosters.firstIndex(where: { $0.id == id }) else { return }
        body(&rosters[index])
        rosters[index].modifiedAt = Date()
        scheduleSave()
    }

    // MARK: - Entries

    /// Adds one or many with **no duplicate check** — pasted text, split the way
    /// `RosterImport.labels(fromPasted:)` splits it. The roster panel does not call this
    /// any more: it goes through `prepareImport` / `commitImport` so a duplicate is
    /// something the user is asked about (FR-4). Kept for callers that want a blind add.
    /// Returns the number added, which is less than requested when the cap is hit.
    @discardableResult
    func addEntries(from raw: String) -> Int {
        commitImport(RosterImport.labels(fromPasted: raw))
    }

    /// Step one of an add: classify what is about to be added against what is already on
    /// the selected roster. Changes nothing.
    func prepareImport(_ labels: [String]) -> RosterImport.Plan {
        RosterImport.plan(incoming: labels, existing: selected?.entries.map(\.label) ?? [])
    }

    /// Step two: add `labels`, capped at `DrawRoster.entryCap`. Labels arrive already
    /// trimmed and truncated by `RosterImport`.
    @discardableResult
    func commitImport(_ labels: [String]) -> Int {
        guard !labels.isEmpty else { return 0 }
        var added = 0
        mutateSelected { roster in
            for label in labels where roster.entries.count < DrawRoster.entryCap {
                roster.entries.append(DrawEntry(label: String(label.prefix(RosterImport.labelLimit))))
                added += 1
            }
        }
        return added
    }

    func removeEntry(_ entry: DrawEntry) {
        mutateSelected { roster in
            roster.entries.removeAll { $0.id == entry.id }
        }
    }

    func setExcluded(_ excluded: Bool, for entry: DrawEntry) {
        mutateSelected { roster in
            guard let i = roster.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            roster.entries[i].isExcluded = excluded
        }
    }

    func rename(_ entry: DrawEntry, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateSelected { roster in
            guard let i = roster.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            roster.entries[i].label = String(trimmed.prefix(60))
        }
    }

    func clearEntries() {
        mutateSelected { roster in
            roster.entries.removeAll()
            roster.history.removeAll()
        }
    }

    // MARK: - Drawing

    /// All three delegate to `DrawRoster`, which is where the draw rules are defined
    /// and tested. The store's job is selection, notification and persistence.
    func recordWin(entryID: UUID, label: String) {
        mutateSelected { $0.recordWin(entryID: entryID, label: label) }
    }

    func putBack(_ result: DrawResult) {
        mutateSelected { $0.putBack(result) }
    }

    func resetDraw() {
        mutateSelected { $0.resetDraw() }
    }

    var canReset: Bool { selected?.canReset ?? false }

    // MARK: - Settings

    func setAutoRetire(_ on: Bool) {
        mutateSelected { $0.autoRetireWinner = on }
    }

    func setSpinDuration(_ duration: SpinDuration) {
        mutateSelected { $0.spinDuration = duration }
    }

    func setSoundEnabled(_ on: Bool) {
        mutateSelected { $0.soundEnabled = on }
    }

    // MARK: - Rosters

    func addRoster(named name: String = "New roster") {
        let roster = DrawRoster(name: name)
        rosters.append(roster)
        selectedRosterID = roster.id
        scheduleSave()
    }

    /// FR-13 "duplicate". The copy becomes the selected roster.
    func duplicateSelected() {
        guard let source = selected else { return }
        let copy = source.duplicated(named: String("\(source.name) copy".prefix(60)))
        rosters.append(copy)
        selectedRosterID = copy.id
        scheduleSave()
    }

    func renameSelected(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateSelected { $0.name = String(trimmed.prefix(60)) }
    }

    func deleteSelected() {
        guard rosters.count > 1, let id = selected?.id else { return }
        rosters.removeAll { $0.id == id }
        selectedRosterID = rosters.first?.id
        scheduleSave()
    }

    // MARK: - Export

    func historyCSV() -> String {
        guard let roster = selected else { return "" }
        let formatter = ISO8601DateFormatter()
        var lines = ["drawn_at,label,put_back"]
        for row in roster.history.reversed() {
            let escaped = row.label.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(formatter.string(from: row.drawnAt)),\"\(escaped)\",\(row.wasReturned)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private static let storageURL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }()

    /// Coalesced so a burst of edits (pasting 200 names) writes once, and off the
    /// main actor so the UI never waits on the encode.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = rosters
        let item = DispatchWorkItem {
            guard let url = Self.storageURL else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func flushToDisk() {
        saveWorkItem?.cancel()
        guard let url = Self.storageURL,
              let data = try? JSONEncoder().encode(rosters) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = Self.storageURL,
              let data = try? Data(contentsOf: url) else { return }
        do {
            rosters = try JSONDecoder().decode([DrawRoster].self, from: data)
        } catch {
            // A roster file we can't read is the user's typed data, so it is moved
            // aside rather than silently overwritten by the next save.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("luckyDraw.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            rosters = []
        }
    }
}
