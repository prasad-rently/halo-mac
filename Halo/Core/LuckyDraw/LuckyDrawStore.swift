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
    private let fileURL: URL?
    /// F-053: where participants' photos live — beside the roster file, in `luckydraw/avatars/`.
    /// Nil when the store has no file (no persistence ⇒ no photos).
    let avatarStore: AvatarStore?
    /// True only when the roster file was read successfully. The orphan sweep deletes files, so
    /// it must never run after a failed or missing read — an unreadable file would otherwise
    /// make every photo look unreferenced.
    private var loadedCleanly = false

    private convenience init() {
        self.init(fileURL: Self.defaultStorageURL)
        AvatarImageCache.shared.store = avatarStore
    }

    /// Test seam: a scratch file and a private notification center, so a test never
    /// touches the user's rosters or posts a real app-termination notification.
    init(fileURL: URL?, notificationCenter: NotificationCenter = .default, detectFaces: Bool = true) {
        self.fileURL = fileURL
        self.avatarStore = fileURL.map {
            AvatarStore(rootURL: $0.deletingLastPathComponent()
                .appendingPathComponent("luckydraw/avatars", isDirectory: true),
                        detectFaces: detectFaces)
        }
        loadFromDisk()
        if rosters.isEmpty {
            rosters = [DrawRoster.starter()]
        }
        selectedRosterID = rosters.first?.id
        sweepOrphanPhotos()

        // Saves are debounced 0.6 s, so an edit made just before ⌘Q would otherwise be
        // lost. Write whatever is pending as the app terminates.
        notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushToDisk() }
        }
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
        let rosterID = selected?.id
        // Read the avatar from the roster, not from `entry`: the caller's copy can predate the
        // photo being set, and trusting it would leave the file behind.
        let file = selected?.entries.first { $0.id == entry.id }?.avatar?.photoFileName
        mutateSelected { roster in
            roster.entries.removeAll { $0.id == entry.id }
        }
        if let rosterID, let file {
            avatarStore?.delete(fileName: file, rosterID: rosterID)
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
        let rosterID = selected?.id
        mutateSelected { roster in
            roster.entries.removeAll()
            roster.history.removeAll()
        }
        if let rosterID { avatarStore?.deleteAll(rosterID: rosterID) }
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
        var copy = source.duplicated(named: String("\(source.name) copy".prefix(60)))
        // `duplicated` leaves photos out (they belong to a roster's own folder); copy them across
        // and re-point the new entries. Entry order is preserved, so indices line up.
        if let avatarStore {
            for (i, original) in source.entries.enumerated() where i < copy.entries.count {
                if let file = original.avatar?.photoFileName,
                   let newName = avatarStore.copyPhoto(fileName: file, from: source.id, to: copy.id) {
                    copy.entries[i].avatar = .photo(fileName: newName)
                }
            }
        }
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
        avatarStore?.deleteAll(rosterID: id)
    }

    // MARK: - Avatars (F-053)

    func setAvatarDisplay(_ mode: AvatarDisplayMode) {
        mutateSelected { $0.avatarDisplay = mode }
    }

    /// Sets (or, with nil, clears) an entry's avatar, and removes the entry's previous photo file
    /// when it is being replaced. If the entry has vanished meanwhile (a photo import is async),
    /// a just-written photo is removed rather than orphaned.
    func setAvatar(_ avatar: EntryAvatar?, for entry: DrawEntry, inRoster rosterID: UUID? = nil) {
        guard let rosterID = rosterID ?? selected?.id,
              let r = rosters.firstIndex(where: { $0.id == rosterID }) else { return }
        guard let e = rosters[r].entries.firstIndex(where: { $0.id == entry.id }) else {
            if let file = avatar?.photoFileName { avatarStore?.delete(fileName: file, rosterID: rosterID) }
            return
        }
        let old = rosters[r].entries[e].avatar?.photoFileName
        rosters[r].entries[e].avatar = avatar
        rosters[r].modifiedAt = Date()
        scheduleSave()
        if let old, old != avatar?.photoFileName { avatarStore?.delete(fileName: old, rosterID: rosterID) }
    }

    /// Imports a picture the user chose and makes it the entry's avatar. Decoding runs off the
    /// main actor; on any failure nothing changes.
    func setPhoto(from url: URL, for entry: DrawEntry) async throws {
        guard let avatarStore, let rosterID = selected?.id else { throw AvatarStore.AvatarError.writeFailed }
        let name = try await avatarStore.importPhotoAsync(from: url, rosterID: rosterID)
        setAvatar(.photo(fileName: name), for: entry, inRoster: rosterID)
    }

    func setPhoto(data: Data, for entry: DrawEntry) async throws {
        guard let avatarStore, let rosterID = selected?.id else { throw AvatarStore.AvatarError.writeFailed }
        let name = try await avatarStore.importPhotoAsync(data: data, rosterID: rosterID)
        setAvatar(.photo(fileName: name), for: entry, inRoster: rosterID)
    }

    /// FR-B1: applies a confirmed folder match. Returns how many photos were applied and how many failed.
    func applyPhotoMatches(_ matches: [AvatarFolderMatcher.Match]) async -> (applied: Int, failed: Int) {
        var applied = 0, failed = 0
        for m in matches {
            guard let entry = selected?.entries.first(where: { $0.id == m.entryID }) else { failed += 1; continue }
            do { try await setPhoto(from: m.file, for: entry); applied += 1 } catch { failed += 1 }
        }
        return (applied, failed)
    }

    /// Settings → "Clear all photos": removes every stored photo and un-points the entries.
    func clearAllPhotos() {
        avatarStore?.deleteEverything()
        for r in rosters.indices {
            for e in rosters[r].entries.indices where rosters[r].entries[e].avatar?.isPhoto == true {
                rosters[r].entries[e].avatar = nil
            }
        }
        scheduleSave()
    }

    func avatarStorageBytes() -> Int64 { avatarStore?.totalBytes() ?? 0 }

    /// Deletes photo files nothing references — only after a clean load (see `loadedCleanly`).
    private func sweepOrphanPhotos() {
        guard loadedCleanly, let avatarStore else { return }
        let live = liveReferences()
        let fileURL = self.fileURL
        DispatchQueue.global(qos: .utility).async {
            Self.performSweep(avatarStore: avatarStore, live: live, fileURL: fileURL)
        }
    }

    /// Test seam: the same sweep, run synchronously. Returns files removed, or nil when it
    /// declined to run (unclean load, or an unparseable recovery file).
    @discardableResult
    func sweepOrphanPhotosNow() -> Int? {
        guard loadedCleanly, let avatarStore else { return nil }
        return Self.performSweep(avatarStore: avatarStore, live: liveReferences(), fileURL: fileURL)
    }

    private func liveReferences() -> [UUID: Set<String>] {
        var referenced: [UUID: Set<String>] = [:]
        for roster in rosters {
            referenced[roster.id] = Set(roster.entries.compactMap { $0.avatar?.photoFileName })
        }
        return referenced
    }

    @discardableResult
    nonisolated private static func performSweep(avatarStore: AvatarStore,
                                                 live: [UUID: Set<String>], fileURL: URL?) -> Int? {
        var referenced = live
        // A recovery roster (`luckyDraw.corrupt.json`, or any backup beside it) still points at
        // photos. Deleting them would destroy the only path back to the user's data — so they
        // count as live, and if a recovery file can't be understood we delete nothing at all.
        if let fileURL {
            guard let recovered = recoveryReferences(besides: fileURL) else { return nil }
            for (rosterID, files) in recovered { referenced[rosterID, default: []].formUnion(files) }
        }
        return avatarStore.sweepOrphans(referenced: referenced)
    }

    /// Every photo file name referenced by a retained recovery/backup roster file next to the live
    /// one, keyed by roster. Decodes *leniently* (plain JSON, no model types): only enough to
    /// collect `rosterID → photo file names`. Returns nil — "unsafe, skip the sweep" — when any
    /// such file can't be read or parsed, or names photos under a roster it can't identify.
    nonisolated static func recoveryReferences(besides liveFile: URL) -> [UUID: Set<String>]? {
        let dir = liveFile.deletingLastPathComponent()
        let liveName = liveFile.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [UUID: Set<String>] = [:]
        for name in names where name != liveName && name.hasPrefix("luckyDraw")
            && (name.hasSuffix(".json") || name.hasSuffix(".bak")) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let rosters = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
            for case let roster as [String: Any] in rosters {
                var files = Set<String>()
                for case let entry as [String: Any] in (roster["entries"] as? [Any]) ?? [] {
                    if let avatar = entry["avatar"] as? [String: Any], avatar["kind"] as? String == "photo",
                       let file = avatar["file"] as? String, AvatarFileName.isValid(file) {
                        files.insert(file)
                    }
                }
                guard !files.isEmpty else { continue }
                guard let idString = roster["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
                result[id, default: []].formUnion(files)
            }
        }
        return result
    }

    // MARK: - Export

    func historyCSV() -> String {
        guard let roster = selected else { return "" }
        let formatter = ISO8601DateFormatter()
        var lines = ["drawn_at,label,put_back"]
        for row in roster.history.reversed() {
            let escaped = Self.csvSafe(row.label).replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(formatter.string(from: row.drawnAt)),\"\(escaped)\",\(row.wasReturned)")
        }
        return lines.joined(separator: "\n")
    }

    /// A name typed by the user (or pasted from a stranger's list) that starts with
    /// `= + - @` is a *formula* when the exported CSV is opened in Excel or Numbers.
    /// A leading apostrophe makes the spreadsheet read it as plain text.
    static func csvSafe(_ field: String) -> String {
        guard let first = field.first, "=+-@\t\r".contains(first) else { return field }
        return "'" + field
    }

    // MARK: - Persistence

    private static let defaultStorageURL: URL? = {
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
        let fileURL = self.fileURL
        let item = DispatchWorkItem {
            guard let url = fileURL else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Writes any pending edit now. A no-op when nothing was edited this session, so
    /// quitting never rewrites a roster file the user did not change.
    func flushToDisk() {
        guard let pending = saveWorkItem else { return }
        pending.cancel()
        saveWorkItem = nil
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(rosters) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return }
        do {
            rosters = try JSONDecoder().decode([DrawRoster].self, from: data)
            loadedCleanly = true
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
