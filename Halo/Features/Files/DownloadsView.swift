import SwiftUI

// MARK: - DownloadsView

struct DownloadsView: View {
    @StateObject private var viewModel = DownloadsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DownloadsHeader(viewModel: viewModel)

                if viewModel.isScanning && !viewModel.hasScanned {
                    DownloadsLoadingCard()
                } else if viewModel.files.isEmpty && viewModel.hasScanned {
                    DownloadsEmptyCard()
                } else {
                    DownloadsSummaryBar(viewModel: viewModel)

                    // Status message
                    if let msg = viewModel.statusMessage {
                        StatusBanner(message: msg)
                    }

                    // Installer callout
                    if !viewModel.safeInstallers.isEmpty {
                        InstallerCallout(viewModel: viewModel)
                    }

                    // Grouped content
                    DownloadsGroupedContent(viewModel: viewModel)

                    // Action buttons
                    DownloadsActionBar(viewModel: viewModel)
                }
            }
            .padding(24)
        }
        .background(Color.haloSurface)
        .task { await viewModel.scan() }
        .alert("Clean Stale Downloads", isPresented: $viewModel.showCleanConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await viewModel.cleanStaleFiles() }
            }
        } message: {
            Text("Move \(viewModel.staleFiles.count) files older than 90 days to Trash? (\(viewModel.staleSizeFormatted))")
        }
        .alert("Organize Downloads", isPresented: $viewModel.showOrganizeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Organize") {
                Task { await viewModel.organizeIntoSubfolders() }
            }
        } message: {
            Text("Sort \(viewModel.fileCount) files into subfolders by type (Images, Documents, Archives, etc.)?")
        }
        // Per-file trash now confirms first (TC-SAFE-02).
        .alert("Move to Trash", isPresented: Binding(
            get: { viewModel.pendingTrash != nil },
            set: { if !$0 { viewModel.pendingTrash = nil } }
        )) {
            Button("Cancel", role: .cancel) { viewModel.pendingTrash = nil }
            Button("Move to Trash", role: .destructive) {
                if let file = viewModel.pendingTrash { viewModel.trashFile(file) }
                viewModel.pendingTrash = nil
            }
        } message: {
            Text(viewModel.pendingTrash.map { "Move \"\($0.name)\" to Trash?" } ?? "")
        }
    }
}

// MARK: - Header

private struct DownloadsHeader: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads")
                        .font(HaloFont.display(18, weight: .bold))
                        .foregroundColor(.haloText)
                    if viewModel.hasScanned {
                        Text("\(viewModel.fileCount) files · \(viewModel.totalSizeFormatted)")
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer()

                // Group mode picker
                Picker("", selection: $viewModel.groupMode) {
                    ForEach(DownloadGroupMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                // Refresh
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.haloText2)
                }
                .buttonStyle(.plain)
                .help("Rescan Downloads folder")
            }

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.haloText3)
                TextField("Search files…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(HaloFont.body(13))
                if !viewModel.searchText.isEmpty {
                    Button { viewModel.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.haloText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.haloSurface2)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
        }
    }
}

// MARK: - Summary Breakdown Bar

