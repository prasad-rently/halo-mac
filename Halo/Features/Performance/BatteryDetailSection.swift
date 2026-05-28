import SwiftUI

// MARK: - BatteryDetailSection  (P3-04)
//
// Foreground view: presents cached data from AppState (already collected every 2 s).
// Low Power Mode toggle uses ProcessInfo — available on macOS 12+.

struct BatteryDetailSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = true

    private var healthColor: Color {
        if appState.batteryHealth >= 0.80 { return .haloGreen }
        if appState.batteryHealth >= 0.60 { return .haloAmber }
        return .haloRed
    }

    private var cycleRatio: Double {
        // Apple considers ~1000 cycles as full wear for most MacBooks
        min(Double(appState.batteryCycles) / 1000.0, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(
                title: "Battery",
                subtitle: "\(appState.batteryPercent)% · \(appState.batteryIsCharging ? "Charging" : appState.batteryIsOnAC ? "On AC" : "On Battery")",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                HaloCard {
                    VStack(spacing: 16) {
                        // Top row: health ring + stats
                        HStack(alignment: .top, spacing: 20) {

                            // Health ring
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .stroke(Color.haloBorder, lineWidth: 8)
                                        .frame(width: 72, height: 72)
                                    Circle()
                                        .trim(from: 0, to: appState.batteryHealth)
                                        .stroke(healthColor,
                                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                        .frame(width: 72, height: 72)
                                        .rotationEffect(.degrees(-90))
                                    VStack(spacing: 1) {
                                        Text(String(format: "%.0f%%", appState.batteryHealth * 100))
                                            .font(HaloFont.display(16, weight: .bold))
                                            .foregroundColor(healthColor)
                                        Text("Health")
                                            .font(HaloFont.body(9))
                                            .foregroundColor(.haloText3)
                                    }
                                }
                                Text(healthLabel(appState.batteryHealth))
                                    .font(HaloFont.body(11, weight: .semibold))
                                    .foregroundColor(healthColor)
                            }

                            Divider().frame(height: 90).background(Color.haloBorder)

                            // Stats grid
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                      alignment: .leading, spacing: 10) {
                                BattStatCell(label: "Cycle Count",
                                             value: "\(appState.batteryCycles)")
                                BattStatCell(label: "Amperage",
                                             value: appState.batteryAmperageMa != 0
                                             ? "\(appState.batteryAmperageMa) mA" : "—")
                                BattStatCell(label: "Voltage",
                                             value: appState.batteryVoltageMv > 0
                                             ? "\(appState.batteryVoltageMv) mV" : "—")
                                BattStatCell(label: "Temperature",
                                             value: appState.batteryTemperatureC > 0
                                             ? String(format: "%.1f °C", appState.batteryTemperatureC) : "—")
                                if !appState.batteryIsCharging && !appState.batteryTimeRemaining.isEmpty {
                                    BattStatCell(label: "Time Left",
                                                 value: appState.batteryTimeRemaining)
                                }
                                if appState.batteryIsCharging && !appState.batteryTimeToFull.isEmpty {
                                    BattStatCell(label: "Full In",
                                                 value: appState.batteryTimeToFull)
                                }
                            }
                        }

                        Divider().background(Color.haloBorder)

                        // Cycle count bar
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Cycle Count")
                                    .font(HaloFont.body(12))
                                    .foregroundColor(.haloText2)
                                Spacer()
                                Text("\(appState.batteryCycles) / 1000")
                                    .font(HaloFont.mono(11))
                                    .foregroundColor(cycleRatio > 0.8 ? .haloAmber : .haloText)
                            }
                            HaloMiniBar(value: cycleRatio,
                                        color: cycleRatio > 0.8 ? .haloAmber : .haloGreen)
                        }

                        // Capacity breakdown
                        if appState.batteryDesignCapMAh > 0 {
                            Divider().background(Color.haloBorder)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Capacity")
                                    .font(HaloFont.body(12, weight: .semibold))
                                    .foregroundColor(.haloText)
                                HStack(spacing: 16) {
                                    CapCell(label: "Design",  value: "\(appState.batteryDesignCapMAh) mAh")
                                    CapCell(label: "Current", value: "\(appState.batteryMaxCapMAh) mAh")
                                    CapCell(label: "Level",   value: "\(appState.batteryPercent)%")
                                }
                            }
                        }

                        // Low Power Mode toggle (macOS 12+)
                        Divider().background(Color.haloBorder)
                        HStack {
                            Image(systemName: "leaf.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.haloGreen)
                            Text("Low Power Mode")
                                .font(HaloFont.body(13))
                                .foregroundColor(.haloText)
                            Spacer()
                            if appState.batteryIsLowPower {
                                HaloBadge(text: "Active", color: .haloGreen)
                            } else {
                                HaloBadge(text: "Off", color: .haloText3)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func healthLabel(_ h: Double) -> String {
        if h >= 0.80 { return "Good" }
        if h >= 0.60 { return "Fair" }
        return "Replace Soon"
    }
}

private struct BattStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HaloFont.body(10))
                .foregroundColor(.haloText3)
            Text(value)
                .font(HaloFont.mono(12))
                .foregroundColor(.haloText)
        }
    }
}

private struct CapCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HaloFont.body(10))
                .foregroundColor(.haloText3)
            Text(value)
                .font(HaloFont.mono(11))
                .foregroundColor(.haloText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
