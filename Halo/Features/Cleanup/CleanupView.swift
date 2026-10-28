import SwiftUI

struct CleanupView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CleanupViewModel()
    @StateObject private var browserViewModel = BrowserCleanerViewModel()
    @State private var selectedCategory: CleanupKind = .systemCaches

    var body: some View {
        HStack(spacing: 0) {
            // Left Panel — Categories
            CleanupSidebar(selectedCategory: $selectedCategory, viewModel: viewModel, browserViewModel: browserViewModel)
                .frame(width: 260)
            Divider().background(Color.haloBorder)
            // Right Panel — File List (or the Browsers pane for that one category)
            if selectedCategory == .browsers {
                BrowserCleanerPane(viewModel: browserViewModel)
            } else {
                CleanupFileList(category: selectedCategory, viewModel: viewModel)
            }
        }
        .background(Color.haloSurface)
        .task { await viewModel.scanAll() }
        .task { await browserViewModel.loadAll() }
        .onChange(of: selectedCategory) { _ in viewModel.clearOutcome() }
        // Changes made outside Halo (Finder, `rm`, another app) can't be seen without a file
        // watcher; coming back to the app after a minute rescans, which is the cheap answer.
        .onChange(of: browserViewModel.isClearing) { clearing in
            if !clearing { Task { await viewModel.refreshAfterExternalDeletion() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if viewModel.rescanIfStale() { Task { await browserViewModel.loadAll() } }
        }
    }
}

// MARK: - Clean-All confirmation snapshot

/// The set of items shown in a Clean-All confirmation dialog, frozen when it was opened.
struct CleanAllSnapshot: Sendable {
    let kind: CleanupKind
    let items: [ScannedItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var formatted: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: - Per-operation result (H-03)

/// What the last Clean All / per-row trash did — one value, so the banner can never mix the
/// outcome of one operation with the error of another.
struct CleanOutcome: Equatable, Sendable {
    var moved: Int
    var failed: Int
    var freed: Int64
    /// "<name>: <message>" of the first failure, if any.
    var firstError: String?

    var hasFailures: Bool { failed > 0 }

    /// Nothing happened worth a banner (nothing moved, nothing failed).
    var isEmpty: Bool { moved == 0 && failed == 0 }

    /// Banner text. A partial failure leads with the counts — "Moved 2, 1 failed: …" — rather than
    /// hiding the successes behind the error.
    var message: String {
        let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        if failed > 0 {
            return "Moved \(moved), \(failed) failed: \(firstError ?? "unknown error")"
        }
        return "Moved \(moved) item\(moved == 1 ? "" : "s") (\(size)) to the Trash — space is freed when you empty the Trash."
    }
}

// MARK: - ViewModel

@MainActor
final class CleanupViewModel: ObservableObject {
    @Published var categories: [CleanupCategory] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var cleanError: String? = nil
    @Published var lastCleanResult: (deleted: Int, freed: Int64)? = nil
    /// The banner's source of truth (H-03): set by every clean operation, cleared by a category
    /// switch (`clearOutcome()`, called from the view) or the next full rescan.
    @Published private(set) var outcome: CleanOutcome? = nil
    @Published private(set) var lastScanned: Date? = nil

    private let coordinator: ScanCoordinator
    /// The categories this model manages — everything, except in tests.
    private let kinds: [CleanupKind]
    private var scanTask: Task<Void, Never>?
    /// Bumped by every full scan; a scan whose generation is no longer current discards its
    /// results, so a slow old scan can never overwrite a newer one (BUG-001 R8).
    private var scanGeneration = 0
    /// Paths this model has removed, each stamped with a serial. A scan that read a folder just
    /// before the user trashed something in it would otherwise bring that row back — but only
    /// removals made AFTER a scan began may be filtered out of its result. A scan that began
    /// later saw the folder as it is now, so a file that reappeared (a cache an app regenerated,
    /// an item put back from the Trash) is real and must stay listed.
    private var removalSerial = 0
    private var removals: [String: Int] = [:]

    /// How existence is checked by `pruneMissing`. Injectable so a test can observe which thread
    /// the stat work runs on and make it slow.
    private let existsOnDisk: @Sendable (URL) -> Bool
    private let pruneDeadline: TimeInterval

    init(coordinator: ScanCoordinator = ScanCoordinator(),
         kinds: [CleanupKind] = CleanupKind.allCases,
         existsOnDisk: @escaping @Sendable (URL) -> Bool = CleanupPath.existsOnDisk,
         pruneDeadline: TimeInterval = 5) {
        self.coordinator = coordinator
        self.kinds = kinds
        self.existsOnDisk = existsOnDisk
        self.pruneDeadline = pruneDeadline
    }

    /// Drop the result banner — a category switch or the user's dismiss.
    func clearOutcome() {
        outcome = nil
        cleanError = nil
        lastCleanResult = nil
    }

    /// Distinct paths — a file listed by two categories is counted once (BUG-001 R6).
    var totalBytes: Int64 { CleanupReconciler.distinctBytes(categories) }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    // MARK: Scanning

    /// Rescan every category. Safe to call while a scan is running: the newer call wins.
    func scanAll() async {
        scanGeneration += 1
        let generation = scanGeneration
        removals = [:]
        clearOutcome()                     // a banner describes the list it was shown against
        let startedAt = removalSerial
        isScanning = true
        categories = kinds.map { CleanupCategory(kind: $0) }
        await withTaskGroup(of: CleanupCategory.self) { group in
            for kind in kinds {
                group.addTask { await self.coordinator.scanCategory(kind) }
            }
            for await cat in group {
                guard generation == scanGeneration else { continue }   // superseded
                apply(scanned: cat, startedAt: startedAt)
            }
        }
        guard generation == scanGeneration else { return }   // the newer scan owns the flags
        isScanning = false
        lastScanned = Date()
    }

    /// Fire-and-forget rescan for the toolbar button and ⌘R; cancels a scan still in flight.
    func rescan() {
        scanTask?.cancel()
        scanTask = Task { await scanAll() }
    }

    /// Rescans only when the last scan is older than `maxAge`. Returns whether it started one.
    @discardableResult
    func rescanIfStale(maxAge: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard !isScanning, !isCleaning,
              CleanupFreshness.isStale(lastScanned: lastScanned, now: now, maxAge: maxAge) else { return false }
        rescan()
        return true
    }

    /// Replace one category's list with fresh scan results, minus anything removed after the
    /// scan began (`startedAt` is `removalSerial` when it did). The default, 0, means "began
    /// before every removal" — the conservative reading for a result of unknown age.
    func apply(scanned cat: CleanupCategory, startedAt: Int = 0) {
        guard let idx = categories.firstIndex(where: { $0.kind == cat.kind }) else { return }
        var fresh = cat
        if !removals.isEmpty {
            let newer = Set(removals.filter { $0.value > startedAt }.keys)
            if !newer.isEmpty {
                fresh.items.removeAll { CleanupReconciler.isRemoved(CleanupPath.key($0.url), in: newer) }
            }
        }
        categories[idx] = fresh
    }

    /// Re-scan just these categories (after a delete), so sizes are exact without a full rescan.
    private func rescan(kinds: Set<CleanupKind>) async {
        for kind in kinds where kind != .browsers {
            let startedAt = removalSerial
            let cat = await coordinator.scanCategory(kind)
            apply(scanned: cat, startedAt: startedAt)
        }
    }

    /// The Browsers pane trashes files under `~/Library/Caches` (Chrome's HTTP cache, Arc's, …)
    /// without going through this model, so without this its rows linger in User Caches and the
    /// moved files are missing from the Trash list — the very ghost-row bug BUG-001 is about.
    func refreshAfterExternalDeletion() async {
        await rescan(kinds: Set(kinds).intersection([.userCaches, .systemCaches, .trash]))
    }

    // MARK: Reconcile

    /// Make every category forget `urls` (and anything under them) at once, before any rescan
    /// returns — the "real time" requirement. Returns the kinds whose lists changed.
    @discardableResult
    func reconcile(removed urls: [URL]) -> [CleanupKind] {
        let keys = urls.map(CleanupPath.key)
        removalSerial += 1
        for k in keys { removals[k] = removalSerial }
        return CleanupReconciler.apply(removedKeys: keys, to: &categories)
    }

    /// Drop rows whose file has disappeared, so a confirmation sheet never lists something that
    /// is already gone. The stat work (one per row — 20 000 rows is routine) runs on a detached
    /// task, not the main actor, and is bounded by `pruneDeadline` (H-02); only the list surgery
    /// happens back on the main actor.
    func pruneMissing() async {
        let urls = categories.flatMap(\.items).map(\.url)
        guard !urls.isEmpty else { return }
        let exists = existsOnDisk, deadline = pruneDeadline
        let missing = await Task.detached(priority: .userInitiated) {
            CleanupPath.missing(among: urls, exists: exists, deadline: deadline)
        }.value
        if !missing.isEmpty { reconcile(removed: missing) }
    }

    // MARK: Cleaning

    /// Capture what the user is about to be asked to confirm. The snapshot is immutable: a rescan
    /// (activation, manual, post-clean) that lands while the dialog is open changes the live list
    /// but never what "Move to Trash" acts on. Returns nil when there is nothing to clean.
    func beginCleanAll(for kind: CleanupKind) async -> CleanAllSnapshot? {
        await pruneMissing()      // never offer to trash what is already gone
        guard let cat = category(for: kind), !cat.items.isEmpty else { return nil }
        return CleanAllSnapshot(kind: kind, items: cat.items)
    }

    /// Clean exactly the items the user confirmed — the snapshot, intersected with what still
    /// exists on disk. Items a later rescan discovered are NOT included.
    func cleanAll(confirmed snapshot: CleanAllSnapshot) async {
        await pruneMissing()
        let exists = existsOnDisk
        let urls = snapshot.items.map(\.url)
        let missing = Set(await Task.detached(priority: .userInitiated) {
            CleanupPath.missing(among: urls, exists: exists, deadline: 30)
        }.value.map(CleanupPath.key))
        let stillThere = snapshot.items.filter { !missing.contains(CleanupPath.key($0.url)) }
        await clean(items: stillThere, from: snapshot.kind)
    }

    /// Clean a single item — called from the per-row trash button.
    func cleanSingleItem(_ item: ScannedItem, for kind: CleanupKind) async {
        await clean(items: [item], from: kind)
    }

    private func clean(items: [ScannedItem], from kind: CleanupKind) async {
        guard !items.isEmpty else { return }
        isCleaning = true
        cleanError = nil
        outcome = nil
        let result = await coordinator.executeCleanup(items: items)

        // Only what actually left the disk leaves the lists — in EVERY category.
        var affected = Set(reconcile(removed: result.gone))
        affected.insert(kind)
        affected.insert(.trash)          // trashed items now live there

        if let first = result.failures.first {
            let more = result.failures.count > 1 ? " (and \(result.failures.count - 1) more)" : ""
            cleanError = "Could not trash \"\(first.name)\": \(first.message)\(more)"
        }
        lastCleanResult = (result.removed.count, result.freed)
        let op = CleanOutcome(moved: result.removed.count, failed: result.failures.count, freed: result.freed,
                              firstError: result.failures.first.map { "\($0.name) — \($0.message)" })
        outcome = op.isEmpty ? nil : op

        await rescan(kinds: affected)    // exact sizes; failures stay listed
        isCleaning = false

        // F-037: Celebrate when > 1 GB freed
        if result.freed > 1_073_741_824 {
            CelebrationManager.shared.trigger(.spaceRecovered)
        }
    }

    func category(for kind: CleanupKind) -> CleanupCategory? {
        categories.first { $0.kind == kind }
    }

    func categoryIndex(for kind: CleanupKind) -> Int? {
        categories.firstIndex(where: { $0.kind == kind })
    }
}

// MARK: - Left Panel

struct CleanupSidebar: View {
    @Binding var selectedCategory: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel
    @ObservedObject var browserViewModel: BrowserCleanerViewModel

    private var combinedTotalBytes: Int64 { viewModel.totalBytes + browserViewModel.totalBytes }
    private var combinedTotalFormatted: String {
        ByteCountFormatter.string(fromByteCount: combinedTotalBytes, countStyle: .file)
    }
    private var isScanningAny: Bool { viewModel.isScanning || browserViewModel.isLoading }

    private func rescan() {
        viewModel.rescan()
        Task { await browserViewModel.loadAll() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header + Total
            VStack(spacing: 12) {
                HStack {
                    Text("Cleanup")
                        .font(HaloFont.display(22, weight: .bold))
                        .foregroundColor(.haloText)
                    Spacer()
                    if isScanningAny {
                        ProgressView().scaleEffect(0.6).tint(.haloAccent)
                    }
                    Button { rescan() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.haloText2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isScanningAny || viewModel.isCleaning)
                    .help("Rescan all categories (⌘R)")
                    .accessibilityIdentifier("cleanup.rescan.button")
                }

                VStack(spacing: 3) {
                    Text(isScanningAny ? "Scanning…" : combinedTotalFormatted)
                        .font(HaloFont.display(30, weight: .heavy))
                        .foregroundColor(.haloAccent)
                        .animation(.easeOut, value: combinedTotalFormatted)
                    Text("total removable")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    if let scanned = viewModel.lastScanned, !isScanningAny {
                        Text("Last scanned \(scanned.formatted(date: .omitted, time: .shortened))")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [Color.haloAccent.opacity(0.1), Color.haloAccent2.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloAccent.opacity(0.2), lineWidth: 1))
            }
            .padding(16)

            Divider().background(Color.haloBorder)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(CleanupKind.allCases) { kind in
                        if kind == .browsers {
                            BrowserCleanupCategoryRow(
                                browserViewModel: browserViewModel,
                                isSelected: selectedCategory == kind
                            ) { selectedCategory = kind }
                        } else {
                            let cat = viewModel.category(for: kind)
                            CleanupCategoryRow(
                                kind: kind,
                                category: cat,
                                isSelected: selectedCategory == kind
                            ) { selectedCategory = kind }
                        }
                    }
                }
                .padding(.vertical, 8)

                // P3-07: Disk Health at bottom of cleanup sidebar
                Divider().background(Color.haloBorder)
                DiskHealthSection()
                    .padding(12)
            }
        }
    }
}

struct CleanupCategoryRow: View {
    let kind: CleanupKind
    let category: CleanupCategory?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.rawValue)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(isSelected ? .haloText : .haloText2)
                    if let cat = category, !cat.isScanning {
                        Text(cat.allFormatted)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    } else {
                        Text("Scanning…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .overlay(
                Rectangle()
                    .fill(isSelected ? Color.haloAccent : Color.clear)
                    .frame(width: 3)
                , alignment: .leading
            )
            // Without an explicit hit-testing shape, taps over the transparent
            // Spacer/background area pass through instead of selecting the row.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Panel

struct CleanupFileList: View {
    let category: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel
    @State private var showCleanAllConfirm = false
    /// Frozen when the Clean-All button is tapped; the dialog and its action both use this,
    /// never the live list, so a rescan while the dialog is open cannot widen what is trashed.
    @State private var pendingCleanAll: CleanAllSnapshot?
    @State private var showErrorAlert = false

    private var currentCategory: CleanupCategory? {
        viewModel.category(for: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(HaloFont.display(15, weight: .semibold))
                        .foregroundColor(.haloText)
                    if let cat = currentCategory, !cat.items.isEmpty {
                        Text("\(cat.items.count) item\(cat.items.count == 1 ? "" : "s") · \(cat.allFormatted)")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }
                }
                Spacer()
                if let cat = currentCategory, !cat.items.isEmpty {
                    // Clean All button — trashes every item in this category
                    Button {
                        Task {
                            // The existence checks run off the main actor (H-02), so the sheet
                            // opens a beat after the click rather than freezing the window.
                            pendingCleanAll = await viewModel.beginCleanAll(for: category)
                            showCleanAllConfirm = pendingCleanAll != nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isCleaning {
                                ProgressView().scaleEffect(0.6).tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text("Clean All (\(cat.allFormatted))")
                                .font(HaloFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.haloRed.opacity(viewModel.isCleaning ? 0.5 : 1))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isCleaning)
                    .accessibilityIdentifier("cleanup.cleanAll.button")
                }
            }
            .confirmationDialog(
                pendingCleanAll.map { "Move all \($0.items.count) items (\($0.formatted)) to Trash?" } ?? "Move to Trash?",
                isPresented: $showCleanAllConfirm,
                titleVisibility: .visible,
                presenting: pendingCleanAll
            ) { snapshot in
                Button("Move to Trash", role: .destructive) {
                    Task { await viewModel.cleanAll(confirmed: snapshot) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Per-operation result banner (H-03): one banner for the last operation — success,
            // partial failure ("Moved 2, 1 failed: …") or total failure. Cleared on category
            // switch and on the next full rescan.
            if let outcome = viewModel.outcome {
                let tint: Color = outcome.hasFailures ? .haloAmber : .haloGreen
                HStack(spacing: 8) {
                    Image(systemName: outcome.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(tint)
                    Text(outcome.message)
                        .font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(2)
                    Spacer()
                    Button { viewModel.clearOutcome() } label: {
                        Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.haloText2)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(tint.opacity(0.08))
                .overlay(Rectangle().fill(tint).frame(height: 1), alignment: .bottom)
                .accessibilityIdentifier("cleanup.result.banner")
            }

            Divider().background(Color.haloBorder)

            if viewModel.isScanning {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2).tint(.haloAccent)
                    Text("Scanning \(category.rawValue)…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let cat = currentCategory, !cat.items.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(cat.items) { item in
                            FileItemRow(
                                item: item,
                                category: category,
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("fileListView")
            } else {
                EmptyCleanupState(category: category)
            }
        }
    }
}

// MARK: - File Item Row

struct FileItemRow: View {
    let item: ScannedItem
    let category: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel
    @State private var showTrashConfirm = false

    /// Show a folder icon for directory-level items (DerivedData project folders,
    /// Trash directories) and the item's file kind icon otherwise.
    private var itemIcon: String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: item.url.path, isDirectory: &isDir)
        if isDir.boolValue { return "folder.fill" }
        return item.kind.icon
    }

    var body: some View {
        HStack(spacing: 10) {
            // File/folder type icon
            Image(systemName: itemIcon)
                .font(.system(size: 14))
                .foregroundColor(.haloText2)
                .frame(width: 20)

            // Path + name
            VStack(alignment: .leading, spacing: 2) {
                Text(item.parentDisplayPath + "/")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                    .lineLimit(1)
                Text(item.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
            }

            Spacer()

            // Size
            Text(item.sizeFormatted)
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloText2)
                .frame(width: 72, alignment: .trailing)

            // Modified date
            if let modified = item.modifiedDate {
                Text(RelativeDateTimeFormatter().localizedString(for: modified, relativeTo: Date()))
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
                    .frame(width: 80, alignment: .trailing)
            }

            // Per-item trash button (red)
            Button {
                showTrashConfirm = true
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.haloRed)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCleaning)
            .confirmationDialog(
                "Move \"\(item.name)\" (\(item.sizeFormatted)) to Trash?",
                isPresented: $showTrashConfirm,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await viewModel.cleanSingleItem(item, for: category) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
        .opacity(viewModel.isCleaning ? 0.6 : 1)
    }
}

// MARK: - Empty State

struct EmptyCleanupState: View {
    let category: CleanupKind

    private var message: (icon: String, title: String, subtitle: String) {
        switch category {
        case .trash:
            return ("trash", "Trash is empty", "Your system Trash contains no items.")
        default:
            return ("checkmark.circle.fill", "\(category.rawValue) is clean!",
                    "No files found that need cleanup.")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: message.icon)
                .font(.system(size: 40))
                .foregroundColor(.haloGreen)
            Text(message.title)
                .font(HaloFont.display(15, weight: .semibold))
                .foregroundColor(.haloText)
            Text(message.subtitle)
                .font(HaloFont.body(13))
                .foregroundColor(.haloText2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