private struct DownloadsSummaryBar: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        HaloCard {
            VStack(spacing: 12) {
                // Breakdown bar
                GeometryReader { geo in
                    let total = max(viewModel.totalSize, 1)
                    HStack(spacing: 1) {
                        if viewModel.groupMode == .byAge {
                            ForEach(viewModel.ageBreakdown(), id: \.0) { group, size in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(group.color)
                                    .frame(width: max(4, geo.size.width * CGFloat(size) / CGFloat(total)))
                                    .help("\(group.rawValue): \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            }
                        } else {
                            ForEach(viewModel.typeBreakdown(), id: \.0) { type, size in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(type.color)
                                    .frame(width: max(4, geo.size.width * CGFloat(size) / CGFloat(total)))
                                    .help("\(type.rawValue): \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            }
                        }
                    }
                }
                .frame(height: 8)
                .cornerRadius(4)

                // Legend
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        if viewModel.groupMode == .byAge {
                            ForEach(viewModel.ageBreakdown(), id: \.0) { group, size in
                                LegendItem(color: group.color,
                                           label: group.rawValue,
                                           size: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                        } else {
                            ForEach(viewModel.typeBreakdown(), id: \.0) { type, size in
                                LegendItem(color: type.color,
                                           label: type.rawValue,
                                           size: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let size: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label).font(HaloFont.body(11)).foregroundColor(.haloText2)
            Text(size).font(HaloFont.mono(10)).foregroundColor(.haloText3)
        }
    }
}

// MARK: - Installer Callout

private struct InstallerCallout: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        HaloCard(accentTop: .haloGreen) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.haloGreen)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe to Remove")
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    let count = viewModel.safeInstallers.count
                    let size = viewModel.safeInstallers.reduce(0 as Int64) { $0 + $1.sizeBytes }
                    Text("\(count) installer\(count == 1 ? "" : "s") for apps already installed (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                }

                Spacer()

                Button("Clean") {
                    Task { await viewModel.cleanSafeInstallers() }
                }
                .font(HaloFont.body(12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.haloGreen)
                .cornerRadius(8)
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }
}

// MARK: - Grouped Content

private struct DownloadsGroupedContent: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.groupMode == .byAge {
                ForEach(viewModel.groupedByAge(), id: \.0) { group, files in
                    DownloadsGroupSection(
                        title: group.rawValue,
                        icon: group.icon,
                        color: group.color,
                        files: files,
                        viewModel: viewModel
                    )
                }
            } else {
                ForEach(viewModel.groupedByType(), id: \.0) { type, files in
                    DownloadsGroupSection(
                        title: type.rawValue,
                        icon: type.icon,
                        color: type.color,
                        files: files,
                        viewModel: viewModel
                    )
                }
            }
        }
    }
}

// MARK: - Group Section

private struct DownloadsGroupSection: View {
    let title: String
    let icon: String
    let color: Color
    let files: [DownloadFile]
    @ObservedObject var viewModel: DownloadsViewModel
    @State private var isExpanded = true

    private var groupSize: String {
        let total = files.reduce(0 as Int64) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(color)
                        .frame(width: 20)
                    Text(title)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    HaloBadge(text: "\(files.count)", color: color)
                    Spacer()
                    Text(groupSize)
                        .font(HaloFont.mono(12))
                        .foregroundColor(.haloText3)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.haloText3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(files) { file in
                        DownloadFileRow(file: file, viewModel: viewModel)
                    }
                }
            }
        }
        .background(Color.haloSurface2.opacity(0.5))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - File Row

private struct DownloadFileRow: View {
    let file: DownloadFile
    @ObservedObject var viewModel: DownloadsViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: file.fileType.icon)
                .font(.system(size: 13))
                .foregroundColor(file.fileType.color)
                .frame(width: 24)

            // Name
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if file.isSafeToRemoveInstaller {
                    Text("App installed — safe to remove")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloGreen)
                }
            }

            Spacer()

            // Date
            Text(file.modifiedDate, style: .relative)
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
                .frame(width: 100, alignment: .trailing)

            // Size
            Text(file.sizeFormatted)
                .font(HaloFont.mono(11))
                .foregroundColor(.haloText2)
                .frame(width: 70, alignment: .trailing)

            // Actions
            HStack(spacing: 6) {
                Button {
                    viewModel.revealInFinder(file)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button {
                    viewModel.pendingTrash = file       // ask first
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.haloRed.opacity(isHovered ? 1.0 : 0.5))
                }
                .buttonStyle(.plain)
                .help("Move to Trash")
                .accessibilityIdentifier("files.downloads.trash.button")
            }
            .frame(width: 50)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.haloAccent.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("files.downloads.row")
    }
}

// MARK: - Action Bar

private struct DownloadsActionBar: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Clean stale
            if !viewModel.staleFiles.isEmpty {
                Button {
                    viewModel.showCleanConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                        Text("Clean Stale (\(viewModel.staleFiles.count) files, \(viewModel.staleSizeFormatted))")
                    }
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.haloRed)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("files.downloads.cleanStale.button")
            }

            // Organize
            Button {
                viewModel.showOrganizeConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                    Text("Organize by Type")
                }
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.haloAccent.opacity(0.1))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloAccent.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Open in Finder
            Button {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                    Text("Open in Finder")
                }
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloText2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.haloSurface2)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }
}

// MARK: - Status Banner

private struct StatusBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.haloGreen)
            Text(message)
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
            Spacer()
        }
        .padding(12)
        .background(Color.haloGreen.opacity(0.08))
        .cornerRadius(8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Empty / Loading States

private struct DownloadsEmptyCard: View {
    var body: some View {
        HaloCard {
            VStack(spacing: 12) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.haloText3)
                Text("Downloads folder is empty")
                    .font(HaloFont.body(14, weight: .medium))
                    .foregroundColor(.haloText2)
                Text("No files found in ~/Downloads")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}

private struct DownloadsLoadingCard: View {
    var body: some View {
        HaloCard {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning Downloads folder…")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
                Spacer()
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
        }
    }
}
