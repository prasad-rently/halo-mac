import SwiftUI

// MARK: - BackupHealthCard  (F-022)
//
// Dashboard card surfacing Time Machine's real backup health via
// `TimeMachineMonitor` (owned by AppState, refreshed every 15 min — see
// AppState.startTimeMachineMonitoring()). Three honest states:
//   1. Not configured  → explicit empty state + "Set Up Time Machine" deep link.
//   2. Configured but unreachable/no data → says so; never fakes a heatmap.
//   3. Configured + reachable → last backup, free space, 30-day heatmap.

struct BackupHealthCard: View {
    @EnvironmentObject var appState: AppState

    private var status: TimeMachineStatus { appState.timeMachineStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HaloSectionHeader(
                    title: "Backup Health",
                    subtitle: "Time Machine · via tmutil"
                )
                Spacer()
                if appState.isCheckingTimeMachine {
                    ProgressView().scaleEffect(0.6).tint(.haloAccent)
                } else if status.isConfigured {
                    Button {
                        Task { await appState.refreshTimeMachineStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.haloText2)
                    }
                    .buttonStyle(.plain)
                }
            }

            HaloCard(accentTop: accentColor) {
                Group {
                    if !status.isConfigured {
                        notConfiguredState
                    } else if !status.isReachable {
                        unreachableState
                    } else {
                        configuredState
                    }
                }
                .padding(18)
            }
            .accessibilityIdentifier("dashboard.backupHealth.card")
        }
    }

    private var accentColor: Color {
        guard status.isConfigured else { return .haloText3 }
        if status.isStale { return .haloRed }
        if !status.isReachable { return .haloAmber }
        return .haloGreen
    }

    // MARK: - Not configured

    private var notConfiguredState: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 22))
                .foregroundColor(.haloText3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Time Machine isn't set up")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText)
                Text("Connect a backup disk to protect your files automatically.")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            HaloGhostButton("Set Up", icon: "gearshape") {
                openTimeMachineSettings()
            }
            .accessibilityIdentifier("dashboard.backupHealth.setup.button")
        }
    }

    // MARK: - Configured but unreachable (drive disconnected) / no known snapshots

    private var unreachableState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 18))
                    .foregroundColor(.haloAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.destinationName ?? "Backup destination")
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text("Not currently reachable — check that the drive is connected.")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                Spacer()
            }
            if let last = status.lastBackupDate {
                Text("Last known backup: \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
            }
        }
    }

    // MARK: - Fully configured + reachable

    private var configuredState: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Last backup — the headline number
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last Backup")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    if let last = status.lastBackupDate {
                        Text(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))
                            .font(HaloFont.display(20, weight: .bold))
                            .foregroundColor(status.isStale ? .haloRed : .haloText)
                    } else {
                        Text("No backups found")
                            .font(HaloFont.display(16, weight: .bold))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer()
                HaloPrimaryButton(
                    status.isBackupRunning || appState.isStartingBackup ? "Backing Up…" : "Back Up Now",
                    icon: status.isBackupRunning || appState.isStartingBackup ? nil : "arrow.triangle.2.circlepath",
                    isLoading: appState.isStartingBackup
                ) {
                    Task { await appState.startTimeMachineBackupNow() }
                }
                .disabled(status.isBackupRunning || appState.isStartingBackup)
                .accessibilityIdentifier("dashboard.backupHealth.backupNow.button")
            }

            // Destination + free space
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.haloText3)
                    Text(status.destinationName ?? "Backup Disk")
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloText)
                    Spacer()
                    if let available = status.availableBytes, let total = status.totalBytes {
                        Text("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }
                }
                if let ratio = status.spaceUsedRatio {
                    HaloMiniBar(value: ratio, color: ratio > 0.9 ? .haloRed : ratio > 0.75 ? .haloAmber : .haloAccent)
                }
            }

            // 30-day heatmap
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last 30 Days")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Spacer()
                    HeatmapLegend()
                }
                BackupHeatmapGrid(days: TimeMachineMonitor.heatmap(backupDates: status.backupDates))
                    .accessibilityIdentifier("dashboard.backupHealth.heatmap")
            }
        }
    }

    private func openTimeMachineSettings() {
        // Verified working on macOS Sonoma/Sequoia — the Time Machine pane's
        // ExtensionKit bundle identifier is com.apple.Time-Machine-Settings.extension.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Heatmap grid

private struct BackupHeatmapGrid: View {
    let days: [BackupHeatmapDay]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(days) { day in
                RoundedRectangle(cornerRadius: 3)
                    .fill(day.state.color.opacity(day.state == .noData ? 0.5 : 1))
                    .frame(height: 14)
                    .help(tooltip(for: day))
            }
        }
    }

    private func tooltip(for day: BackupHeatmapDay) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        let dateString = df.string(from: day.date)
        switch day.state {
        case .backedUp: return "\(dateString) — backed up"
        case .late: return "\(dateString) — backup was late"
        case .missed: return "\(dateString) — backup missed"
        case .noData: return "\(dateString) — no data"
        }
    }
}

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            LegendSwatch(color: .haloGreen, label: "Backed up")
            LegendSwatch(color: .haloAmber, label: "Late")
            LegendSwatch(color: .haloRed, label: "Missed")
        }
    }
}

private struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(HaloFont.body(9))
                .foregroundColor(.haloText3)
        }
    }
}
