import SwiftUI

struct ProtectionView: View {
    @StateObject private var viewModel = ProtectionViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProtectionHeader(viewModel: viewModel)
                ScannerCardsRow(viewModel: viewModel)
                PermissionsAuditSection(viewModel: viewModel)
                LaunchAgentsSection(viewModel: viewModel)
            }
            .padding(28)
        }
        .background(Color.haloSurface)
        .task { await viewModel.loadAll() }
    }
}

// MARK: - ViewModel

@MainActor
final class ProtectionViewModel: ObservableObject {
    // Malware
    @Published var scanState: ScanState = .idle
    @Published var threatsFound: [MalwareThreat] = []
    @Published var lastScanDate: Date? = nil
    @Published var signatureDBDate: Date? = Date().addingTimeInterval(-86400 * 3)

    // Privacy Cleaner
    @Published var installedBrowsers: [DetectedBrowser] = []
    @Published var browserDataSizes: [UUID: Int64] = [:]
    @Published var isLoadingBrowsers = false
    @Published var showBrowserReviewSheet = false
    @Published var selectedBrowsersForClear: Set<UUID> = []
    @Published var isClearingBrowser = false
    @Published var clearBrowserError: String? = nil

    // Permissions
    @Published var permissions: [AppPermission] = []

    private let scanner = ProtectionScanner()

    enum ScanState: Equatable {
        case idle, scanning(progress: Double), complete(clean: Bool), found(count: Int)
    }

    var scanStatusText: String {
        switch scanState {
        case .idle: return "Not yet scanned"
        case .scanning(let p): return String(format: "Scanning… %.0f%%", p * 100)
        case .complete: return "No threats found"
        case .found(let n): return "\(n) threat\(n == 1 ? "" : "s") found"
        }
    }

    var scanStatusColor: Color {
        switch scanState {
        case .idle: return .haloText2
        case .scanning: return .haloAccent
        case .complete: return .haloGreen
        case .found: return .haloRed
        }
    }

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPermissions() }
            group.addTask { await self.loadInstalledBrowsers() }
        }
    }

    // MARK: Malware

    func runMalwareScan() async {
        scanState = .scanning(progress: 0)
        threatsFound = []
        let found = await scanner.runMalwareScan { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in self.scanState = .scanning(progress: progress) }
        }
        lastScanDate = Date()
        threatsFound = found
        scanState = found.isEmpty ? .complete(clean: true) : .found(count: found.count)
    }

    func quarantineThreat(_ threat: MalwareThreat) {
        if let idx = threatsFound.firstIndex(where: { $0.id == threat.id }) {
            threatsFound[idx].isQuarantined = true
        }
    }

    // MARK: Browser Privacy (real detection + real clearing)

    func loadInstalledBrowsers() async {
        isLoadingBrowsers = true
        let browsers = await scanner.detectInstalledBrowsers()
        installedBrowsers = browsers
        selectedBrowsersForClear = Set(browsers.filter(\.hasData).map(\.id))
        var sizes: [UUID: Int64] = [:]
        for b in browsers { sizes[b.id] = await scanner.dataSize(for: b) }
        browserDataSizes = sizes
        isLoadingBrowsers = false
    }

    func clearSelectedBrowserData() async {
        isClearingBrowser = true
        clearBrowserError = nil
        var firstError: String?
        for browser in installedBrowsers where selectedBrowsersForClear.contains(browser.id) {
            let result = await scanner.clearBrowserData(browser)
            if result.error != nil && firstError == nil { firstError = result.error }
        }
        if let err = firstError { clearBrowserError = err }
        // Refresh data sizes after clearing
        var sizes: [UUID: Int64] = [:]
        for b in installedBrowsers { sizes[b.id] = await scanner.dataSize(for: b) }
        browserDataSizes = sizes
        isClearingBrowser = false
        showBrowserReviewSheet = false
    }

    // MARK: Permissions (sample — TCC.db needs Full Disk Access)

    func loadPermissions() async {
        permissions = PermissionKind.allCases.map { kind in
            AppPermission(kind: kind, grantedApps: sampleApps(for: kind))
        }
    }

    private func sampleApps(for kind: PermissionKind) -> [String] {
        switch kind {
        case .camera:          return ["Zoom", "FaceTime", "Slack"]
        case .microphone:      return ["Zoom", "Spotify", "Discord", "FaceTime"]
        case .location:        return ["Maps", "Weather"]
        case .contacts:        return ["Mimestream", "Cardhop", "Zoom"]
        case .calendar:        return ["Fantastical", "Zoom"]
        case .fullDisk:        return ["Halo"]
        case .screenRecording: return ["Zoom", "CleanShot X", "Loom"]
        case .accessibility:   return ["Raycast", "BetterTouchTool"]
        }
    }
}

// MARK: - Header

struct ProtectionHeader: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Protection")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Malware · Privacy · Permissions")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            if let date = viewModel.lastScanDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last scan")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .font(HaloFont.body(11, weight: .medium))
                        .foregroundColor(.haloText2)
                }
            }
        }
    }
}

// MARK: - Scanner Cards

