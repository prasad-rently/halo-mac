import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                DashHeader()
                HealthAndMetrics()
                GPUDashboardCard()            // F-001: GPU utilisation + memory
                NetworkSparklineCard()        // P3-10: bandwidth history
                BackupHealthCard()            // F-022: Time Machine backup health
                QuickActionsGrid()
                AlertHistorySection()          // F-011: system alert history log
                RecentActivityList()
            }
            .padding(28)
        }
        .background(Color.haloSurface)
    }
}

// MARK: - Header

struct DashHeader: View {
    @EnvironmentObject var appState: AppState
    @State private var isExportingReport = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"   // incl. late night
        }
    }

    /// Emoji that matches the time of day, using the same ranges as `greeting`
    /// so the two never contradict (was a fixed ☀️ even at night).
    private var greetingEmoji: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "☀️"
        case 12..<17: return "🌤️"
        case 17..<22: return "🌆"
        default:      return "🌙"   // late night
        }
    }

    private var lastScanText: String {
        guard let date = appState.lastSmartScanDate else { return "Never scanned" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last scan \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var nextScanText: String {
        guard let next = ScanScheduler.shared.nextFireDate else { return "" }
        let interval = next.timeIntervalSinceNow
        if interval > 24 * 3600 {
            let df = DateFormatter()
            df.dateFormat = "EEEE 'at' h:mm a"
            return " · Next: \(df.string(from: next))"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return " · Next: \(formatter.localizedString(for: next, relativeTo: Date()))"
        }
    }

    private var statusLabel: String {
        if appState.isSmartScanRunning { return "Scanning your Mac…" }
        if appState.systemHealthScore >= 75 { return "Your Mac is in great shape." }
        if appState.systemHealthScore >= 50 { return "A few things need attention." }
        return "Issues detected — run a Smart Scan."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left: greeting + status line
            VStack(alignment: .leading, spacing: 4) {
                Text("\(greeting) \(greetingEmoji)")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text(lastScanText + nextScanText)
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                Text(statusLabel)
                    .font(HaloFont.body(12))
                    .foregroundColor(
                        appState.isSmartScanRunning ? .haloAccent
                        : appState.systemHealthScore >= 75 ? .haloGreen
                        : appState.systemHealthScore >= 50 ? .haloAmber : .haloRed
                    )
            }

            Spacer()

            // Right: actions stacked vertically — Smart Scan primary, Export secondary
            VStack(alignment: .trailing, spacing: 8) {
                // Smart Scan button
                HaloPrimaryButton(
                    appState.isSmartScanRunning ? "Scanning…" : "Smart Scan",
                    icon: appState.isSmartScanRunning ? nil : "play.fill",
                    isLoading: appState.isSmartScanRunning
                ) {
                    Task { await appState.runSmartScan() }
                }
                .disabled(appState.isSmartScanRunning)
                .accessibilityIdentifier("dashboard.smartScan.button")

                // Export Report — off-thread PDF generation so UI never freezes
                Button {
                    guard !isExportingReport else { return }
                    isExportingReport = true
                    let snapshot = ReportSnapshot.capture(from: appState)
                    Task.detached(priority: .userInitiated) {
                        let doc = ReportGenerator.shared.generate(snapshot: snapshot)
                        await MainActor.run {
                            ReportGenerator.presentSavePanel(document: doc)
                            isExportingReport = false
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isExportingReport {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 11))
                        }
                        Text(isExportingReport ? "Generating…" : "Export Report")
                            .font(HaloFont.body(12))
                    }
                    .foregroundColor(.haloText2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.haloSurface2)
                    .cornerRadius(9)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.haloBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExportingReport)
                .accessibilityIdentifier("dashboard.exportReport.button")
            }
        }
    }
}

// MARK: - Health + Metrics

