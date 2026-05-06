import Foundation

// MARK: - Protection Scanner
// Real file-system scanner for malware signatures, browser data, and launch agents.

actor ProtectionScanner {

    // MARK: - Malware Signature Database
    // Curated list of known macOS adware, PUPs, hijackers, and keyloggers.

    private static let signatures: [String: (kind: ThreatKind, risk: ThreatRisk)] = [
        // Adware
        "genieo":           (.adware, .high),
        "resoft":           (.adware, .medium),
        "vsearch":          (.adware, .high),
        "conduit":          (.adware, .medium),
        "crossrider":       (.adware, .medium),
        "pirrit":           (.adware, .high),
        "guagua":           (.adware, .high),
        "downlite":         (.adware, .medium),
        "vidx":             (.adware, .medium),
        "yontoo":           (.adware, .low),
        "zugo":             (.adware, .low),
        "bundlore":         (.adware, .high),
        "amonetize":        (.adware, .high),
        "adload":           (.adware, .high),
        "bnodge":           (.adware, .high),
        "rload":            (.adware, .high),
        "dockster":         (.adware, .medium),
        "coinhive":         (.adware, .high),
        "coinminer":        (.adware, .high),
        // PUPs (Potentially Unwanted Programs)
        "macbooster":       (.pup, .low),
        "macoptimizer":     (.pup, .low),
        "macpurifier":      (.pup, .low),
        "advancedmaccleaner": (.pup, .medium),
        "mackeeper":        (.pup, .medium),
        "zeobit":           (.pup, .medium),
        "macupdater":       (.pup, .medium),
        "mymacupdater":     (.pup, .medium),
        "softwareupdater":  (.pup, .medium),
        "pcvark":           (.pup, .medium),
        "pvcore":           (.pup, .medium),
        // Browser Hijackers
        "searchbaron":      (.hijacker, .high),
        "searchmarquis":    (.hijacker, .high),
        "searchpulse":      (.hijacker, .medium),
        "lkysearchd":       (.hijacker, .high),
        "lkysearch":        (.hijacker, .high),
        "newtab":           (.hijacker, .medium),
        "gotosearch":       (.hijacker, .high),
        "cofinderservices": (.hijacker, .high),
        "trustdaemon":      (.hijacker, .high),
        "analyticshelper":  (.hijacker, .medium),
        // Keyloggers / Stalkerware
        "refog":            (.keylogger, .high),
        "aobo":             (.keylogger, .high),
        "spyrix":           (.keylogger, .high),
        "logkext":          (.keylogger, .high),
        "elite keylogger":  (.keylogger, .high),
    ]

    // Directories to scan for malware artefacts
    private static let scanPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "\(home)/Library/Application Support",
            "\(home)/Library/InputManagers",
            "/Library/InputManagers",
            "\(home)/Library/ScriptingAdditions",
            "/Library/ScriptingAdditions",
        ]
    }()

    // MARK: - Malware Scan

    /// Scans known malware drop-zones against the signature database.
    /// Calls `onProgress` with 0.0→1.0 as each location is checked.
    func runMalwareScan(onProgress: @Sendable @escaping (Double) -> Void) async -> [MalwareThreat] {
        var found: [MalwareThreat] = []
        let paths = Self.scanPaths

        for (i, pathStr) in paths.enumerated() {
            onProgress(Double(i) / Double(paths.count))
            found += scanDirectory(URL(fileURLWithPath: pathStr))
        }
        onProgress(1.0)

        // De-duplicate by file path
        var seen = Set<String>()
        return found.filter { seen.insert($0.filePath).inserted }
    }

    private func scanDirectory(_ url: URL) -> [MalwareThreat] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }

        let children = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var threats: [MalwareThreat] = []

        for child in children {
            let nameLower = child.lastPathComponent.lowercased()

            // Direct name match
            for (sig, info) in Self.signatures where nameLower.contains(sig) {
                threats.append(MalwareThreat(
                    name: child.lastPathComponent,
                    kind: info.kind, risk: info.risk,
                    filePath: child.path))
                break
            }

            // Also inspect plist Label / ProgramArguments
            if child.pathExtension.lowercased() == "plist",
               let t = plistThreat(at: child) {
                threats.append(t)
            }
        }
        return threats
    }

    private func plistThreat(at url: URL) -> MalwareThreat? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }

        let label = (plist["Label"] as? String ?? "").lowercased()
        let args  = (plist["ProgramArguments"] as? [String] ?? []).joined(separator: " ").lowercased()

        for (sig, info) in Self.signatures where label.contains(sig) || args.contains(sig) {
            return MalwareThreat(
                name: plist["Label"] as? String ?? url.lastPathComponent,
                kind: info.kind, risk: info.risk,
                filePath: url.path)
        }

        // Heuristic: ProgramArguments pointing to volatile tmp dirs
        if args.contains("/private/tmp/") || args.contains("/var/folders/") {
            return MalwareThreat(
                name: plist["Label"] as? String ?? url.lastPathComponent,
                kind: .pup, risk: .medium,
                filePath: url.path)
        }
        return nil
    }

    // MARK: - Browser Detection

    /// Returns only the browsers that are actually installed on this Mac.
    func detectInstalledBrowsers() -> [DetectedBrowser] {
        let home = NSHomeDirectory()
        let fm   = FileManager.default

        let candidates: [DetectedBrowser] = [
            DetectedBrowser(
                name: "Safari", icon: "safari",
                appPath: "/Applications/Safari.app",
                dataPaths: [
                    "\(home)/Library/Safari/History.db",
                    "\(home)/Library/Safari/History.plist",
                    "\(home)/Library/Caches/com.apple.Safari",
                ]
            ),
            DetectedBrowser(
                name: "Google Chrome", icon: "globe",
                appPath: "/Applications/Google Chrome.app",
                dataPaths: [
                    "\(home)/Library/Application Support/Google/Chrome/Default/History",
                    "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",
                    "\(home)/Library/Caches/Google/Chrome",
                ]
            ),
            DetectedBrowser(
                name: "Firefox", icon: "flame.fill",
                appPath: "/Applications/Firefox.app",
                dataPaths: [
                    "\(home)/Library/Application Support/Firefox/Profiles",
                    "\(home)/Library/Caches/Firefox",
                ]
            ),
            DetectedBrowser(
                name: "Arc", icon: "circle.hexagongrid.fill",
                appPath: "/Applications/Arc.app",
                dataPaths: [
                    "\(home)/Library/Caches/company.thebrowser.Browser",
                    "\(home)/Library/Application Support/Arc/StorableSidebarV2.json",
                ]
            ),
            DetectedBrowser(
                name: "Brave", icon: "bolt.shield.fill",
                appPath: "/Applications/Brave Browser.app",
                dataPaths: [
                    "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/History",
                    "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
                    "\(home)/Library/Caches/BraveSoftware/Brave-Browser",
                ]
            ),
            DetectedBrowser(
                name: "Microsoft Edge", icon: "e.circle.fill",
                appPath: "/Applications/Microsoft Edge.app",
                dataPaths: [
                    "\(home)/Library/Application Support/Microsoft Edge/Default/History",
                    "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies",
                    "\(home)/Library/Caches/Microsoft Edge",
                ]
            ),
            DetectedBrowser(
                name: "Opera", icon: "o.circle.fill",
                appPath: "/Applications/Opera.app",
                dataPaths: [
                    "\(home)/Library/Application Support/com.operasoftware.Opera/Default/History",
                ]
            ),
        ]

        return candidates.filter { fm.fileExists(atPath: $0.appPath) }
    }

    /// Calculates total size of clearable data for a browser (best-effort).
    func dataSize(for browser: DetectedBrowser) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for path in browser.dataPaths {
            guard fm.fileExists(atPath: path) else { continue }
            total += recursiveSize(URL(fileURLWithPath: path))
        }
        return total
    }

    private func recursiveSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
            return children.reduce(0) { $0 + recursiveSize($1) }
        }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    /// Moves browser data files to Trash. Returns (items trashed, first error if any).
    func clearBrowserData(_ browser: DetectedBrowser) async -> (cleared: Int, error: String?) {
        let fm = FileManager.default
        var cleared = 0
        var firstError: String?
        for path in browser.dataPaths {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                cleared += 1
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (cleared, firstError)
    }

    // MARK: - Launch Agent Scanner

    /// Reads real plist files from all standard LaunchAgent/Daemon directories.
    func scanLaunchAgents() async -> [RealLaunchAgentItem] {
        let home = NSHomeDirectory()
        let dirs: [(path: String, scope: String)] = [
            ("\(home)/Library/LaunchAgents", "User"),
            ("/Library/LaunchAgents", "System"),
            ("/Library/LaunchDaemons", "System Daemon"),
        ]

        let fm = FileManager.default
        var results: [RealLaunchAgentItem] = []

        for dir in dirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            let plists = (try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir.path),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ))?.filter { $0.pathExtension == "plist" } ?? []

            for url in plists {
                if let item = parseLaunchAgent(at: url, scope: dir.scope) {
                    results.append(item)
                }
            }
        }

        // Suspicious entries first, then alphabetical
        return results.sorted {
            if $0.isSuspicious != $1.isSuspicious { return $0.isSuspicious }
            return $0.label < $1.label
        }
    }

    private func parseLaunchAgent(at url: URL, scope: String) -> RealLaunchAgentItem? {
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let label: String
        let program: String

        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] {
            label   = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            let args = plist["ProgramArguments"] as? [String] ?? []
            program  = plist["Program"] as? String ?? args.first ?? ""
        } else {
            label   = url.deletingPathExtension().lastPathComponent
            program = ""
        }

        let suspicious = isSuspicious(label: label, program: program)

        return RealLaunchAgentItem(
            label: label,
            path: url.path,
            scope: scope,
            isSuspicious: suspicious,
            lastModified: modDate,
            program: program
        )
    }

    private func isSuspicious(label: String, program: String) -> Bool {
        let l = label.lowercased()
        let p = program.lowercased()

        // Known signature match
        for sig in Self.signatures.keys where l.contains(sig) || p.contains(sig) {
            return true
        }
        // Points to volatile temp space
        if p.contains("/private/tmp/") || p.contains("/var/folders/") { return true }

        // Heuristic: last component looks like a random hash (>5 digits in a short string)
        let parts = label.components(separatedBy: ".")
        if let last = parts.last, last.count < 14 {
            let digits = last.filter(\.isNumber).count
            if digits > 5 { return true }
        }
        return false
    }
}

// MARK: - Supporting Models

struct DetectedBrowser: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let icon: String
    let appPath: String
    let dataPaths: [String]

    var hasData: Bool {
        dataPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

struct RealLaunchAgentItem: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let path: String
    let scope: String
    let isSuspicious: Bool
    let lastModified: Date?
    let program: String
}
