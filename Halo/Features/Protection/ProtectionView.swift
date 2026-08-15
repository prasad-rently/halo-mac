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
    @Published var signatureDBDate: Date? = nil   // real date loaded from SignatureDatabase

    // Privacy Cleaner
    @Published var installedBrowsers: [DetectedBrowser] = []
    @Published var browserDataSizes: [UUID: Int64] = [:]
    @Published var isLoadingBrowsers = false
    @Published var showBrowserReviewSheet = false
    @Published var selectedBrowsersForClear: Set<UUID> = []
    @Published var isClearingBrowser = false
    @Published var clearBrowserError: String? = nil

    // Permissions (F-016)
    @Published var permissions: [AppPermission] = []
    @Published var permissionAudit: PermissionAuditResult = .unavailable(reason: "Not yet checked")
    @Published var isLoadingPermissions = false

    // Launch Agents — real scan from ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons
    @Published var launchAgents: [RealLaunchAgentItem] = []
    @Published var isLoadingAgents = false

    private let scanner = ProtectionScanner()
    private let permissionAuditor = PermissionAuditor()

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
        // Real signature-definitions date from the loaded database.
        signatureDBDate = await SignatureDatabase.shared.lastUpdatedDate
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPermissions() }
            group.addTask { await self.loadInstalledBrowsers() }
            group.addTask { await self.loadLaunchAgents() }
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

    // MARK: Browser Privacy

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
        var sizes: [UUID: Int64] = [:]
        for b in installedBrowsers { sizes[b.id] = await scanner.dataSize(for: b) }
        browserDataSizes = sizes
        isClearingBrowser = false
        showBrowserReviewSheet = false
    }

    // MARK: Permissions (F-016)

    func loadPermissions() async {
        // Per-app TCC grants live in a SIP-protected database that requires Full
        // Disk Access to read. `PermissionAuditor` attempts the real read first;
        // when it can't (sandboxed release build, no Full Disk Access, locked
        // database), Halo does not fabricate an audit — it honestly falls back
        // to category cards that link straight to System Settings, where the
        // real, authoritative list lives.
        isLoadingPermissions = true
        permissions = PermissionKind.allCases.map { AppPermission(kind: $0, grantedApps: []) }

        let result = await permissionAuditor.run()
        permissionAudit = result

        if case .available(let grants) = result {
            var grouped: [PermissionKind: [String]] = [:]
            for grant in grants { grouped[grant.kind, default: []].append(grant.appName) }
            permissions = PermissionKind.allCases.map { AppPermission(kind: $0, grantedApps: grouped[$0] ?? []) }
        }
        isLoadingPermissions = false
    }

    // MARK: Launch Agents (real scan)

    func loadLaunchAgents() async {
        isLoadingAgents = true
        launchAgents = await scanner.scanLaunchAgents()
        isLoadingAgents = false
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
        HStack(alignment: .top, spacing: 16) {
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
                .accessibilityIdentifier("protection.scan.button")
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

// MARK: - Privacy Cleaner Card

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

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundColor(.haloAmber)
                Text("Close all browsers before clearing to avoid data corruption.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.haloAmber.opacity(0.08))

            Divider().background(Color.haloBorder)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(viewModel.installedBrowsers) { browser in
                        let isSelected = viewModel.selectedBrowsersForClear.contains(browser.id)
                        HStack(spacing: 12) {
                            Button {
                                if isSelected { viewModel.selectedBrowsersForClear.remove(browser.id) }
                                else { viewModel.selectedBrowsersForClear.insert(browser.id) }
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

            if let err = viewModel.clearBrowserError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloAmber)
                    Text(err).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(2)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.haloAmber.opacity(0.08))
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(HaloFont.body(13)).foregroundColor(.haloText2).buttonStyle(.plain)
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
                        ? Color.haloRed.opacity(0.4) : Color.haloRed)
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

// MARK: - Permissions Audit (F-016)

struct PermissionsAuditSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    private var totalAuditedApps: Int {
        guard case .available(let grants) = viewModel.permissionAudit else { return 0 }
        return Set(grants.map(\.bundleID)).count
    }

    private var excessiveAppCount: Int {
        guard case .available(let grants) = viewModel.permissionAudit else { return 0 }
        return Set(grants.filter(\.isElevatedRisk).map(\.bundleID)).count
    }

    private var subtitle: String {
        if case .available = viewModel.permissionAudit {
            return "Real per-app grants read from this Mac's permission database"
        }
        return "Open a category to review which apps have access, in System Settings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HaloSectionHeader(title: "App Permissions", subtitle: subtitle)
                Spacer()
                if viewModel.isLoadingPermissions {
                    ProgressView().scaleEffect(0.6).tint(.haloAccent)
                } else if case .available = viewModel.permissionAudit {
                    HaloBadge(
                        text: "\(excessiveAppCount) of \(totalAuditedApps) apps excessive",
                        color: excessiveAppCount > 0 ? .haloAmber : .haloGreen
                    )
                    .accessibilityIdentifier("protection.permissions.summary")
                }
            }

            switch viewModel.permissionAudit {
            case .available(let grants):
                PermissionAuditList(grants: grants)

            case .unavailable(let reason):
                FullDiskAccessBanner(reason: reason)
                    .accessibilityIdentifier("protection.permissions.banner")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(viewModel.permissions) { permission in
                        PermissionCard(permission: permission)
                    }
                }
            }
        }
    }
}