struct HealthAndMetrics: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            // Health Ring Card
            HaloCard {
                VStack(spacing: 12) {
                    HaloHealthRing(score: appState.systemHealthScore, size: 120)
                    HStack(spacing: 4) {
                        // 3-tier color that matches HaloHealthRing (green ≥75, amber ≥50, red below).
                        let healthColor: Color = appState.systemHealthScore >= 75 ? .haloGreen
                            : appState.systemHealthScore >= 50 ? .haloAmber : .haloRed
                        Circle()
                            .fill(healthColor)
                            .frame(width: 6, height: 6)
                        Text(appState.systemHealthScore >= 75 ? "Good Shape"
                             : appState.systemHealthScore >= 50 ? "Needs Attention" : "Issues Found")
                            .font(HaloFont.body(12, weight: .medium))
                            .foregroundColor(healthColor)
                    }
                }
                .padding(20)
            }
            .frame(width: 190)

            // 3 Metric Cards
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    MetricCard(
                        label: "CPU Usage",
                        value: String(format: "%.0f", appState.cpuUsage * 100),
                        unit: "%",
                        ratio: appState.cpuUsage,
                        color: .haloAccent,
                        icon: "cpu"
                    )
                    MetricCard(
                        label: "RAM Used",
                        value: String(format: "%.1f", appState.ramUsedGB),
                        unit: "GB",
                        subtitle: String(format: "of %.0f GB", appState.ramTotalGB),
                        ratio: appState.ramUsage,
                        color: .haloPurple,
                        icon: "memorychip"
                    )
                    MetricCard(
                        label: "Disk Free",
                        value: String(format: "%.0f", appState.diskFreeGB),
                        unit: "GB",
                        ratio: 1 - (appState.diskTotalGB > 0 ? (appState.diskTotalGB - appState.diskFreeGB) / appState.diskTotalGB : 0),
                        color: .haloGreen,
                        icon: "internaldrive"
                    )
                }
                HStack(spacing: 12) {
                    MetricCard(
                        label: "Battery",
                        value: "\(appState.batteryPercent)",
                        unit: "%",
                        subtitle: appState.batteryTimeRemaining.isEmpty ? nil : appState.batteryTimeRemaining + " left",
                        ratio: Double(appState.batteryPercent) / 100,
                        color: .haloGreen,
                        icon: "battery.100"
                    )
                    MetricCard(
                        label: "Upload",
                        value: String(format: "%.1f", appState.networkUpMBps),
                        unit: "MB/s",
                        ratio: min(appState.networkUpMBps / 10, 1),
                        color: .haloCyan,
                        icon: "arrow.up.circle"
                    )
                    MetricCard(
                        label: "Download",
                        value: String(format: "%.1f", appState.networkDownMBps),
                        unit: "MB/s",
                        ratio: min(appState.networkDownMBps / 50, 1),
                        color: .haloAmber,
                        icon: "arrow.down.circle"
                    )
                }
            }
        }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    var subtitle: String? = nil
    let ratio: Double
    let color: Color
    let icon: String

    var body: some View {
        HaloCard(accentTop: color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(color)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(HaloFont.display(24, weight: .bold))
                        .foregroundColor(color)
                    Text(unit)
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                }
                if let sub = subtitle {
                    Text(sub)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                } else {
                    Text(label)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                // Real current-value bar (was a random, fake sparkline).
                HaloMiniBar(value: ratio, color: color)
                    .padding(.top, 2)
            }
            .padding(14)
        }
    }
}

// MARK: - Quick Actions

struct QuickActionsGrid: View {
    @EnvironmentObject var appState: AppState

