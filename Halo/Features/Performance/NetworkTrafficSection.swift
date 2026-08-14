import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - NetworkTrafficSection (F-017)
//
// Sub-section embedded in the existing Network card (see
// NetworkDetailSection.swift). See NetworkTrafficMonitor.swift for the full
// feasibility/honesty notes on what's real (open sockets via lsof, per-app
// byte totals via nettop) vs best-effort (reverse-DNS hostnames).
//
// Sampled every 2 s while visible — rate-limited per the feature spec to
// avoid CPU overhead from repeated lsof/nettop process spawns.

struct NetworkTrafficSection: View {
    @State private var monitor = NetworkTrafficMonitor()
    @State private var snapshot: NetworkTrafficSnapshot?
    @State private var isExpanded = false
    @State private var filterText = ""
    @State private var sortMode: TrafficSort = .recency
    @State private var pollTask: Task<Void, Never>?

    enum TrafficSort: String, CaseIterable, Identifiable {
        case recency = "Recent"
        case app = "App Name"
        case traffic = "Data"
        var id: String { rawValue }
    }

    private var filteredConnections: [NetworkConnectionEntry] {
        guard let snapshot else { return [] }
        let base = filterText.isEmpty
            ? snapshot.connections
            : snapshot.connections.filter { $0.processName.localizedCaseInsensitiveContains(filterText) }
        switch sortMode {
        case .recency:
            return base.sorted { $0.lastSeen > $1.lastSeen }
        case .app:
            return base.sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
        case .traffic:
            return base.sorted { (appTotal(for: $0.pid)?.totalBytes ?? 0) > (appTotal(for: $1.pid)?.totalBytes ?? 0) }
        }
    }

    // Joined by pid, not processName — lsof and nettop truncate the same
    // process's name to different lengths (see AppNetworkTotal's doc
    // comment), so pid is the only reliable key between the two.
    private func appTotal(for pid: Int32) -> AppNetworkTotal? {
        snapshot?.appTotals.first { $0.pid == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().background(Color.haloBorder)

            HaloSectionHeader(
                title: "Network Traffic Monitor",
                subtitle: "Read-only \u{00B7} no blocking",
                action: { isExpanded.toggle() },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let topTalker = snapshot?.topTalker, topTalker.totalBytes > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12))
                                .foregroundColor(.haloAccent)
                            Text("Top talker: \(topTalker.processName) \u{2014} \(formatBytes(topTalker.totalBytes)) this session")
                                .font(HaloFont.body(12, weight: .semibold))
                                .foregroundColor(.haloText)
                            Spacer()
                        }
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(.haloText3)
                            TextField("Filter by app…", text: $filterText)
                                .textFieldStyle(.plain)
                                .font(HaloFont.body(12))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.haloSurface)
                        .cornerRadius(7)

                        Picker("", selection: $sortMode) {
                            ForEach(TrafficSort.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }

                    if snapshot == nil {
                        ProgressView("Scanning connections…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else if filteredConnections.isEmpty {
                        Text("No active outbound connections match.")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 0) {
                            TrafficHeaderRow()
                            ForEach(filteredConnections.prefix(50)) { entry in
                                TrafficRow(entry: entry, appTotal: appTotal(for: entry.pid))
                                if entry.id != filteredConnections.prefix(50).last?.id {
                                    Divider().background(Color.haloBorder)
                                }
                            }
                        }
                        .background(Color.haloSurface)
                        .cornerRadius(8)
                    }

                    Text("Remote Host is best-effort reverse DNS on the real IP address — many hosts (CDNs, load balancers) resolve to a generic infrastructure name rather than the domain you'd recognize, or don't resolve at all; unresolved hosts are never flagged as suspicious. Data totals are real per-app session figures from nettop — macOS doesn't expose per-connection byte counts to third-party apps.")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: isExpanded) { expanded in
            if expanded { startPolling() } else { pollTask?.cancel() }
        }
    }

    private func startPolling() {
        guard isExpanded else { return }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                let snap = await monitor.snapshot()
                if Task.isCancelled { return }
                await MainActor.run { snapshot = snap }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Rows

private struct TrafficHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("App").frame(width: 100, alignment: .leading)
            Text("Remote Host (best-effort)").frame(maxWidth: .infinity, alignment: .leading)
            Text("Proto").frame(width: 36, alignment: .leading)
            Text("Data (session)").frame(width: 90, alignment: .trailing)
            Text("Last Seen").frame(width: 64, alignment: .trailing)
        }
        .font(HaloFont.body(9, weight: .semibold))
        .foregroundColor(.haloText3)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct TrafficRow: View {
    let entry: NetworkConnectionEntry
    let appTotal: AppNetworkTotal?

    private var icon: NSImage {
        NSRunningApplication(processIdentifier: entry.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }

    private var dataText: String {
        guard let appTotal, appTotal.totalBytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(appTotal.totalBytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                if entry.isSuspicious {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.haloRed)
                }
                Text(entry.processName)
                    .font(HaloFont.body(11, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)

            Text(entry.displayHost)
                .font(HaloFont.mono(10))
                .foregroundColor(entry.isSuspicious ? .haloRed : .haloText2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.protocolType)
                .font(HaloFont.mono(10))
                .foregroundColor(.haloText3)
                .frame(width: 36, alignment: .leading)

            Text(dataText)
                .font(HaloFont.mono(10))
                .foregroundColor(.haloText2)
                .frame(width: 90, alignment: .trailing)

            Text(entry.lastSeen, style: .time)
                .font(HaloFont.mono(9))
                .foregroundColor(.haloText3)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
