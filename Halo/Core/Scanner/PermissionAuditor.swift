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
    private static let expectedElevatedPrefixes: [String] = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.duckduckgo",
        "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.microsoft.teams2",
        "com.microsoft.teams", "com.cisco.webexmeetingsapp", "com.skype.skype",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord",
        "com.microsoft.Outlook", "com.apple.mail", "com.apple.FaceTime",
        "com.apple.iChat", "com.apple.MobileSMS"
    ]

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
    func run() async -> PermissionAuditResult {
        let dbPath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"

        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            return .unavailable(reason:
                "Halo needs Full Disk Access to show per-app grants — showing categories only.")
        }

        let output = runSQLite(dbPath: dbPath, query: "SELECT service, client, auth_value FROM access;")
        let lowered = output.lowercased()
        guard !output.isEmpty, !lowered.contains("unable to open"), !lowered.contains("error:") else {
            return .unavailable(reason:
                "Halo couldn't read the permissions database (locked or inaccessible) — showing categories only.")
        }

        var grants: [TCCGrant] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let kind = Self.serviceMap[String(fields[0])],
                  let authValue = Int(fields[2]) else { continue }

            // TCC auth_value: 0 = denied, 1 = unknown/not yet decided,
            // 2 = allowed, 3 = limited. Only surface grants that are actually
            // in effect — never guess at rows we can't interpret.
            guard authValue == 2 || authValue == 3 else { continue }

            let bundleID = String(fields[1])
            guard !bundleID.isEmpty else { continue }
            let appName = Self.appName(forBundleID: bundleID)
            let isElevated = (kind == .screenRecording || kind == .accessibility)
                && !Self.expectedElevatedPrefixes.contains(where: bundleID.hasPrefix)

            grants.append(TCCGrant(kind: kind, bundleID: bundleID, appName: appName, isElevatedRisk: isElevated))
        }

        guard !grants.isEmpty else {
            return .unavailable(reason:
                "No readable permission grants found — showing categories only.")
        }

        return .available(grants: grants)
    }

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

    private func runSQLite(dbPath: String, query: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, query]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
