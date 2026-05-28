import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                DashHeader(isScanning: $isScanning)
                HealthAndMetrics()
                GPUDashboardCard()            // F-001: GPU utilisation + memory
                NetworkSparklineCard()        // P3-10: bandwidth history
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
    @Binding var isScanning: Bool

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var lastScanText: String {
        guard let date = appState.lastSmartScanDate else { return "Never scanned" }
        let formatter = RelativeDateTimeFormatter()
        return "Last scan \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var nextScanText: String {
        guard let next = ScanScheduler.shared.nextFireDate else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return " · Next: \(formatter.localizedString(for: next, relativeTo: Date()))"
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(greeting) ☀️")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text(lastScanText + nextScanText + " · Your Mac is in good shape.")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            HaloPrimaryButton("Smart Scan", icon: "play.fill", isLoading: appState.isSmartScanRunning) {
                Task { await appState.runSmartScan() }
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
                        Circle()
                            .fill(appState.systemHealthScore >= 75 ? Color.haloGreen : Color.haloAmber)
                            .frame(width: 6, height: 6)
                        Text(appState.systemHealthScore >= 75 ? "Good Shape"
                             : appState.systemHealthScore >= 50 ? "Needs Attention" : "Issues Found")
                            .font(HaloFont.body(12, weight: .medium))
                            .foregroundColor(appState.systemHealthScore >= 75 ? .haloGreen : .haloAmber)
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

    @State private var sparkData: [Double] = (0..<6).map { _ in Double.random(in: 0.2...0.9) }

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
                HaloSparkline(values: sparkData + [ratio], color: color, height: 30)
                    .onAppear {
                        sparkData = (0..<6).map { _ in Double.random(in: 0.2...0.9) }
                    }
            }
            .padding(14)
        }
    }
}

// MARK: - Quick Actions

struct QuickActionsGrid: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Quick Actions")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                QuickActionCard(icon: "sparkles", title: "System Junk",
                                meta: "2.1 GB found", color: .haloAccent) {
                    appState.selectedModule = .cleanup
                }
                QuickActionCard(icon: "doc.on.clipboard.fill", title: "Clipboard",
                                meta: "\(appState.clipboardItems.count) items", color: .haloAmber) {
                    appState.selectedModule = .clipboard
                }
                QuickActionCard(icon: "doc.on.doc.fill", title: "Duplicates",
                                meta: "312 MB wasted", color: .haloPurple) {
                    appState.selectedModule = .files
                }
                QuickActionCard(icon: "trash.fill", title: "App Ghosts",
                                meta: "6 leftovers", color: .haloRed) {
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
                    .foregroundColor(.haloText2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.haloSurface2)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isHovered ? color.opacity(0.3) : Color.haloBorder, lineWidth: 1)
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
            HaloSectionHeader(title: "Recent Activity", action: {}, actionLabel: "Clear")
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
        HaloCard {
            VStack(spacing: 0) {
                // Header
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
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.haloRed)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        if !alertLog.entries.isEmpty {
                            Button("Clear") { alertLog.clearAll() }
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText2)
                                .buttonStyle(.plain)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.haloText2)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, isExpanded && !alertLog.entries.isEmpty ? 10 : 0)

                if isExpanded {
                    if alertLog.entries.isEmpty {
                        Text("No alerts yet — your Mac looks great.")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
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
        .onAppear { /* Trigger @StateObject creation so unread badge updates */ }
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
        .padding(.vertical, 4)
        .opacity(entry.isRead ? 0.65 : 1.0)
    }
}
