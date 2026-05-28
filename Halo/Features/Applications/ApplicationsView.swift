import SwiftUI

struct ApplicationsView: View {
    @StateObject private var viewModel = ApplicationsViewModel()

    var body: some View {
        HStack(spacing: 0) {
            AppListPanel(viewModel: viewModel)
                .frame(width: 300)
            Divider().background(Color.haloBorder)
            if let selected = viewModel.selectedApp {
                AppDetailPanel(app: selected, viewModel: viewModel)
            } else {
                AppDetailEmptyState()
            }
        }
        .background(Color.haloSurface)
        .task { await viewModel.loadApps() }
    }
}

// MARK: - ViewModel

@MainActor
final class ApplicationsViewModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp? = nil
    @Published var isLoading = false
    @Published var isUninstalling = false
    @Published var uninstallError: String? = nil   // non-nil when last uninstall failed
    @Published var uninstallSuccess = false         // briefly true after successful uninstall
    @Published var searchText = ""
    @Published var sortMode: SortMode = .size
    @Published var showUnusedOnly = false

    // F-010: real app scanner
    private let scanner = AppScanner()

    enum SortMode: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case lastUsed = "Last Used"
    }

    var filteredApps: [InstalledApp] {
        var result = apps
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        if showUnusedOnly {
            result = result.filter(\.isUnused)
        }
        switch sortMode {
        case .name: result.sort { $0.name < $1.name }
        case .size: result.sort { $0.sizeBytes > $1.sizeBytes }
        case .lastUsed:
            result.sort {
                ($0.lastUsedDate ?? .distantPast) > ($1.lastUsedDate ?? .distantPast)
            }
        }
        return result
    }

    var unusedAppsCount: Int { apps.filter(\.isUnused).count }

    func loadApps() async {
        isLoading = true
        // F-010: real enumeration of /Applications and ~/Applications
        let realApps = await scanner.scanApps()
        apps = realApps.isEmpty ? InstalledApp.samples : realApps
        isLoading = false
    }

    func loadLeftovers(for app: InstalledApp) async {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        // F-010: real leftover scan across 12 standard locations
        let found = await scanner.scanLeftovers(for: app)
        apps[idx].leftovers = found.isEmpty ? AppLeftover.samples(for: app) : found
        if selectedApp?.id == app.id { selectedApp = apps[idx] }
    }

    /// Toggles the `isSelected` flag on a leftover file so that the user's checkbox
    /// choices are reflected back into the model before `uninstall()` is called.
    func toggleLeftover(appId: UUID, leftoverId: UUID) {
        guard let appIdx = apps.firstIndex(where: { $0.id == appId }),
              let lvIdx  = apps[appIdx].leftovers.firstIndex(where: { $0.id == leftoverId })
        else { return }
        apps[appIdx].leftovers[lvIdx].isSelected.toggle()
        if selectedApp?.id == appId { selectedApp = apps[appIdx] }
    }

    func uninstall(_ app: InstalledApp) async {
        isUninstalling = true
        uninstallError = nil

        // Pass the version of the app that lives in `apps[]` — it carries the
        // up-to-date `isSelected` flags the user may have toggled.
        let liveApp = apps.first(where: { $0.id == app.id }) ?? app
        let (success, error) = await scanner.uninstall(liveApp)

        if success {
            apps.removeAll { $0.id == app.id }
            selectedApp = nil
            uninstallSuccess = true
        } else {
            // Keep the app in the list — it wasn't actually removed from disk.
            uninstallError = error ?? "Could not move \(app.name) to the Trash. " +
                "If the app is in /Applications, try dragging it to the Trash manually " +
                "or use Finder → Move to Trash."
        }
        isUninstalling = false
    }
}

