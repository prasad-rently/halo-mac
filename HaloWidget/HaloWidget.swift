import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct HaloEntry: TimelineEntry {
    let date: Date
    let data: HaloWidgetData
}

// MARK: - Timeline provider

struct HaloProvider: TimelineProvider {
    func placeholder(in context: Context) -> HaloEntry {
        HaloEntry(date: .now, data: HaloWidgetData(
            cpuUsage: 0.42, ramUsage: 0.67, ramUsedGB: 5.4, ramTotalGB: 8,
            networkUpMBps: 0.8, networkDownMBps: 3.2,
            clipboardPreviews: ["Hello world", "swift build", "git commit -m"]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (HaloEntry) -> Void) {
        completion(HaloEntry(date: .now, data: HaloWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HaloEntry>) -> Void) {
        let data = HaloWidgetData.load()
        // Build one entry per minute for the next 5 minutes using the current snapshot.
        // The main app writes fresh data every 2 s, so each entry will show the latest
        // values that were available when this timeline was generated.
        // After 5 minutes the system calls getTimeline again for a brand-new snapshot.
        var entries: [HaloEntry] = []
        for minuteOffset in 0..<5 {
            let entryDate = Calendar.current.date(byAdding: .minute, value: minuteOffset, to: .now)!
            entries.append(HaloEntry(date: entryDate, data: data))
        }
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 1, to: .now)!
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }
}

// MARK: - Design tokens (inlined — no shared module in extension)

private extension Color {
    static let wBackground  = Color(hex: "#080c14")
    static let wSurface     = Color(hex: "#0d1220")
    static let wAccent      = Color(hex: "#4f7cff")
    static let wAccent2     = Color(hex: "#7b5ea7")
    static let wGreen       = Color(hex: "#22d97a")
    static let wAmber       = Color(hex: "#f5a623")
    static let wRed         = Color(hex: "#ff4d6a")
    static let wText        = Color.white
    static let wText2       = Color.white.opacity(0.6)
    static let wText3       = Color.white.opacity(0.35)
    static let wBorder      = Color.white.opacity(0.08)

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }

    static func rampColor(for value: Double) -> Color {
        value > 0.85 ? .wRed : value > 0.6 ? .wAmber : .wGreen
    }
}

// MARK: - Shared sub-views

private struct StatGauge: View {
    let label: String
    let value: Double   // 0–1
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.wText2)
                Spacer()
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.rampColor(for: value))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.wBorder)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.rampColor(for: value).opacity(0.9),
                                     Color.rampColor(for: value)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * max(0.02, value))
                }
            }
            .frame(height: 5)
        }
    }
}

private struct NetRow: View {
    let up: Double
    let down: Double

    private func fmt(_ v: Double) -> String {
        v >= 1 ? String(format: "%.1f MB/s", v) : String(format: "%.0f KB/s", v * 1024)
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(fmt(up), systemImage: "arrow.up.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.wAccent)
            Label(fmt(down), systemImage: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.wGreen)
        }
    }
}

// MARK: - Small widget  (CPU + RAM)

struct HaloSmallView: View {
    let entry: HaloEntry

    var body: some View {
        ZStack {
            Color.wBackground
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LinearGradient(
                            colors: [.wAccent, .wAccent2],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Halo")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.wText)
                    Spacer()
                }
                Spacer()
                StatGauge(label: "CPU",
                          value: entry.data.cpuUsage,
                          detail: String(format: "%.0f%%", entry.data.cpuUsage * 100))
                StatGauge(label: "RAM",
                          value: entry.data.ramUsage,
                          detail: String(format: "%.1f/%.0fG",
                                         entry.data.ramUsedGB, entry.data.ramTotalGB))
            }
            .padding(14)
        }
    }
}

// MARK: - Medium widget  (CPU + RAM + Network)

struct HaloMediumView: View {
    let entry: HaloEntry

