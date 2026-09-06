import SwiftUI
import AppKit

// MARK: - iCloud Drive Analyzer (F-030)
//
// Honest scope: a LOCAL analyzer of `~/Library/Mobile Documents/`. There is no
// donut chart by category, no account-wide quota bar, and no "old device
// backups" detector — those all require iCloud account data no public API
// exposes to third-party apps. See docs/FEATURE_ROADMAP.md's F-030 "As
// actually built" section for the full explanation.

@MainActor
final class ICloudDriveViewModel: ObservableObject {
    @Published var containers: [ICloudContainer] = []
    @Published var selectedContainer: ICloudContainer?
    @Published var currentItems: [ICloudDriveItem] = []
    @Published var breadcrumb: [(name: String, url: URL)] = []
    @Published var isScanning = false
    @Published var isAvailable = true
    @Published var trashErrorMessage: String?

    private let scanner = ICloudDriveScanner()
    private var scanTask: Task<Void, Never>?

    var totalBytes: Int64 { currentItems.reduce(0) { $0 + $1.sizeBytes } }
    var totalBytesFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    var evictedCount: Int { currentItems.filter { $0.syncStatus == .evicted }.count }

    func load() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let available = await self.scanner.isICloudDriveAvailable()
            let found = await self.scanner.availableContainers()
            await MainActor.run {
                self.isAvailable = available
                self.containers = found
            }
            guard let first = found.first else { return }
            await self.select(container: first)
        }
    }

    func select(container: ICloudContainer) async {
        selectedContainer = container
        breadcrumb = [(container.displayName, container.url)]
        await scan(url: container.url)
    }

    func drillInto(_ item: ICloudDriveItem) {
        guard item.isDirectory else { return }
        breadcrumb.append((item.name, item.url))
        Task { await scan(url: item.url) }
    }

    func navigateTo(depth: Int) {
        guard depth < breadcrumb.count - 1 else { return }
        let target = breadcrumb[depth]
        breadcrumb = Array(breadcrumb.prefix(depth + 1))
        Task { await scan(url: target.url) }
    }

    private func scan(url: URL) async {
        isScanning = true
        let items = await scanner.scanDirectory(url)
        guard !Task.isCancelled else { return }
        currentItems = items
        isScanning = false
    }

    func revealInFinder(_ item: ICloudDriveItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Called only after the confirmation dialog in `ICloudDriveView` — never
    /// directly from a row tap (TC-SAFE-02, mandatory-confirmation rule).
    func trash(_ item: ICloudDriveItem) {
        Task {
            let (success, message) = await scanner.trash(item)
            await MainActor.run {
                if success {
                    self.currentItems.removeAll { $0.id == item.id }
                } else {
                    self.trashErrorMessage = message
                }
            }
        }
    }
}