struct FullDiskAccessBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.haloAmber)
            Text(reason)
                .font(HaloFont.body(12))
                .foregroundColor(.haloText)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haloAmber.opacity(0.08))
        .cornerRadius(10)
    }
}

/// Per-app grants grouped by `PermissionKind`, each group expandable.
struct PermissionAuditList: View {
    let grants: [TCCGrant]
    @State private var expanded: Set<PermissionKind> = []

    private var groups: [(kind: PermissionKind, grants: [TCCGrant])] {
        PermissionKind.allCases.compactMap { kind in
            let matches = grants.filter { $0.kind == kind }.sorted { $0.appName < $1.appName }
            return matches.isEmpty ? nil : (kind, matches)
        }
    }

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(groups, id: \.kind) { group in
                PermissionGroupRow(
                    kind: group.kind,
                    grants: group.grants,
                    isExpanded: expanded.contains(group.kind)
                ) {
                    if expanded.contains(group.kind) { expanded.remove(group.kind) }
                    else { expanded.insert(group.kind) }
                }
            }
        }
    }
}

struct PermissionGroupRow: View {
    let kind: PermissionKind
    let grants: [TCCGrant]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var riskCount: Int { grants.filter(\.isElevatedRisk).count }

    /// Stable slug for this kind, used to build `protection.permissions.*`
    /// accessibility identifiers (e.g. "Screen Recording" → "screenrecording").
    private var slug: String {
        kind.rawValue.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// System Settings privacy-pane anchor for this permission kind — same
    /// mapping `PermissionCard` uses for its deep link.
    private var settingsURL: URL? {
        let anchor: String
        switch kind {
        case .camera:          anchor = "Privacy_Camera"
        case .microphone:      anchor = "Privacy_Microphone"
        case .location:        anchor = "Privacy_LocationServices"
        case .contacts:        anchor = "Privacy_Contacts"
        case .calendar:        anchor = "Privacy_Calendars"
        case .fullDisk:        anchor = "Privacy_AllFiles"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility:   anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.haloAccent)
                        .frame(width: 20)
                    Text(kind.rawValue)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Spacer()
                    if riskCount > 0 {
                        HaloBadge(text: "\(riskCount) elevated", color: .haloAmber)
                    }
                    Text("\(grants.count) app\(grants.count == 1 ? "" : "s")")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.haloText3)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protection.permissions.row.\(slug)")

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(grants) { grant in
                        HStack(spacing: 8) {
                            Image(systemName: grant.isElevatedRisk
                                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(grant.isElevatedRisk ? .haloAmber : .haloGreen)
                                .frame(width: 16)
                            Text(grant.appName)
                                .font(HaloFont.body(12))
                                .foregroundColor(.haloText)
                                .lineLimit(1)
                            if grant.isElevatedRisk {
                                Text("excessive for this app")
                                    .font(HaloFont.body(10))
                                    .foregroundColor(.haloAmber)
                            }
                            Spacer()
                            Button {
                                if let url = settingsURL { NSWorkspace.shared.open(url) }
                            } label: {
                                HStack(spacing: 3) {
                                    Text("Revoke")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .font(HaloFont.body(10, weight: .semibold))
                                .foregroundColor(.haloRed)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("protection.permissions.revoke.\(slug)")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(riskCount > 0 ? Color.haloAmber.opacity(0.3) : Color.haloBorder, lineWidth: 1))
    }
}

struct PermissionCard: View {
    let permission: AppPermission

    /// System Settings privacy-pane anchor for this permission kind.
    private var settingsURL: URL? {
        let anchor: String
        switch permission.kind {
        case .camera:          anchor = "Privacy_Camera"
        case .microphone:      anchor = "Privacy_Microphone"
        case .location:        anchor = "Privacy_LocationServices"
        case .contacts:        anchor = "Privacy_Contacts"
        case .calendar:        anchor = "Privacy_Calendars"
        case .fullDisk:        anchor = "Privacy_AllFiles"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility:   anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var body: some View {
        Button {
            if let url = settingsURL { NSWorkspace.shared.open(url) }
        } label: {
            HaloCard {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: permission.kind.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.haloAccent)
                    Text(permission.kind.rawValue)
                        .font(HaloFont.body(12, weight: .semibold))
                        .foregroundColor(.haloText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text("Open in Settings")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText2)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.haloText3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 96, alignment: .topLeading)
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "protection.permissions.card.\(permission.kind.rawValue.replacingOccurrences(of: " ", with: "").lowercased())"
        )
    }
}

// MARK: - Launch Agents Monitor (real plist scan)

struct LaunchAgentsSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    private var suspiciousCount: Int { viewModel.launchAgents.filter(\.isSuspicious).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HaloSectionHeader(
                    title: "Launch Agents Monitor",
                    subtitle: "Background processes found in ~/Library/LaunchAgents and /Library/LaunchAgents"
                )
                Spacer()
                if viewModel.isLoadingAgents {
                    ProgressView().scaleEffect(0.6).tint(.haloAccent)
                } else if !viewModel.launchAgents.isEmpty {
                    HStack(spacing: 6) {
                        if suspiciousCount > 0 {
                            HaloBadge(text: "\(suspiciousCount) suspicious", color: .haloAmber)
                        }
                        HaloBadge(text: "\(viewModel.launchAgents.count) total", color: .haloAccent)
                        Button {
                            Task { await viewModel.loadLaunchAgents() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(.haloText2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.isLoadingAgents {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8).tint(.haloAccent)
                    Text("Scanning launch agents…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.haloSurface2)
                .cornerRadius(12)
            } else if viewModel.launchAgents.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.haloGreen)
                    Text("No launch agents found in user or system directories.")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.haloSurface2)
                .cornerRadius(12)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.launchAgents) { agent in
                        LaunchAgentRow(agent: agent)
                    }
                }
            }
        }
    }
}

struct LaunchAgentRow: View {
    let agent: RealLaunchAgentItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.isSuspicious
                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(agent.isSuspicious ? .haloAmber : .haloGreen)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label)
                    .font(HaloFont.mono(12))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(agent.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~")
                        .replacingOccurrences(of: "/" + agent.label + ".plist", with: ""))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                        .lineLimit(1)
                    if !agent.program.isEmpty {
                        Text("→ " + agent.program
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(HaloFont.mono(10))
                            .foregroundColor(.haloText3)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                HaloBadge(
                    text: agent.isSuspicious ? "Review" : agent.scope,
                    color: agent.isSuspicious ? .haloAmber : .haloAccent.opacity(0.7)
                )
                if let date = agent.lastModified {
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(agent.isSuspicious ? Color.haloAmber.opacity(0.06) : Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(agent.isSuspicious ? Color.haloAmber.opacity(0.3) : Color.haloBorder,
                    lineWidth: 1))
    }
}
