import SwiftUI

// MARK: - NetworkDetailSection  (P3-05 + P3-06)
//
// Foreground-active: detail fetched on onAppear, public IP fetched once per session.
// Speed test: on-demand only, cancels automatically when user navigates away.

struct NetworkDetailSection: View {
    @EnvironmentObject var appState: AppState
    @State private var monitor = NetworkDetailMonitor()
    @State private var detail: NetworkDetailMonitor.NetworkDetail?
    @State private var isLoadingDetail = false
    @State private var speedTestState: SpeedTestState = .idle
    @State private var speedResult: SpeedTestService.SpeedResult?
    @State private var speedProgress: SpeedTestService.SpeedTestProgress?
    @State private var speedTestTask: Task<Void, Never>?
    @State private var isExpanded = true

    enum SpeedTestState { case idle, running, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(
                title: "Network",
                subtitle: appState.isVPNActive ? "VPN Active" : "Direct",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                HaloCard {
                    VStack(alignment: .leading, spacing: 14) {

                        // VPN badge
                        if appState.isVPNActive {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.haloGreen)
                                Text("VPN Active")
                                    .font(HaloFont.body(13, weight: .semibold))
                                    .foregroundColor(.haloGreen)
                                Spacer()
                            }
                            Divider().background(Color.haloBorder)
                        }

                        if isLoadingDetail {
                            ProgressView("Fetching network info…")
                                .frame(maxWidth: .infinity)
                        } else if let d = detail {
                            // Network info grid
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                      alignment: .leading, spacing: 10) {
                                NetInfoCell(label: "Local IPv4",  value: d.localIPv4 ?? "—")
                                NetInfoCell(label: "WiFi SSID",   value: d.wifiSSID ?? "—")
                                NetInfoCell(label: "Interface",   value: d.activeInterface ?? "—")
                                NetInfoCell(label: "Public IP",   value: d.publicIP ?? "Fetching…",
                                            canCopy: d.publicIP != nil)
                            }

                            // Interface list
                            if !d.interfaces.isEmpty {
                                Divider().background(Color.haloBorder)
                                ForEach(d.interfaces) { iface in
                                    InterfaceRow(iface: iface)
                                }
                            }
                        }

                        Divider().background(Color.haloBorder)

                        // Speed test card
                        SpeedTestCard(
                            state: speedTestState,
                            progress: speedProgress,
                            result: speedResult,
                            onRun: { runSpeedTest() },
                            onCancel: { speedTestTask?.cancel(); speedTestState = .idle }
                        )
                    }
                    .padding(18)
                }
            }
        }
        .onAppear { loadDetail() }
        .onDisappear { speedTestTask?.cancel() }
    }

    private func loadDetail() {
        isLoadingDetail = true
        Task {
            async let d = monitor.fetchDetail()
            async let ip = monitor.fetchPublicIP()
            var loaded = await d
            loaded.publicIP = await ip
            await MainActor.run {
                detail = loaded
                isLoadingDetail = false
            }
        }
    }

    private func runSpeedTest() {
        speedTestState = .running
        speedResult = nil
        let svc = SpeedTestService()
        speedTestTask = Task {
            do {
                let result = try await svc.runTest { p in
                    Task { @MainActor in speedProgress = p }
                }
                await MainActor.run {
                    speedResult = result
                    speedTestState = .done
                }
            } catch {
                await MainActor.run { speedTestState = .idle }
            }
        }
    }
}

// MARK: - Speed Test Card

private struct SpeedTestCard: View {
    let state: NetworkDetailSection.SpeedTestState
    let progress: SpeedTestService.SpeedTestProgress?
    let result: SpeedTestService.SpeedResult?
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 12))
                    .foregroundColor(.haloAccent)
                Text("Internet Speed Test")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                switch state {
                case .idle:
                    Button("Run Test", action: onRun)
                        .buttonStyle(HaloSmallButtonStyle(color: .haloAccent))
                case .running:
                    Button("Cancel", action: onCancel)
                        .buttonStyle(HaloSmallButtonStyle(color: .haloRed))
                case .done:
                    Button("Run Again", action: onRun)
                        .buttonStyle(HaloSmallButtonStyle(color: .haloAccent))
                }
            }

            if state == .running, let p = progress {
                SpeedProgressRow(progress: p)
            }

            if let r = result {
                HStack(spacing: 16) {
                    SpeedChip(icon: "arrow.down.circle.fill", label: "Download",
                              value: String(format: "%.1f", r.downloadMbps), unit: "Mbps", color: .haloAccent)
                    SpeedChip(icon: "arrow.up.circle.fill", label: "Upload",
                              value: String(format: "%.1f", r.uploadMbps), unit: "Mbps", color: .haloPurple)
                    SpeedChip(icon: "bolt.fill", label: "Latency",
                              value: String(format: "%.0f", r.latencyMs), unit: "ms", color: .haloAmber)
                }
            }
        }
    }
}

private struct SpeedProgressRow: View {
    let progress: SpeedTestService.SpeedTestProgress

    private var label: String {
        switch progress {
        case .pinging(let i, let of): return "Pinging \(i)/\(of)…"
        case .downloading(let pct, let mbps): return String(format: "Downloading %.0f%% — %.1f Mbps", pct*100, mbps)
        case .uploading(let pct, _): return String(format: "Uploading %.0f%%…", pct*100)
        case .done: return "Done"
        }
    }

    private var pct: Double {
        switch progress {
        case .pinging: return 0.1
        case .downloading(let p, _): return 0.2 + p * 0.5
        case .uploading(let p, _):   return 0.7 + p * 0.3
        case .done: return 1.0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(HaloFont.body(11)).foregroundColor(.haloText2)
            ProgressView(value: pct)
                .tint(.haloAccent)
                .animation(.easeInOut, value: pct)
        }
    }
}

private struct SpeedChip: View {
    let icon: String; let label: String; let value: String; let unit: String; let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            Text(value).font(HaloFont.display(16, weight: .bold)).foregroundColor(color)
            Text(unit).font(HaloFont.body(9)).foregroundColor(.haloText3)
            Text(label).font(HaloFont.body(9)).foregroundColor(.haloText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - Net Info helpers

private struct NetInfoCell: View {
    let label: String; let value: String; var canCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(HaloFont.body(10)).foregroundColor(.haloText3)
            HStack(spacing: 4) {
                Text(value).font(HaloFont.mono(12)).foregroundColor(.haloText)
                if canCopy {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(.haloAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct InterfaceRow: View {
    let iface: NetworkDetailMonitor.InterfaceInfo

    private var typeColor: Color {
        switch iface.type {
        case "VPN":     return .haloGreen
        case "Wi-Fi":   return .haloAccent
        case "Ethernet": return .haloCyan
        default:        return .haloText3
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(iface.isActive ? typeColor : .haloText3).frame(width: 7, height: 7)
            Text(iface.id).font(HaloFont.mono(11)).foregroundColor(.haloText)
            HaloBadge(text: iface.type, color: typeColor)
            Spacer()
            if let ip = iface.ipv4 {
                Text(ip).font(HaloFont.mono(11)).foregroundColor(.haloText2)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Small button style

struct HaloSmallButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HaloFont.body(11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(color.opacity(0.1))
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
