import SwiftUI
import AppKit

struct FilesView: View {
    @State private var activeTab: FilesTab = .spaceLens

    enum FilesTab: String, CaseIterable {
        case spaceLens  = "Space Lens"
        case duplicates = "Duplicates"
        case largeFiles = "Large Files"
        case downloads  = "Downloads"
        case driveSpeed = "Drive Speed"
        case iCloudDrive = "iCloud Drive"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 4) {
                ForEach(FilesTab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    }
                    .accessibilityIdentifier("files.tab.\(tab.rawValue)")
                    .font(HaloFont.body(13, weight: activeTab == tab ? .semibold : .regular))
                    .foregroundColor(activeTab == tab ? .haloText : .haloText2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(activeTab == tab ? Color.haloSurface2 : Color.clear)
                            .overlay(
                                Capsule().stroke(activeTab == tab ? Color.haloBorder2 : Color.clear, lineWidth: 1)
                            )
                    )
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().background(Color.haloBorder)

            // Content
            switch activeTab {
            case .spaceLens:  SpaceLensView()
            case .duplicates: DuplicateFinderView()
            case .largeFiles: LargeFilesView()
            case .downloads:  DownloadsView()
            case .driveSpeed: DriveSpeedView()
            case .iCloudDrive: ICloudDriveView()
            }
        }
        .background(Color.haloSurface)
    }
}

// MARK: - Space Lens