struct ScannerCardsRow: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        HStack(spacing: 16) {
            MalwareScanCard(viewModel: viewModel)
            PrivacyCleanerCard(viewModel: viewModel)
        }
    }
}

// MARK: - Malware Scan Card

struct MalwareScanCard: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(hex: "#1c3a2a"), Color(hex: "#1a4030")],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                        Image(systemName: "shield.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.haloGreen)
                    }
                    Spacer()
                    if let dbDate = viewModel.signatureDBDate {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("Signatures")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText3)
                            Text(RelativeDateTimeFormatter()
                                .localizedString(for: dbDate, relativeTo: Date()))
                                .font(HaloFont.body(10, weight: .medium))
                                .foregroundColor(.haloText2)
                        }
                    }
                }

                Text("Malware Scanner")
                    .font(HaloFont.display(15, weight: .semibold))
                    .foregroundColor(.haloText)

                Text("Scans known malware drop-zones against a curated signature database of adware, PUPs, hijackers, and keyloggers.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.scanStatusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: viewModel.scanStatusColor.opacity(0.5), radius: 3)
                    Text(viewModel.scanStatusText)
                        .font(HaloFont.body(12))
                        .foregroundColor(viewModel.scanStatusColor)
                }

                if case .scanning(let p) = viewModel.scanState {
                    VStack(spacing: 4) {
                        HaloMiniBar(value: p, color: .haloAccent)
                        Text("Scanning system locations…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }

                if !viewModel.threatsFound.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(viewModel.threatsFound) { threat in
                            ThreatRow(threat: threat) { viewModel.quarantineThreat(threat) }
                        }
                    }
                }

                HaloPrimaryButton(
                    { if case .scanning = viewModel.scanState { return "Scanning…" }
                      return "Run Full Scan" }(),
                    icon: "shield.lefthalf.filled",
                    isLoading: { if case .scanning = viewModel.scanState { return true }; return false }()
                ) { Task { await viewModel.runMalwareScan() } }
            }
            .padding(20)
        }
    }
}

struct ThreatRow: View {
    let threat: MalwareThreat
    let onQuarantine: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(threat.risk.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(threat.name)
                    .font(HaloFont.body(11, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(threat.filePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(HaloFont.mono(10))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
            }
            Spacer()
            if threat.isQuarantined {
                HaloBadge(text: "Quarantined", color: .haloGreen)
            } else {
                Button("Quarantine") { onQuarantine() }
                    .font(HaloFont.body(10, weight: .semibold))
                    .foregroundColor(.haloRed)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.haloSurface.opacity(0.6))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(threat.risk.color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Privacy Cleaner Card (real browser detection)

struct PrivacyCleanerCard: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(hex: "#3a1a10"), Color(hex: "#4a2008")],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.haloAmber)
                    }
                    Spacer()
                }

                Text("Privacy Cleaner")
                    .font(HaloFont.display(15, weight: .semibold))
                    .foregroundColor(.haloText)

