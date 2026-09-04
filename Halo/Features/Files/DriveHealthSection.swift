import SwiftUI
import Charts

// MARK: - DriveHealthSection  (F-020 · S.M.A.R.T. Disk Health Monitor)
//
// Per-volume S.M.A.R.T. health card, shown below the volume picker in the
// Drive Speed tab (Files module) — this is the "Drive Health" surface the
// F-020 spec calls for. On-demand only, mirroring DiskHealthSection (P3-07)
// in Cleanup: nothing runs until the section appears / the volume changes.
//
// Every field that diskutil/IOKit didn't actually report is rendered as
// "Not available on this drive" — never a zeroed or guessed value. See
// SMARTDiskMonitor.swift's header for exactly what is and isn't readable.

@MainActor
final class DriveHealthViewModel: ObservableObject {
    @Published var info: SMARTDiskMonitor.SMARTDiskInfo?
    @Published var isScanning = false

    private let monitor = SMARTDiskMonitor()

    /// The volume the *user* is currently looking at. Recorded before the
    /// in-flight guard below, so a switch that arrives mid-scan is never lost.
    private var requestedVolume: DriveVolume?

    func scanIfNeeded(volume: DriveVolume) {
        guard requestedVolume?.id != volume.id else { return }
        scan(volume: volume)
    }

    func scan(volume: DriveVolume) {
        // Record the request first. If a scan is already running we return
        // below, but the completion handler re-dispatches against whatever
        // the user has since selected — otherwise switching volumes mid-scan
        // would leave the previous drive's S.M.A.R.T. data on screen under the
        // new drive's name, which is worse than showing nothing.
        let isSwitch = requestedVolume?.id != volume.id
        requestedVolume = volume
        if isSwitch { info = nil }

        guard !isScanning else { return }
        isScanning = true
        Task { [weak self] in
            let result = await monitor.scan(volume: volume)
            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                if self.requestedVolume?.id == volume.id {
                    self.info = result
                } else if let pending = self.requestedVolume {
                    // Selection moved on while we were reading — discard this
                    // result rather than mis-attributing it, and read the
                    // volume the user is actually on.
                    self.scan(volume: pending)
                }
            }
        }
    }
}

struct DriveHealthSection: View {
    let volume: DriveVolume
    @StateObject private var vm = DriveHealthViewModel()
    @ObservedObject private var tempHistory = SMARTTemperatureHistory.shared

    /// `SMARTTemperatureHistory` is fed exclusively by `AppState.runSMARTCheck()`,
    /// which samples the boot volume (`path: "/"`). Gating the chart on
    /// `volume.isInternal` would therefore render the boot drive's history under
    /// a *different* internal volume on any Mac that has one (a second internal
    /// drive, or a Fusion/multi-container setup). Match on the boot volume
    /// itself so the chart can only ever appear beside the drive it describes.
    ///
    /// Matched on `volumeIdentifierKey` rather than `path == "/"`: on this Mac
    /// `mountedVolumeURLs` happens to return the boot volume as `/` (verified),
    /// but `/Volumes/Macintosh HD` is a firmlink to the same volume and a path
    /// comparison would silently hide the chart if macOS ever reported it that
    /// way instead. Falls back to the path check if either identifier is absent.
    private var isBootVolume: Bool {
        let bootID = (try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let volumeID = (try? volume.url
            .resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let bootID, let volumeID else { return volume.url.path == "/" }
        return bootID.isEqual(volumeID)
    }

    var body: some View {
        HaloCard(accentTop: vm.info.map(accentColor)) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().background(Color.haloBorder)

                if vm.isScanning {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let info = vm.info {
                    statusRow(info)
                    metricsGrid(info)
                    lifespanSection(info)
                    if isBootVolume { temperatureSection }
                } else {
                    Text("Tap “Check Drive Health” to read S.M.A.R.T. status for this drive.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("files.driveHealth.card")
        .onAppear { vm.scanIfNeeded(volume: volume) }
        .onChange(of: volume.id) { _ in vm.scanIfNeeded(volume: volume) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 14))
                .foregroundColor(.haloAccent)
            Text("Drive Health")
                .font(HaloFont.display(14, weight: .semibold))
                .foregroundColor(.haloText)
            Text("S.M.A.R.T.")
                .font(HaloFont.body(9, weight: .semibold))
                .foregroundColor(.haloText3)
            Spacer(minLength: 0)
            if !vm.isScanning {
                HaloGhostButton(vm.info == nil ? "Check Drive Health" : "Re-Check", icon: "arrow.clockwise") {
                    vm.scan(volume: volume)
                }
                .accessibilityIdentifier("files.driveHealth.check.button")
            }
        }
    }

    // MARK: Status row

    private func accentColor(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> Color {
        switch info.healthLevel {
        case .good:    return .haloGreen
        case .warning: return .haloAmber
        case .failing: return .haloRed
        case .unknown: return .haloText3
        }
    }

    private func statusLabel(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String {
        switch info.healthLevel {
        case .good:    return "Good"
        case .warning: return "Warning"
        case .failing: return "Failing"
        case .unknown: return "Unknown"
        }
    }

    private func statusRow(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon(info))
                    .font(.system(size: 16))
                    .foregroundColor(accentColor(info))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.model ?? "Unknown drive")
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        HaloBadge(text: statusLabel(info), color: accentColor(info))
                            .accessibilityIdentifier("files.driveHealth.status")
                    }
                    Text(rawStatusDetail(info))
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                Spacer()
            }
        }
    }

