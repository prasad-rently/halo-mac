import SwiftUI
import AppKit
import Charts

// MARK: - MemoryTrendsSection  (F-023)
//
// Sub-section directly below TopProcessesSection: per-app RAM sparklines over
// a rolling 2-hour window (sampled every 30 s by MemoryTrendTracker, which
// runs continuously — not tied to this view's lifetime), plus a "Possible
// memory leak" badge for apps that have grown monotonically for >1 hour.
//
// "Restart App" is only offered on flagged apps, and always behind a
// confirmation dialog (CLAUDE.md: disruptive actions require confirmation —
// terminating another app, even to relaunch it, counts).
struct MemoryTrendsSection: View {
    @ObservedObject private var tracker = MemoryTrendTracker.shared
    @State private var isExpanded = true
    @State private var appPendingRestart: AppMemoryHistory?

    @AppStorage("memoryLeakAlertThresholdGB") private var alertThresholdGB: Double = MemoryTrendTracker.defaultAlertThresholdGB

    /// Only surface apps with a meaningful footprint — helper processes under
    /// 50 MB just add noise to a list meant to catch "Slack ballooned to 1.4 GB."
    private var visibleHistories: [AppMemoryHistory] {
        tracker.histories
            .filter { ($0.samples.last?.ramMB ?? 0) > 50 }
            .sorted { ($0.samples.last?.ramMB ?? 0) > ($1.samples.last?.ramMB ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(
                title: "Memory Trends",
                subtitle: "Rolling 2h window · sampled every 30s",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                HStack {
                    Text("Alert when an app exceeds")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Stepper(
                        String(format: "%.1f GB", alertThresholdGB),
                        value: $alertThresholdGB, in: 0.5...16, step: 0.5
                    )
                    .font(HaloFont.mono(11))
                    .foregroundColor(.haloText)
                    .fixedSize()
                    Spacer()
                }

                if visibleHistories.isEmpty {
                    Text("Collecting data — memory trends appear once apps have been observed for a little while.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.haloSurface2)
                        .cornerRadius(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleHistories.enumerated()), id: \.element.id) { idx, history in
                            MemoryTrendRow(
                                history: history,
                                leak: tracker.leakStatus(for: history),
                                onRestart: { appPendingRestart = history }
                            )
                            if idx < visibleHistories.count - 1 {
                                Divider().padding(.horizontal, 12).background(Color.haloBorder)
                            }
                        }
                    }
                    .background(Color.haloSurface2)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder, lineWidth: 1))
                }
            }
        }
        .confirmationDialog(
            appPendingRestart.map { "Restart \"\($0.appName)\"?" } ?? "",
            isPresented: .init(get: { appPendingRestart != nil }, set: { if !$0 { appPendingRestart = nil } }),
            titleVisibility: .visible
        ) {
            if let history = appPendingRestart {
                Button("Restart App", role: .destructive) {
                    MemoryTrendTracker.shared.restart(history)
                    appPendingRestart = nil
                }
            }
            Button("Cancel", role: .cancel) { appPendingRestart = nil }
        } message: {
            Text("This will quit the app immediately, which may cause unsaved data loss, then relaunch it fresh.")
        }
    }
}

// MARK: - Row

private struct MemoryTrendRow: View {
    let history: AppMemoryHistory
    let leak: MemoryLeakStatus
    let onRestart: () -> Void

    private var icon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == history.bundleID })?.icon
    }

    private var currentRAMText: String {
        let mb = history.samples.last?.ramMB ?? 0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private var growthSinceText: String? {
        guard leak.isPossibleLeak, let start = leak.streakStartDate else { return nil }
        let deltaMB = leak.currentRAMMB - leak.streakStartRAMMB
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return String(format: "+%.0f MB since %@", deltaMB, formatter.string(from: start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.haloPurple.opacity(0.1))
                        .frame(width: 28, height: 28)
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.haloPurple)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(history.appName)
                            .font(HaloFont.body(12, weight: .medium))
                            .foregroundColor(.haloText)
                            .lineLimit(1)
                        if leak.isPossibleLeak {
                            HaloBadge(text: "Possible memory leak", color: .haloAmber)
                        }
                    }
                    if let growthSinceText {
                        Text(growthSinceText)
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloAmber)
                    }
                }

                Spacer()

                Text(currentRAMText)
                    .font(HaloFont.mono(12))
                    .foregroundColor(leak.isPossibleLeak ? .haloAmber : .haloPurple)

                if leak.isPossibleLeak {
                    Button("Restart App", action: onRestart)
                        .buttonStyle(HaloSmallButtonStyle(color: .haloRed))
                }
            }

            sparkline
                .frame(height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sparkline: some View {
        if history.samples.count > 1 {
            Chart {
                ForEach(Array(history.samples.enumerated()), id: \.offset) { _, sample in
                    AreaMark(x: .value("t", sample.date), y: .value("RAM", sample.ramMB))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [(leak.isPossibleLeak ? Color.haloAmber : Color.haloPurple).opacity(0.35),
                                         (leak.isPossibleLeak ? Color.haloAmber : Color.haloPurple).opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                    LineMark(x: .value("t", sample.date), y: .value("RAM", sample.ramMB))
                        .foregroundStyle(leak.isPossibleLeak ? Color.haloAmber : Color.haloPurple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        } else {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("Collecting samples…")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
            }
        }
    }
}
