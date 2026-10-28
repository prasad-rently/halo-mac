import Foundation
import SwiftUI

// MARK: - F-054 — Build Artifacts pane: roots store + view model
//
// The UI-free half of the pane, so the rules that decide what can be deleted are testable:
// selection (smart-select never picks Caution / Active / git-unverified-in-repo), the frozen
// review snapshot (Cancel deletes nothing; the confirmation acts on exactly what was shown),
// partial-failure reporting (only items that really moved leave the list), generation-token scan
// supersession, and reconcile-after-removal into the rest of Cleanup (BUG-001).

// MARK: - Roots store (D8 / D9)

/// User-chosen scan roots, the "never offer" list and the stale threshold. Persisted in
/// `UserDefaults` (the user's own choices — NFR-4); bookmarks as `Data` for the sandboxed build.
final class BuildArtifactRootsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Security-scoped URLs we have started accessing this session (kept open on purpose).
    private var accessing: [URL] = []

    static let rootsKey = "buildArtifactUserRoots"
    static let bookmarksKey = "buildArtifactRootBookmarks"
    static let ignoredKey = "buildArtifactIgnoredPaths"
    static let includeHomeKey = "buildArtifactIncludeHome"
    static let staleDaysKey = "buildArtifactStaleDays"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var userRoots: [String] { defaults.stringArray(forKey: Self.rootsKey) ?? [] }
    var ignoredPaths: Set<String> { Set(defaults.stringArray(forKey: Self.ignoredKey) ?? []) }
    var includeHome: Bool {
        get { defaults.bool(forKey: Self.includeHomeKey) }
        set { defaults.set(newValue, forKey: Self.includeHomeKey) }
    }
    var staleDays: Int {
        get { let v = defaults.integer(forKey: Self.staleDaysKey); return v > 0 ? v : 30 }
        set { defaults.set(max(1, newValue), forKey: Self.staleDaysKey) }
    }

    func addRoot(_ url: URL, sandboxed: Bool) {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        var roots = userRoots
        if !roots.contains(path) { roots.append(path); defaults.set(roots, forKey: Self.rootsKey) }
        if sandboxed,
           let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var marks = (defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data]) ?? [:]
            marks[path] = data
            defaults.set(marks, forKey: Self.bookmarksKey)
        }
    }

    func removeRoot(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(userRoots.filter { $0 != path }, forKey: Self.rootsKey)
        var marks = (defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data]) ?? [:]
        marks[path] = nil
        defaults.set(marks, forKey: Self.bookmarksKey)
    }

    func ignore(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        var s = ignoredPaths; s.insert(path)
        defaults.set(Array(s).sorted(), forKey: Self.ignoredKey)
    }

    func resetIgnoreList() { defaults.removeObject(forKey: Self.ignoredKey) }

    /// The roots a scan should walk. Unsandboxed: default roots that exist + user roots (+ home when
    /// opted in). Sandboxed: ONLY roots the user granted via `NSOpenPanel` (resolved from their
    /// bookmark and opened), because nothing else is readable — an empty result must show the
    /// "Choose folders" state, never look like "nothing found" (D9).
    func scanRoots(sandboxed: Bool, home: String = NSHomeDirectory(),
                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        var roots: [String] = []
        if sandboxed {
            let marks = (defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data]) ?? [:]
            for (path, data) in marks.sorted(by: { $0.key < $1.key }) {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                         relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
                lock.lock()
                if url.startAccessingSecurityScopedResource() { accessing.append(url) }
                lock.unlock()
                roots.append(url.standardizedFileURL.path)
                _ = path
            }
        } else {
            roots = BuildArtifactRoots.defaultRoots(home: home, exists: exists) + userRoots.filter(exists)
            if includeHome { roots.append(home) }
        }
        return Self.pruneNested(roots)
    }

    /// Drop duplicates and any root that lies inside another root (it would be scanned twice).
    static func pruneNested(_ roots: [String]) -> [String] {
        let std = Array(Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        return std.filter { r in !std.contains { $0 != r && CleanupPath.isCovered(r, by: $0) } }
    }
}

// MARK: - View model

@MainActor
final class BuildArtifactsViewModel: ObservableObject {

    enum Grouping: String, CaseIterable, Identifiable {
        case biggest = "Biggest first", project = "By project", toolchain = "By toolchain"
        var id: String { rawValue }
    }

    enum RemovalMode: Equatable { case trash, trashAndEmpty }

    /// Frozen when the review sheet opens: the confirmation acts on exactly this list, never on
    /// whatever a later rescan put in `items` (the BUG-001 / #53 Clean-All lesson).
    struct ReviewSnapshot: Identifiable, Equatable {
        let id = UUID()
        let items: [BuildArtifactItem]
        var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var formatted: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        /// D-02: the permanent action is offered only when EVERY item in the snapshot is eligible.
        var allPermanentEligible: Bool { !items.isEmpty && items.allSatisfy(\.permanentRemovalEligible) }
        var ineligibleForPermanent: Int { items.filter { !$0.permanentRemovalEligible }.count }
    }

