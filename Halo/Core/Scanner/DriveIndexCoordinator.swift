import Foundation
import AppKit
import Darwin

// MARK: - DriveIndexCoordinator  (F-051)
//
// Owns the end-to-end drive lifecycle: mount detection → ask-first (or
// silent resolve for an already-approved drive) → walk → diff → store.
// @MainActor because it drives NSOpenPanel and publishes state SwiftUI
// reads directly (mirrors how other feature-owned singletons — e.g.
// LocalShareManager, ActionRunner — are read straight from the sidebar's
// badgeInfo(for:) rather than routed through AppState).

@MainActor
final class DriveIndexCoordinator: ObservableObject {

    static let shared = DriveIndexCoordinator()

    // MARK: Published state (UI reads these directly)

    /// Non-nil while a never-seen drive is waiting on the ask-first prompt.
    @Published var pendingAskDrive: DriveVolume?
    @Published private(set) var knownDrives: [KnownDrive] = []
    @Published private(set) var activelyIndexingDriveKeys: Set<String> = []
    @Published private(set) var lastDiffSummaries: [String: DriveDiffSummary] = [:]
    @Published private(set) var lastError: String?

    // MARK: Settings (UserDefaults-backed; Settings tab writes the same keys)

    static let sizeThresholdDefaultsKey = "driveIndexSizeThresholdBytes"
    static let excludedFolderNamesRawDefaultsKey = "driveIndexExcludedFolderNamesRaw"
    static let pausedDefaultsKey = "driveIndexPaused"
    static let defaultExcludedFolderNames = [".git", "node_modules", ".Trashes", ".Spotlight-V100", ".fseventsd"]

    var sizeThresholdBytes: Int64 {
        let stored = UserDefaults.standard.integer(forKey: Self.sizeThresholdDefaultsKey)
        return stored > 0 ? Int64(stored) : 100_000_000
    }

    private static func categoryDefaultsKey(_ category: IndexedFileCategory) -> String {
        "driveIndexCategoryEnabled.\(category.rawValue)"
    }

    /// Absent = enabled (default all-on, per FR-17).
    func isCategoryEnabled(_ category: IndexedFileCategory) -> Bool {
        let key = Self.categoryDefaultsKey(category)
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setCategoryEnabled(_ category: IndexedFileCategory, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.categoryDefaultsKey(category))
    }

    private var enabledCategories: Set<IndexedFileCategory> {
        Set(IndexedFileCategory.allCases.filter(isCategoryEnabled))
    }

