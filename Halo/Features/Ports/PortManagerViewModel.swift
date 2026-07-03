import Foundation
import SwiftUI

// MARK: - PortManagerViewModel

@MainActor
final class PortManagerViewModel: ObservableObject {

    // MARK: Published state

    @Published var ports: [PortEntry] = []
    @Published var namedPorts: [NamedPort] = []
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var killSignal: KillSignalPreference = .ask
    @Published var sortByPort = true   // true = by port number, false = by process name

    // Kill confirmation
    @Published var showKillConfirm = false
    @Published var pendingKillEntry: PortEntry?
    @Published var pendingForceKill = false

    // Named port editor
    @Published var showNamedPortEditor = false
    @Published var editingPort: Int = 0
    @Published var editingName: String = ""

    // Status message
    @Published var statusMessage: String?

    // MARK: Private

    private let scanner = PortScanner()
    private var refreshTimer: Timer?
    private let namedPortsKey = "haloNamedPorts"

    // MARK: - Init / Deinit

    init() {
        loadNamedPorts()
        loadKillSignal()
    }

    // MARK: - Refresh lifecycle

    func startRefresh() {
        Task { await refresh() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        if !hasLoaded { isLoading = true }
        let scanned = await scanner.scan()
        // Enrich with named ports
        var enriched = scanned
        for i in enriched.indices {
            enriched[i].friendlyName = namedPorts.first(where: { $0.port == enriched[i].port })?.name
        }
        ports = enriched
        isLoading = false
        hasLoaded = true
    }

    // MARK: - Filtered / Sorted

    var filteredPorts: [PortEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var result = ports

        if !trimmed.isEmpty {
            result = result.filter { entry in
                entry.processName.lowercased().contains(trimmed)
                    || String(entry.port).contains(trimmed)
                    || (entry.friendlyName?.lowercased().contains(trimmed) ?? false)
                    || (entry.processPath?.lowercased().contains(trimmed) ?? false)
            }
        }

        if sortByPort {
            result.sort { $0.port < $1.port }
        } else {
            result.sort { $0.processName.lowercased() < $1.processName.lowercased() }
        }

        return result
    }

    var portCount: Int { ports.count }

    // MARK: - Kill actions

    func requestKill(_ entry: PortEntry, force: Bool) {
        let savedPref = killSignal
        if savedPref == .ask {
            pendingKillEntry = entry
            pendingForceKill = force
            showKillConfirm = true
        } else {
            let useForce = savedPref == .sigkill
            Task { await performKill(entry, force: useForce) }
        }
    }

    func confirmKill() {
        guard let entry = pendingKillEntry else { return }
        showKillConfirm = false
        Task { await performKill(entry, force: pendingForceKill) }
    }

    private func performKill(_ entry: PortEntry, force: Bool) async {
        let (success, message) = await scanner.killProcess(pid: entry.pid, force: force)
        if success {
            statusMessage = "Killed \(entry.processName) on port \(entry.port)"
            // Remove from list immediately
            ports.removeAll { $0.pid == entry.pid && $0.port == entry.port }
        } else {
            statusMessage = "Failed: \(message)"
        }

        // Clear status after 3 seconds
        let currentMessage = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.statusMessage == currentMessage {
                self?.statusMessage = nil
            }
        }
    }

    func killAllByName(_ processName: String) async {
        let targets = ports.filter { $0.processName == processName }
        for entry in targets {
            _ = await scanner.killProcess(pid: entry.pid, force: killSignal == .sigkill)
        }
        ports.removeAll { $0.processName == processName }
        statusMessage = "Killed all \(processName) processes (\(targets.count))"
    }

    // MARK: - Named Ports CRUD

    func addOrUpdateNamedPort(port: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let idx = namedPorts.firstIndex(where: { $0.port == port }) {
            namedPorts[idx] = NamedPort(port: port, name: trimmed)
        } else {
            namedPorts.append(NamedPort(port: port, name: trimmed))
        }
        persistNamedPorts()

        // Update displayed ports
        for i in ports.indices where ports[i].port == port {
            ports[i].friendlyName = trimmed
        }
    }

    func removeNamedPort(port: Int) {
        namedPorts.removeAll { $0.port == port }
        persistNamedPorts()

        for i in ports.indices where ports[i].port == port {
            ports[i].friendlyName = nil
        }
    }

    func openNamedPortEditor(for port: Int) {
        editingPort = port
        editingName = namedPorts.first(where: { $0.port == port })?.name ?? ""
        showNamedPortEditor = true
    }

    // MARK: - Copy helpers

    func copyLsofCommand(for entry: PortEntry) {
        let cmd = "lsof -i :\(entry.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        statusMessage = "Copied: \(cmd)"
    }

    func copyKillCommand(for entry: PortEntry) {
        let cmd = "kill -9 \(entry.pid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        statusMessage = "Copied: \(cmd)"
    }

    func copyPID(for entry: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(entry.pid), forType: .string)
        statusMessage = "Copied PID: \(entry.pid)"
    }

    func copyPortNumber(for entry: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(entry.port), forType: .string)
        statusMessage = "Copied port: \(entry.port)"
    }

    // MARK: - Kill signal preference

    func setKillSignal(_ pref: KillSignalPreference) {
        killSignal = pref
        UserDefaults.standard.set(pref.rawValue, forKey: "haloKillSignalPref")
    }

    private func loadKillSignal() {
        if let raw = UserDefaults.standard.string(forKey: "haloKillSignalPref"),
           let pref = KillSignalPreference(rawValue: raw) {
            killSignal = pref
        }
    }

    // MARK: - Persistence

    private func loadNamedPorts() {
        guard let data = UserDefaults.standard.data(forKey: namedPortsKey),
              let decoded = try? JSONDecoder().decode([NamedPort].self, from: data) else { return }
        namedPorts = decoded
    }

    private func persistNamedPorts() {
        if let data = try? JSONEncoder().encode(namedPorts) {
            UserDefaults.standard.set(data, forKey: namedPortsKey)
        }
    }
}
