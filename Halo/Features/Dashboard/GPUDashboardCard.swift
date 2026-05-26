import SwiftUI

// MARK: - GPUDashboardCard  (F-001)
//
// Foreground-active — samples GPUMonitor every 2 s while Dashboard is visible.
// Timer owned here; actor is released when view disappears (zero background cost).
// Supports multi-GPU Macs (e.g. Intel + AMD dGPU); shows one row per GPU.

struct GPUDashboardCard: View {

    @State private var gpuStats: [GPUMonitor.GPUStats] = []
    @State private var timer: Timer?

    private let monitor = GPUMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "GPU")

            HaloCard {
                if gpuStats.isEmpty {
                    // Placeholder while first sample arrives
                    HStack(spacing: 10) {
                        Image(systemName: "cpu")
                            .font(.system(size: 14))
                            .foregroundColor(.haloText3)
                        Text("Reading GPU data…")
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText3)
                        Spacer()
                    }
                    .padding(18)
                } else {
                    VStack(spacing: 16) {
                        ForEach(Array(gpuStats.enumerated()), id: \.offset) { _, gpu in
                            GPURowView(gpu: gpu)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .onAppear  { startSampling() }
        .onDisappear { stopSampling() }
    }

    // MARK: - Sampling

    private func startSampling() {
        Task { await sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await sample() }
        }
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func sample() async {
        let stats = await monitor.sample()
        gpuStats = stats
    }
}

// MARK: - Single GPU row

private struct GPURowView: View {

    let gpu: GPUMonitor.GPUStats

    private var utilColor: Color {
        if gpu.utilisation >= 0.85 { return .haloRed }
        if gpu.utilisation >= 0.60 { return .haloAmber }
        return .haloCyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Name + overall utilisation badge
            HStack(spacing: 8) {
                Image(systemName: "gpu.amd.pro.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.haloCyan)
                    .symbolRenderingMode(.hierarchical)

                Text(cleanName(gpu.name))
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(String(format: "%.0f%%", gpu.utilisation * 100))
                    .font(HaloFont.display(18, weight: .bold))
                    .foregroundColor(utilColor)
            }

            // Overall utilisation bar
            HaloMiniBar(value: gpu.utilisation, color: utilColor)

            // Renderer / Tiler sub-bars (Apple Silicon shows both; Intel shows renderer only)
            HStack(spacing: 20) {
                GPUSubBar(label: "Renderer", value: gpu.rendererUtil)
                if gpu.tilerUtil > 0 {
                    GPUSubBar(label: "Tiler", value: gpu.tilerUtil)
                }
                Spacer()

                // VRAM / shared memory
                if gpu.memoryTotalMB > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(gpu.memoryUsedMB) MB")
                            .font(HaloFont.mono(11))
                            .foregroundColor(.haloText)
                        Text("of \(gpu.memoryTotalMB) MB")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                }
            }

            // Memory bar (only when data is available and meaningful)
            if gpu.memoryTotalMB > 0 && gpu.memoryUsage > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 9))
                        .foregroundColor(.haloText3)
                    HaloMiniBar(
                        value: gpu.memoryUsage,
                        color: gpu.memoryUsage > 0.85 ? .haloRed : gpu.memoryUsage > 0.60 ? .haloAmber : .haloPurple
                    )
                }
            }
        }
    }

    /// Strip IOKit class-name noise: "AGXMetalG14X" → "Apple GPU",
    /// "AMDRadeonRX5600M" → "Radeon RX 5600M"
    private func cleanName(_ raw: String) -> String {
        if raw.hasPrefix("AGX")     { return "Apple GPU" }
        if raw.hasPrefix("AGXG")    { return "Apple GPU" }
        if raw.hasPrefix("AMD")     { return raw.replacingOccurrences(of: "AMD", with: "AMD ").trimmingCharacters(in: .whitespaces) }
        if raw.hasPrefix("Intel")   { return raw }
        if raw == "GPU"             { return "Integrated GPU" }
        return raw
    }
}

// MARK: - Sub-metric bar (Renderer / Tiler)

private struct GPUSubBar: View {
    let label: String
    let value: Double   // 0–1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                Text(String(format: "%.0f%%", value * 100))
                    .font(HaloFont.mono(10))
                    .foregroundColor(.haloText2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.haloBorder)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.haloCyan.opacity(0.75))
                        .frame(width: geo.size.width * max(0, min(value, 1)), height: 4)
                }
            }
            .frame(height: 4)
            .frame(minWidth: 60, maxWidth: 100)
        }
    }
}
