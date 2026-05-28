import SwiftUI
import Charts

// MARK: - NetworkSparklineCard  (P3-10)
//
// Foreground-active: reads the rolling buffer from AppState (already filled every 2 s).
// Chart is only rendered when this card is visible — no extra data collection.

struct NetworkSparklineCard: View {
    @EnvironmentObject var appState: AppState

    private struct Sample: Identifiable {
        let id: Int
        let up: Double
        let down: Double
    }

    private var samples: [Sample] {
        let count = max(appState.uploadHistory.count, appState.downloadHistory.count)
        return (0..<count).map { i in
            Sample(
                id: i,
                up:   i < appState.uploadHistory.count   ? appState.uploadHistory[i]   : 0,
                down: i < appState.downloadHistory.count ? appState.downloadHistory[i] : 0
            )
        }
    }

    private var peakDown: Double { appState.downloadHistory.max() ?? 0.1 }
    private var peakUp:   Double { appState.uploadHistory.max() ?? 0.1 }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {

                // Header
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 13))
                        .foregroundColor(.haloAccent)
                    Text("Network Activity")
                        .font(HaloFont.display(14, weight: .semibold))
                        .foregroundColor(.haloText)
                    Spacer()
                    // Live readout
                    HStack(spacing: 10) {
                        NetBadge(icon: "arrow.down", value: appState.networkDownMBps, color: .haloAccent)
                        NetBadge(icon: "arrow.up",   value: appState.networkUpMBps,   color: .haloAmber)
                    }
                }

                // Chart
                if samples.count > 1 {
                    Chart {
                        ForEach(samples) { s in
                            AreaMark(x: .value("t", s.id), y: .value("Down", s.down))
                                .foregroundStyle(
                                    LinearGradient(colors: [Color.haloAccent.opacity(0.5), Color.haloAccent.opacity(0.05)],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                                .interpolationMethod(.catmullRom)

                            LineMark(x: .value("t", s.id), y: .value("Down", s.down))
                                .foregroundStyle(Color.haloAccent)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .interpolationMethod(.catmullRom)

                            AreaMark(x: .value("t", s.id), y: .value("Up", s.up))
                                .foregroundStyle(
                                    LinearGradient(colors: [Color.haloAmber.opacity(0.35), Color.haloAmber.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                                .interpolationMethod(.catmullRom)

                            LineMark(x: .value("t", s.id), y: .value("Up", s.up))
                                .foregroundStyle(Color.haloAmber)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3,3]))
                                .foregroundStyle(Color.haloBorder)
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text(formatMBps(d))
                                        .font(.system(size: 9))
                                        .foregroundColor(.haloText3)
                                }
                            }
                        }
                    }
                    .frame(height: 70)
                    .animation(.easeInOut(duration: 0.5), value: samples.count)
                } else {
                    // Placeholder while buffer fills
                    HStack {
                        ProgressView().scaleEffect(0.6)
                        Text("Collecting data…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                    .frame(height: 70)
                }

                // Legend
                HStack(spacing: 14) {
                    LegendDot(color: .haloAccent, label: "Download")
                    LegendDot(color: .haloAmber,  label: "Upload")
                    Spacer()
                    Text("Last 60 s")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(16)
        }
    }

    private func formatMBps(_ v: Double) -> String {
        if v >= 1 { return String(format: "%.1f", v) }
        if v >= 0.01 { return String(format: "%.2f", v) }
        return "0"
    }
}

private struct NetBadge: View {
    let icon: String; let value: Double; let color: Color

    private var label: String {
        if value >= 1 { return String(format: "%.1f MB/s", value) }
        return String(format: "%.0f KB/s", value * 1024)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(HaloFont.mono(11))
                .foregroundColor(color)
        }
    }
}

private struct LegendDot: View {
    let color: Color; let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 3)
            Text(label).font(HaloFont.body(10)).foregroundColor(.haloText3)
        }
    }
}