extension InstalledApp {
    static let samples: [InstalledApp] = [
        .init(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", version: "16.2",
              path: "/Applications/Xcode.app", sizeBytes: 14_500_000_000,
              lastUsedDate: Date().addingTimeInterval(-86400), installDate: nil),
        .init(name: "Figma", bundleIdentifier: "com.figma.Desktop", version: "116.15",
              path: "/Applications/Figma.app", sizeBytes: 580_000_000,
              lastUsedDate: Date(), installDate: nil),
        .init(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", version: "4.39",
              path: "/Applications/Slack.app", sizeBytes: 320_000_000,
              lastUsedDate: Date(), installDate: nil),
        .init(name: "Spotify", bundleIdentifier: "com.spotify.client", version: "1.2.48",
              path: "/Applications/Spotify.app", sizeBytes: 410_000_000,
              lastUsedDate: Date().addingTimeInterval(-604800), installDate: nil),
        .init(name: "Adobe Acrobat", bundleIdentifier: "com.adobe.Acrobat.Pro", version: "24.0",
              path: "/Applications/Adobe Acrobat.app", sizeBytes: 1_800_000_000,
              lastUsedDate: Date().addingTimeInterval(-7776000), installDate: nil),
        .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", version: "11.1",
              path: "/Applications/Logic Pro.app", sizeBytes: 3_200_000_000,
              lastUsedDate: Date().addingTimeInterval(-10000000), installDate: nil),
        .init(name: "Sketch", bundleIdentifier: "com.bohemiancoding.sketch3", version: "99.1",
              path: "/Applications/Sketch.app", sizeBytes: 210_000_000,
              lastUsedDate: Date().addingTimeInterval(-8640000), installDate: nil),
    ]
}

extension AppLeftover {
    static func samples(for app: InstalledApp) -> [AppLeftover] {
        let home = NSHomeDirectory()
        let id = app.bundleIdentifier
        let name = app.name
        return [
            AppLeftover(url: URL(fileURLWithPath: "\(home)/Library/Preferences/\(id).plist"),
                       kind: .preferences, sizeBytes: 45_000),
            AppLeftover(url: URL(fileURLWithPath: "\(home)/Library/Application Support/\(name)"),
                       kind: .appSupport, sizeBytes: 128_000_000),
            AppLeftover(url: URL(fileURLWithPath: "\(home)/Library/Caches/\(id)"),
                       kind: .cache, sizeBytes: 340_000_000),
        ]
    }
}

// MARK: - App List Panel

struct AppListPanel: View {
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Applications")
                        .font(HaloFont.display(16, weight: .bold))
                        .foregroundColor(.haloText)
                    Spacer()
                    if viewModel.unusedAppsCount > 0 {
                        HaloBadge(text: "\(viewModel.unusedAppsCount) unused", color: .haloAmber)
                    }
                }

                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.haloText2)
                    TextField("Search apps…", text: $viewModel.searchText)
                        .font(HaloFont.body(12))
                        .textFieldStyle(.plain)
                        .foregroundColor(.haloText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.haloSurface)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))

                // Sort + Filter
                HStack(spacing: 8) {
                    Picker("Sort", selection: $viewModel.sortMode) {
                        ForEach(ApplicationsViewModel.SortMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)

                    Button {
                        viewModel.showUnusedOnly.toggle()
                    } label: {
                        Image(systemName: viewModel.showUnusedOnly ? "clock.badge.xmark.fill" : "clock.badge.xmark")
                            .font(.system(size: 14))
                            .foregroundColor(viewModel.showUnusedOnly ? .haloAmber : .haloText2)
                    }
                    .buttonStyle(.plain)
                    .help("Show unused apps only")
                }
            }
            .padding(14)

            Divider().background(Color.haloBorder)

            if viewModel.isLoading {
                Spacer()
                ProgressView().tint(.haloAccent)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.filteredApps) { app in
                            AppListRow(
                                app: app,
                                isSelected: viewModel.selectedApp?.id == app.id
                            ) {
                                viewModel.selectedApp = app
                                Task { await viewModel.loadLeftovers(for: app) }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

struct AppListRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.haloAccent.opacity(0.08))
                        .frame(width: 34, height: 34)
                    if let icon = NSWorkspace.shared.icon(forFile: app.path) as NSImage?,
                       icon.size.width > 32 {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(String(app.name.prefix(1)))
                            .font(HaloFont.display(14, weight: .bold))
                            .foregroundColor(.haloAccent)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(.haloText)
                    HStack(spacing: 6) {
                        Text(app.sizeFormatted)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                        if app.isUnused {
                            Text("• Unused")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloAmber)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.haloText3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.haloAccent.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Detail Panel

struct AppDetailPanel: View {
    let app: InstalledApp
    @ObservedObject var viewModel: ApplicationsViewModel

    @State private var showUninstallConfirm = false

    var totalLeftoverBytes: Int64 { app.leftovers.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // App header
                HStack(spacing: 16) {
                    // Real app icon from NSWorkspace, fallback to initial letter
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.haloAccent.opacity(0.1))
                            .frame(width: 56, height: 56)
                        if let icon = NSWorkspace.shared.icon(forFile: app.path) as NSImage?,
                           icon.size.width > 32 {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Text(String(app.name.prefix(1)))
                                .font(HaloFont.display(24, weight: .heavy))
                                .foregroundColor(.haloAccent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(HaloFont.display(18, weight: .bold))
                            .foregroundColor(.haloText)
                        Text("v\(app.version) · \(app.sizeFormatted)")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                        if app.isUnused {
                            HaloBadge(text: "Not used in 90+ days", color: .haloAmber)
                        }
                    }
                    Spacer()
                    HaloPrimaryButton("Uninstall", icon: "trash.fill", isLoading: viewModel.isUninstalling) {
                        showUninstallConfirm = true
                    }
                }

                // Error banner — shown when trashItem failed
                if let err = viewModel.uninstallError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.haloAmber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Uninstall failed")
                                .font(HaloFont.body(12, weight: .semibold))
                                .foregroundColor(.haloAmber)
                            Text(err)
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .background(Color.haloAmber.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.haloAmber.opacity(0.2), lineWidth: 1))
                }

                Divider().background(Color.haloBorder)

                // Leftover files
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Leftover Files")
                            .font(HaloFont.display(14, weight: .semibold))
                            .foregroundColor(.haloText)
                        Spacer()
                        if totalLeftoverBytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: totalLeftoverBytes, countStyle: .file))
                                .font(HaloFont.body(13, weight: .semibold))
                                .foregroundColor(.haloAmber)
                        }
                    }

                    ForEach(app.leftovers) { leftover in
                        LeftoverRow(
                            leftover: leftover,
                            onToggle: { viewModel.toggleLeftover(appId: app.id, leftoverId: leftover.id) }
                        )
                    }

                    if app.leftovers.isEmpty {
                        Text("Scanning for leftover files…")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                            .padding(.top, 4)
                    }
                }

                // Info note about what will happen
                if !app.leftovers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.haloText3)
                        Text("Checked items will be moved to the Trash along with the app bundle.")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }
            }
            .padding(24)
        }
        // Confirmation sheet before running destructive uninstall
        .confirmationDialog(
            "Uninstall \"\(app.name)\"?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await viewModel.uninstall(app) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let selectedCount = app.leftovers.filter(\.isSelected).count
            if selectedCount > 0 {
                Text("\(app.name) and \(selectedCount) leftover file\(selectedCount == 1 ? "" : "s") will be moved to the Trash. This action can be undone from the Trash.")
            } else {
                Text("\(app.name) will be moved to the Trash. This action can be undone from the Trash.")
            }
        }
    }
}