    var body: some View {
        ZStack {
            Color.wBackground
            HStack(spacing: 16) {
                // Left: gauges
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LinearGradient(
                                colors: [.wAccent, .wAccent2],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text("Halo")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundColor(.wText)
                    }
                    Spacer()
                    StatGauge(label: "CPU",
                              value: entry.data.cpuUsage,
                              detail: String(format: "%.0f%%", entry.data.cpuUsage * 100))
                    StatGauge(label: "RAM",
                              value: entry.data.ramUsage,
                              detail: String(format: "%.1f/%.0fG",
                                             entry.data.ramUsedGB, entry.data.ramTotalGB))
                }
                .frame(maxWidth: .infinity)

                Divider().background(Color.wBorder)

                // Right: network
                VStack(alignment: .leading, spacing: 8) {
                    Text("Network")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.wText2)
                    Spacer()
                    Label(netLabel(entry.data.networkUpMBps), systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.wAccent)
                    Label(netLabel(entry.data.networkDownMBps), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.wGreen)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
        }
    }

    private func netLabel(_ v: Double) -> String {
        v >= 1 ? String(format: "%.1f MB/s", v) : String(format: "%.0f KB/s", v * 1024)
    }
}

// MARK: - Large widget  (CPU + RAM + Network + Clipboard)

struct HaloLargeView: View {
    let entry: HaloEntry

    var body: some View {
        ZStack {
            Color.wBackground
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LinearGradient(
                            colors: [.wAccent, .wAccent2],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Halo")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.wText)
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.wText3)
                }

                Divider().background(Color.wBorder)

                // System stats
                VStack(spacing: 8) {
                    StatGauge(label: "CPU",
                              value: entry.data.cpuUsage,
                              detail: String(format: "%.0f%%", entry.data.cpuUsage * 100))
                    StatGauge(label: "RAM",
                              value: entry.data.ramUsage,
                              detail: String(format: "%.1f / %.0f GB",
                                             entry.data.ramUsedGB, entry.data.ramTotalGB))
                }

                // Network
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundColor(.wText2)
                    Text("Network")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.wText2)
                    Spacer()
                    NetRow(up: entry.data.networkUpMBps, down: entry.data.networkDownMBps)
                }
                .padding(8)
                .background(Color.wSurface)
                .cornerRadius(8)

                Divider().background(Color.wBorder)

                // Clipboard
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.wAccent)
                        Text("Recent Clipboard")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.wText2)
                    }
                    if entry.data.clipboardPreviews.isEmpty {
                        Text("No recent items")
                            .font(.system(size: 11))
                            .foregroundColor(.wText3)
                    } else {
                        ForEach(Array(entry.data.clipboardPreviews.prefix(5).enumerated()),
                                id: \.offset) { idx, preview in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.wAccent)
                                    .frame(width: 14)
                                Text(preview)
                                    .font(.system(size: 11))
                                    .foregroundColor(.wText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.wSurface)
                            .cornerRadius(6)
                        }
                    }
                }

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Widget definition

struct HaloSystemWidget: Widget {
    let kind = "HaloSystemWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HaloProvider()) { entry in
            if #available(macOS 14.0, *) {
                HaloWidgetEntryView(entry: entry)
                    .containerBackground(.clear, for: .widget)
            } else {
                HaloWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Halo Monitor")
        .description("Live CPU, RAM, network and clipboard at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HaloWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: HaloEntry

    var body: some View {
        switch family {
        case .systemSmall:  HaloSmallView(entry: entry)
        case .systemMedium: HaloMediumView(entry: entry)
        default:            HaloLargeView(entry: entry)
        }
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview(as: .systemLarge) {
    HaloSystemWidget()
} timeline: {
    HaloEntry(date: .now, data: HaloWidgetData(
        cpuUsage: 0.38, ramUsage: 0.72, ramUsedGB: 5.8, ramTotalGB: 8,
        networkUpMBps: 1.2, networkDownMBps: 4.5,
        clipboardPreviews: ["xcrun simctl list", "UserDefaults.standard.set(", "group.com.halo.mac", "print(\"Hello, Halo\")"]
    ))
}
