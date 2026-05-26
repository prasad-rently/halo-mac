import SwiftUI

// MARK: - CPUCoresSection  (P3-01)
//
// Foreground-active: timer started on onAppear, cancelled on onDisappear.
// CPUDetailMonitor is created as @StateObject — auto-deallocated with the view.

struct CPUCoresSection: View {
    @State private var monitor = CPUDetailMonitor()
    @State private var cores: [CPUDetailMonitor.CoreSample] = []
    @State private var timer: Timer?
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(
                title: "CPU Cores",
                subtitle: "\(cores.count) logical cores",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                if cores.isEmpty {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Sampling…")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let pCores = cores.filter { !$0.isEfficiency }
                    let eCores = cores.filter {  $0.isEfficiency }

                    VStack(alignment: .leading, spacing: 8) {
                        if !pCores.isEmpty {
                            CoreGroupLabel("Performance Cores (\(pCores.count))", color: .haloAccent)
                            ForEach(pCores) { core in CoreRow(core: core) }
                        }
                        if !eCores.isEmpty {
                            CoreGroupLabel("Efficiency Cores (\(eCores.count))", color: .haloGreen)
                            ForEach(eCores) { core in CoreRow(core: core) }
                        }
                        if pCores.isEmpty && eCores.isEmpty {
                            ForEach(cores) { core in CoreRow(core: core) }
                        }
                    }
                    .padding(14)
                    .background(Color.haloSurface2)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
                }
            }
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        Task { cores = await monitor.sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task {
                let s = await monitor.sample()
                await MainActor.run { cores = s }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Sub-views

private struct CoreGroupLabel: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(HaloFont.body(10, weight: .semibold))
            .foregroundColor(color)
            .tracking(1)
            .textCase(.uppercase)
            .padding(.top, 4)
    }
}

private struct CoreRow: View {
    let core: CPUDetailMonitor.CoreSample

    private var barColor: Color {
        if core.usage > 0.8 { return .haloRed }
        if core.usage > 0.5 { return .haloAmber }
        return core.isEfficiency ? .haloGreen : .haloAccent
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("C\(core.id)")
                .font(HaloFont.mono(10))
                .foregroundColor(.haloText3)
                .frame(width: 22, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.haloSurface)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * core.usage), height: 8)
                        .animation(.easeOut(duration: 0.3), value: core.usage)
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f%%", core.usage * 100))
                .font(HaloFont.mono(10))
                .foregroundColor(barColor)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