    struct Banner: Equatable { var text: String; var isError: Bool }

    typealias ScanFunction = @Sendable ([String], BuildArtifactScanner.Config) async -> AsyncStream<BuildArtifactScanEvent>

    @Published private(set) var items: [BuildArtifactItem] = []
    @Published var selection: Set<String> = []
    @Published var grouping: Grouping = .biggest
    @Published var toolchainFilter: String? = nil
    @Published var staleOnly = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var summary: BuildArtifactScanSummary? = nil
    @Published private(set) var lastScanned: Date? = nil
    @Published private(set) var foldersScanned = 0
    @Published private(set) var needsRoots = false
    @Published private(set) var scannedRoots: [String] = []
    @Published var review: ReviewSnapshot? = nil
    @Published var banner: Banner? = nil

    let roots: BuildArtifactRootsStore
    private let scanFunction: ScanFunction
    private let trash: BuildArtifactRemover.TrashFunction
    private let trashDirectories: [URL]
    private let sandboxed: Bool
    private let home: String
    /// Called with the URLs that really left their place, so the rest of Cleanup forgets them at
    /// once (BUG-001 FR-I1) — sidebar totals, other categories, Trash.
    var onRemoved: ([URL]) -> Void = { _ in }

    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?

    init(roots: BuildArtifactRootsStore = BuildArtifactRootsStore(),
         sandboxed: Bool = BuildArtifactRemover.isSandboxed,
         home: String = NSHomeDirectory(),
         trash: @escaping BuildArtifactRemover.TrashFunction = BuildArtifactRemover.systemTrash,
         trashDirectories: [URL]? = nil,
         scan: ScanFunction? = nil) {
        self.roots = roots
        self.sandboxed = sandboxed
        self.home = home
        self.trash = trash
        self.trashDirectories = trashDirectories ?? BuildArtifactRemover.defaultTrashDirectories()
        self.scanFunction = scan ?? { roots, config in await BuildArtifactsViewModel.defaultScan(roots: roots, config: config) }
    }

