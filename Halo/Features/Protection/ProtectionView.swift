import SwiftUI

struct ProtectionView: View {
    @StateObject private var viewModel = ProtectionViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProtectionHeader(viewModel: viewModel)
                ScannerCardsRow(viewModel: viewModel)
                PermissionsAuditSection(viewModel: viewModel)
                BrowserPrivacySection(viewModel: viewModel)
            }
            .padding(28)
        }
        .background(Color.haloSurface)
        .task { await viewModel.loadPermissions() }
    }
}

// MARK: - ViewModel

@MainActor
final class ProtectionViewModel: ObservableObject {
    @Published var scanState: ScanState = .idle
    @Published var threatsFound: [MalwareThreat] = []
    @Published var permissions: [AppPermission] = []
    @Published var lastScanDate: Date? = nil
    @Published var isClearingBrowser = false
    @Published var signatureDBDate: Date? = Date().addingTimeInterval(-86400 * 3)

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

    func runMalwareScan() async {
        scanState = .scanning(progress: 0)
        // Simulate scan progress
        for i in 1...20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            scanState = .scanning(progress: Double(i) / 20.0)
        }
        lastScanDate = Date()
        // In production: scan against bundled SignatureDatabase
        scanState = .complete(clean: true)
    }

    func loadPermissions() async {
        // In production: read TCC.db with Full Disk Access
        permissions = PermissionKind.allCases.map { kind in
            AppPermission(kind: kind, grantedApps: sampleApps(for: kind))
        }
    }

    private func sampleApps(for kind: PermissionKind) -> [String] {
        switch kind {
        case .camera: return ["Zoom", "FaceTime", "Slack", "Teams"]
        case .microphone: return ["Zoom", "Spotify", "Discord", "Teams", "FaceTime", "Voice Memos"]
        case .location: return ["Maps", "Weather"]
        case .contacts: return ["Mimestream", "Cardhop", "Zoom"]
        case .calendar: return ["Fantastical", "Zoom"]
        case .fullDisk: return ["Halo"]
        case .screenRecording: return ["Zoom", "CleanShot X", "Loom"]
        case .accessibility: return ["Raycast", "BetterTouchTool"]
        }
    }

    func quarantineThreat(_ threat: MalwareThreat) {
        if let idx = threatsFound.firstIndex(where: { $0.id == threat.id }) {
            threatsFound[idx].isQuarantined = true
        }
    }

    func clearBrowserData() async {
        isClearingBrowser = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        isClearingBrowser = false
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

struct MalwareScanCard: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: "#1c3a2a"), Color(hex: "#1a4030")],
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

                Text("Scans for adware, keyloggers, PUPs & browser hijackers using a local signature database.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.scanStatusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: viewModel.scanStatusColor.opacity(0.5), radius: 3)
                    Text(viewModel.scanStatusText)
                        .font(HaloFont.body(12))
                        .foregroundColor(viewModel.scanStatusColor)
                }

                // Scan progress bar
                if case .scanning(let p) = viewModel.scanState {
                    VStack(spacing: 4) {
                        HaloMiniBar(value: p, color: .haloAccent)
                        Text("Scanning system files…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }

                HaloPrimaryButton(
                    viewModel.scanState == .scanning(progress: 0) ? "Scanning…" : "Run Full Scan",
                    icon: "shield.lefthalf.filled",
                    isLoading: {
                        if case .scanning = viewModel.scanState { return true }
                        return false
                    }()
                ) {
                    Task { await viewModel.runMalwareScan() }
                }
            }
            .padding(20)
        }
    }
}

struct PrivacyCleanerCard: View {
    @ObservedObject var viewModel: ProtectionViewModel

    let browsers: [(name: String, icon: String, hasData: Bool)] = [
        ("Safari", "safari", true),
        ("Chrome", "globe", true),
        ("Firefox", "flame.fill", true),
        ("Arc", "arc.circle", false)
    ]

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: "#3a1a10"), Color(hex: "#4a2008")],
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

                Text("Clear browsing history, cookies, autofill, and cached data across all major browsers.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Browser status rows
                VStack(spacing: 6) {
                    ForEach(browsers, id: \.name) { browser in
                        HStack(spacing: 8) {
                            Image(systemName: browser.icon)
                                .font(.system(size: 12))
                                .foregroundColor(.haloText2)
                                .frame(width: 18)
                            Text(browser.name)
                                .font(HaloFont.body(12))
                                .foregroundColor(.haloText)
                            Spacer()
                            if browser.hasData {
                                HaloBadge(text: "Has data", color: .haloAmber)
                            } else {
                                HaloBadge(text: "Clean", color: .haloGreen)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.haloSurface)
                        .cornerRadius(8)
                    }
                }

                HaloPrimaryButton("Review & Clear", icon: "trash.fill", isLoading: viewModel.isClearingBrowser) {
                    Task { await viewModel.clearBrowserData() }
                }
            }
            .padding(20)
        }
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

// MARK: - Browser Privacy

struct BrowserPrivacySection: View {
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
        .init(name: "com.adobe.agsService", path: "~/Library/LaunchAgents/", isSuspicious: true, lastRun: nil),
        .init(name: "com.dropbox.DropboxHelper", path: "~/Library/LaunchAgents/", isSuspicious: false, lastRun: Date().addingTimeInterval(-3600)),
        .init(name: "com.apple.SafariHistory", path: "/Library/LaunchAgents/", isSuspicious: false, lastRun: Date())
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