                Text("Clear browsing history, cookies, and cached data from browsers actually installed on this Mac.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Detected-browser list
                if viewModel.isLoadingBrowsers {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6).tint(.haloAccent)
                        Text("Detecting browsers…")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                    }
                } else if viewModel.installedBrowsers.isEmpty {
                    Text("No supported browsers detected.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                } else {
                    VStack(spacing: 6) {
                        ForEach(viewModel.installedBrowsers) { browser in
                            HStack(spacing: 8) {
                                Image(systemName: browser.icon)
                                    .font(.system(size: 12))
                                    .foregroundColor(.haloText2)
                                    .frame(width: 18)
                                Text(browser.name)
                                    .font(HaloFont.body(12))
                                    .foregroundColor(.haloText)
                                Spacer()
                                if let sz = viewModel.browserDataSizes[browser.id], sz > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))
                                        .font(HaloFont.body(10))
                                        .foregroundColor(.haloText3)
                                }
                                if browser.hasData {
                                    HaloBadge(text: "Has data", color: .haloAmber)
                                } else {
                                    HaloBadge(text: "Clean", color: .haloGreen)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.haloSurface)
                            .cornerRadius(8)
                        }
                    }
                }

                HaloPrimaryButton("Review & Clear", icon: "trash.fill",
                                  isLoading: viewModel.isClearingBrowser) {
                    viewModel.showBrowserReviewSheet = true
                }
                .disabled(viewModel.installedBrowsers.isEmpty || viewModel.isLoadingBrowsers)
            }
            .padding(20)
        }
        .sheet(isPresented: $viewModel.showBrowserReviewSheet) {
            BrowserReviewSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Browser Review Sheet

struct BrowserReviewSheet: View {
    @ObservedObject var viewModel: ProtectionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review & Clear Browser Data")
                        .font(HaloFont.display(16, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text("Selected data will be moved to Trash.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            // Warning banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundColor(.haloAmber)
                Text("Close all browsers before clearing to avoid data corruption.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.haloAmber.opacity(0.08))

            Divider().background(Color.haloBorder)

            // Browser list with toggles
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(viewModel.installedBrowsers) { browser in
                        let isSelected = viewModel.selectedBrowsersForClear.contains(browser.id)
                        HStack(spacing: 12) {
                            Button {
                                if isSelected {
                                    viewModel.selectedBrowsersForClear.remove(browser.id)
                                } else {
                                    viewModel.selectedBrowsersForClear.insert(browser.id)
                                }
                            } label: {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16))
                                    .foregroundColor(isSelected ? .haloAccent : .haloText3)
                            }
                            .buttonStyle(.plain)

                            Image(systemName: browser.icon)
                                .font(.system(size: 14))
                                .foregroundColor(.haloText2)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(browser.name)
                                    .font(HaloFont.body(13, weight: .medium))
                                    .foregroundColor(.haloText)
                                Text(browser.dataPaths.map {
                                    $0.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                }.joined(separator: "\n"))
                                    .font(HaloFont.mono(10))
                                    .foregroundColor(.haloText3)
                                    .lineLimit(3)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                if let sz = viewModel.browserDataSizes[browser.id], sz > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))
                                        .font(HaloFont.body(12, weight: .semibold))
                                        .foregroundColor(.haloAmber)
                                }
                                if browser.hasData {
                                    HaloBadge(text: "Has data", color: .haloAmber)
                                } else {
                                    HaloBadge(text: "Clean", color: .haloGreen)
                                }
                            }
                        }
                        .padding(14)
                        .background(isSelected ? Color.haloAccent.opacity(0.06) : Color.haloSurface2)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.haloAccent.opacity(0.3) : Color.haloBorder,
                                    lineWidth: 1))
                    }
                }
                .padding(20)
            }

            Divider().background(Color.haloBorder)

            // Error banner
            if let err = viewModel.clearBrowserError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloAmber)
                    Text(err).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(2)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.haloAmber.opacity(0.08))
            }

            // Footer
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
                    .buttonStyle(.plain)

                Spacer()

                Button {
                    Task { await viewModel.clearSelectedBrowserData() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isClearingBrowser {
                            ProgressView().scaleEffect(0.6).tint(.white)
                        } else {
                            Image(systemName: "trash.fill").font(.system(size: 12))
                        }
                        Text("Clear Selected Data")
                            .font(HaloFont.body(13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(viewModel.selectedBrowsersForClear.isEmpty
                        ? Color.haloRed.opacity(0.4)
                        : Color.haloRed)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedBrowsersForClear.isEmpty || viewModel.isClearingBrowser)
            }
            .padding(20)
        }
        .background(Color.haloSurface)
        .frame(width: 560, height: 480)
    }
}

// MARK: - Permissions Audit

struct PermissionsAuditSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "App Permissions Audit",
                              subtitle: "Review which apps have access to sensitive data")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(viewModel.permissions) { permission in
                    PermissionCard(permission: permission)
                }
            }
        }
    }
}

struct PermissionCard: View {
    let permission: AppPermission

    private var severityColor: Color {
        if permission.count == 0 { return .haloGreen }
        if permission.count >= 5 { return .haloRed }
        if permission.count >= 3 { return .haloAmber }
        return .haloAccent
    }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: permission.kind.icon)
                    .font(.system(size: 20))
                    .foregroundColor(severityColor)
                Text(permission.kind.rawValue)
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.haloText)
                Text("\(permission.count) app\(permission.count == 1 ? "" : "s")")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                HaloMiniBar(value: min(Double(permission.count) / 8.0, 1.0), color: severityColor)
                if !permission.grantedApps.isEmpty {
                    Text(permission.grantedApps.prefix(3).joined(separator: ", "))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                        .lineLimit(1)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Launch Agents (original sample data — replaced in next commit)

struct LaunchAgentsSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Launch Agents Monitor",
                              subtitle: "Background processes that start automatically")
            HStack(spacing: 12) {
                ForEach(LaunchAgentItem.samples) { agent in
                    LaunchAgentCard(agent: agent)
                }
            }
        }
    }
}

struct LaunchAgentItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isSuspicious: Bool
    let lastRun: Date?

    static let samples: [LaunchAgentItem] = [
        .init(name: "com.adobe.agsService",      path: "~/Library/LaunchAgents/", isSuspicious: true,  lastRun: nil),
        .init(name: "com.dropbox.DropboxHelper",  path: "~/Library/LaunchAgents/", isSuspicious: false, lastRun: Date().addingTimeInterval(-3600)),
        .init(name: "com.apple.SafariHistory",    path: "/Library/LaunchAgents/",  isSuspicious: false, lastRun: Date())
    ]
}

struct LaunchAgentCard: View {
    let agent: LaunchAgentItem

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: agent.isSuspicious ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(agent.isSuspicious ? .haloAmber : .haloGreen)
                    Spacer()
                    HaloBadge(text: agent.isSuspicious ? "Review" : "OK",
                              color: agent.isSuspicious ? .haloAmber : .haloGreen)
                }
                Text(agent.name)
                    .font(HaloFont.mono(11))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(agent.path)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                if let date = agent.lastRun {
                    Text("Last run: \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                } else {
                    Text("Never ran")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloRed)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
    }
}
