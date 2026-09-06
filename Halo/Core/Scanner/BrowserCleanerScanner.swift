import Foundation
import AppKit

// MARK: - Browser Cleaner Scanner (F-024)
//
// Per-category browser data scanner for the Cleanup module's "Browsers" tab.
// This is a more granular sibling to `ProtectionScanner.detectInstalledBrowsers()`
// (which powers Protection's "clear everything per browser" Privacy Cleaner card):
// instead of one lump `dataPaths` array per browser, each browser is broken into
// individually-sized, individually-selectable `BrowserCategoryItem`s (HTTP cache,
// GPU shader cache, history, cookies, sessions, crash reports, site data).
//
// Path verification (2026-08-14, on the author's own Mac):
//   - Chrome and Arc: every path below was confirmed to exist via `ls`/`find`
//     against this machine's real, in-use profiles (Chrome has 4 live profiles:
//     Default, Profile 1, Profile 2, Profile 3 — profile discovery below is
//     dynamic for exactly this reason, not hardcoded to "Default").
//   - Safari: HTTP cache / History paths reused verbatim from the existing,
//     already-shipped `ProtectionScanner.detectInstalledBrowsers()`. Downloads
//     history / last-session paths are Apple's long-documented, stable Safari
//     file names. GPU cache and Site Data categories are intentionally omitted
//     for Safari — WebKit does not expose a comparably-named GPU shader cache,
//     and the modern per-container WebsiteData path could not be verified from
//     a sandboxed shell without Full Disk Access (guessing it would risk a
//     silently-wrong path, which is worse than omitting the category).
//   - Brave / Microsoft Edge / Opera / Vivaldi: not installed on the dev
//     machine. These reuse the same Chromium per-profile layout verified live
//     against Chrome + Arc, with each vendor's own Application Support / Caches
//     folder name (Brave/Edge names already appear in `ProtectionScanner`;
//     Opera's Caches folder name and Vivaldi's paths follow the same
//     "Caches/<same-subpath-as-Application Support>" convention every verified
//     Chromium vendor on this machine follows, but are unverified live).
//   - Firefox: not installed on the dev machine. Paths (places.sqlite,
//     cookies.sqlite, cache2, sessionstore*, Crash Reports) are Mozilla's own
//     long-stable, documented profile file names, unchanged for many years —
//     unverified live but not a guess.
actor BrowserCleanerScanner {

    // MARK: - Detection

    /// Returns every supported browser that is actually installed on this Mac,
    /// each broken down into its verified per-category clearable items (sizes
    /// not yet measured — call `measure(_:)` next).
    func detectBrowsers() -> [BrowserProfile] {
        let fm = FileManager.default
        return Self.candidates(home: NSHomeDirectory())
            .filter { fm.fileExists(atPath: $0.appPath) }
            .map { BrowserProfile(name: $0.name, icon: $0.icon, appPath: $0.appPath, categories: $0.categories()) }
    }

    /// Fills in real on-disk sizes for every category of a browser profile.
    func measure(_ profile: BrowserProfile) -> BrowserProfile {
        var updated = profile
        for i in updated.categories.indices {
            updated.categories[i].size = Self.size(ofPaths: updated.categories[i].paths)
        }
        return updated
    }

    /// Moves every *selected* category's backing paths to the Trash.
    /// Returns (items trashed, freed bytes, first error message if any).
    /// SQLite sidecar suffixes. `History`, `Cookies` and `Sessions` are WAL-mode
    /// databases; trashing the primary file alone leaves an orphaned `-wal` with
    /// no matching database, which Chromium meets on next launch as a corrupt
    /// profile.
    private static let sqliteSiblingSuffixes = ["-journal", "-wal", "-shm"]

    /// True when the browser this profile belongs to is currently running.
    ///
    /// Clearing an open browser's `Sessions` directory is a direct "lost all my
    /// tabs" bug — it holds the *current* session — and its WAL-mode databases
    /// are being written to as we trash them. There was no running check
    /// anywhere.
    static func isRunning(_ profile: BrowserProfile) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let path = app.bundleURL?.path else { return false }
            return path == profile.appPath
        }
    }

    /// Moves every *selected* category's backing paths to the Trash.
    ///
    /// Returns every failure rather than only the first: under the sandbox most
    /// paths are expected to fail, and reporting one message beside a `cleared`
    /// count gave the user no idea the operation had mostly not worked.
    func clear(_ profile: BrowserProfile, categories selectedIDs: Set<UUID>) -> BrowserClearResult {
        let fm = FileManager.default
        var cleared = 0
        var freed: Int64 = 0
        var errors: [String] = []

        for item in profile.categories where selectedIDs.contains(item.id) {
            for path in item.paths {
                guard fm.fileExists(atPath: path) else { continue }
                // Resolved *before* trashing — measuring afterwards reads a
                // path that no longer exists and reports 0.
                //
                // Measured per path, and NOT reused from `item.size`.
                // `measure(_:)` sets `item.size` to the total across *all* of the
                // category's paths, so adding it once per path inflated the
                // reported figure by the number of paths that existed: 2x for
                // Safari's history (History.db + History.plist), up to 4x for a
                // four-profile Chrome, whose categories carry one path per
                // profile. The fallback measured a single path, so the two
                // branches were not even reporting the same quantity.
                //
                // That re-walk is the cost of a correct number. If it ever shows
                // up on a multi-GB cache, the fix is for `measure(_:)` to keep
                // per-path sizes — not to reuse a total as though it were one.
                let size = Self.size(ofPaths: [path])
                do {
                    // ALWAYS trashItem — never removeItem. Confirmed by the
                    // review sheet before this function is ever called.
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    cleared += 1
                    freed += size

                    // Take the SQLite sidecars with it, so what is left on disk
                    // is consistent rather than a WAL pointing at nothing.
                    for suffix in Self.sqliteSiblingSuffixes {
                        let sibling = path + suffix
                        guard fm.fileExists(atPath: sibling) else { continue }
                        try? fm.trashItem(at: URL(fileURLWithPath: sibling), resultingItemURL: nil)
                    }
                } catch {
                    errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return BrowserClearResult(cleared: cleared, freed: freed, errors: errors)
    }

    // MARK: - Size measurement

    /// Non-private (internal) purely for `HaloTests` — recursive on-disk size
    /// over synthetic paths, no behavior change.
    static func size(ofPaths paths: [String]) -> Int64 {
        paths.reduce(0) { $0 + recursiveSize(URL(fileURLWithPath: $1)) }
    }

    /// Maximum entries walked per path. Matches the 20,000 cap
    /// `ICloudDriveScanner.directorySize` and `SpaceLensViewModel.directorySize`
    /// already use.
    private static let maxEntriesPerPath = 20_000

    /// Iterative, via `FileManager.enumerator(at:)`.
    ///
    /// The recursive version used `fileExists(atPath:isDirectory:)`, which
    /// **resolves symlinks** — so a symlink inside any of these trees pointing at
    /// a parent, or at `/`, recursed without bound. That is a stack-overflow
    /// crash rather than a slow scan, and a symlink to $HOME would have made
    /// "measure Chrome's cache" walk the entire home directory. There was no
    /// depth or entry cap either.
    ///
    /// `enumerator(at:)` does not descend into directory symlinks by default,
    /// which removes the cycle entirely; the cap bounds the rest.
    private static func recursiveSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        guard isDir.boolValue else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var seen = 0
        for case let child as URL in enumerator {
            seen += 1
            if seen > maxEntriesPerPath { break }
            guard let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Candidate table

    /// Non-private (internal) purely for `HaloTests` — the candidate table
    /// itself is pure data, no I/O until `.categories()` is invoked.
    struct Candidate {
        let name: String
        let icon: String
        let appPath: String
        let categories: () -> [BrowserCategoryItem]
    }

    static func candidates(home: String) -> [Candidate] {
        [
            Candidate(name: "Safari", icon: "safari", appPath: "/Applications/Safari.app") {
                safariCategories(home: home)
            },
            Candidate(name: "Google Chrome", icon: "globe", appPath: "/Applications/Google Chrome.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/Google/Chrome",
                    cacheRoot: "\(home)/Library/Caches/Google/Chrome",
                    hasFlatCache: false)
            },
            Candidate(name: "Arc", icon: "circle.hexagongrid.fill", appPath: "/Applications/Arc.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/Arc/User Data",
                    cacheRoot: "\(home)/Library/Caches/company.thebrowser.Browser",
                    // Verified live: Arc's Caches folder has no per-profile
                    // "Default/Cache" subfolder the way Chrome's does — its
                    // HTTP cache lives flat at the cache root.
                    hasFlatCache: true)
            },
            Candidate(name: "Brave", icon: "bolt.shield.fill", appPath: "/Applications/Brave Browser.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser",
                    cacheRoot: "\(home)/Library/Caches/BraveSoftware/Brave-Browser",
                    hasFlatCache: false)
            },
            Candidate(name: "Microsoft Edge", icon: "e.circle.fill", appPath: "/Applications/Microsoft Edge.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/Microsoft Edge",
                    cacheRoot: "\(home)/Library/Caches/Microsoft Edge",
                    hasFlatCache: false)
            },
            Candidate(name: "Opera", icon: "o.circle.fill", appPath: "/Applications/Opera.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/com.operasoftware.Opera",
                    cacheRoot: "\(home)/Library/Caches/com.operasoftware.Opera",
                    hasFlatCache: false)
            },
            Candidate(name: "Vivaldi", icon: "v.circle.fill", appPath: "/Applications/Vivaldi.app") {
                chromiumCategories(
                    appSupportRoot: "\(home)/Library/Application Support/Vivaldi",
                    cacheRoot: "\(home)/Library/Caches/Vivaldi",
                    hasFlatCache: false)
            },
            Candidate(name: "Firefox", icon: "flame.fill", appPath: "/Applications/Firefox.app") {
                firefoxCategories(home: home)
            },
        ]
    }

    // MARK: - Safari

    private static func safariCategories(home: String) -> [BrowserCategoryItem] {
        [
            BrowserCategoryItem(category: .httpCache, paths: [
                "\(home)/Library/Caches/com.apple.Safari",
            ]),
            BrowserCategoryItem(category: .history, paths: [
                "\(home)/Library/Safari/History.db",
                "\(home)/Library/Safari/History.plist",
            ]),
            BrowserCategoryItem(category: .downloadHistory, paths: [
                "\(home)/Library/Safari/Downloads.plist",
            ]),
            // Safari cookies are deliberately NOT offered.
            //
            // `~/Library/Cookies/Cookies.binarycookies` is the shared,
            // process-wide NSHTTPCookieStorage file used by every non-sandboxed
            // app that touches NSURLSession or WKWebView outside a container.
            // Modern Safari is sandboxed and keeps its cookies in
            // ~/Library/Containers/com.apple.Safari/Data/Library/Cookies/, which
            // needs Full Disk Access to reach.
            //
            // So the old entry did two wrong things at once: it did not clear
            // Safari's cookies, and it *did* clear cookies belonging to other
            // apps — silently signing the user out of unrelated software behind
            // a one-click "Clean All Browsers". That is collateral damage to
            // state the user never agreed to touch.
            //
            // Dropped for the same reason Safari's Site Data already was.
            BrowserCategoryItem(category: .sessions, paths: [
                "\(home)/Library/Safari/LastSession.plist",
            ]),
            BrowserCategoryItem(category: .crashReports, paths: crashReportPaths(home: home, prefix: "Safari")),
        ]
    }

    // MARK: - Chromium family (Chrome, Arc, Brave, Edge, Opera, Vivaldi)

    /// Every Chromium-based browser lays out its user-data root identically:
    /// one directory per profile ("Default", "Profile 1", "Profile 2", …),
    /// each containing History/Cookies/GPUCache/Sessions/etc. Verified live
    /// against Chrome (4 real profiles) and Arc (1 real profile) on this Mac.
    private static func chromiumCategories(
        appSupportRoot: String, cacheRoot: String, hasFlatCache: Bool
    ) -> [BrowserCategoryItem] {
        let profiles = chromiumProfileDirs(appSupportRoot: appSupportRoot)

        var httpCache: [String] = hasFlatCache ? [cacheRoot] : []
        var gpuCache: [String] = []
        var history: [String] = []
        var cookies: [String] = []
        var sessions: [String] = []
        var webStorage: [String] = []

        for profile in profiles {
            let support = "\(appSupportRoot)/\(profile)"
            if !hasFlatCache {
                let cache = "\(cacheRoot)/\(profile)"
                httpCache.append("\(cache)/Cache")
                httpCache.append("\(cache)/Code Cache")
            }
            gpuCache.append("\(support)/GPUCache")
            gpuCache.append("\(support)/DawnGraphiteCache")
            gpuCache.append("\(support)/DawnWebGPUCache")
            history.append("\(support)/History")
            cookies.append("\(support)/Cookies")
            sessions.append("\(support)/Sessions")
            webStorage.append("\(support)/IndexedDB")
            webStorage.append("\(support)/Local Storage")
            webStorage.append("\(support)/Session Storage")
            webStorage.append("\(support)/WebStorage")
        }

        return [
            BrowserCategoryItem(category: .httpCache, paths: httpCache),
            BrowserCategoryItem(category: .gpuCache, paths: gpuCache),
            // Chromium's History file stores browsing AND download history in
            // one SQLite database — there is no separate download-history file
            // to select independently, so this category is intentionally
            // labelled "Browsing History" (not split) for the Chromium family.
            BrowserCategoryItem(category: .history, paths: history),
            BrowserCategoryItem(category: .cookies, paths: cookies),
            BrowserCategoryItem(category: .sessions, paths: sessions),
            // Crashpad's own store, verified present for Chrome; engine-level
            // (not vendor-branded) so the relative path generalizes.
            BrowserCategoryItem(category: .crashReports, paths: ["\(appSupportRoot)/Crashpad/completed"]),
            BrowserCategoryItem(category: .webStorage, paths: webStorage),
        ]
    }

    /// Chromium profile directories are named "Default", "Profile 1", "Profile 2", …
    /// Enumerated dynamically because real installs commonly have several (this
    /// dev machine's live Chrome has 4). Falls back to ["Default"] if the user-data
    /// root can't be read yet (fresh install / never launched).
    /// Non-private (internal) purely for `HaloTests`, against a synthetic
    /// temp directory instead of a real browser install.
    static func chromiumProfileDirs(appSupportRoot: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: appSupportRoot) else {
            return ["Default"]
        }
        let profiles = entries.filter { $0 == "Default" || $0 == "Guest Profile" || $0.hasPrefix("Profile ") }
        return profiles.isEmpty ? ["Default"] : profiles
    }

    // MARK: - Firefox

    /// Firefox profile folders have randomized names (`<hash>.default-release`),
    /// so — unlike Chromium — they must be discovered by listing the Profiles
    /// directory rather than assumed.
    /// Non-private (internal) purely for `HaloTests`, against a synthetic
    /// temp directory instead of a real Firefox install.
    static func firefoxProfileDirs(home: String) -> [String] {
        let root = "\(home)/Library/Application Support/Firefox/Profiles"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.filter { !$0.hasPrefix(".") }
    }

    private static func firefoxCategories(home: String) -> [BrowserCategoryItem] {
        let profiles = firefoxProfileDirs(home: home)
        let appRoot = "\(home)/Library/Application Support/Firefox/Profiles"
        let cacheRoot = "\(home)/Library/Caches/Firefox/Profiles"

        var httpCache: [String] = []
        var history: [String] = []
        var cookies: [String] = []
        var sessions: [String] = []
        var webStorage: [String] = []

        for profile in profiles {
            httpCache.append("\(cacheRoot)/\(profile)/cache2")
            // places.sqlite holds browsing history AND download history in one
            // database (no separate download-history file), same caveat as Chromium.
            history.append("\(appRoot)/\(profile)/places.sqlite")
            cookies.append("\(appRoot)/\(profile)/cookies.sqlite")
            sessions.append("\(appRoot)/\(profile)/sessionstore.jsonlz4")
            sessions.append("\(appRoot)/\(profile)/sessionstore-backups")
            webStorage.append("\(appRoot)/\(profile)/storage/default")
            webStorage.append("\(appRoot)/\(profile)/webappsstore.sqlite")
        }

        return [
            BrowserCategoryItem(category: .httpCache, paths: httpCache),
            BrowserCategoryItem(category: .history, paths: history),
            BrowserCategoryItem(category: .cookies, paths: cookies),
            BrowserCategoryItem(category: .sessions, paths: sessions),
            BrowserCategoryItem(category: .crashReports, paths: [
                "\(home)/Library/Application Support/Firefox/Crash Reports",
            ]),
            BrowserCategoryItem(category: .webStorage, paths: webStorage),
        ]
    }

    // MARK: - Shared: OS-level crash reports

    /// macOS writes every app's crash reports to one shared directory, named
    /// `<AppName>_<date>_<host>.ips` (or `.crash` on older releases). Verified
    /// live: this directory exists and is readable on the dev machine. Used for
    /// browsers (Safari) that don't maintain their own separate crash store.
    private static func crashReportPaths(home: String, prefix: String) -> [String] {
        let dir = "\(home)/Library/Logs/DiagnosticReports"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .map { "\(dir)/\($0)" }
    }
}
