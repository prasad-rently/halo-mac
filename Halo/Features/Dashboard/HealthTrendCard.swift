import SwiftUI
import Charts

// MARK: - HealthTrendCard (F-029)
//
// 7-day health-score sparkline, backed by MetricsHistory's hourly samples —
// NOT the 2 s AppState metrics timer (see MetricsHistory.swift). Mirrors
// NetworkSparklineCard's layout/pattern (P3-10) for visual consistency.

struct HealthTrendCard: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var history = MetricsHistory.shared

    private var samples: [MetricsSample] { history.recent(days: 7) }

    private var deltaScore: Int? {
        guard let first = samples.first else { return nil }
        return appState.systemHealthScore - first.healthScore
    }

    private var trendColor: Color {
        guard let delta = deltaScore else { return .haloAccent }
        if delta > 0 { return .haloGreen }
        if delta < 0 { return .haloRed }
        return .haloAccent
    }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {

                // Header
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 13))
                        .foregroundColor(.haloAccent)
                    Text("7-Day Health Trend")
                        .font(HaloFont.display(14, weight: .semibold))
                        .foregroundColor(.haloText)
                    Spacer()
                    if let delta = deltaScore {
                        HStack(spacing: 3) {
                            Image(systemName: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "minus")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(delta > 0 ? "+" : "")\(delta) pts")
                                .font(HaloFont.mono(11))
                        }
                        .foregroundColor(trendColor)
                    }
                }

                // Chart
                if samples.count > 1 {
                    Chart {
                        ForEach(samples) { s in
                            AreaMark(x: .value("Time", s.date), y: .value("Score", s.healthScore))
                                .foregroundStyle(
                                    LinearGradient(colors: [trendColor.opacity(0.35), trendColor.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                                .interpolationMethod(.catmullRom)

                            LineMark(x: .value("Time", s.date), y: .value("Score", s.healthScore))
                                .foregroundStyle(trendColor)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.haloBorder)
                            AxisValueLabel {
                                if let d = v.as(Int.self) {
                                    Text("\(d)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.haloText3)
                                }
                            }
                        }
                    }
                    .frame(height: 70)
                    .animation(.easeInOut(duration: 0.5), value: samples.count)
                } else {
                    // Fresh install / not enough hourly samples yet — honest
                    // placeholder rather than a fabricated trend line.
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.haloText3)
                        Text("Collecting hourly samples — the trend fills in over the next few days.")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                    .frame(height: 70)
                }

                // Footer
                HStack(spacing: 14) {
                    Text("\(samples.count) sample\(samples.count == 1 ? "" : "s") · sampled hourly")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                    Spacer()
                    Text("Feeds the Weekly Digest")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(16)
        }
    }
}
