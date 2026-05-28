import SwiftUI

// MARK: - SensorsSection  (P3-02)
//
// Foreground-active: 5-second timer, alive only while section visible.

struct SensorsSection: View {
    @AppStorage("temperatureUnit") private var useFahrenheit = false
    @State private var reader = SMCReader()
    @State private var readings: [SMCReader.SensorReading] = []
    @State private var timer: Timer?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(
                title: "Sensors & Fans",
                subtitle: useFahrenheit ? "°F" : "°C",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                if readings.isEmpty {
                    HaloCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .foregroundColor(.haloAccent)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Sensor Data Not Available")
                                    .font(HaloFont.body(13, weight: .semibold))
                                    .foregroundColor(.haloText)
                                Text("Apple Silicon Macs (M1/M2/M3/M4 series) manage thermal sensors entirely on-chip and do not expose raw SMC readings through public APIs. This is by design — macOS handles throttling and fan control automatically with no manual intervention needed.")
                                    .font(HaloFont.body(12))
                                    .foregroundColor(.haloText2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Battery temperature is available in the Battery section above.")
                                    .font(HaloFont.body(11))
                                    .foregroundColor(.haloText3)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(readings.enumerated()), id: \.element.id) { idx, reading in
                            SensorRow(reading: reading, useFahrenheit: useFahrenheit)
                            if idx < readings.count - 1 {
                                Divider().padding(.horizontal, 14).background(Color.haloBorder)
                            }
                        }
                    }
                    .background(Color.haloSurface2)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
                }

                // Unit toggle
                HStack {
                    Spacer()
                    Picker("", selection: $useFahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
            }
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        Task { readings = await reader.readAll() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task {
                let r = await reader.readAll()
                await MainActor.run { readings = r }
            }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}

private struct SensorRow: View {
    let reading: SMCReader.SensorReading
    let useFahrenheit: Bool

    private var formattedValue: String {
        switch reading.unit {
        case .celsius:
            let v = useFahrenheit ? reading.value * 9/5 + 32 : reading.value
            return String(format: "%.1f%@", v, useFahrenheit ? "°F" : "°C")
        case .rpm:
            return String(format: "%.0f RPM", reading.value)
        }
    }

    private var alertColor: Color {
        switch reading.unit {
        case .celsius:
            if reading.value > 90 { return .haloRed }
            if reading.value > 75 { return .haloAmber }
            return .haloGreen
        case .rpm:
            return reading.value > 4000 ? .haloAmber : .haloGreen
        }
    }

    private var icon: String {
        switch reading.unit {
        case .celsius: return "thermometer"
        case .rpm:     return "wind"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(alertColor)
                .frame(width: 18)

            Text(reading.label)
                .font(HaloFont.body(13))
                .foregroundColor(.haloText)

            Spacer()

            Text(formattedValue)
                .font(HaloFont.mono(13))
                .foregroundColor(alertColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