struct LeftoverRow: View {
    let leftover: AppLeftover
    /// Called when the checkbox is toggled — lets the ViewModel update model state.
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox driven by the model's isSelected flag, not local @State.
            // Toggling calls back to the ViewModel which updates apps[].leftovers[].isSelected.
            Button {
                onToggle()
            } label: {
                Image(systemName: leftover.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundColor(leftover.isSelected ? .haloAccent : .haloText3)
            }
            .buttonStyle(.plain)

            Image(systemName: leftoverIcon(for: leftover.kind))
                .font(.system(size: 13))
                .foregroundColor(.haloAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.kind.rawValue)
                    .font(HaloFont.body(11, weight: .semibold))
                    .foregroundColor(.haloText2)
                Text(leftover.displayPath)
                    .font(HaloFont.mono(11))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
            }
            Spacer()
            Text(leftover.sizeFormatted)
                .font(HaloFont.body(11, weight: .medium))
                .foregroundColor(.haloText2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(leftover.isSelected ? Color.haloSurface2 : Color.haloSurface2.opacity(0.4))
        .cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(leftover.isSelected ? Color.haloBorder : Color.haloBorder.opacity(0.3), lineWidth: 1))
    }

    private func leftoverIcon(for kind: LeftoverKind) -> String {
        switch kind {
        case .preferences:    return "doc.text.fill"
        case .appSupport:     return "folder.fill"
        case .cache:          return "clock.arrow.circlepath"
        case .container:      return "square.stack.fill"
        case .groupContainer: return "square.stack.3d.up.fill"
        case .logs:           return "doc.plaintext.fill"
        case .savedState:     return "arrow.clockwise.circle.fill"
        case .cookies:        return "lock.doc.fill"
        case .webkit:         return "globe"
        case .launchAgent:    return "gearshape.fill"
        case .crashLogs:      return "exclamationmark.circle.fill"
        }
    }
}

struct AppDetailEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundColor(.haloText3)
            Text("Select an app")
                .font(HaloFont.display(14, weight: .semibold))
                .foregroundColor(.haloText2)
            Text("Choose an application to view details and uninstall it along with all leftover files.")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