    /// Project scan + the fixed Xcode (global) folders (D7), as one stream.
    nonisolated static func defaultScan(roots: [String], config: BuildArtifactScanner.Config) async -> AsyncStream<BuildArtifactScanEvent> {
        let scanner = BuildArtifactScanner()
        return AsyncStream { continuation in
            let task = Task {
                for item in await scanner.xcodeGlobalItems(config: config) { continuation.yield(.found(item)) }
                for await ev in await scanner.scan(roots: roots, config: config) { continuation.yield(ev) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Permanent removal is built, but hidden whenever S-B cannot be shown to hold (sandboxed).
    var permanentRemovalAvailable: Bool { BuildArtifactRemover.permanentRemovalAvailable(sandboxed: sandboxed) }
    /// Spec R5: in a sandboxed build the git gate cannot run, so nothing inside a repo is verified.
    var gitGateAvailable: Bool { !sandboxed }

    // MARK: Derived

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    var selectedItems: [BuildArtifactItem] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var toolchains: [(id: String, name: String)] {
        var seen = Set<String>(); var out: [(String, String)] = []
        for i in items where seen.insert(i.toolchainID).inserted { out.append((i.toolchainID, i.toolchainName)) }
        return out.sorted { $0.1 < $1.1 }
    }

    func isStale(_ item: BuildArtifactItem, now: Date = Date()) -> Bool {
        item.isSmartSelectable(staleDays: roots.staleDays, now: now)
    }

    var visibleItems: [BuildArtifactItem] {
        items.filter { i in
            (toolchainFilter == nil || i.toolchainID == toolchainFilter)
                && (!staleOnly || isStale(i))
        }
    }

    /// Sections for the chosen grouping, each sorted biggest-first.
    var sections: [(title: String, items: [BuildArtifactItem])] {
        let v = visibleItems.sorted { $0.size > $1.size }
        switch grouping {
        case .biggest: return [("", v)]
        case .project:
            return Dictionary(grouping: v, by: \.projectName).map { ($0.key, $0.value) }
                .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
        case .toolchain:
            return Dictionary(grouping: v, by: \.toolchainName).map { ($0.key, $0.value) }
                .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
        }
    }

    // MARK: Scanning

    func rescan() {
        scanTask?.cancel()
        scanTask = Task(priority: .utility) { await scan() }
    }

    func cancelScan() { scanTask?.cancel(); scanGeneration += 1; isScanning = false }

    /// A newer call supersedes an older one: the older stream's events stop landing the moment the
    /// generation moves on (BUG-001 FR-4 / R8).
    func scan() async {
        scanGeneration += 1
        let generation = scanGeneration
        let scanRoots = roots.scanRoots(sandboxed: sandboxed, home: home)
        needsRoots = sandboxed && scanRoots.isEmpty
        scannedRoots = scanRoots
        isScanning = true
        summary = nil
        foldersScanned = 0
        var found: [String: BuildArtifactItem] = [:]

        var config = BuildArtifactScanner.Config()
        config.home = home
        config.excludedPaths = BuildArtifactRoots.defaultExcluded(home: home)
        config.ignoredPaths = roots.ignoredPaths

        if !needsRoots {
            for await ev in await scanFunction(scanRoots, config) {
                guard generation == scanGeneration else { return }       // superseded: never land
                switch ev {
                case .found(let item):
                    found[item.id] = item
                    items = found.values.sorted { $0.size > $1.size }
                case .progress(let n): foldersScanned = n
                case .skipped: break
                case .finished(let s): summary = s
                }
            }
        }
        guard generation == scanGeneration else { return }
        items = found.values.sorted { $0.size > $1.size }
        selection = selection.intersection(Set(items.map(\.id)))
        isScanning = false
        lastScanned = Date()
    }

    // MARK: Selection (FR-U4)

    func toggle(_ item: BuildArtifactItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectNone() { selection = [] }

    /// Never selects Caution, Active, or items git could not vouch for in a repo (D5, §5.3.5).
    func selectAllSafe() {
        selection = Set(visibleItems.filter { $0.regenClass == .safe && $0.isSmartSelectable() }.map(\.id))
    }

    func selectStale(now: Date = Date()) {
        selection = Set(visibleItems.filter { $0.isSmartSelectable(staleDays: roots.staleDays, now: now) }.map(\.id))
    }

    func neverOffer(_ item: BuildArtifactItem) {
        roots.ignore(item.artifactURL.path)
        roots.ignore(item.id)
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    // MARK: Removal (FR-U5 / U5b / U6)

    /// Freeze what the user is about to confirm. Rows whose folder has already vanished are dropped
    /// first, so a sheet never lists something that is gone.
    func beginReview() {
        let gone = items.filter { !CleanupPath.existsOnDisk($0.artifactURL) }
        if !gone.isEmpty { drop(ids: Set(gone.map(\.id))) }
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        review = ReviewSnapshot(items: chosen.sorted { $0.size > $1.size })
    }

    /// Cancel on the review sheet — and on the second confirmation — changes nothing.
    func cancelReview() { review = nil }

    /// Acts on the frozen snapshot only. The blocking filesystem work runs off the main actor.
    func confirm(_ mode: RemovalMode) async {
        guard let snap = review, !isRemoving else { return }
        review = nil
        isRemoving = true
        banner = nil
        let trash = self.trash, dirs = trashDirectories, home = self.home
        let allowed = permanentRemovalAvailable
        let outcome: BuildArtifactRemover.Outcome = await Task.detached(priority: .userInitiated) {
            switch mode {
            case .trash: return BuildArtifactRemover.moveToTrash(snap.items, trash: trash, home: home)
            case .trashAndEmpty: return BuildArtifactRemover.trashAndEmpty(snap.items, trash: trash, trashDirectories: dirs,
                                                                          home: home, permanentAllowed: allowed)
            }
        }.value
        apply(outcome, snapshot: snap, mode: mode)
        isRemoving = false
    }

    private func drop(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Only items that actually moved leave the list (FR-U6); failures and refusals stay listed.
    func apply(_ o: BuildArtifactRemover.Outcome, snapshot: ReviewSnapshot, mode: RemovalMode) {
        let moved = Set(o.moved)
        let movedURLs = snapshot.items.filter { moved.contains($0.id) }.map(\.artifactURL)
        drop(ids: moved)
        if !movedURLs.isEmpty { onRemoved(movedURLs) }

        let bytes = ByteCountFormatter.string(fromByteCount: o.movedBytes, countStyle: .file)
        var parts: [String] = []
        if mode == .trashAndEmpty {
            let removedBytes = snapshot.items.filter { o.permanentlyRemoved.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
            parts.append("Permanently removed \(o.permanentlyRemoved.count) (\(ByteCountFormatter.string(fromByteCount: removedBytes, countStyle: .file)) freed).")
            if !o.leftInTrash.isEmpty { parts.append("\(o.leftInTrash.count) moved to Trash but left there: \(o.leftInTrash[0].message)") }
        } else if !o.moved.isEmpty {
            parts.append("Moved \(o.moved.count) to Trash (\(bytes)). Space is freed when you empty the Trash.")
        }
        let problems = o.failed + o.refused
        if let first = problems.first {
            let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            parts.append("\(problems.count) not removed — \"\(first.name)\": \(first.message)\(more)")
        }
        if parts.isEmpty { parts.append("Nothing was removed.") }
        banner = Banner(text: parts.joined(separator: " "), isError: !problems.isEmpty || !o.leftInTrash.isEmpty)
    }
}
