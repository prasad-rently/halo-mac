import Foundation

// MARK: - AppScanner (F-010)
//
// Enumerates real installed applications and finds leftover files for any app.
//
// scanApps()            — scans /Applications and ~/Applications
// scanLeftovers(for:)   — searches 12 standard leftover locations by bundle ID + app name
// uninstall(_:)         — moves app bundle and selected leftovers to Trash

actor AppScanner {

    // MARK: - App Enumeration

    /// Scans /Applications and ~/Applications, returning apps sorted by size descending.
    func scanApps() async -> [InstalledApp] {
        let home = NSHomeDirectory()
        let dirs = [
            "/Applications",
            "\(home)/Applications",
        ]

        let fm = FileManager.default
        var apps: [InstalledApp] = []

        for dir in dirs {
            guard fm.fileExists(atPath: dir) else { continue }
            let bundles = (try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: .skipsHiddenFiles
            ))?.filter { $0.pathExtension == "app" } ?? []

            for bundle in bundles {
                if let app = appInfo(at: bundle) {
                    apps.append(app)
                }
            }
        }

        // Sort by size descending (largest first)
        return apps.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func appInfo(at url: URL) -> InstalledApp? {
        let fm = FileManager.default

        // Read Info.plist for bundle metadata
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }

        let name    = plist["CFBundleName"] as? String
                   ?? plist["CFBundleDisplayName"] as? String
                   ?? url.deletingPathExtension().lastPathComponent
        let bundleId = plist["CFBundleIdentifier"] as? String ?? ""
        guard !bundleId.isEmpty else { return nil }

        let version = plist["CFBundleShortVersionString"] as? String ?? "—"

        // Compute bundle size (best-effort; skip if too slow)
        let sizeBytes = recursiveSize(url)

        // Last used date via extended attribute (kMDItemLastUsedDate would need Spotlight)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let installDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate

        // Use the Spotlight extended attr if accessible
        let lastUsed = spotlightLastUsed(at: url) ?? modDate

        _ = fm   // suppress warning

        return InstalledApp(
            name: name,
            bundleIdentifier: bundleId,
            version: version,
            path: url.path,
            sizeBytes: sizeBytes,
            lastUsedDate: lastUsed,
            installDate: installDate
        )
    }

    // MARK: - Leftover Scanner

    /// Searches 12 standard macOS leftover locations for files belonging to `app`.
    func scanLeftovers(for app: InstalledApp) async -> [AppLeftover] {
        let home = NSHomeDirectory()
        let lib  = "\(home)/Library"
        let id   = app.bundleIdentifier
        let name = app.name

        // (path, kind) — all 12 standard locations + reversed-domain variants
        let candidates: [(String, LeftoverKind)] = [
            // Preferences
            ("\(lib)/Preferences/\(id).plist",                .preferences),
            // Application Support (both by ID and by name)
            ("\(lib)/Application Support/\(id)",              .appSupport),
            ("\(lib)/Application Support/\(name)",            .appSupport),
            // Caches
            ("\(lib)/Caches/\(id)",                           .cache),
            ("\(lib)/Caches/\(name)",                         .cache),
            // Containers (sandbox)
            ("\(lib)/Containers/\(id)",                       .container),
            // Group Containers — match any that start with the bundle domain
            groupContainerPath(home: home, bundleId: id),
            // Logs
            ("\(lib)/Logs/\(name)",                           .logs),
            ("\(lib)/Logs/\(id)",                             .logs),
            // Cookies
            ("\(lib)/Cookies/\(id).binarycookies",            .cookies),
            // Saved Application State
            ("\(lib)/Saved Application State/\(id).savedState", .savedState),
            // WebKit data
            ("\(lib)/WebKit/\(id)",                           .webkit),
            // LaunchAgents referencing this bundle ID
            ("\(home)/Library/LaunchAgents/\(id).plist",      .launchAgent),
        ].compactMap { $0 }

        let fm = FileManager.default
        var leftovers: [AppLeftover] = []
        var seen = Set<String>()

        for (path, kind) in candidates {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            guard fm.fileExists(atPath: path) else { continue }
            let url  = URL(fileURLWithPath: path)
            let size = recursiveSize(url)
            leftovers.append(AppLeftover(url: url, kind: kind, sizeBytes: size))
        }

        // Also find any pref plists that start with the bundle ID (e.g. com.foo.Bar.plist, com.foo.Bar.sub.plist)
        let prefDir = URL(fileURLWithPath: "\(lib)/Preferences")
        if let prefs = try? fm.contentsOfDirectory(at: prefDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for pref in prefs where pref.lastPathComponent.hasPrefix(id) && pref.pathExtension == "plist" {
                let path = pref.path
                guard seen.insert(path).inserted else { continue }
                leftovers.append(AppLeftover(url: pref, kind: .preferences, sizeBytes: recursiveSize(pref)))
            }
        }

        return leftovers.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Uninstall

    /// Moves the app bundle and all selected leftovers to Trash.
    /// Returns (success, errorString).
    func uninstall(_ app: InstalledApp) async -> (Bool, String?) {
        let fm = FileManager.default
        var firstError: String?

        // 1. Move selected leftover files first (so partial failures are non-destructive)
        for leftover in app.leftovers where leftover.isSelected {
            do {
                try fm.trashItem(at: leftover.url, resultingItemURL: nil)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // 2. Move the app bundle itself
        let appURL = URL(fileURLWithPath: app.path)
        guard fm.fileExists(atPath: app.path) else {
            return (firstError == nil, firstError)
        }
        do {
            try fm.trashItem(at: appURL, resultingItemURL: nil)
            return (true, firstError)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func recursiveSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
            return children.reduce(0) { $0 + recursiveSize($1) }
        }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
    }

    private func spotlightLastUsed(at url: URL) -> Date? {
        // NSMetadataItem queries Spotlight's on-disk database — the authoritative source
        // for kMDItemLastUsedDate. The older getxattr approach only works when macOS
        // happens to mirror that value as a file xattr, which it does not do reliably
        // for .app bundles.
        guard let item = NSMetadataItem(url: url) else { return nil }
        return item.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }

    private func groupContainerPath(home: String, bundleId: String) -> (String, LeftoverKind)? {
        // Group containers follow pattern: ~/Library/Group Containers/{team}.{bundleDomain}/
        // We extract the domain (e.g. com.foo for com.foo.Bar) and scan for a match
        let parts = bundleId.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        let domain = parts.prefix(2).joined(separator: ".")
        let gcDir  = URL(fileURLWithPath: "\(home)/Library/Group Containers")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: gcDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return nil }
        if let match = entries.first(where: { $0.lastPathComponent.hasSuffix(".\(domain)") || $0.lastPathComponent.contains(domain) }) {
            return (match.path, .groupContainer)
        }
        return nil
    }
}
