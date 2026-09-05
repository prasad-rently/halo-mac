import SwiftUI
import Combine

struct ProtectionView: View {
    @StateObject private var viewModel = ProtectionViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProtectionHeader(viewModel: viewModel)
                ScannerCardsRow(viewModel: viewModel)
                SecurityPostureSection(viewModel: viewModel)
                PermissionsAuditSection(viewModel: viewModel)
                LaunchAgentsSection(viewModel: viewModel)
                PrivacyExposureSection(viewModel: viewModel)
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

    // Permissions
    @Published var permissions: [AppPermission] = []

    // Launch Agents — real scan from ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons
    @Published var launchAgents: [RealLaunchAgentItem] = []
    @Published var isLoadingAgents = false

    // Privacy Exposure Scanner (F-018) — find-only, no deletion capability.
    @Published var privacyScanState: PrivacyScanState = .idle
    @Published var privacyFindings: [PrivacyExposureFinding] = []
    @Published var privacyLastScanDate: Date? = nil
    @Published var privacyIncludeICloud: Bool = false
    @Published var privacyCurrentPath: String = ""
    /// Set when the scan stopped at `maxFiles` — the result is a sample, not an
    /// exhaustive answer, and must not be shown as one.
    @Published var privacyScanTruncated = false
    /// Set when the scan could not run at all. Distinct from "finished with no
    /// findings", which is what this used to be reported as.
    @Published var privacyScanError: String?
    // Security Posture (F-019) — read through the shared store so the checklist
    // and the Dashboard health score can never disagree.
    @Published var isLoadingSecurity = false
    var securityChecks: [SecurityCheck] { SecurityPostureStore.shared.checks }
    var securityScore: Int { SecurityPostureStore.shared.score }
    var securityAutomationAvailable: Bool { SecurityPostureStore.shared.automationAvailable }

    private let scanner = ProtectionScanner()
    private let privacyScanner = PrivacyExposureScanner()
    private var privacyScanTask: Task<Void, Never>?

    /// The three `security*` properties above read `SecurityPostureStore.shared`,
    /// which is shared state this view model does not own. Reading it without
    /// subscribing meant the section only repainted for refreshes *it* started —
    /// a refresh from anywhere else (AppState's launch scan today, anything
    /// added later) changed the values under a view that had no reason to
    /// re-render. Forwarding the store's `objectWillChange` is the standard way
    /// to republish a nested `ObservableObject`; SwiftUI re-reads after the
    /// change lands, so the computed properties give fresh values.
    private var securityStoreObserver: AnyCancellable?