    // System Junk: use real totalCleanableBytes from last cleanup scan or Smart Scan
    private var junkMeta: String {
        let bytes = appState.totalCleanableBytes
        guard bytes > 0 else {
            return appState.lastSmartScanDate != nil ? "Clean ✓" : "Tap to scan"
        }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) found"
    }

    // Duplicates: derived from Smart Scan category results if available
    private var duplicatesMeta: String {
        guard let result = appState.smartScanResult else { return "Tap to detect" }
        // Sum bytes from categories that imply redundant data (caches are a proxy)
        let wastedBytes = result.totalBytes
        guard wastedBytes > 0 else { return "None found" }
        return "\(ByteCountFormatter.string(fromByteCount: wastedBytes, countStyle: .file)) potential"
    }

    // App Ghosts: count cleanup categories that found items as a proxy for leftover presence
    private var ghostsMeta: String {
        guard appState.smartScanResult != nil else { return "Tap to detect" }
        let count = appState.cleanupCategories.filter { $0.allBytes > 0 }.count
        guard count > 0 else { return "None found" }
        return "\(count) categories"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Quick Actions")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                QuickActionCard(
                    icon: "sparkles",
                    title: "System Junk",
                    meta: junkMeta,
                    color: .haloAccent,
                    isHighlighted: appState.totalCleanableBytes > 0
                ) {
                    appState.selectedModule = .cleanup
                }
                QuickActionCard(
                    icon: "doc.on.clipboard.fill",
                    title: "Clipboard",
                    meta: "\(appState.clipboardItems.count) items",
                    color: .haloAmber
                ) {
                    appState.selectedModule = .clipboard
                }
                QuickActionCard(
                    icon: "doc.on.doc.fill",
                    title: "Duplicates",
                    meta: duplicatesMeta,
                    color: .haloPurple
                ) {
                    appState.selectedModule = .files
                }
                QuickActionCard(
                    icon: "trash.fill",
                    title: "App Ghosts",
                    meta: ghostsMeta,
                    color: .haloRed
                ) {
                    appState.selectedModule = .applications
                }
            }
        }
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let meta: String
    let color: Color
    var isHighlighted: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(color)
                Text(title)
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.haloText)
                Text(meta)
                    .font(HaloFont.body(11))
                    .foregroundColor(isHighlighted ? color : .haloText2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.haloSurface2)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovered ? color.opacity(0.4)
                        : isHighlighted ? color.opacity(0.25)
                        : Color.haloBorder,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent Activity

struct RecentActivityList: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Recent Activity",
                              action: { appState.recentActivities.removeAll() },
                              actionLabel: "Clear")
            VStack(spacing: 6) {
                ForEach(appState.recentActivities.prefix(5)) { event in
                    ActivityRow(event: event)
                }
                if appState.recentActivities.isEmpty {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.haloText3)
                        Text("No activity yet — run a Smart Scan to get started")
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                }
            }
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(event.kind.color)
                .frame(width: 8, height: 8)
                .shadow(color: event.kind.color.opacity(0.5), radius: 3)
            Text(event.message)
                .font(HaloFont.body(12))
                .foregroundColor(.haloText)
            Spacer()
            Text(event.dateFormatted)
                .font(HaloFont.body(11))
                .foregroundColor(.haloText2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Alert History Section (F-011)

struct AlertHistorySection: View {
    @StateObject private var alertLog = AlertLog.shared
    @State private var isExpanded = true

    var body: some View {
        // Same structure as RecentActivityList: a plain section (no card) with a
        // header and haloSurface2 pill rows, so both dashboard lists match.
        VStack(alignment: .leading, spacing: 12) {
            // Header — the title/chevron toggle and the "Clear" button are
            // siblings (not nested), so each gets its own clean hit target.
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.haloAmber)
                        Text("Alert History")
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        if alertLog.unreadCount > 0 {
                            Text("\(alertLog.unreadCount)")
                                .font(HaloFont.body(10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.haloRed)
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dashboard.alertHistory")
                Spacer()
                if !alertLog.entries.isEmpty {
                    Button("Clear") { alertLog.clearAll() }
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                        .buttonStyle(.plain)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText2)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                if alertLog.entries.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.haloText3)
                        Text("No alerts yet — your Mac looks great.")
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText2)
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                } else {
                    VStack(spacing: 6) {
                        ForEach(alertLog.entries.prefix(8)) { entry in
                            AlertEntryRow(entry: entry)
                                .onTapGesture { alertLog.markRead(entry) }
                        }
                        if alertLog.entries.count > 8 {
                            Button("Mark all as read · \(alertLog.entries.count) total") {
                                alertLog.markAllRead()
                            }
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloAccent)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }
}

struct AlertEntryRow: View {
    let entry: AlertEntry

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(entry.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: entry.icon)
                    .font(.system(size: 11))
                    .foregroundColor(entry.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(HaloFont.body(12, weight: entry.isRead ? .regular : .semibold))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(entry.body)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()))
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText2)
                if !entry.isRead {
                    Circle()
                        .fill(Color.haloAccent)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
        .opacity(entry.isRead ? 0.65 : 1.0)
    }
}
