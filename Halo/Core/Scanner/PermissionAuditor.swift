import Foundation
import AppKit

// MARK: - Permission Auditor (F-016)

/// Attempts to read the real per-app TCC grant list from
/// `~/Library/Application Support/com.apple.TCC/TCC.db` via the `sqlite3` CLI.
///
/// That database is SIP-protected and requires Full Disk Access to read. In the
/// sandboxed release build — and on any Mac where Halo hasn't been separately
/// granted Full Disk Access — the read fails. This deliberately does **not**
/// fall back to a fabricated per-app audit when that happens: callers must
/// handle both `PermissionAuditResult` cases, `.available` (real per-app
/// grants) and `.unavailable` (an honest reason, so the caller can fall back
/// to the category-card-only view).
actor PermissionAuditor {

    /// Bundle ID prefixes for browsers and communication apps — Screen
    /// Recording or Accessibility access is expected for these and is not
    /// flagged as elevated risk.
    /// Exact bundle identifiers for which Screen Recording or Accessibility is
    /// expected, and therefore not flagged.
    ///
    /// This was prefix-matched, which for an allowlist whose job is *suppressing*
    /// a risk flag fails in the permissive direction: `com.apple.mail` matched
    /// `com.apple.mailctl`, and anything calling itself `com.apple.Safari.helper`
    /// was silently never flagged. `com.duckduckgo` was not even a real bundle ID
    /// (the browser is `com.duckduckgo.macos.browser`) — that entry only worked
    /// *because* of the prefix behaviour, which is a good illustration of the
    /// problem.
    private static let expectedElevatedIdentifiers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.duckduckgo.macos.browser",
        "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.microsoft.teams2",
        "com.microsoft.teams", "com.cisco.webexmeetingsapp", "com.skype.skype",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord",
        "com.microsoft.Outlook", "com.apple.mail", "com.apple.FaceTime",
        "com.apple.iChat", "com.apple.MobileSMS"
    ]

    /// Genuine family prefixes, chosen deliberately rather than as a side effect
    /// of loose matching. Chrome and Edge register helper processes under their
    /// own identifiers, and those legitimately inherit the parent's expectation.
    private static let expectedElevatedPrefixes: [String] = [
        "com.google.Chrome.helper",
        "com.microsoft.edgemac.helper",
        "com.brave.Browser.helper"
    ]

    static func isExpectedElevated(_ bundleID: String) -> Bool {
        if expectedElevatedIdentifiers.contains(bundleID) { return true }
        return expectedElevatedPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// TCC service identifiers mapped to Halo's `PermissionKind`. Not every
    /// TCC service Apple defines is represented here — only the ones
    /// `PermissionKind` already models.
    private static let serviceMap: [String: PermissionKind] = [
        "kTCCServiceCamera": .camera,
        "kTCCServiceMicrophone": .microphone,
        "kTCCServiceLocation": .location,
        "kTCCServiceLocationServices": .location,
        "kTCCServiceAddressBook": .contacts,
        "kTCCServiceCalendar": .calendar,
        "kTCCServiceSystemPolicyAllFiles": .fullDisk,
        "kTCCServiceScreenCapture": .screenRecording,
        "kTCCServiceAccessibility": .accessibility
    ]

    /// Reads real per-app grants, or returns an honest reason it couldn't.
    /// The per-user TCC store.
    static let userDatabasePath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    /// The system-wide TCC store.
    ///
    /// macOS splits TCC across both. `kTCCServiceAccessibility` and
    /// `kTCCServiceSystemPolicyAllFiles` are recorded in the *system* store, and
    /// `kTCCServiceScreenCapture` has moved between the two across releases —
    /// and those are exactly the services `isElevatedRisk` keys on. Reading only
    /// the user store meant the headline capability ("X apps hold Screen
    /// Recording or Accessibility they probably shouldn't") could find nothing to
    /// flag even where the read succeeded.
    ///
    /// NOT empirically verified: both databases are unreadable without Full Disk
    /// Access, which this environment does not have, so the split above is from
    /// Apple's documented behaviour rather than from observation. Confirm with
    /// `sqlite3 -readonly <path> "SELECT DISTINCT service FROM access;"` against
    /// both once FDA is granted.
    static let systemDatabasePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    func run() async -> PermissionAuditResult {
        let query = "SELECT service, client, auth_value FROM access;"
        var rows: [TCCRow] = []
        var anySucceeded = false

        // Both stores, merged. The system store needs FDA too, so a failure
        // there is not itself evidence of a problem — it is only when *neither*
        // could be read that Halo genuinely has nothing to say.
        for path in [Self.userDatabasePath, Self.systemDatabasePath] {
            guard FileManager.default.isReadableFile(atPath: path) else { continue }
            let result = runSQLite(dbPath: path, query: query)
            guard result.didRun else { continue }
            anySucceeded = true
            rows.append(contentsOf: parseRows(result.output))
        }

        guard anySucceeded else {
            return .unavailable(reason:
                "Halo needs Full Disk Access to show per-app grants — showing categories only.")
        }

        var grants: [TCCGrant] = []
        var seen = Set<String>()
        for row in rows {
            guard let kind = Self.serviceMap[row.service] else { continue }

            // TCC auth_value: 0 = denied, 1 = unknown/not yet decided,
            // 2 = allowed, 3 = limited. Only surface grants that are actually
            // in effect — never guess at rows we can't interpret.
            guard row.auth_value == 2 || row.auth_value == 3 else { continue }

            let bundleID = row.client
            guard !bundleID.isEmpty else { continue }

            // The same (service, client) pair can appear in both stores.
            let key = "\(row.service)|\(bundleID)"
            guard seen.insert(key).inserted else { continue }

            let isElevated = (kind == .screenRecording || kind == .accessibility)
                && !Self.isExpectedElevated(bundleID)

            // Display names are resolved on the MainActor by the caller — see
            // `resolveAppNames(for:)`.
            grants.append(TCCGrant(kind: kind, bundleID: bundleID, appName: bundleID, isElevatedRisk: isElevated))
        }

        // An empty result after a *successful* read is a successful audit that
        // legitimately found nothing — a fresh Mac, or no app granted any of the
        // eight mapped services. Returning `.unavailable` showed the
        // Full-Disk-Access fallback banner, telling the user Halo couldn't read
        // anything when in fact it read fine. It also masked the system-store
        // gap: if every row mapped to an unmodelled service, `grants` was empty
        // and the user was told the database was unreadable.
        //
        // "Couldn't read" and "read fine, nothing granted" are different facts.
        return .available(grants: grants)
    }

    /// Resolves display names for a set of grants.
    ///
    /// `@MainActor`, and cached. `appName(forBundleID:)` used to be called from
    /// `run()` — which is actor-isolated and therefore runs on a cooperative pool
    /// thread — and `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`
    /// is main-thread-affine AppKit, invoked once per grant, several hundred
    /// times in a loop. Same shape as `ProcessMonitor.runningAppRAMSamples()`
    /// in #13.
    ///
    /// Caching also means a refresh no longer re-resolves every name from disk.
    @MainActor private static var nameCache: [String: String] = [:]

    @MainActor
    static func resolveAppNames(for grants: [TCCGrant]) -> [TCCGrant] {
        grants.map { grant in
            var resolved = grant
            if let cached = nameCache[grant.bundleID] {
                resolved.appName = cached
            } else {
                let name = appName(forBundleID: grant.bundleID)
                nameCache[grant.bundleID] = name
                resolved.appName = name
            }
            return resolved
        }
    }

    @MainActor
    private static func appName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return bundleID
        }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }

    // MARK: - Process helper (same read-only pattern as SecurityPostureScanner)

    /// Runs a read-only query and returns JSON rows.
    ///
    /// Three things changed here, all of which mattered:
    ///
    /// **Pipe ordering.** `waitUntilExit()` ran before the pipe was drained, and
    /// stdout and stderr shared one 64 KB buffer. `SELECT service, client,
    /// auth_value FROM access;` returns a row per (service, client) pair —
    /// several hundred rows at ~50-80 bytes, so 12-48 KB typically and past
    /// 64 KB on a developer's machine. Once full, sqlite3 blocks in write(2)
    /// while Halo blocks in waitUntilExit(). That is worse here than elsewhere
    /// in the batch: this is launched from `ProtectionViewModel.loadAll()`'s task
    /// group, so a wedged auditor stops the *whole Protection module* loading.
    /// And it can only happen on machines that have Full Disk Access granted —
    /// i.e. never on the dev machine, always on the machines where the feature
    /// actually works.
    ///
    /// **`-readonly`.** The header claims "read-only checks", but plain
    /// `sqlite3 <path> <query>` opens read-write. On a live database the OS holds
    /// open that means lock contention, and a "database is locked" failure was
    /// indistinguishable from a permissions problem.
    ///
    /// **`-json`.** sqlite3's default list mode separates columns with `|` and
    /// performs no quoting or escaping — and the `client` column holds bundle
    /// identifiers *and* absolute executable paths, so a path containing `|`
    /// silently shifted every field. JSON removes that class of problem
    /// entirely. (Requires sqlite3 >= 3.33, shipped on macOS 12+; this project
    /// targets 13.0.)
    private func runSQLite(dbPath: String, query: String) -> (output: String, didRun: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", dbPath, query]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Its own handle, not shared with stdout. Merging them is also what made
        // the `contains("error:")` check fragile.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ("", false)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus == 0)
    }

    /// Decoded shape of one `-json` row.
    private struct TCCRow: Decodable {
        let service: String
        let client: String
        let auth_value: Int
    }

    private func parseRows(_ json: String) -> [TCCRow] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([TCCRow].self, from: data)) ?? []
    }
}
