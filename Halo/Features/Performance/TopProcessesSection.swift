import SwiftUI
import AppKit

// MARK: - TopProcessesSection  (P3-11)
//
// Foreground-active: 3-second timer, alive only while section is expanded.
// "Force Quit" requires confirmation before calling NSWorkspace.

struct TopProcessesSection: View {
    @State private var monitor = ProcessMonitor()
    @State private var processes: [ProcessMonitor.ProcessInfo] = []
    @State private var sortBy: ProcessMonitor.SortKey = .cpu
    @State private var timer: Timer?
    @State private var isExpanded = true
    @State private var processToQuit: ProcessMonitor.ProcessInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HaloSectionHeader(
                    title: "Top Processes",
                    subtitle: "Live · Top 10",
                    action: { isExpanded.toggle() },
                    actionLabel: isExpanded ? "Hide" : "Show"
                )
                if isExpanded {
                    Spacer()
                    Picker("Sort by", selection: $sortBy) {
                        Text("CPU").tag(ProcessMonitor.SortKey.cpu)
                        Text("RAM").tag(ProcessMonitor.SortKey.ram)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                }
            }

            if isExpanded {
                if processes.isEmpty {
                    ProgressView("Loading processes…")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(processes.enumerated()), id: \.element.id) { idx, proc in
                            ProcessRow(process: proc, sortBy: sortBy) {
                                processToQuit = proc
                            }
                            if idx < processes.count - 1 {
                                Divider().padding(.horizontal, 12).background(Color.haloBorder)
                            }
                        }
                    }
                    .background(Color.haloSurface2)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
                }
            }
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: sortBy) { _ in reload() }
        .confirmationDialog(
            processToQuit.map { "Force Quit \"\($0.name)\"?" } ?? "",
            isPresented: .init(get: { processToQuit != nil }, set: { if !$0 { processToQuit = nil } }),
            titleVisibility: .visible
        ) {
            if let p = processToQuit {
                Button("Force Quit", role: .destructive) {
                    NSWorkspace.shared.terminateApplication(withPid: p.id)
                    processToQuit = nil
                }
            }
            Button("Cancel", role: .cancel) { processToQuit = nil }
        } message: {
            Text("This will immediately terminate the process and may cause unsaved data loss.")
        }
    }

    private func startTimer() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in reload() }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func reload() {
        let key = sortBy
        Task {
            let list = await monitor.topProcesses(sortBy: key, limit: 10)
            await MainActor.run { processes = list }
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessMonitor.ProcessInfo
    let sortBy: ProcessMonitor.SortKey
    let onForceQuit: () -> Void

    @State private var isHovered = false

    private var primaryValue: String {
        switch sortBy {
        case .cpu: return String(format: "%.1f%%", process.cpuPercent)
        case .ram: return String(format: "%.0f MB", process.ramMB)
        }
    }

    private var barValue: Double {
        switch sortBy {
        case .cpu: return min(process.cpuPercent / 100.0, 1.0)
        case .ram: return min(process.ramMB / 1000.0, 1.0)
        }
    }

    private var barColor: Color {
        switch sortBy {
        case .cpu: return process.cpuPercent > 50 ? .haloAmber : .haloAccent
        case .ram: return process.ramMB > 500 ? .haloAmber : .haloPurple
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(barColor.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(systemName: "app.fill")
                    .font(.system(size: 13))
                    .foregroundColor(barColor)
            }

            // Name + bar
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                HaloMiniBar(value: barValue, color: barColor)
            }

            Spacer()

            Text(primaryValue)
                .font(HaloFont.mono(12))
                .foregroundColor(barColor)
                .frame(width: 56, alignment: .trailing)

            if process.isUserApp && isHovered {
                Button("Quit") { onForceQuit() }
                    .buttonStyle(HaloSmallButtonStyle(color: .haloRed))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onHover { isHovered = $0 }
    }
}

// MARK: - NSWorkspace force-quit helper

private extension NSWorkspace {
    func terminateApplication(withPid pid: Int32) {
        let apps = NSWorkspace.shared.runningApplications
        apps.first(where: { $0.processIdentifier == pid })?.forceTerminate()
    }
}