    /// Newline-separated in storage (a single String is `@AppStorage`-friendly,
    /// unlike `[String]`); empty/unset falls back to the seed list.
    private var excludedFolderNames: Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: Self.excludedFolderNamesRawDefaultsKey),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Set(Self.defaultExcludedFolderNames)
        }
        let names = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(names)
    }

    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pausedDefaultsKey) }
    }

    // MARK: Internals

    private let monitor = DriveMonitor()
    private var accessManager: DriveAccessManager?
    private var store: DriveIndexStore?
    private(set) var connectedVolumesByKey: [String: DriveVolume] = [:]

    private init() {}

    func isConnected(driveKey: String) -> Bool {
        connectedVolumesByKey[driveKey] != nil
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            store = try DriveIndexStore()
            accessManager = try DriveAccessManager()
        } catch {
            lastError = "Drive Index couldn't open its store: \(error.localizedDescription)"
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingSeedDriveIndex") {
            await seedForUITesting()
        }
        await refreshKnownDrives()
        await monitor.startMonitoring { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    /// Deterministic sample data for `HaloUITests/DriveIndexUITests.swift` —
    /// no real external drive is available in CI. One drive is marked
    /// "connected" (so Reveal/Open enable), one is left out of
    /// `connectedVolumesByKey` entirely (so it reads as "disconnected"), and
    /// both share a same-size file to exercise the cross-drive duplicate
    /// path once Phase 4 lands. Routed to a temp-dir store — see
    /// `DriveIndexStore.storeDirectory()` — so this never touches a real
    /// developer's index.
    private func seedForUITesting() async {
        guard let store else { return }

        let driveA = DriveVolume(
            id: "/Volumes/UITestDriveA", name: "Test Drive A",
            url: URL(fileURLWithPath: "/Volumes/UITestDriveA"),
            isInternal: false, isRemovable: true,
            totalBytes: 500_000_000_000, freeBytes: 250_000_000_000,
            volumeUUID: "UITEST-DRIVE-AAAA")
        connectedVolumesByKey[driveA.driveKey] = driveA
        let driveBKey = "UITEST-DRIVE-BBBB"

        let sharedSize: Int64 = 150_000_000
        let now = Date()
        let rowsA: [WalkedFileRow] = [
            WalkedFileRow(relativePath: "/Documents/report.pdf", fileName: "report.pdf",
                          size: 2_000_000, createdDate: now, modifiedDate: now, inode: 1001, category: .documents),
            WalkedFileRow(relativePath: "/Movies/vacation.mov", fileName: "vacation.mov",
                          size: sharedSize, createdDate: now, modifiedDate: now, inode: 1002, category: .video)
        ]
        let rowsB: [WalkedFileRow] = [
            WalkedFileRow(relativePath: "/Backups/vacation-copy.mov", fileName: "vacation-copy.mov",
                          size: sharedSize, createdDate: now, modifiedDate: now, inode: 2001, category: .video)
        ]

        try? await store.applyDiff(driveKey: driveA.driveKey, walked: rowsA)
        try? await store.applyDiff(driveKey: driveBKey, walked: rowsB)

        try? await store.upsertKnownDrive(KnownDrive(
            driveKey: driveA.driveKey, name: driveA.name, indexingState: .indexed,
            lastIndexedDate: now, fileCount: rowsA.count, totalBytes: rowsA.reduce(0) { $0 + $1.size }))
        try? await store.upsertKnownDrive(KnownDrive(
            driveKey: driveBKey, name: "Test Drive B", indexingState: .indexed,
            lastIndexedDate: now.addingTimeInterval(-86_400), fileCount: rowsB.count,
            totalBytes: rowsB.reduce(0) { $0 + $1.size }))
    }

    private func handle(_ event: DriveMonitorEvent) {
        switch event {
        case .mounted(let volume):
            connectedVolumesByKey[volume.driveKey] = volume
            Task { await handleMount(volume) }
        case .unmounted(let driveKey):
            connectedVolumesByKey.removeValue(forKey: driveKey)
        }
    }

    private func handleMount(_ volume: DriveVolume) async {
        guard !isPaused, let store else { return }
        guard let existing = try? await store.knownDrive(driveKey: volume.driveKey) else {
            // Never seen before — ask before doing anything.
            pendingAskDrive = volume
            return
        }
        switch existing.indexingState {
        case .declined, .notIndexed:
            return   // No auto-prompt; user can index manually from the Drives tab.
        case .indexed:
            await beginIndexing(volume)
        }
    }

    // MARK: - Ask-first responses (called from the prompt UI)

    func acceptIndexing(for volume: DriveVolume) {
        pendingAskDrive = nil
        presentGrantPanel(for: volume)
    }

    func declineIndexing(for volume: DriveVolume) {
        pendingAskDrive = nil
        Task {
            try? await store?.upsertKnownDrive(KnownDrive(
                driveKey: volume.driveKey, name: volume.name, indexingState: .declined,
                lastIndexedDate: nil, fileCount: 0, totalBytes: 0))
            await refreshKnownDrives()
            AlertLog.shared.append(
                title: "Drive not indexed",
                body: "\"\(volume.name)\" was not indexed. You can index it later from Drive Index → Drives.",
                kindRaw: "drive_declined")
        }
    }

    /// Manual "Index Now" from the Drives tab — for a never-approved or
    /// previously-declined drive, this is the consent, so it goes straight
    /// to the grant panel (same as accepting the ask-first prompt).
    func manuallyIndex(driveKey: String) {
        guard let volume = connectedVolumesByKey[driveKey] else { return }
        presentGrantPanel(for: volume)
    }

    /// Manual "Re-index" for an already-approved, currently connected drive.
    func manuallyReindex(driveKey: String) {
        guard let volume = connectedVolumesByKey[driveKey] else { return }
        Task { await beginIndexing(volume) }
    }

    func forgetDrive(driveKey: String) {
        Task {
            try? await store?.forgetDrive(driveKey: driveKey)
            await accessManager?.forgetBookmark(driveKey: driveKey)
            await refreshKnownDrives()
        }
    }

    // MARK: - Grant flow

    private func presentGrantPanel(for volume: DriveVolume) {
        let panel = NSOpenPanel()
        panel.message = "Grant Halo access to index \"\(volume.name)\" so it can be searched and checked for duplicates — including while it's disconnected."
        panel.prompt = "Grant Access"
        panel.directoryURL = volume.url
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let grantedURL = panel.url else { return }
            Task { await self?.handleGrant(volume: volume, grantedURL: grantedURL) }
        }
    }

    private func handleGrant(volume: DriveVolume, grantedURL: URL) async {
        guard let accessManager, let store else { return }
        do {
            try await accessManager.saveBookmark(driveKey: volume.driveKey, grantedURL: grantedURL)
        } catch {
            lastError = "Couldn't save access to \"\(volume.name)\": \(error.localizedDescription)"
            return
        }
        try? await store.upsertKnownDrive(KnownDrive(
            driveKey: volume.driveKey, name: volume.name, indexingState: .indexed,
            lastIndexedDate: nil, fileCount: 0, totalBytes: 0))
        AlertLog.shared.append(
            title: "Indexing \"\(volume.name)\"",
            body: "Halo is building a searchable index of this drive.",
            kindRaw: "drive_indexing_started")
        await beginIndexing(volume)
    }

    // MARK: - Indexing

    func beginIndexing(_ volume: DriveVolume) async {
        guard !isPaused else { return }
        guard let accessManager, let store else { return }
        guard !activelyIndexingDriveKeys.contains(volume.driveKey) else { return }

        activelyIndexingDriveKeys.insert(volume.driveKey)
        defer { activelyIndexingDriveKeys.remove(volume.driveKey) }

        guard let scopedURL = await accessManager.resolveAndStartAccessing(driveKey: volume.driveKey) else {
            lastError = "Couldn't access \"\(volume.name)\" — its grant may need to be renewed from the Drives tab."
            return
        }
        defer { Task { await accessManager.stopAccessing(scopedURL) } }

        let walked = DriveIndexCoordinator.walk(
            root: scopedURL,
            excludedFolderNames: excludedFolderNames,
            enabledCategories: enabledCategories)

        guard let summary = try? await store.applyDiff(driveKey: volume.driveKey, walked: walked) else { return }
        lastDiffSummaries[volume.driveKey] = summary

        let totalBytes = walked.reduce(Int64(0)) { $0 + $1.size }
        try? await store.upsertKnownDrive(KnownDrive(
            driveKey: volume.driveKey, name: volume.name, indexingState: .indexed,
            lastIndexedDate: Date(), fileCount: walked.count, totalBytes: totalBytes))
        await refreshKnownDrives()
    }

    func refreshKnownDrives() async {
        guard let store else { return }
        knownDrives = (try? await store.allKnownDrives()) ?? []
    }

    // MARK: - Search (Phase 2 UI reads this)

    func search(query: String) async -> [IndexedFileEntry] {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? await store.search(query: query)) ?? []
    }

    /// Reveal/open both need the *security-scoped* root (not the plain
    /// `DriveVolume.url` from the mount notification) to read the file under
    /// sandbox — resolved fresh each call and released right after.
    func revealInFinder(_ entry: IndexedFileEntry) {
        guard let accessManager else { return }
        Task {
            guard let root = await accessManager.resolveAndStartAccessing(driveKey: entry.driveKey) else { return }
            defer { Task { await accessManager.stopAccessing(root) } }
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(entry.relativePath)])
        }
    }

    func openFile(_ entry: IndexedFileEntry) {
        guard let accessManager else { return }
        Task {
            guard let root = await accessManager.resolveAndStartAccessing(driveKey: entry.driveKey) else { return }
            defer { Task { await accessManager.stopAccessing(root) } }
            NSWorkspace.shared.open(root.appendingPathComponent(entry.relativePath))
        }
    }

    // MARK: - Cross-drive duplicates (Phase 4)

    /// Same-size candidates across every indexed drive (free — an index
    /// lookup), then hash-confirmed via the existing `DuplicateDetector`
    /// among whichever members are currently connected. A group is
    /// `isConfirmed` only when ALL its same-size members were connected and
    /// hash-matched; if any member's drive is offline, the whole group
    /// surfaces as "awaiting reconnect" instead (F-051 FR-10) — the
    /// connected members might already hash-match each other, but the
    /// group as a whole can't be called a confirmed duplicate set until
    /// every candidate has been checked.
    func duplicates(minSizeBytes: Int64) async -> [CrossDriveDuplicateGroup] {
        guard let store, let accessManager else { return [] }
        guard let sizes = try? await store.candidateDuplicateSizes(minSize: minSizeBytes) else { return [] }

        var groups: [CrossDriveDuplicateGroup] = []

        for size in sizes {
            guard let entries = try? await store.filesOfSize(size), entries.count > 1 else { continue }
            let connected = entries.filter { isConnected(driveKey: $0.driveKey) }
            let disconnected = entries.filter { !isConnected(driveKey: $0.driveKey) }

            guard connected.count > 1 else {
                // Nothing connected to hash-compare — surface as a same-size
                // candidate awaiting reconnect rather than silently dropping it.
                groups.append(makeDuplicateGroup(entries, isConfirmed: false))
                continue
            }

            var scopedRoots: [String: URL] = [:]
            var resolved: [(entry: IndexedFileEntry, url: URL)] = []
            for entry in connected {
                let root: URL
                if let cached = scopedRoots[entry.driveKey] {
                    root = cached
                } else if let scoped = await accessManager.resolveAndStartAccessing(driveKey: entry.driveKey) {
                    root = scoped
                    scopedRoots[entry.driveKey] = scoped
                } else {
                    continue
                }
                resolved.append((entry, root.appendingPathComponent(entry.relativePath)))
            }
            defer { for (_, root) in scopedRoots { Task { await accessManager.stopAccessing(root) } } }

            guard resolved.count > 1,
                  let hashGroups = try? await DuplicateDetector().detect(in: resolved.map(\.url), onProgress: { _ in }) else {
                groups.append(makeDuplicateGroup(entries, isConfirmed: false))
                continue
            }

            for hashGroup in hashGroups where hashGroup.items.count > 1 {
                let matchedURLs = Set(hashGroup.items.map(\.url))
                let matchedEntries = resolved.filter { matchedURLs.contains($0.url) }.map(\.entry)
                guard matchedEntries.count > 1 else { continue }
                groups.append(makeDuplicateGroup(matchedEntries + disconnected, isConfirmed: disconnected.isEmpty))
            }
        }

        return groups
    }

    private func makeDuplicateGroup(_ entries: [IndexedFileEntry], isConfirmed: Bool) -> CrossDriveDuplicateGroup {
        let items = entries.map { entry in
            CrossDriveDuplicateItem(
                driveKey: entry.driveKey,
                driveName: knownDrives.first { $0.driveKey == entry.driveKey }?.name ?? "Unknown drive",
                isDriveConnected: isConnected(driveKey: entry.driveKey),
                relativePath: entry.relativePath,
                sizeBytes: entry.size,
                modifiedDate: entry.modifiedDate
            )
        }
        return CrossDriveDuplicateGroup(items: items, isConfirmed: isConfirmed)
    }

    /// Trashes each marked item (never `removeItem`), resolving its
    /// security-scoped root fresh. Only ever called after the UI's own
    /// confirmation sheet — this method itself does not confirm.
    @discardableResult
    func deleteDuplicates(_ items: [CrossDriveDuplicateItem]) async -> (deleted: Int, failed: Int) {
        guard let accessManager else { return (0, items.count) }
        var deleted = 0
        var failed = 0
        var scopedRoots: [String: URL] = [:]

        for item in items {
            let root: URL
            if let cached = scopedRoots[item.driveKey] {
                root = cached
            } else if let scoped = await accessManager.resolveAndStartAccessing(driveKey: item.driveKey) {
                root = scoped
                scopedRoots[item.driveKey] = scoped
            } else {
                failed += 1
                continue
            }
            let url = root.appendingPathComponent(item.relativePath)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                deleted += 1
            } catch {
                failed += 1
            }
        }

        for (_, root) in scopedRoots { await accessManager.stopAccessing(root) }
        return (deleted, failed)
    }

    // MARK: - Walk

    /// Walks a granted volume root, skipping excluded folder names entirely
    /// (not just hiding their contents) and skipping any file whose category
    /// isn't enabled — both per Settings (FR-17/FR-18).
    nonisolated static func walk(root: URL, excludedFolderNames: Set<String>, enabledCategories: Set<IndexedFileCategory>) -> [WalkedFileRow] {
        var rows: [WalkedFileRow] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return rows }

        let rootPathLength = root.path.count
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                if excludedFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let size = values.fileSize else { continue }
            let fileName = url.lastPathComponent
            let category = IndexedFileCategory.categorize(fileName: fileName)
            guard enabledCategories.contains(category) else { continue }

            rows.append(WalkedFileRow(
                relativePath: String(url.path.dropFirst(rootPathLength)),
                fileName: fileName,
                size: Int64(size),
                createdDate: values.creationDate,
                modifiedDate: values.contentModificationDate,
                inode: DriveIndexCoordinator.inode(for: url),
                category: category
            ))
        }
        return rows
    }

    nonisolated private static func inode(for url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }
}