    init() {
        securityStoreObserver = SecurityPostureStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    enum ScanState: Equatable {
        case idle, scanning(progress: Double), complete(clean: Bool), found(count: Int)
    }

    /// Separate from `ScanState` because a privacy scan has no known total file count
    /// up front (unlike the malware scan's fixed drop-zone list), so progress is
    /// reported as a running count rather than a percentage.
    enum PrivacyScanState: Equatable {
        case idle
        case scanning(filesScanned: Int)
        case complete(findingsCount: Int)
    }

    var privacyScanStatusText: String {
        switch privacyScanState {
        case .idle: return "Not yet scanned"
        case .scanning(let n): return "Scanning… \(n) file\(n == 1 ? "" : "s") checked"
        case .complete(let n): return n == 0 ? "No exposed sensitive data found" : "\(n) item\(n == 1 ? "" : "s") found"
        }
    }

    var privacyScanStatusColor: Color {
        switch privacyScanState {
        case .idle: return .haloText2
        case .scanning: return .haloAccent
        case .complete(let n): return n == 0 ? .haloGreen : .haloRed
        }
    }

    var privacyFindingsByRisk: [(PrivacyExposureRiskLevel, [PrivacyExposureFinding])] {
        let grouped = Dictionary(grouping: privacyFindings, by: \.riskLevel)
        return PrivacyExposureRiskLevel.allCases.compactMap { risk in
            guard let items = grouped[risk], !items.isEmpty else { return nil }
            let sorted = items.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
            return (risk, sorted)
        }
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
            group.addTask { await self.loadSecurityPosture() }
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

    // MARK: Permissions

    func loadPermissions() async {
        // Per-app TCC grants live in a SIP-protected database that requires Full
        // Disk Access to read, so Halo does not fabricate an audit. Instead each
        // category links straight to its System Settings privacy pane, where the
        // real, authoritative list lives.
        permissions = PermissionKind.allCases.map { AppPermission(kind: $0, grantedApps: []) }
    }

    // MARK: Launch Agents (real scan)

    func loadLaunchAgents() async {
        isLoadingAgents = true
        launchAgents = await scanner.scanLaunchAgents()
        isLoadingAgents = false
    }

    // MARK: Privacy Exposure Scanner (F-018)

    func runPrivacyScan() {
        privacyScanTask?.cancel()
        privacyScanTask = Task {
            privacyScanState = .scanning(filesScanned: 0)
            privacyFindings = []
            privacyCurrentPath = ""

            var locations = PrivacyScanLocation.defaultLocations.map(\.url)
            if privacyIncludeICloud, let icloud = PrivacyScanLocation.iCloudDriveLocation() {
                locations.append(icloud.url)
            }

            for await event in await privacyScanner.scan(locations: locations) {
                if Task.isCancelled { break }
                switch event {
                case .progress(let filesScanned, let currentPath):
                    // Throttled to ~5 Hz. This loop runs on the main actor and
                    // the scanner yields one `.progress` per file examined, so
                    // publishing each one meant ~80,000 objectWillChange
                    // emissions and view invalidations for an 80,000-file
                    // Documents tree — the UI unusable for the duration and the
                    // path label an unreadable blur. The count stays honest; it
                    // just doesn't need publishing at file granularity.
                    let now = Date()
                    if now.timeIntervalSince(lastPrivacyProgressPublish) > 0.2 {
                        lastPrivacyProgressPublish = now
                        privacyScanState = .scanning(filesScanned: filesScanned)
                        privacyCurrentPath = currentPath
                    }
                case .finding(let finding):
                    privacyFindings.append(finding)
                case .completed(_, let findingsCount, let truncated):
                    privacyLastScanDate = Date()
                    privacyScanState = .complete(findingsCount: findingsCount)
                    privacyScanTruncated = truncated
                    privacyCurrentPath = ""
                case .error(let message):
                    // A scan that failed used to be presented as a scan that
                    // finished cleanly — the one thing a security feature can
                    // least afford to get wrong.
                    privacyScanError = message
                    privacyScanState = .idle
                    privacyCurrentPath = ""
                }
            }
        }
    }

    /// Rate-limits the main-actor republish of scan progress.
    private var lastPrivacyProgressPublish = Date.distantPast

    func cancelPrivacyScan() {
        privacyScanTask?.cancel()
        privacyScanTask = nil
    }

    /// Opens Finder with the file selected. This — and nothing else — is the only
    /// action a user can take on a finding. There is deliberately no delete/quarantine
    /// path: v1 is find-only, the user decides what to do next.
    func revealInFinder(_ finding: PrivacyExposureFinding) {
        NSWorkspace.shared.activateFileViewerSelecting([finding.fileURL])
    }

    // MARK: Security Posture (F-019)

    func loadSecurityPosture() async {
        isLoadingSecurity = true
        // No manual `objectWillChange.send()`: the store is observed in `init`,
        // so its own change notification is what repaints this section — and it
        // does so for refreshes started anywhere, not just this one.
        await SecurityPostureStore.shared.refresh()
        isLoadingSecurity = false
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

// MARK: - Permissions Audit

struct PermissionsAuditSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "App Permissions",
                              subtitle: "Open a category to review which apps have access, in System Settings")
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
    }
}

// MARK: - Security Posture (F-019)

struct SecurityPostureSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    private var scoreColor: Color {
        switch viewModel.securityScore {
        case 80...100: return .haloGreen
        case 50..<80:  return .haloAmber
        default:       return .haloRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HaloSectionHeader(
                    title: "Security Posture",
                    subtitle: "Read-only checks of key macOS security settings"
                )
                Spacer()
                if viewModel.isLoadingSecurity {
                    ProgressView().scaleEffect(0.6).tint(.haloAccent)
                } else {
                    HStack(spacing: 6) {
                        // Only the badge is gated on having checks. Refresh was
                        // gated on the same condition, so an empty result — the
                        // one state where you most need to re-run — left no way
                        // to do it.
                        if !viewModel.securityChecks.isEmpty {
                            HaloBadge(text: "\(viewModel.securityScore)/100", color: scoreColor)
                                .accessibilityIdentifier("protection.securityPosture.score")
                        }
                        Button {
                            Task { await viewModel.loadSecurityPosture() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(.haloText2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("protection.securityPosture.refresh")
                    }
                }
            }

            if viewModel.isLoadingSecurity {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8).tint(.haloAccent)
                    Text("Checking security settings…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.haloSurface2)
                .cornerRadius(12)
            } else {
                // Under the App Sandbox every automated check degrades to
                // "unknown" and the score sits at a permanent 100/100. Saying so
                // is the honest thing — eight silent "unknown"s otherwise read as
                // "this Mac can't be verified" rather than "Halo wasn't allowed
                // to look".
                if !viewModel.securityAutomationAvailable {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.slash")
                            .font(.system(size: 12))
                            .foregroundColor(.haloAmber)
                        Text("This build can't read your security settings automatically, so every row below needs checking by hand and the score isn't meaningful.")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                    .accessibilityIdentifier("protection.securityPosture.sandboxNotice")
                }

                LazyVStack(spacing: 6) {
                    ForEach(viewModel.securityChecks) { check in
                        SecurityCheckRow(check: check)
                    }
                }
                .accessibilityIdentifier("protection.securityPosture.list")
            }
        }
    }
}

struct SecurityCheckRow: View {
    let check: SecurityCheck

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: check.kind.icon)
                .font(.system(size: 14))
                .foregroundColor(.haloAccent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.kind.rawValue)
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText)
                Text(check.detail)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
            }

            Spacer()

            Image(systemName: check.state.icon)
                .font(.system(size: 14))
                .foregroundColor(check.state.color)
                .accessibilityIdentifier("protection.securityPosture.check.\(check.kind.idSlug).state")

            if let url = check.kind.settingsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
                .help("Open in System Settings")
                .accessibilityIdentifier("protection.securityPosture.check.\(check.kind.idSlug).fix")
            }
        }
        .padding(12)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .accessibilityIdentifier("protection.securityPosture.check.\(check.kind.idSlug)")
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

