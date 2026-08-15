import SwiftUI
import Charts

// MARK: - AppUsageInsightsSection (F-021)
//
// "Insights" sub-section on the Dashboard, below the health ring. Shows the
// top-5-apps bar chart, the Background Hogs list, context-switch score, and
// week-over-week trend — all sourced from `AppUsageTracker`.
//
// HONESTY CAPTION IS NOT DECORATIVE: every state below carries some form of
// "based on time Halo has been running" because that is the actual scope of
// this data (see the long comment at the top of AppUsageTracker.swift). Do
// not remove the caption or reword it to imply full-day/system Screen Time.

struct AppUsageInsightsSection: View {
    @ObservedObject private var tracker = AppUsageTracker.shared
    @AppStorage(AppUsageTracker.enabledDefaultsKey) private var trackingEnabled = false
    @State private var isExpanded = true

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if !trackingEnabled {
                    disabledState
                } else if isExpanded {
                    if tracker.topApps().isEmpty {
                        collectingState
                    } else {
                        content
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 13))
                        .foregroundColor(.haloAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Usage Insights")
                            .font(HaloFont.display(14, weight: .semibold))
                            .foregroundColor(.haloText)
                        Text("Based on time Halo has been running — not a full Screen Time replacement")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dashboard.appUsageInsights")

            Spacer()

            if trackingEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - States

    private var disabledState: some View {
        HStack {
            Image(systemName: "eye.slash")
                .foregroundColor(.haloText3)
            Text("Usage tracking is off. Enable it in Settings → General → Privacy to see foreground-time insights.")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .accessibilityIdentifier("dashboard.appUsageInsights.disabledState")
    }

    private var collectingState: some View {
        HStack {
            ProgressView().scaleEffect(0.6)
            Text("Collecting usage data — check back once you've used a few apps with Halo running.")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .accessibilityIdentifier("dashboard.appUsageInsights.collectingState")
    }

    // MARK: - Populated content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            topAppsChart
            statsRow
            if !tracker.backgroundHogs().isEmpty {
                backgroundHogsList
            }
        }
    }

    private var topAppsChart: some View {
        let apps = tracker.topApps()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top Apps · Past 7 Days")
                .font(HaloFont.body(11, weight: .semibold))
                .foregroundColor(.haloText2)

            Chart(apps) { app in
                BarMark(
                    x: .value("Hours", app.totalForegroundSeconds / 3600),
                    y: .value("App", app.appName)
                )
                .foregroundStyle(Color.haloAccent.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(app.hoursFormatted)
                        .font(HaloFont.mono(10))
                        .foregroundColor(.haloText2)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.haloBorder)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0fh", d))
                                .font(.system(size: 9))
                                .foregroundColor(.haloText3)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Color.haloText2)
                }
            }
            .frame(height: CGFloat(apps.count) * 32 + 20)
        }
        .accessibilityIdentifier("dashboard.appUsageInsights.chart")
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            InsightStatTile(
                icon: "arrow.left.arrow.right",
                title: "Context Switching",
                value: switchesPerHourText,
                color: .haloAccent
            )
            InsightStatTile(
                icon: trendIcon,
                title: "vs Last Week",
                value: trendText,
                color: trendColor
            )
        }
    }

    private var switchesPerHourText: String {
        guard let rate = tracker.contextSwitchesPerHour() else { return "Not enough data yet" }
        return String(format: "%.1f / hr", rate)
    }

    private var trendText: String {
        guard let woW = tracker.weekOverWeekChange() else { return "Needs 14 days of history" }
        guard let pct = woW.percentChange else { return "New this week" }
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(Int(pct))%"
    }

    private var trendIcon: String {
        guard let woW = tracker.weekOverWeekChange(), let pct = woW.percentChange else {
            return "calendar.badge.clock"
        }
        return pct >= 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private var trendColor: Color {
        guard let woW = tracker.weekOverWeekChange(), let pct = woW.percentChange else {
            return .haloText3
        }
        // More foreground time isn't inherently bad — colour is informational, not judgmental.
        return pct >= 0 ? .haloAmber : .haloGreen
    }

    private var backgroundHogsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background Hogs · Running 8h+ Without Ever Being Activated")
                .font(HaloFont.body(11, weight: .semibold))
                .foregroundColor(.haloText2)

            VStack(spacing: 6) {
                ForEach(tracker.backgroundHogs()) { hog in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.haloAmber.opacity(0.15)).frame(width: 26, height: 26)
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.haloAmber)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hog.appName)
                                .font(HaloFont.body(12, weight: .semibold))
                                .foregroundColor(.haloText)
                            Text("Observed running \(hog.observedHoursFormatted), avg \(Int(hog.averageRAMMB)) MB")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                }
            }
        }
        .accessibilityIdentifier("dashboard.appUsageInsights.backgroundHogs.list")
    }
}

private struct InsightStatTile: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(HaloFont.body(10, weight: .semibold))
                    .foregroundColor(.haloText2)
            }
            Text(value)
                .font(HaloFont.body(14, weight: .semibold))
                .foregroundColor(.haloText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haloSurface2)
        .cornerRadius(10)
    }
}
