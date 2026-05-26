import SwiftUI

// MARK: - DiskHealthSection  (P3-07)
//
// Volume usage shown immediately (cheap FileManager call).
// SMART check is on-demand only — never runs automatically.

struct DiskHealthSection: View {
    @State private var monitor = DiskHealthMonitor()
    @State private var volumes: [DiskHealthMonitor.VolumeInfo] = []
    @State private var disks:   [DiskHealthMonitor.DiskInfo]   = []
    @State private var isScanRunning = false
    @State private var scanDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Disk Health",
                              subtitle: scanDone ? "Checked" : "On Demand")

            // Volume usage cards
            if !volumes.isEmpty {
                VStack(spacing: 8) {
                    ForEach(volumes) { vol in VolumeCard(vol: vol) }
                }
            }

            // SMART check
            HaloCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 14))
                            .foregroundColor(.haloAccent)
                        Text("SMART Disk Health")
                            .font(HaloFont.display(14, weight: .semibold))
                            .foregroundColor(.haloText)
                        Spacer()
                        if isScanRunning {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            HaloPrimaryButton(
                                scanDone ? "Re-Check" : "Check Disk Health",
                                icon: "magnifyingglass",
                                isLoading: isScanRunning
                            ) { runScan() }
                        }
                    }

                    if !disks.isEmpty {
                        Divider().background(Color.haloBorder)
                        ForEach(disks) { disk in DiskRow(disk: disk) }
                    } else if !isScanRunning {
                        Text("Tap \"Check Disk Health\" to run a SMART status check.")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText3)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { loadVolumes() }
    }

    private func loadVolumes() {
        Task {
            let v = await monitor.volumeUsage()
            await MainActor.run { volumes = v }
        }
    }

    private func runScan() {
        isScanRunning = true
        Task {
            // Refresh volumes too on each scan — drives may have been mounted/unmounted
            async let freshVolumes = monitor.volumeUsage()
            async let diskResults  = monitor.scanAllDisks()
            let (v, result) = await (freshVolumes, diskResults)
            await MainActor.run {
                volumes = v
                disks = result
                isScanRunning = false
                scanDone = true
            }
        }
    }
}

// MARK: - Volume card

private struct VolumeCard: View {
    let vol: DiskHealthMonitor.VolumeInfo

    private var usageColor: Color {
        if vol.usageRatio > 0.9 { return .haloRed }
        if vol.usageRatio > 0.75 { return .haloAmber }
        return .haloGreen
    }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 12))
                        .foregroundColor(usageColor)
                    Text(vol.name)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Spacer()
                    Text(vol.freeLabel)
                        .font(HaloFont.mono(11))
                        .foregroundColor(.haloText2)
                }
                HaloMiniBar(value: vol.usageRatio, color: usageColor)
                HStack {
                    Text(String(format: "%.1f GB used", vol.usedGB))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                    Spacer()
                    Text(String(format: "%.0f GB total", vol.totalGB))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Disk SMART row

private struct DiskRow: View {
    let disk: DiskHealthMonitor.DiskInfo

    private var statusColor: Color {
        switch disk.smartStatus {
        case .verified: return .haloGreen
        case .warning:  return .haloAmber
        case .failed:   return .haloRed
        case .unavailable: return .haloText3
        }
    }

    private var statusLabel: String {
        switch disk.smartStatus {
        case .verified:           return "Verified"
        case .warning(let s):     return "Warning: \(s)"
        case .failed(let s):      return "Failed: \(s)"
        case .unavailable:        return "N/A"
        }
    }

    private var statusIcon: String {
        switch disk.smartStatus {
        case .verified:    return "checkmark.shield.fill"
        case .warning:     return "exclamationmark.triangle.fill"
        case .failed:      return "xmark.shield.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14))
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.model.isEmpty ? disk.bsdName : disk.model)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text(statusLabel)
                        .font(HaloFont.body(11))
                        .foregroundColor(statusColor)
                }
                Spacer()
                if disk.totalGB > 0 {
                    Text(String(format: "%.0f GB", disk.totalGB))
                        .font(HaloFont.mono(11))
                        .foregroundColor(.haloText2)
                }
            }

            if disk.lifetimeWrittenGB > 0 || disk.lifetimeReadGB > 0 {
                HStack(spacing: 16) {
                    if disk.lifetimeWrittenGB > 0 {
                        Text(String(format: "Written: %.1f TB", disk.lifetimeWrittenGB / 1024))
                            .font(HaloFont.body(10)).foregroundColor(.haloText3)
                    }
                    if disk.lifetimeReadGB > 0 {
                        Text(String(format: "Read: %.1f TB", disk.lifetimeReadGB / 1024))
                            .font(HaloFont.body(10)).foregroundColor(.haloText3)
                    }
                    if let h = disk.powerOnHours {
                        Text("Power on: \(h) hrs")
                            .font(HaloFont.body(10)).foregroundColor(.haloText3)
                    }
                }
            }
        }
    }
}