    private func statusIcon(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String {
        switch info.healthLevel {
        case .good:    return "checkmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.shield.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func rawStatusDetail(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String {
        switch info.overallStatus {
        case .verified:      return "diskutil reports S.M.A.R.T. status: Verified"
        case .failing:       return "diskutil reports S.M.A.R.T. status: Failing"
        case .other(let s):  return "diskutil reports S.M.A.R.T. status: \(s)"
        case .unavailable:   return "S.M.A.R.T. status not exposed for this drive"
        }
    }

    // MARK: Metrics grid

    private func metricsGrid(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> some View {
        let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            metric("Capacity", byteString(info.capacityBytes), id: "capacity")
            metric("Serial Number", info.serialNumber, id: "serialNumber")
            metric("Bus / Connection", info.busProtocol, id: "busProtocol")
            metric("Temperature", info.temperatureCelsius.map { String(format: "%.0f°C", $0) }, id: "temperature")
            metric("Power-On Hours", info.powerOnHours.map { "\($0) hrs" }, id: "powerOnHours")
            metric("Power Cycles", info.powerCycles.map { "\($0)" }, id: "powerCycles")
            metric("Total Bytes Written", info.totalBytesWritten.map(byteString), id: "totalBytesWritten")
            metric("Total Bytes Read", info.totalBytesRead.map(byteString), id: "totalBytesRead")
            metric("Available Spare", spareNote(info), id: "availableSpare")
            metric("Media Errors", info.mediaErrorCount.map { "\($0)" }, id: "mediaErrors")
            metric("Reallocated Sectors", reallocatedSectorNote(info), id: "reallocatedSectors")
            metric("Pending Sectors", pendingSectorNote(info), id: "pendingSectors")
        }
    }

    /// Available spare, with the drive's own threshold alongside it. The
    /// threshold is what `SMARTDiskInfo.classify` compares against, so showing
    /// the bare percentage on its own leaves the user unable to tell why a drive
    /// is (or isn't) flagged. Apple Silicon reports a threshold of 99, which is
    /// exactly why it's worth surfacing rather than hiding.
    private func spareNote(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String? {
        guard let spare = info.availableSparePercent else { return nil }
        guard let threshold = info.availableSpareThresholdPercent else { return "\(spare)%" }
        return "\(spare)% (threshold \(threshold)%)"
    }

    /// NVMe drives (all internal Apple Silicon SSDs) don't have this ATA-only
    /// counter at all — that's a real protocol difference, not a failed read.
    private func reallocatedSectorNote(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String? {
        if let n = info.reallocatedSectorCount { return "\(n)" }
        return info.isSolidState == true ? "N/A on NVMe" : nil
    }

    private func pendingSectorNote(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> String? {
        if let n = info.pendingSectorCount { return "\(n)" }
        return info.isSolidState == true ? "N/A on NVMe" : nil
    }

    private func metric(_ label: String, _ value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(HaloFont.body(9, weight: .semibold))
                .foregroundColor(.haloText3)
            Text(value ?? "Not available on this drive")
                .font(HaloFont.body(12, weight: value == nil ? .regular : .semibold))
                .foregroundColor(value == nil ? .haloText3 : .haloText)
                .italic(value == nil)
                .accessibilityIdentifier("files.driveHealth.field.\(id)")
        }
    }

    // MARK: Lifespan bar

    @ViewBuilder
    private func lifespanSection(_ info: SMARTDiskMonitor.SMARTDiskInfo) -> some View {
        if let remaining = info.lifespanRemainingPercent {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ESTIMATED LIFESPAN REMAINING")
                        .font(HaloFont.body(9, weight: .semibold))
                        .foregroundColor(.haloText3)
                    Spacer()
                    Text("\(remaining)%")
                        .font(HaloFont.mono(12).weight(.semibold))
                        .foregroundColor(remaining < 10 ? .haloRed : (remaining < 25 ? .haloAmber : .haloGreen))
                }
                HaloMiniBar(value: Double(remaining) / 100.0,
                            color: remaining < 10 ? .haloRed : (remaining < 25 ? .haloAmber : .haloGreen))
                Text("Based on the drive's own NVMe wear indicator — no manufacturer lookup table needed.")
                    .font(HaloFont.body(9))
                    .foregroundColor(.haloText3)
            }
        } else {
            Text("Lifespan estimate unavailable — this drive didn't report a wear percentage.")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
        }
    }

    // MARK: Temperature sparkline

    @ViewBuilder
    private var temperatureSection: some View {
        if tempHistory.samples.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("TEMPERATURE · LAST 24H (INTERNAL DRIVE)")
                    .font(HaloFont.body(9, weight: .semibold))
                    .foregroundColor(.haloText3)
                Chart(tempHistory.samples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("°C", sample.celsius))
                        .foregroundStyle(Color.haloCyan)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Time", sample.date), y: .value("°C", sample.celsius))
                        .foregroundStyle(
                            LinearGradient(colors: [Color.haloCyan.opacity(0.35), Color.haloCyan.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Color.haloBorder)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.0f°", d))
                                    .font(.system(size: 9))
                                    .foregroundColor(.haloText3)
                            }
                        }
                    }
                }
                .frame(height: 60)
            }
        } else {
            Text("Collecting temperature history — sampled every 5 minutes while Halo is running.")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
        }
    }

    // MARK: Helpers

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
