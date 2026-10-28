import SwiftUI
import AppKit

// MARK: - F-054 Build Artifacts — "Build Artifacts" pane of the Cleanup module
//
// Lists regenerable build output found across the user's projects (and the Xcode-global folders),
// largest first, each with its regeneration hint. Removal always goes through a review sheet.
// Default action: Move to Trash (recoverable; frees no space until the Trash is emptied — said so
// on the sheet and in the banner). A second, separate button "Move to Trash and empty those items"
// exists only for Safe + git-verified items and only in a build where it is permitted
// (`BuildArtifactRemover.permanentRemovalAvailable`), behind its own confirmation.

// MARK: Sidebar row

struct BuildArtifactsCategoryRow: View {
    @ObservedObject var viewModel: BuildArtifactsViewModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: CleanupKind.buildArtifacts.icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CleanupKind.buildArtifacts.rawValue)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(isSelected ? .haloText : .haloText2)
                    Text(viewModel.isScanning ? "Scanning…" : viewModel.totalFormatted)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .overlay(Rectangle().fill(isSelected ? Color.haloAccent : Color.clear).frame(width: 3), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cleanup.category.buildArtifacts.button")
    }
}

// MARK: Pane

struct BuildArtifactsPane: View {
    @ObservedObject var viewModel: BuildArtifactsViewModel
    /// Jump to the Trash category (D4: trashed folders free no space until it is emptied).
    var openTrash: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            if let b = viewModel.banner { bannerView(b) }
            if !viewModel.gitGateAvailable { gitNotice }
            controls
            Divider().background(Color.haloBorder)
            content
        }
        .background(Color.haloSurface)
        .sheet(item: $viewModel.review) { snap in
            BuildArtifactsReviewSheet(viewModel: viewModel, snapshot: snap)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Build Artifacts")
                    .font(HaloFont.display(15, weight: .semibold)).foregroundColor(.haloText)
                Text(subtitle).font(HaloFont.body(11)).foregroundColor(.haloText2)
                if let t = viewModel.lastScanned, !viewModel.isScanning {
                    Text("Last scanned \(t.formatted(date: .omitted, time: .shortened))")
                        .font(HaloFont.body(10)).foregroundColor(.haloText3)
                }
            }
            Spacer()
            if viewModel.isScanning {
                ProgressView().scaleEffect(0.6).tint(.haloAccent)
                Button("Stop") { viewModel.cancelScan() }
                    .buttonStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText2)
            } else {
                Button { chooseFolders() } label: {
                    Label("Choose folders…", systemImage: "folder.badge.plus").font(HaloFont.body(12))
                }
                .buttonStyle(.plain).foregroundColor(.haloAccent)
                .accessibilityIdentifier("buildArtifacts.chooseFolders.button")
                Button { viewModel.rescan() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(.haloText2)
                }
                .buttonStyle(.plain).padding(.leading, 8)
                .accessibilityIdentifier("buildArtifacts.rescan.button")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var subtitle: String {
        if viewModel.isScanning { return "Scanning… \(viewModel.foldersScanned) folders" }
        let n = viewModel.items.count
        var s = "\(n) item\(n == 1 ? "" : "s") · \(viewModel.totalFormatted) regenerable"
        if let sum = viewModel.summary {
            s += " · \(sum.foldersScanned) folders scanned"
            if sum.skippedTrackedByGit > 0 { s += " · \(sum.skippedTrackedByGit) skipped: tracked by git" }
            if sum.skippedNotGitIgnored > 0 { s += " · \(sum.skippedNotGitIgnored) skipped: not git-ignored" }
            if sum.stoppedEarly { s += " · stopped early (time budget) — results may be incomplete" }
            if sum.catalogMissing { s += " · catalogue missing" }
        }
        return s
    }

    private func bannerView(_ b: BuildArtifactsViewModel.Banner) -> some View {
        let color: Color = b.isError ? .haloAmber : .haloGreen
        return HStack(spacing: 8) {
            Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundColor(color)
            Text(b.text).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(3)
            Spacer()
            if !b.isError || b.text.contains("Moved") {
                Button("Open Trash", action: openTrash)
                    .buttonStyle(.plain).font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloAccent)
            }
            Button { viewModel.banner = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.haloText2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(color.opacity(0.08))
        .overlay(Rectangle().fill(color).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("buildArtifacts.banner")
    }

    /// Spec R5: say plainly that the git gate cannot run, rather than silently omitting anything.
    private var gitNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundColor(.haloAmber)
            Text("Git can't run in this build, so folders inside git projects are shown as Unverified (Move to Trash only), and folders that need a git-ignore check (dist, Pods, .next) are not offered.")
                .font(HaloFont.body(11)).foregroundColor(.haloText2)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haloAmber.opacity(0.06))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $viewModel.grouping) {
                    ForEach(BuildArtifactsViewModel.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 330).labelsHidden()
                Menu {
                    Button("All toolchains") { viewModel.toolchainFilter = nil }
                    ForEach(viewModel.toolchains, id: \.id) { t in
                        Button(t.name) { viewModel.toolchainFilter = t.id }
                    }
                } label: {
                    Text(viewModel.toolchains.first { $0.id == viewModel.toolchainFilter }?.name ?? "All toolchains")
                        .font(HaloFont.body(12))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Toggle("Stale only (> \(viewModel.roots.staleDays) d)", isOn: $viewModel.staleOnly)
                    .toggleStyle(.checkbox).font(HaloFont.body(12))
                Spacer()
            }
            HStack(spacing: 12) {
                Button("Select stale (> \(viewModel.roots.staleDays) d)") { viewModel.selectStale() }
                Button("Select all Safe") { viewModel.selectAllSafe() }
                Button("Select none") { viewModel.selectNone() }
                Spacer()
                if !viewModel.selection.isEmpty {
                    Text("\(viewModel.selection.count) selected · \(ByteCountFormatter.string(fromByteCount: viewModel.selectedBytes, countStyle: .file))")
                        .font(HaloFont.body(12, weight: .medium)).foregroundColor(.haloText2)
                }
                Button { viewModel.beginReview() } label: {
                    HStack(spacing: 6) {
                        if viewModel.isRemoving { ProgressView().scaleEffect(0.6).tint(.white) }
                        else { Image(systemName: "trash.fill").font(.system(size: 12, weight: .semibold)) }
                        Text("Clean selected…").font(HaloFont.body(13, weight: .semibold))
                    }
                    .foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.haloRed.opacity(viewModel.selection.isEmpty || viewModel.isRemoving ? 0.4 : 1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selection.isEmpty || viewModel.isRemoving || viewModel.isScanning)
                .accessibilityIdentifier("buildArtifacts.clean.button")
            }
            .buttonStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloAccent)
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if viewModel.needsRoots {
            emptyState(icon: "folder.badge.plus", title: "Choose your project folders",
                       text: "This build can only look in folders you grant it. Pick the folder(s) that hold your projects.",
                       button: ("Choose folders…", chooseFolders))
        } else if viewModel.isScanning && viewModel.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.2).tint(.haloAccent)
                Text("Scanning \(viewModel.scannedRoots.count) folder\(viewModel.scannedRoots.count == 1 ? "" : "s")… \(viewModel.foldersScanned) so far")
                    .font(HaloFont.body(13)).foregroundColor(.haloText2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.visibleItems.isEmpty {
            emptyState(icon: "checkmark.circle.fill", title: "Nothing found",
                       text: viewModel.summary.map { "\($0.foldersScanned) folders scanned in \(viewModel.scannedRoots.count) root(s)." }
                           ?? "Press rescan to look for build folders.", button: nil)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                    ForEach(viewModel.sections, id: \.title) { section in
                        if !section.title.isEmpty {
                            Text("\(section.title) · \(ByteCountFormatter.string(fromByteCount: section.items.reduce(0) { $0 + $1.size }, countStyle: .file))")
                                .font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloText3)
                                .padding(.top, 8)
                        }
                        ForEach(section.items) { item in
                            BuildArtifactRow(item: item, isSelected: viewModel.selection.contains(item.id),
                                             onToggle: { viewModel.toggle(item) },
                                             onNeverOffer: { viewModel.neverOffer(item) })
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func emptyState(icon: String, title: String, text: String, button: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(.haloAccent)
            Text(title).font(HaloFont.display(15, weight: .semibold)).foregroundColor(.haloText)
            Text(text).font(HaloFont.body(13)).foregroundColor(.haloText2).multilineTextAlignment(.center)
            if let button { Button(button.0, action: button.1).buttonStyle(.borderedProminent) }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = "Choose the folders that contain your projects."
        guard panel.runModal() == .OK else { return }
        let sandboxed = BuildArtifactRemover.isSandboxed
        viewModel.addRoots(panel.urls, sandboxed: sandboxed)
        viewModel.rescan()
    }
}

// MARK: Row

struct BuildArtifactRow: View {
    let item: BuildArtifactItem
    let isSelected: Bool
    let onToggle: () -> Void
    let onNeverOffer: () -> Void

    private var classColor: Color {
        switch item.regenClass { case .safe: return .haloGreen; case .needsNetwork: return .haloAmber; case .caution: return .haloRed }
    }
    private var ageText: String {
        guard let d = item.artifactModified ?? item.projectLastModified else { return "—" }
        return d.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundColor(isSelected ? .haloAccent : .haloText3)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.projectName).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                    HaloBadge(text: item.toolchainName, color: .haloAccent)
                    HaloBadge(text: item.regenClass.label, color: classColor)
                    if item.isActive { HaloBadge(text: "Active", color: .haloAmber) }
                    if item.isUnverified && !item.isXcodeGlobal { HaloBadge(text: "Unverified", color: .haloText3) }
                }
                Text(item.artifactURL.path).font(HaloFont.body(10)).foregroundColor(.haloText3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ageText).font(HaloFont.body(11)).foregroundColor(.haloText3)
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloAmber).frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.haloAccent.opacity(0.06) : Color.haloSurface2)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .help("Rebuild: \(item.regenHint)\(item.isUnverified && !item.isXcodeGlobal ? "\nNot verified by git" : "")")
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.artifactURL]) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.artifactURL.path, forType: .string) }
            Button("Never offer this folder", action: onNeverOffer)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.projectName), \(item.toolchainName), \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)), \(item.regenClass.label)\(item.isActive ? ", active" : "")")
    }
}

