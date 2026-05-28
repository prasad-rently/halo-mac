import Foundation
import ServiceManagement

// MARK: - LoginItemScanner (F-009)
//
// Enumerates real login items from LaunchAgent / LaunchDaemon plist files in
// the three standard directories.  Returns the list sorted: suspicious first,
// then alphabetically.
//
// NOTE: SMAppService is used only for Halo's own "Launch at Login" toggle
//       (see LaunchAtLoginManager below).  Enumerating other apps' SMAppService
//       registrations is not possible with the public API.

actor LoginItemScanner {

    // MARK: - Scan

    /// Returns all discovered auto-start items, suspicious entries first.
    func scan() async -> [LoginItem] {
        let items = await plistItems()

        // De-duplicate by path
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.path).inserted }

        // Suspicious first, then alphabetical
        return unique.sorted {
            if $0.isSuspicious != $1.isSuspicious { return $0.isSuspicious }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Plist enumeration

    private func plistItems() async -> [LoginItem] {
        let home = NSHomeDirectory()
        let dirs: [(path: String, kind: LoginItemKind)] = [
            ("\(home)/Library/LaunchAgents", .launchAgent),
            ("/Library/LaunchAgents",        .launchAgent),
            ("/Library/LaunchDaemons",       .launchAgent),
        ]

        let fm = FileManager.default
        var results: [LoginItem] = []

        for dir in dirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            let plists = (try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir.path),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ))?.filter { $0.pathExtension == "plist" } ?? []

            for url in plists {
                if let item = parsePlist(at: url, kind: dir.kind) {
                    results.append(item)
                }
            }
        }
        return results
    }

    private func parsePlist(at url: URL, kind: LoginItemKind) -> LoginItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }

        let label   = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let args    = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? args.first ?? ""

        // Only include items that auto-start (RunAtLoad or KeepAlive=true)
        let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        let keepAlive = plist["KeepAlive"] as? Bool ?? false
        guard runAtLoad || keepAlive else { return nil }

        let isEnabled = !(plist["Disabled"] as? Bool ?? false)

        let isSuspicious = isSuspiciousItem(label: label, program: program)

        // Derive a readable name from the program path or label
        let name: String
        if !program.isEmpty {
            name = URL(fileURLWithPath: program)
                .deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        } else {
            name = label.components(separatedBy: ".").last ?? label
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        return LoginItem(
            name: name,
            bundleIdentifier: label.contains(".") ? label : nil,
            path: url.path,
            isEnabled: isEnabled,
            ramUsageMB: 0,
            lastLaunchedDate: modified,
            kind: kind,
            isSuspicious: isSuspicious
        )
    }

    private func isSuspiciousItem(label: String, program: String) -> Bool {
        let p = program.lowercased()
        if p.contains("/private/tmp/") || p.contains("/var/folders/") { return true }
        let parts = label.components(separatedBy: ".")
        if let last = parts.last, last.count < 14, last.filter(\.isNumber).count > 5 { return true }
        return false
    }
}

// MARK: - LaunchAtLoginManager (F-009)
//
// Controls whether Halo itself launches at login, using SMAppService (macOS 13+).
// Exposed as a static helper so PerformanceViewModel and SettingsView can call it.

enum LaunchAtLoginManager {

    /// Returns true when Halo is registered as a login item via SMAppService.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Registers or unregisters Halo as a login item.  Returns the new state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return SMAppService.mainApp.status == .enabled
            } catch {
                return isEnabled
            }
        }
        return false
    }
}