struct ICloudDriveView: View {
    @StateObject private var viewModel = ICloudDriveViewModel()
    @State private var pendingDelete: ICloudDriveItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)

            if !viewModel.isAvailable {
                unavailableState
            } else if viewModel.containers.isEmpty && !viewModel.isScanning {
                emptyState
            } else {
                containerPicker
                breadcrumbBar
                Divider().background(Color.haloBorder)
                content
            }
        }
        .onAppear { viewModel.load() }
        // Mandatory confirmation before trashing (TC-SAFE-02).
        .confirmationDialog(
            pendingDelete.map { "Move \"\($0.name)\" (\($0.sizeFormatted)) to Trash?" } ?? "Move to Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = pendingDelete { viewModel.trash(item) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This also removes the file from iCloud Drive, on every device it's synced to — the same as trashing it in Finder.")
        }
        .alert("Could not move to Trash", isPresented: Binding(
            get: { viewModel.trashErrorMessage != nil },
            set: { if !$0 { viewModel.trashErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.trashErrorMessage = nil }
        } message: {
            Text(viewModel.trashErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Drive Analyzer")
                    .font(HaloFont.display(18, weight: .bold))
                    .foregroundColor(.haloText)
                if !viewModel.currentItems.isEmpty {
                    Text("\(viewModel.currentItems.count) items · \(viewModel.totalBytesFormatted) shown"
                         + (viewModel.evictedCount > 0 ? " · \(viewModel.evictedCount) iCloud-only" : ""))
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                }
            }
            Spacer()
            HaloGhostButton("Refresh", icon: "arrow.clockwise") {
                if let c = viewModel.selectedContainer {
                    Task { await viewModel.select(container: c) }
                } else {
                    viewModel.load()
                }
            }
            .disabled(viewModel.isScanning)
        }
        .padding(20)
    }

    private var containerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.containers) { container in
                    let isSelected = viewModel.selectedContainer?.id == container.id
                    Button {
                        Task { await viewModel.select(container: container) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: container.isUserDrive ? "icloud.fill" : "shippingbox.fill")
                                .font(.system(size: 11))
                            Text(container.displayName)
                                .font(HaloFont.body(12, weight: isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? Color.haloAccent.opacity(0.18) : Color.haloSurface2)
                        )
                        .overlay(Capsule().stroke(isSelected ? Color.haloAccent : Color.haloBorder, lineWidth: 1))
                        .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.breadcrumb.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.haloText3)
                }
                Button(viewModel.breadcrumb[i].name) { viewModel.navigateTo(depth: i) }
                    .font(HaloFont.body(12, weight: i == viewModel.breadcrumb.count - 1 ? .semibold : .regular))
                    .foregroundColor(i == viewModel.breadcrumb.count - 1 ? .haloText : .haloAccent)
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isScanning {
            Spacer()
            VStack(spacing: 10) {
                ProgressView()
                Text("Analyzing…").font(HaloFont.body(12)).foregroundColor(.haloText2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer()
        } else if viewModel.currentItems.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32)).foregroundColor(.haloGreen)
                Text("This folder is empty")
                    .font(HaloFont.body(14, weight: .medium)).foregroundColor(.haloText)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(viewModel.currentItems) { item in
                        ICloudDriveItemRow(
                            item: item,
                            onTap: { viewModel.drillInto(item) },
                            onReveal: { viewModel.revealInFinder(item) },
                            onTrash: { pendingDelete = item }
                        )
                        .accessibilityIdentifier("files.icloud.row")
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 40)).foregroundColor(.haloText3)
            Text("No iCloud containers found")
                .font(HaloFont.display(14, weight: .semibold)).foregroundColor(.haloText2)
            Text("Sign in to iCloud and enable iCloud Drive in System Settings.")
                .font(HaloFont.body(12)).foregroundColor(.haloText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 40)).foregroundColor(.haloText3)
            Text("iCloud Drive isn't set up on this Mac")
                .font(HaloFont.display(14, weight: .semibold)).foregroundColor(.haloText2)
            Text("Turn on iCloud Drive in System Settings → Apple ID → iCloud, then reopen this tab.")
                .font(HaloFont.body(12)).foregroundColor(.haloText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ICloudDriveItemRow: View {
    let item: ICloudDriveItem
    let onTap: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        // Not a Button (unlike TreemapListRow) — this row also hosts the
        // Reveal/Trash buttons, and nested Buttons don't reliably split hit
        // testing on macOS. Only the leading name/icon area drills in.
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 16))
                    .foregroundColor(item.isDirectory ? .haloAccent : .haloText2)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(.haloText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Image(systemName: item.syncStatus.icon)
                            .font(.system(size: 9))
                        Text(item.syncStatus.label)
                        Text("· \(item.modifiedDateFormatted)")
                    }
                    .font(HaloFont.body(11))
                    .foregroundColor(item.syncStatus.color)
                }
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.haloText3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if item.isDirectory { onTap() } }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.sizeFormatted)
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.haloText)
                // Two figures, because "in iCloud" and "on this Mac" are
                // different numbers and the difference is the whole point of the
                // tab. Only shown when they actually diverge.
                if item.hasEvictedContent {
                    Text("\(item.localSizeFormatted) on this Mac")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
            HaloGhostButton("Reveal", icon: "arrow.up.forward.square") { onReveal() }
                .accessibilityIdentifier("files.icloud.reveal.button")
            HaloGhostButton("Trash", icon: "trash") { onTrash() }
                .accessibilityIdentifier("files.icloud.trash.button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.haloSurface2)
        .cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.haloBorder, lineWidth: 1))
    }
}