struct SpaceLensView: View {
    @StateObject private var viewModel = SpaceLensViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb
            HStack(spacing: 6) {
                ForEach(viewModel.breadcrumb.indices, id: \.self) { i in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.haloText3) }
                    Button(viewModel.breadcrumb[i]) {
                        viewModel.navigateTo(depth: i)
                    }
                    .font(HaloFont.body(12, weight: i == viewModel.breadcrumb.count - 1 ? .semibold : .regular))
                    .foregroundColor(i == viewModel.breadcrumb.count - 1 ? .haloText : .haloAccent)
                    .buttonStyle(.plain)
                }
                Spacer()
                HaloGhostButton("Choose Folder", icon: "folder") {
                    viewModel.chooseFolderAndScan()
                }
                .disabled(viewModel.isScanning)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            // Treemap / scanning / empty prompt
            GeometryReader { geo in
                Group {
                    if viewModel.isScanning {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Analyzing…").font(HaloFont.body(12)).foregroundColor(.haloText2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.currentNodes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.pie")
                                .font(.system(size: 30)).foregroundColor(.haloText3)
                            Text("Choose a folder to analyze storage usage")
                                .font(HaloFont.body(12)).foregroundColor(.haloText2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TreemapView(nodes: viewModel.currentNodes, size: geo.size) { node in
                            viewModel.drillInto(node)
                        }
                    }
                }
                .padding(16)
            }
            .frame(height: 300)

            // Legend
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(SpaceLensViewModel.FileCategory.allCases, id: \.self) { cat in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(cat.color).frame(width: 10, height: 10)
                            Text(cat.rawValue).font(HaloFont.body(11)).foregroundColor(.haloText2)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider().background(Color.haloBorder)

            // Top items list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.currentNodes.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(10), id: \.name) { node in
                        TreemapListRow(node: node) { viewModel.drillInto(node) }
                    }
                }
                .padding(16)
            }
        }
    }
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    @Published var currentNodes: [TreeNode] = []
    @Published var breadcrumb: [String] = []
    @Published var navigationStack: [[TreeNode]] = []
    @Published var isScanning = false

    struct TreeNode: Identifiable {
        let id = UUID()
        let name: String
        let sizeBytes: Int64
        let category: FileCategory
        var children: [TreeNode] = []

        var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    }

    enum FileCategory: String, CaseIterable {
        case applications = "Applications"
        case developer = "Developer"
        case media = "Media"
        case documents = "Documents"
        case downloads = "Downloads"
        case other = "Other"

        var color: Color {
            switch self {
            case .applications: return Color(hex: "#1e4080")
            case .developer: return Color(hex: "#9a3412")
            case .media: return Color(hex: "#3b0f8e")
            case .documents: return Color(hex: "#065f46")
            case .downloads: return Color(hex: "#3730a3")
            case .other: return Color(hex: "#374151")
            }
        }
    }

    func drillInto(_ node: TreeNode) {
        guard !node.children.isEmpty else { return }
        navigationStack.append(currentNodes)
        breadcrumb.append(node.name)
        currentNodes = node.children
    }

    func navigateTo(depth: Int) {
        guard depth < breadcrumb.count - 1 else { return }
        breadcrumb = Array(breadcrumb.prefix(depth + 1))
        let stepsBack = (navigationStack.count) - depth
        if stepsBack > 0 {
            currentNodes = navigationStack[depth]
            navigationStack = Array(navigationStack.prefix(depth))
        }
    }

    // MARK: - Real scan (replaces the former hardcoded sample data)

    /// Prompt for a folder, then analyze its top-level contents by real size.
    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a folder to analyze storage usage"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url: url)
    }

    func scan(url: URL) {
        isScanning = true
        currentNodes = []
        navigationStack = []
        breadcrumb = [url.lastPathComponent]
        Task { [weak self] in
            let nodes = Self.scanTopLevel(of: url)
            await MainActor.run {
                self?.currentNodes = nodes
                self?.isScanning = false
            }
        }
    }

    /// Top-level children of `dir` with real byte sizes (directories summed,
    /// bounded so a huge tree can't hang the scan).
    private static func scanTopLevel(of dir: URL) -> [TreeNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var nodes: [TreeNode] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isDir
                ? directorySize(entry)
                : Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 0 else { continue }
            nodes.append(TreeNode(name: entry.lastPathComponent, sizeBytes: size,
                                  category: category(for: entry, isDir: isDir)))
        }
        return nodes.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func directorySize(_ url: URL, cap: Int = 20_000) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0, count = 0
        while let u = en.nextObject() as? URL {
            if let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               vals.isRegularFile == true, let s = vals.fileSize {
                total += Int64(s); count += 1
                if count >= cap { break }
            }
        }
        return total
    }

    private static func category(for url: URL, isDir: Bool) -> FileCategory {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "app" || name == "applications" { return .applications }
        if ["developer", "node_modules", "xcode", "derived_data"].contains(name)
            || ["swift", "js", "ts", "py", "o", "a", "framework"].contains(ext) { return .developer }
        if ["movies", "music", "pictures"].contains(name) || name.contains("photos library")
            || ["mov", "mp4", "m4v", "mp3", "wav", "aac", "m4a", "jpg", "jpeg", "png", "heic", "gif"].contains(ext) { return .media }
        if name == "documents" || ["pdf", "doc", "docx", "pages", "txt", "key", "numbers", "xlsx", "csv"].contains(ext) { return .documents }
        if name == "downloads" { return .downloads }
        return .other
    }
}

// Squarified Treemap Renderer
struct TreemapView: View {
    let nodes: [SpaceLensViewModel.TreeNode]
    let size: CGSize
    let onTap: (SpaceLensViewModel.TreeNode) -> Void

