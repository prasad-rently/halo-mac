import SwiftUI

// MARK: - PortManagerView

struct PortManagerView: View {
    @StateObject private var viewModel = PortManagerViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PortHeader(viewModel: viewModel)
                PortControls(viewModel: viewModel)

                if viewModel.isLoading && !viewModel.hasLoaded {
                    LoadingCard()
                } else if viewModel.filteredPorts.isEmpty {
                    EmptyPortsCard(hasSearch: !viewModel.searchText.isEmpty)
                } else {
                    PortList(viewModel: viewModel)
                }

                if !viewModel.namedPorts.isEmpty {
                    NamedPortsSection(viewModel: viewModel)
                }
            }
            .padding(28)
        }
        .background(Color.haloSurface)
        .onAppear { viewModel.startRefresh() }
        .onDisappear { viewModel.stopRefresh() }
        .alert("Kill Process", isPresented: $viewModel.showKillConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(viewModel.pendingForceKill ? "Force Kill (SIGKILL)" : "Kill (SIGTERM)",
                   role: .destructive) {
                viewModel.confirmKill()
            }
        } message: {
            if let entry = viewModel.pendingKillEntry {
                Text("Kill \(entry.processName) (PID \(entry.pid)) on port \(entry.port)?")
            }
        }
        .sheet(isPresented: $viewModel.showNamedPortEditor) {
            NamedPortEditorSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Header

private struct PortHeader: View {
    @ObservedObject var viewModel: PortManagerViewModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Port Manager")
                    .font(HaloFont.display(28, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Monitor and manage listening network ports")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText3)
            }
            Spacer()

            // Port count badge
            HStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 14))
                Text("\(viewModel.portCount) ports")
                    .font(HaloFont.body(13, weight: .semibold))
            }
            .foregroundColor(.haloAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.haloAccent.opacity(0.12))
            .cornerRadius(8)
        }
    }
}

// MARK: - Controls

private struct PortControls: View {
    @ObservedObject var viewModel: PortManagerViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.haloText3)
                TextField("Search ports, processes…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(HaloFont.body(13))
                if !viewModel.searchText.isEmpty {
                    Button { viewModel.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.haloText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.haloSurface2)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))

            // Sort toggle
            Picker("Sort", selection: $viewModel.sortByPort) {
                Text("Port").tag(true)
                Text("Process").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            // Refresh button
            Button { Task { await viewModel.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.haloText2)
            .help("Refresh port list")

            // Kill signal preference
            Menu {
                ForEach(KillSignalPreference.allCases) { pref in
                    Button {
                        viewModel.setKillSignal(pref)
                    } label: {
                        HStack {
                            Text(pref.rawValue)
                            if viewModel.killSignal == pref {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.haloText2)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("Kill signal preference")
        }

        // Status message
        if let msg = viewModel.statusMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.haloGreen)
                Text(msg)
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                Spacer()
            }
            .padding(10)
            .background(Color.haloGreen.opacity(0.08))
            .cornerRadius(8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut, value: viewModel.statusMessage)
        }
    }
}

// MARK: - Port List

private struct PortList: View {
    @ObservedObject var viewModel: PortManagerViewModel