// MARK: Review sheet (FR-U5 / FR-U5b)

struct BuildArtifactsReviewSheet: View {
    @ObservedObject var viewModel: BuildArtifactsViewModel
    let snapshot: BuildArtifactsViewModel.ReviewSnapshot
    @State private var confirmPermanent = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review \(snapshot.items.count) folder\(snapshot.items.count == 1 ? "" : "s") · \(snapshot.formatted)")
                    .font(HaloFont.display(16, weight: .semibold)).foregroundColor(.haloText)
                Text("Moved to Trash — space is freed when you empty the Trash.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText2)
                if snapshot.items.contains(where: \.isActive) {
                    Text("Some of these were modified in the last 24 hours — a build may be running.")
                        .font(HaloFont.body(11)).foregroundColor(.haloAmber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider().background(Color.haloBorder)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(snapshot.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.projectName).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                                Text("· \(item.toolchainName) · \(item.regenClass.label)\(item.isUnverified && !item.isXcodeGlobal ? " · Unverified" : "")")
                                    .font(HaloFont.body(11)).foregroundColor(.haloText3)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloAmber)
                            }
                            Text(item.artifactURL.path).font(HaloFont.body(10)).foregroundColor(.haloText3)
                                .lineLimit(1).truncationMode(.middle)
                            Text("Rebuild: \(item.regenHint)").font(HaloFont.body(10)).foregroundColor(.haloText2)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.haloSurface2).cornerRadius(8)
                    }
                }.padding(16)
            }
            Divider().background(Color.haloBorder)
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button("Cancel") { viewModel.cancelReview() }
                        .buttonStyle(.plain).font(HaloFont.body(13)).foregroundColor(.haloText2)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        Task { await viewModel.confirm(.trash) }
                    } label: {
                        Text("Move to Trash (\(snapshot.formatted))").font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.haloAccent).cornerRadius(10)
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("buildArtifacts.review.moveToTrash")
                }
                // FR-U5b — separate, never the default / Return action; hidden when not permitted.
                if viewModel.permanentRemovalAvailable {
                    HStack {
                        if snapshot.allPermanentEligible {
                            Text("Safe, git-verified items only. Permanently removes just these folders — nothing else in your Trash.")
                                .font(HaloFont.body(10)).foregroundColor(.haloText3)
                        } else {
                            Text("\(snapshot.ineligibleForPermanent) selected item(s) are Needs-network, Caution or not git-verified, so permanent removal is off for this selection.")
                                .font(HaloFont.body(10)).foregroundColor(.haloText3)
                        }
                        Spacer()
                        Button("Move to Trash and empty those items…") { confirmPermanent = true }
                            .buttonStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloRed)
                            .disabled(!snapshot.allPermanentEligible)
                            .opacity(snapshot.allPermanentEligible ? 1 : 0.4)
                            .accessibilityIdentifier("buildArtifacts.review.trashAndEmpty")
                    }
                }
            }
            .padding(20)
        }
        .background(Color.haloSurface)
        .frame(width: 640, height: 560)
        .confirmationDialog("Permanently delete \(snapshot.items.count) folder\(snapshot.items.count == 1 ? "" : "s") (\(snapshot.formatted))?",
                            isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await viewModel.confirm(.trashAndEmpty) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These folders will not be in the Trash afterwards and cannot be recovered. They can only be regenerated by rebuilding.")
        }
    }
}