    var body: some View {
        let total = nodes.reduce(0) { $0 + $1.sizeBytes }
        Canvas { context, canvasSize in
            guard total > 0 else { return }
            let rects = squarify(nodes: nodes, total: total, rect: CGRect(origin: .zero, size: canvasSize))
            for (node, rect) in zip(nodes, rects) {
                let path = Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 6)
                context.fill(path, with: .color(node.category.color))
                if rect.width > 60 && rect.height > 30 {
                    context.draw(Text(node.name).font(HaloFont.body(10, weight: .semibold)).foregroundColor(.white),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
        }
        .background(Color.haloSurface2)
        .cornerRadius(12)
        .overlay(
            // Tap detection layer
            GeometryReader { geo in
                let total = nodes.reduce(0) { $0 + $1.sizeBytes }
                let rects = squarify(nodes: nodes, total: total,
                                     rect: CGRect(origin: .zero, size: geo.size))
                ForEach(nodes.indices, id: \.self) { i in
                    if i < rects.count {
                        Color.clear
                            .frame(width: rects[i].width, height: rects[i].height)
                            .position(x: rects[i].midX, y: rects[i].midY)
                            .onTapGesture { onTap(nodes[i]) }
                    }
                }
            }
        )
    }

    // Simplified proportional layout (production uses full Squarified algorithm)
    func squarify(nodes: [SpaceLensViewModel.TreeNode], total: Int64, rect: CGRect) -> [CGRect] {
        guard total > 0 else { return [] }
        var rects: [CGRect] = []
        let x = rect.minX
        let y = rect.minY
        let width = rect.width
        let height = rect.height
        // Two-row layout based on size ratios
        var row1: [SpaceLensViewModel.TreeNode] = []
        var row2: [SpaceLensViewModel.TreeNode] = []
        for (i, node) in nodes.enumerated() {
            if i < nodes.count / 2 + 1 { row1.append(node) } else { row2.append(node) }
        }
        let row1Total = row1.reduce(0) { $0 + $1.sizeBytes }
        let row1Height = total > 0 ? height * CGFloat(row1Total) / CGFloat(total) : height / 2
        // Row 1
        var rx = x
        for node in row1 {
            let ratio = row1Total > 0 ? CGFloat(node.sizeBytes) / CGFloat(row1Total) : 1 / CGFloat(row1.count)
            let w = width * ratio
            rects.append(CGRect(x: rx, y: y, width: w, height: row1Height))
            rx += w
        }
        // Row 2
        let row2Total = nodes.reduce(0) { $0 + $1.sizeBytes } - row1Total
        rx = x
        for node in row2 {
            let ratio = row2Total > 0 ? CGFloat(node.sizeBytes) / CGFloat(row2Total) : 1 / CGFloat(row2.count)
            let w = width * ratio
            rects.append(CGRect(x: rx, y: y + row1Height, width: w, height: height - row1Height))
            rx += w
        }
        return rects
    }
}

struct TreemapListRow: View {
    let node: SpaceLensViewModel.TreeNode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(node.category.color)
                    .frame(width: 12, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(.haloText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.category.rawValue)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                Spacer(minLength: 8)
                Text(node.sizeFormatted)
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.haloText)
                    .frame(minWidth: 64, alignment: .trailing)
                if !node.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.haloSurface2)
            .cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.haloBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Duplicate Finder

struct DuplicateFinderView: View {
    @StateObject private var viewModel = DuplicateFinderViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Finder")
                        .font(HaloFont.display(18, weight: .bold))
                        .foregroundColor(.haloText)
                    if !viewModel.groups.isEmpty {
                        Text("\(viewModel.groups.count) groups · \(ByteCountFormatter.string(fromByteCount: viewModel.totalWastedBytes, countStyle: .file)) wasted")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                    }
                }
                Spacer()
                HaloGhostButton("Choose Folder", icon: "folder") { viewModel.chooseFolderAndScan() }
                    .disabled(viewModel.isScanning)
                HaloPrimaryButton(viewModel.isScanning ? "Scanning…" : "Scan Home",
                                  icon: "doc.on.doc", isLoading: viewModel.isScanning) {
                    viewModel.scanDefaultLocations()
                }
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            if viewModel.groups.isEmpty && !viewModel.isScanning {
                DuplicateEmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.groups) { group in
                            DuplicateGroupCard(viewModel: viewModel, group: group)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

@MainActor
final class DuplicateFinderViewModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var scanError: String?
    @Published var scannedLocation: String?

    private let detector = DuplicateDetector()
    private var scanTask: Task<Void, Never>?

    var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    /// Scan the curated set of user folders where duplicates accumulate.
    func scanDefaultLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ["Downloads", "Desktop", "Documents", "Pictures", "Movies"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        start(scanning: dirs, label: "Downloads, Desktop, Documents, Pictures, Movies")
    }

    /// Prompt the user for a folder (powerbox-granted, even when sandboxed),
    /// then scan it recursively.
    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for duplicate files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(scanning: [url], label: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }

    private func start(scanning dirs: [URL], label: String) {
        scanTask?.cancel()
        isScanning = true
        progress = 0
        scanError = nil
        groups = []
        scannedLocation = label
        let detector = self.detector
        scanTask = Task { [weak self] in
            let files = Self.enumerateFiles(in: dirs)
            do {
                let found = try await detector.detect(in: files) { p in
                    Task { @MainActor in self?.progress = p }
                }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.groups = found
                    self.isScanning = false
                }
            } catch is CancellationError {
                await MainActor.run { self?.isScanning = false }
            } catch {
                await MainActor.run {
                    self?.scanError = error.localizedDescription
                    self?.isScanning = false
                }
            }
        }
    }

    /// Enumerate regular files under the given directories, bounded so an
    /// accidental huge scan can't run away.
    private static func enumerateFiles(in dirs: [URL], cap: Int = 50_000) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for dir in dirs {
            guard fm.fileExists(atPath: dir.path),
                  let en = fm.enumerator(at: dir,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            // `nextObject()` loop (not for-in) — NSEnumerator's iterator is
            // unavailable from async contexts and `start(scanning:)` runs this
            // inside a Task.
            while let url = en.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    out.append(url)
                    if out.count >= cap { return out }
                }
            }
        }
        return out
    }

    /// Toggle whether a specific copy is marked for deletion.
    func toggleMark(groupID: DuplicateGroup.ID, itemID: DuplicateItem.ID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let ii = groups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        groups[gi].items[ii].isMarkedForDeletion.toggle()
    }

    /// Trash every marked copy in a group (mandatory: only ever `trashItem`).
    /// Called only after the confirmation in `DuplicateGroupCard`.
    func deleteMarked(in groupID: DuplicateGroup.ID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for item in groups[gi].items where item.isMarkedForDeletion {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        groups[gi].items.removeAll { $0.isMarkedForDeletion }
        // A group with ≤1 copy left is no longer a duplicate set.
        if groups[gi].items.count <= 1 { groups.remove(at: gi) }
    }
}

