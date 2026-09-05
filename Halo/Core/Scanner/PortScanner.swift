import Foundation

// MARK: - PortEntry

struct PortEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let pid: Int32
    let processName: String
    let processPath: String?
    let port: Int
    let protocolType: String          // "TCP" or "UDP"
    let state: String                 // "LISTEN", "ESTABLISHED", etc.
    var friendlyName: String?         // user-assigned via named ports

    var displayName: String {
        if let friendly = friendlyName {
            return "\(processName) (\(friendly))"
        }
        return processName
    }
}

// MARK: - NamedPort

struct NamedPort: Codable, Identifiable, Equatable, Sendable {
    var id: Int { port }
    let port: Int
    let name: String
}

// MARK: - KillSignalPreference

enum KillSignalPreference: String, CaseIterable, Identifiable {
    case ask      = "Ask each time"
    case sigterm  = "Always SIGTERM"
    case sigkill  = "Always SIGKILL"

    var id: String { rawValue }
}

// MARK: - PortScanner

/// Scans for open ports by parsing `lsof` output.
/// Actor-isolated to prevent concurrent scan conflicts.
actor PortScanner {

    /// Scan all listening TCP and UDP ports.
    func scan() async -> [PortEntry] {
        let tcpEntries = await parseLsof(args: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"])
        let udpEntries = await parseLsof(args: ["-iUDP", "-P", "-n"])

        // Deduplicate by (pid, port, protocol)
        var seen: Set<String> = []
        var result: [PortEntry] = []
        for entry in tcpEntries + udpEntries {
            let key = "\(entry.pid):\(entry.port):\(entry.protocolType)"
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// Kill a process by PID.
    func killProcess(pid: Int32, force: Bool) async -> (Bool, String) {
        let signal = force ? "KILL" : "TERM"
        let result = ShellReader.run("/bin/kill", ["-\(signal)", String(pid)])

        if let failure = result.launchFailure {
            return (false, failure)
        }
        if result.didTimeOut {
            return (false, "Timed out trying to signal process \(pid).")
        }
        guard result.exitCode == 0 else {
            // `kill` reports the reason on stderr ("No such process",
            // "Operation not permitted"), which is exactly what the user needs
            // to see — previously it shared one pipe with stdout.
            let reason = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, reason.isEmpty ? "Failed to kill process \(pid)." : reason)
        }
        return (true, "Process \(pid) killed with SIG\(signal).")
    }

    // MARK: - Private

    private func parseLsof(args: [String]) async -> [PortEntry] {
        // `lsof` is the highest-volume tool Halo invokes: ~10 KB across 87 open
        // connections on the dev machine, so a heavily loaded Mac can approach
        // the 64 KB pipe buffer. It also writes permission-denied warnings to
        // stderr for other users' sockets. ShellReader drains both streams
        // concurrently and bounds the whole call — see its header.
        let result = ShellReader.run("/usr/sbin/lsof", args)
        guard result.launchFailure == nil else { return [] }
        let output = result.standardOutput

        var entries: [PortEntry] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {  // skip header
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            let pidString = parts[1]
            guard let pid = Int32(pidString) else { continue }

            // Determine protocol from TYPE column (index 4 or 7)
            let protocolType: String
            if parts.contains("IPv4") || parts.contains("IPv6") {
                protocolType = parts.contains(where: { $0.uppercased().contains("UDP") }) ? "UDP" : "TCP"
            } else {
                protocolType = "TCP"
            }

            // NAME column is the last field, format: "hostname:port" or "*:port"
            let nameField = parts.last ?? ""

            // Extract port number from the NAME field
            let port: Int
            if let colonIndex = nameField.lastIndex(of: ":") {
                let portStr = String(nameField[nameField.index(after: colonIndex)...])
                port = Int(portStr) ?? 0
            } else {
                continue
            }

            guard port > 0 else { continue }

            // Determine state — look for (LISTEN), (ESTABLISHED), etc.
            let state: String
            if let stateField = parts.last(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }) {
                state = String(stateField.dropFirst().dropLast())
            } else {
                state = "LISTEN"
            }

            // Try to get the process path via /proc or ps
            let processPath = getProcessPath(pid: pid)

            entries.append(PortEntry(
                id: UUID(),
                pid: pid,
                processName: processName,
                processPath: processPath,
                port: port,
                protocolType: protocolType,
                state: state
            ))
        }

        return entries
    }

    private func getProcessPath(pid: Int32) -> String? {
        // `ps` exits non-zero when the pid is already gone, which is a normal
        // race here (the process can exit between the lsof scan and this
        // lookup) — so a nil return is the right answer, not an error.
        guard let raw = ShellReader.output("/bin/ps", ["-p", String(pid), "-o", "comm="]) else {
            return nil
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