// MARK: - Privacy Exposure Scanner (F-018)

struct PrivacyExposureSection: View {
    @ObservedObject var viewModel: ProtectionViewModel

    private var isScanning: Bool {
        if case .scanning = viewModel.privacyScanState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HaloSectionHeader(
                    title: "Sensitive Data Scanner",
                    subtitle: "Scans Downloads, Documents, and Desktop for exposed credit card numbers, API keys, SSH private keys, and SSNs — find-only, nothing is ever deleted"
                )
                Spacer()
                if let date = viewModel.privacyLastScanDate {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Last scan")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                        Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                            .font(HaloFont.body(10, weight: .medium))
                            .foregroundColor(.haloText2)
                    }
                }
            }

            HaloCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.privacyIncludeICloud) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include iCloud Drive")
                                .font(HaloFont.body(12, weight: .medium))
                                .foregroundColor(.haloText)
                            Text("Off by default — Downloads, Documents, and Desktop are scanned either way.")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isScanning)
                    .accessibilityIdentifier("protection.privacyscan.icloudToggle")

                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.privacyScanStatusColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: viewModel.privacyScanStatusColor.opacity(0.5), radius: 3)
                        Text(viewModel.privacyScanStatusText)
                            .font(HaloFont.body(12))
                            .foregroundColor(viewModel.privacyScanStatusColor)
                    }
                    .accessibilityIdentifier("protection.privacyscan.status")

                    if isScanning, !viewModel.privacyCurrentPath.isEmpty {
                        Text(viewModel.privacyCurrentPath)
                            .font(HaloFont.mono(10))
                            .foregroundColor(.haloText3)
                            .lineLimit(1)
                    }

                    HaloPrimaryButton(
                        isScanning ? "Scanning…" : "Run Sensitive Data Scan",
                        icon: "magnifyingglass.circle.fill",
                        isLoading: isScanning
                    ) { viewModel.runPrivacyScan() }
                    .accessibilityIdentifier("protection.privacyscan.button")
                }
                .padding(20)
            }

            if !viewModel.privacyFindings.isEmpty {
                VStack(spacing: 14) {
                    ForEach(viewModel.privacyFindingsByRisk, id: \.0) { risk, findings in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                HaloBadge(text: risk.rawValue, color: risk.color)
                                Text("\(findings.count) item\(findings.count == 1 ? "" : "s")")
                                    .font(HaloFont.body(11))
                                    .foregroundColor(.haloText3)
                            }
                            LazyVStack(spacing: 6) {
                                ForEach(findings) { finding in
                                    PrivacyFindingRow(finding: finding) {
                                        viewModel.revealInFinder(finding)
                                    }
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("protection.privacyscan.findings.list")
            } else if case .complete(let count) = viewModel.privacyScanState, count == 0 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.haloGreen)
                    Text("No exposed sensitive data found in the scanned locations.")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.haloSurface2)
                .cornerRadius(12)
                .accessibilityIdentifier("protection.privacyscan.emptyState")
            }
        }
    }
}

struct PrivacyFindingRow: View {
    let finding: PrivacyExposureFinding
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: finding.category.icon)
                .font(.system(size: 14))
                .foregroundColor(finding.riskLevel.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.fileName)
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloText)
                        .lineLimit(1)
                    Text(finding.category.rawValue)
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
                Text(finding.redactedPreview)
                    .font(HaloFont.mono(11))
                    .foregroundColor(finding.riskLevel.color)
                    .lineLimit(1)
                Text(finding.displayPath)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let date = finding.modifiedDate {
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
                Button(action: onReveal) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                        Text("Reveal in Finder")
                            .font(HaloFont.body(10, weight: .semibold))
                    }
                    .foregroundColor(.haloAccent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("protection.privacyscan.reveal.\(finding.id)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(finding.riskLevel.color.opacity(0.25), lineWidth: 1))
        .accessibilityIdentifier("protection.privacyscan.row.\(finding.id)")
    }
}
