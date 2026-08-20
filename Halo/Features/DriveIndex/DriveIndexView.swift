import SwiftUI
import AppKit

// MARK: - DriveIndexView  (F-051)
//
// New top-level sidebar module. Tab-bar shell mirrors FilesView's pattern
// exactly (four tabs instead of five, same capsule tab styling).

struct DriveIndexView: View {
    @State private var activeTab: DriveIndexTab = .drives

    enum DriveIndexTab: String, CaseIterable {
        case drives     = "Drives"
        case search     = "Search"
        case duplicates = "Duplicates"
        case settings   = "Settings"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(DriveIndexTab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    }
                    .accessibilityIdentifier("driveIndex.tab.\(tab.rawValue)")
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

            switch activeTab {
            case .drives:     DriveIndexDrivesTab()
            case .search:     DriveIndexSearchTab()
            case .duplicates: DriveIndexDuplicatesTab()
            case .settings:   DriveIndexSettingsTab()
            }
        }
        .background(Color.haloSurface)
    }
}

// MARK: - Drives tab

struct DriveIndexDrivesTab: View {
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = coordinator.lastError {
                    Text(error)
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if coordinator.knownDrives.isEmpty {
                    emptyState
                } else {
                    ForEach(coordinator.knownDrives) { drive in
                        driveRow(drive)
                    }
                }
            }
            .padding(24)
        }
        .task { await coordinator.refreshKnownDrives() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.haloText3)
            Text("No drives yet")
                .font(HaloFont.body(14, weight: .semibold))
                .foregroundColor(.haloText)
            Text("Plug in an external drive — Halo will ask before indexing it.")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func driveRow(_ drive: KnownDrive) -> some View {
        let connected = coordinator.isConnected(driveKey: drive.driveKey)
        return HaloCard {
            HStack(spacing: 12) {
                Image(systemName: connected ? "externaldrive.fill" : "externaldrive")
                    .font(.system(size: 20))
                    .foregroundColor(connected ? .haloGreen : .haloText3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(drive.name)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        HaloBadge(text: connected ? "Connected" : "Disconnected",
                                  color: connected ? .haloGreen : .haloText3)
                        HaloBadge(text: stateLabel(drive.indexingState), color: .haloAccent)
                    }
                    Text(detailLine(drive))
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                Spacer()
                actionArea(for: drive, connected: connected)
            }
            .padding(14)
        }
        .accessibilityIdentifier("driveIndex.drives.row")
    }

    private func stateLabel(_ state: DriveIndexingState) -> String {
        switch state {
        case .indexed: return "Indexed"
        case .notIndexed: return "Not indexed"
        case .declined: return "Declined"
        }
    }

    private func detailLine(_ drive: KnownDrive) -> String {
        guard let date = drive.lastIndexedDate else { return "Not indexed yet" }
        let formatter = RelativeDateTimeFormatter()
        return "\(drive.fileCount) files · \(drive.totalFormatted) · indexed \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    @ViewBuilder
    private func actionArea(for drive: KnownDrive, connected: Bool) -> some View {
        if coordinator.activelyIndexingDriveKeys.contains(drive.driveKey) {
            ProgressView().controlSize(.small)
        } else if !connected {
            Text("Reconnect to manage")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
        } else {
            HStack(spacing: 8) {
                switch drive.indexingState {
                case .indexed:
                    HaloGhostButton("Re-index", icon: "arrow.clockwise") {
                        coordinator.manuallyReindex(driveKey: drive.driveKey)
                    }
                    HaloGhostButton("Forget", icon: "trash") {
                        coordinator.forgetDrive(driveKey: drive.driveKey)
                    }
                case .notIndexed, .declined:
                    HaloPrimaryButton("Index Now", icon: "magnifyingglass") {
                        coordinator.manuallyIndex(driveKey: drive.driveKey)
                    }
                }
            }
        }
    }
}

// MARK: - Search tab