struct DuplicateGroupCard: View {
    @ObservedObject var viewModel: DuplicateFinderViewModel
    let group: DuplicateGroup
    @State private var showDeleteConfirm = false

    private var markedCount: Int { group.items.filter(\.isMarkedForDeletion).count }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HaloBadge(text: "\(group.items.count) copies", color: .haloAmber)
                    Text(group.wastedFormatted + " wasted")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Spacer()
                    HaloGhostButton("Delete marked\(markedCount > 0 ? " (\(markedCount))" : "")") {
                        showDeleteConfirm = true            // ask first
                    }
                    .disabled(markedCount == 0)
                    .accessibilityIdentifier("files.duplicates.deleteMarked.button")
                }
                ForEach(group.items) { item in
                    // Tap a copy to toggle whether it's marked for deletion.
                    Button {
                        viewModel.toggleMark(groupID: group.id, itemID: item.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.isMarkedForDeletion ? "trash.fill" : "doc.fill")
                                .font(.system(size: 13))
                                .foregroundColor(item.isMarkedForDeletion ? .haloRed : .haloGreen)
                            Text(item.displayPath)
                                .font(HaloFont.mono(11))
                                .foregroundColor(.haloText)
                                .lineLimit(1)
                            Spacer()
                            Text(item.sizeFormatted)
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(item.isMarkedForDeletion ? Color.haloRed.opacity(0.05) : Color.haloSurface)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        // Mandatory confirmation before trashing marked copies (TC-SAFE-02).
        .confirmationDialog(
            "Move \(markedCount) marked \(markedCount == 1 ? "copy" : "copies") to Trash?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                viewModel.deleteMarked(in: group.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct DuplicateEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundColor(.haloText3)
            Text("No duplicates scanned yet")
                .font(HaloFont.display(14, weight: .semibold))
                .foregroundColor(.haloText2)
            Text("Tap Scan Home to find duplicate files")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large Files

// MARK: - Large Files ViewModel

@MainActor
final class LargeFilesViewModel: ObservableObject {
    struct LargeFile: Identifiable {
        let id = UUID()
        let url: URL
        let size: Int64
        var name: String { url.lastPathComponent }
        var displayPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return url.deletingLastPathComponent().path
                .replacingOccurrences(of: home, with: "~")
        }
        var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        var ext: String { url.pathExtension.lowercased() }
    }

    @Published var files: [LargeFile] = []
    @Published var isScanning = false
    @Published var trashErrorMessage: String? = nil

    private let minSizeBytes: Int64 = 500_000_000 // 500 MB

    func scan() async {
        isScanning = true
        files = []
        let fm = FileManager.default
        var scanDirs: [URL] = []
        for kind in [FileManager.SearchPathDirectory.downloadsDirectory,
                     .moviesDirectory, .documentDirectory, .desktopDirectory] {
            if let url = fm.urls(for: kind, in: .userDomainMask).first {
                scanDirs.append(url)
            }
        }
        var found: [LargeFile] = []
        for dir in scanDirs {
            guard let enumerator = fm.enumerator(
                at: dir.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            // `nextObject()` loop (not for-in): NSEnumerator's iterator is
            // unavailable from async contexts (this `scan()` is async).
            while let url = enumerator.nextObject() as? URL {
                guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      vals.isRegularFile == true,
                      let size = vals.fileSize,
                      Int64(size) >= minSizeBytes else { continue }
                found.append(LargeFile(url: url, size: Int64(size)))
            }
        }
        found.sort { $0.size > $1.size }
        files = found
        isScanning = false
    }

    func trash(_ file: LargeFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            files.removeAll { $0.id == file.id }
        } catch {
            trashErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Large Files View

struct LargeFilesView: View {
    @StateObject private var viewModel = LargeFilesViewModel()
    // Pending delete — set when the user taps a row's trash button; the actual
    // trashItem only runs after the confirmation below (TC-SAFE-02).
    @State private var pendingDelete: LargeFilesViewModel.LargeFile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Large Files")
                    .font(HaloFont.display(18, weight: .bold))
                    .foregroundColor(.haloText)
                HaloBadge(text: "Files > 500 MB", color: .haloAccent)
                Spacer()
                HaloGhostButton("Re-scan", icon: "arrow.clockwise") {
                    Task { await viewModel.scan() }
                }
                .disabled(viewModel.isScanning)
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            if viewModel.isScanning {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning for large files…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                Spacer()
            } else if viewModel.files.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.haloGreen)
                    Text("No large files found")
                        .font(HaloFont.body(14, weight: .medium))
                        .foregroundColor(.haloText)
                    Text("Click Re-scan to search Downloads, Movies, Documents and Desktop.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(viewModel.files) { file in
                            LargeFileRow(file: file) {
                                pendingDelete = file       // ask first
                            }
                            .accessibilityIdentifier("files.largeFiles.row")
                        }
                    }
                    .padding(16)
                }
            }
        }
        // Mandatory confirmation before trashing (TC-SAFE-02).
        .confirmationDialog(
            pendingDelete.map { "Move \"\($0.name)\" (\($0.sizeFormatted)) to Trash?" } ?? "Move to Trash?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let file = pendingDelete { viewModel.trash(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .alert("Could not move to Trash", isPresented: Binding(
            get: { viewModel.trashErrorMessage != nil },
            set: { if !$0 { viewModel.trashErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.trashErrorMessage = nil }
        } message: {
            Text(viewModel.trashErrorMessage ?? "")
        }
        .onAppear {
            Task { await viewModel.scan() }
        }
    }
}

struct LargeFileRow: View {
    let file: LargeFilesViewModel.LargeFile
    let onTrash: () -> Void

    var icon: String {
        switch file.ext {
        case "dmg": return "externaldrive"
        case "mov", "mp4", "m4v": return "film"
        case "logicx": return "music.note"
        case "fcpbundle": return "video"
        case "xip", "zip", "gz", "tar": return "doc.zipper"
        default: return "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.haloAmber)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(file.displayPath)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(file.sizeFormatted)
                .font(HaloFont.body(13, weight: .semibold))
                .foregroundColor(.haloText)
            HaloGhostButton("Move to Trash") { onTrash() }
                .accessibilityIdentifier("files.largeFiles.trash.button")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }
}