    var body: some View {
        VStack(spacing: 2) {
            // Column header
            HStack(spacing: 0) {
                Text("PORT")
                    .frame(width: 70, alignment: .leading)
                Text("PROCESS")
                    .frame(minWidth: 120, alignment: .leading)
                Spacer()
                Text("PID")
                    .frame(width: 70, alignment: .trailing)
                Text("PROTOCOL")
                    .frame(width: 70, alignment: .center)
                Text("STATE")
                    .frame(width: 80, alignment: .center)
                // Space for actions
                Color.clear.frame(width: 100)
            }
            .font(HaloFont.mono(10))
            .foregroundColor(.haloText3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ForEach(viewModel.filteredPorts) { entry in
                PortRow(entry: entry, viewModel: viewModel)
            }
        }
        .background(Color.haloSurface2.opacity(0.5))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Port Row

private struct PortRow: View {
    let entry: PortEntry
    @ObservedObject var viewModel: PortManagerViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Port number
            Text("\(entry.port)")
                .font(HaloFont.mono(13))
                .foregroundColor(.haloAccent)
                .frame(width: 70, alignment: .leading)

            // Process name + friendly name badge
            HStack(spacing: 6) {
                Text(entry.processName)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                if let friendly = entry.friendlyName {
                    Text(friendly)
                        .font(HaloFont.body(10, weight: .medium))
                        .foregroundColor(.haloGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.haloGreen.opacity(0.12))
                        .cornerRadius(4)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // PID
            Text("\(entry.pid)")
                .font(HaloFont.mono(12))
                .foregroundColor(.haloText2)
                .frame(width: 70, alignment: .trailing)

            // Protocol
            Text(entry.protocolType)
                .font(HaloFont.mono(11))
                .foregroundColor(.haloCyan)
                .frame(width: 70, alignment: .center)

            // State
            Text(entry.state)
                .font(HaloFont.mono(10))
                .foregroundColor(.haloText3)
                .frame(width: 80, alignment: .center)

            // Actions
            HStack(spacing: 8) {
                // Kill button
                Button {
                    viewModel.requestKill(entry, force: false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.haloRed.opacity(isHovered ? 1.0 : 0.6))
                }
                .buttonStyle(.plain)
                .help("Kill (SIGTERM)")

                // Context menu
                Menu {
                    Button("Kill (SIGTERM)") { viewModel.requestKill(entry, force: false) }
                    Button("Force Kill (SIGKILL)") { viewModel.requestKill(entry, force: true) }
                    Divider()
                    Button("Kill All \"\(entry.processName)\"") {
                        Task { await viewModel.killAllByName(entry.processName) }
                    }
                    Divider()
                    Button("Name This Port…") { viewModel.openNamedPortEditor(for: entry.port) }
                    if entry.friendlyName != nil {
                        Button("Remove Port Name") { viewModel.removeNamedPort(port: entry.port) }
                    }
                    Divider()
                    Button("Copy PID") { viewModel.copyPID(for: entry) }
                    Button("Copy Port") { viewModel.copyPortNumber(for: entry) }
                    Button("Copy lsof Command") { viewModel.copyLsofCommand(for: entry) }
                    Button("Copy kill Command") { viewModel.copyKillCommand(for: entry) }
                    if let path = entry.processPath {
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.haloText3)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.haloAccent.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Empty State

private struct EmptyPortsCard: View {
    let hasSearch: Bool

    var body: some View {
        HaloCard {
            VStack(spacing: 12) {
                Image(systemName: hasSearch ? "magnifyingglass" : "network.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.haloText3)
                Text(hasSearch ? "No ports match your search" : "No listening ports found")
                    .font(HaloFont.body(14, weight: .medium))
                    .foregroundColor(.haloText2)
                Text(hasSearch
                     ? "Try a different search term."
                     : "No processes are currently listening on any port.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
}

// MARK: - Loading Card

private struct LoadingCard: View {
    var body: some View {
        HaloCard {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning open ports…")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
                Spacer()
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Named Ports Section

private struct NamedPortsSection: View {
    @ObservedObject var viewModel: PortManagerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Named Ports")
                    .font(HaloFont.body(15, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                Text("\(viewModel.namedPorts.count)")
                    .font(HaloFont.mono(12))
                    .foregroundColor(.haloText3)
            }

            HaloCard {
                VStack(spacing: 2) {
                    ForEach(viewModel.namedPorts) { named in
                        HStack {
                            Text("\(named.port)")
                                .font(HaloFont.mono(13))
                                .foregroundColor(.haloAccent)
                                .frame(width: 60, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundColor(.haloText3)
                            Text(named.name)
                                .font(HaloFont.body(13, weight: .medium))
                                .foregroundColor(.haloGreen)
                            Spacer()
                            Button {
                                viewModel.openNamedPortEditor(for: named.port)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundColor(.haloText3)
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.removeNamedPort(port: named.port)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.haloRed.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Named Port Editor Sheet

private struct NamedPortEditorSheet: View {
    @ObservedObject var viewModel: PortManagerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Name Port \(viewModel.editingPort)")
                .font(HaloFont.body(16, weight: .semibold))
                .foregroundColor(.haloText)

            TextField("Friendly name (e.g. React Dev Server)", text: $viewModel.editingName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.haloText2)

                Button("Save") {
                    viewModel.addOrUpdateNamedPort(port: viewModel.editingPort, name: viewModel.editingName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color.haloSurface)
    }
}