struct DriveIndexSearchTab: View {
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared
    @State private var query = ""
    @State private var results: [IndexedFileEntry] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.haloText3)
                TextField("Search files across all indexed drives…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("driveIndex.search.field")
                    .onChange(of: query) { newValue in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            results = await coordinator.search(query: newValue)
                        }
                    }
            }
            .padding(10)
            .background(Color.haloSurface2)
            .cornerRadius(10)
            .padding(20)

            if results.isEmpty {
                Spacer()
                Text(query.isEmpty
                     ? "Type to search every indexed drive — even ones that are unplugged."
                     : "No matches.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(results) { entry in
                            resultRow(entry)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func resultRow(_ entry: IndexedFileEntry) -> some View {
        let connected = coordinator.isConnected(driveKey: entry.driveKey)
        let driveName = coordinator.knownDrives.first { $0.driveKey == entry.driveKey }?.name ?? "Unknown drive"
        return HaloCard {
            HStack(spacing: 12) {
                Image(systemName: entry.category.icon).foregroundColor(.haloAccent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.fileName).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                        HaloBadge(text: connected ? "Connected" : "Disconnected",
                                  color: connected ? .haloGreen : .haloText3)
                    }
                    Text("\(driveName) · \(entry.relativePath)")
                        .font(HaloFont.body(11)).foregroundColor(.haloText2).lineLimit(1)
                    Text("\(entry.sizeFormatted) · last seen \(RelativeDateTimeFormatter().localizedString(for: entry.lastSeenDate, relativeTo: Date()))")
                        .font(HaloFont.body(10)).foregroundColor(.haloText3)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button { coordinator.revealInFinder(entry) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .disabled(!connected)
                    .accessibilityIdentifier("driveIndex.search.reveal.button")
                    .help(connected ? "Reveal in Finder" : "Connect \(driveName) to reveal this file")

                    Button { coordinator.openFile(entry) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .disabled(!connected)
                    .accessibilityIdentifier("driveIndex.search.open.button")
                    .help(connected ? "Open" : "Connect \(driveName) to open this file")
                }
                .foregroundColor(connected ? .haloAccent : .haloText3)
            }
            .padding(14)
        }
        .accessibilityIdentifier("driveIndex.search.row")
    }
}

// MARK: - Duplicates tab

struct DriveIndexDuplicatesTab: View {
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared
    @AppStorage(DriveIndexCoordinator.sizeThresholdDefaultsKey) private var thresholdBytes = 100_000_000
    @State private var groups: [CrossDriveDuplicateGroup] = []
    @State private var isLoading = false

    private static let presets: [(String, Int)] = [
        ("50 MB", 50_000_000), ("100 MB", 100_000_000),
        ("250 MB", 250_000_000), ("1 GB", 1_000_000_000)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Flag duplicates ≥").font(HaloFont.body(12)).foregroundColor(.haloText2)
                Picker("", selection: $thresholdBytes) {
                    ForEach(Self.presets, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .accessibilityIdentifier("driveIndex.duplicates.threshold")
                Spacer()
                HaloGhostButton("Refresh", icon: "arrow.clockwise") { Task { await reload() } }
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if groups.isEmpty {
                Spacer()
                Text("No duplicates found across connected drives at this threshold.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(groups) { group in groupCard(group) }
                    }
                    .padding(20)
                }
            }
        }
        .task { await reload() }
        .onChange(of: thresholdBytes) { _ in Task { await reload() } }
    }

    private func reload() async {
        isLoading = true
        groups = await coordinator.duplicates(minSizeBytes: Int64(thresholdBytes))
        isLoading = false
    }

    private func groupCard(_ group: CrossDriveDuplicateGroup) -> some View {
        HaloCard(accentTop: group.isConfirmed ? .haloRed : .haloAmber) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HaloBadge(text: group.isConfirmed ? "Confirmed" : "Awaiting reconnect",
                              color: group.isConfirmed ? .haloRed : .haloAmber)
                    Spacer()
                    Text("Wastes \(group.wastedFormatted)")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText2)
                }
                ForEach(group.items) { item in
                    HStack {
                        Image(systemName: item.isDriveConnected ? "externaldrive.fill" : "externaldrive")
                            .foregroundColor(item.isDriveConnected ? .haloGreen : .haloText3)
                        Text("\(item.driveName) · \(item.relativePath)")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                            .lineLimit(1)
                        Spacer()
                        Text(item.sizeFormatted).font(HaloFont.body(11)).foregroundColor(.haloText3)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Settings tab

struct DriveIndexSettingsTab: View {
    @AppStorage(DriveIndexCoordinator.pausedDefaultsKey) private var isPaused = false
    @AppStorage(DriveIndexCoordinator.excludedFolderNamesRawDefaultsKey) private var excludedFolderNamesRaw = ""
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HaloCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Pause all drive indexing", isOn: $isPaused)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("driveIndex.settings.pause")
                        Text("When paused, newly mounted drives are neither prompted for nor indexed.")
                            .font(HaloFont.body(11)).foregroundColor(.haloText2)
                    }
                    .padding(14)
                }

                HaloCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("File types to index").font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                        ForEach(IndexedFileCategory.allCases, id: \.self) { category in
                            categoryToggle(category)
                        }
                        Text("A disabled category is skipped entirely while walking a drive — not just hidden from search.")
                            .font(HaloFont.body(11)).foregroundColor(.haloText2)
                    }
                    .padding(14)
                }

                HaloCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Excluded folder names").font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                        Text("One per line. Any folder with a matching name is skipped on every drive.")
                            .font(HaloFont.body(11)).foregroundColor(.haloText2)
                        TextEditor(text: $excludedFolderNamesRaw)
                            .font(HaloFont.mono(12))
                            .frame(height: 100)
                            .padding(6)
                            .background(Color.haloSurface2)
                            .cornerRadius(8)
                            .accessibilityIdentifier("driveIndex.settings.excludeList")
                            .overlay(alignment: .topLeading) {
                                if excludedFolderNamesRaw.isEmpty {
                                    Text(DriveIndexCoordinator.defaultExcludedFolderNames.joined(separator: "\n"))
                                        .font(HaloFont.mono(12))
                                        .foregroundColor(.haloText3)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    .padding(14)
                }
            }
            .padding(24)
        }
    }

    private func categoryToggle(_ category: IndexedFileCategory) -> some View {
        Toggle(isOn: Binding(
            get: { coordinator.isCategoryEnabled(category) },
            set: { coordinator.setCategoryEnabled(category, enabled: $0) }
        )) {
            HStack(spacing: 6) {
                Image(systemName: category.icon).foregroundColor(.haloAccent).frame(width: 18)
                Text(category.rawValue).font(HaloFont.body(12)).foregroundColor(.haloText)
            }
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("driveIndex.settings.category.\(category.rawValue)")
    }
}

// MARK: - Ask-first prompt (FR-3 / D1)

struct AskIndexDriveSheet: View {
    let volume: DriveVolume
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.haloAccent)

            VStack(spacing: 6) {
                Text("Index \"\(volume.name)\"?")
                    .font(HaloFont.body(16, weight: .semibold))
                    .foregroundColor(.haloText)
                Text("Halo can build a searchable index of this drive, so you can find files on it — and spot duplicates across drives — even while it's disconnected. You'll grant access once; every later mount indexes automatically.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                HaloGhostButton("Not now", icon: nil) {
                    coordinator.declineIndexing(for: volume)
                }
                .accessibilityIdentifier("driveIndex.ask.decline.button")
                HaloPrimaryButton("Index this drive", icon: "checkmark") {
                    coordinator.acceptIndexing(for: volume)
                }
                .accessibilityIdentifier("driveIndex.ask.accept.button")
            }
        }
        .padding(32)
        .frame(width: 380)
        .background(Color.haloSurface)
    }
}
