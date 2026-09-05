import Foundation

// MARK: - Security Posture Scanner (F-019)

/// Read-only checks of key macOS security settings via public CLI tools —
/// no entitlements, no writes, no elevation. **Four** of the eight checks
/// (SIP, Secure Boot, Find My, Login Window — see `SecurityCheckKind`)
/// have no reliable sandbox-safe read path, so they're surfaced as
/// `.unknown` with guidance instead of a guessed verdict.
///
/// ## Sandbox limitation (B4)
///
/// The four *automated* checks spawn `/usr/bin/fdesetup`, `/usr/sbin/spctl` and
/// `/usr/bin/defaults`, and read from `/Library/Preferences`. Under
/// `Halo.entitlements` — the sandboxed App Store configuration — `posix_spawn`
/// is denied outright and those reads would be denied even if it were not. All
/// four then fall through to `.unknown`, so a sandboxed build shows an
/// eight-row "check manually" list and, because `.unknown` is not scored, a
/// permanent 100/100.
///
/// That is honest rather than fabricated, which is the right failure mode, but
/// it means this feature only does anything in an unsandboxed build. `scan()`
/// reports it via `automationAvailable` so the UI can say so instead of
/// presenting eight silent "unknown"s as if the machine were simply
/// unverifiable. The batch-level decision (ship unsandboxed, or route through
/// the F-002 privileged helper) is still open.
actor SecurityPostureScanner {

    func scan() async -> [SecurityCheck] {
        [
            checkFileVault(),
            checkGatekeeper(),
            checkFirewall(),
            checkAutomaticUpdates(),
            manualCheck(.sip, "Open “About This Mac” → System Report, or run `csrutil status` in Terminal."),
            manualCheck(.secureBoot, "Only viewable from Recovery Mode → Startup Security Utility."),
            manualCheck(.findMy, "Check System Settings → Apple ID → Find My."),
            manualCheck(.loginWindow, "Check System Settings → Users & Groups → Login Options.")
        ]
    }

    /// 0–100, weighted only by checks Halo can actually verify — unknowns never penalize.
    static func score(for checks: [SecurityCheck]) -> Int {
        var score = 100
        for check in checks {
            switch check.state {
            case .fail: score -= 15
            case .warn: score -= 7
            case .pass, .unknown: break
            }
        }
        return max(0, min(100, score))
    }

    // MARK: - Checks

    private func checkFileVault() -> SecurityCheck {
        let output = run("/usr/bin/fdesetup", ["status"])
        if output.contains("FileVault is On") {
            return SecurityCheck(kind: .fileVault, state: .pass, detail: "On — your disk is encrypted at rest.")
        } else if output.contains("FileVault is Off") {
            return SecurityCheck(kind: .fileVault, state: .fail, detail: "Off — your disk isn't encrypted.")
        }
        return SecurityCheck(kind: .fileVault, state: .unknown, detail: "Couldn't read FileVault status.")
    }

    private func checkGatekeeper() -> SecurityCheck {
        let output = run("/usr/sbin/spctl", ["--status"])
        if output.contains("assessments enabled") {
            return SecurityCheck(kind: .gatekeeper, state: .pass, detail: "Enabled — unsigned apps are blocked by default.")
        } else if output.contains("assessments disabled") {
            return SecurityCheck(kind: .gatekeeper, state: .fail, detail: "Disabled — any app can run unchecked.")
        }
        return SecurityCheck(kind: .gatekeeper, state: .unknown, detail: "Couldn't read Gatekeeper status.")
    }

    private func checkFirewall() -> SecurityCheck {
        let output = run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.alf", "globalstate"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            return SecurityCheck(kind: .firewall, state: .unknown, detail: "Couldn't read firewall status.")
        }
        return value == 0
            ? SecurityCheck(kind: .firewall, state: .fail, detail: "Off — incoming connections aren't filtered.")
            : SecurityCheck(kind: .firewall, state: .pass, detail: "On — blocking unsolicited incoming connections.")
    }

    /// Security *responses*, not macOS version upgrades.
    ///
    /// This previously read `AutomaticallyInstallMacOSUpdates`, which controls
    /// whether full macOS version upgrades install themselves — a scheduling
    /// preference, not a security posture. Someone who deliberately defers
    /// version upgrades while keeping Rapid Security Responses on is *correctly*
    /// hardened, and was being shown "Off — you'll need to install updates
    /// manually" plus a real deduction from the overall health score.
    ///
    /// The keys that actually govern security patching are
    /// `CriticalUpdateInstall` (Rapid Security Responses) and `ConfigDataInstall`
    /// (XProtect / MRT system data files). Both must be on to pass.
    private func checkAutomaticUpdates() -> SecurityCheck {
        let domain = "/Library/Preferences/com.apple.SoftwareUpdate"
        let critical = readBoolDefault(domain: domain, key: "CriticalUpdateInstall")
        let configData = readBoolDefault(domain: domain, key: "ConfigDataInstall")

        guard let critical, let configData else {
            return SecurityCheck(kind: .automaticUpdates, state: .unknown,
                                 detail: "Couldn't read the security update settings.")
        }

        // Reported separately so a deliberate choice about version upgrades is
        // never confused with a security-patching gap.
        let versionUpgrades = readBoolDefault(domain: domain, key: "AutomaticallyInstallMacOSUpdates")
        let upgradeNote: String
        switch versionUpgrades {
        case .some(true):  upgradeNote = " macOS version upgrades install automatically too."
        case .some(false): upgradeNote = " (macOS version upgrades are set to install manually, which is a separate choice.)"
        case nil:          upgradeNote = ""
        }

        if critical && configData {
            return SecurityCheck(kind: .automaticUpdates, state: .pass,
                                 detail: "On — security responses and system data files install automatically." + upgradeNote)
        }
        if !critical && !configData {
            return SecurityCheck(kind: .automaticUpdates, state: .fail,
                                 detail: "Off — security responses and system data files won't install on their own.")
        }
        return SecurityCheck(kind: .automaticUpdates, state: .warn,
                             detail: critical
                                 ? "Partly on — security responses install, but system data files (XProtect) don't."
                                 : "Partly on — system data files install, but Rapid Security Responses don't.")
    }

    /// `nil` when the key is absent or unreadable — which is not the same as
    /// "off", and must not be scored as though it were.
    private func readBoolDefault(domain: String, key: String) -> Bool? {
        switch run("/usr/bin/defaults", ["read", domain, key]).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default:  return nil
        }
    }

    private func manualCheck(_ kind: SecurityCheckKind, _ guidance: String) -> SecurityCheck {
        SecurityCheck(kind: kind, state: .unknown, detail: guidance)
    }

    // MARK: - Process helper

    /// Drain the pipe **before** waiting, and never leave an unread `Pipe()` on
    /// stderr.
    ///
    /// The output here is a line or two, so the old ordering never actually
    /// deadlocked in this file — but this is the implementation #17 and #9 cite
    /// as their reference ("same read-only pattern as SecurityPostureScanner"),
    /// and in those the output genuinely exceeds the 64 KB pipe buffer and hangs.
    /// Fixing the pattern at its source is what stops it propagating further
    /// (B5).
    ///
    /// `didSpawn` is how callers tell "the tool said nothing" from "we were
    /// never allowed to ask" — under the App Sandbox the spawn itself fails.
    private func run(_ path: String, _ args: [String]) -> String {
        runChecked(path, args).output
    }

    private func runChecked(_ path: String, _ args: [String]) -> (output: String, didSpawn: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ("", false)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", true)
    }

    /// Whether Halo can run the read-only tools at all. False under the App
    /// Sandbox, where every automated check degrades to `.unknown`.
    func automationAvailable() -> Bool {
        runChecked("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "LastResultCode"]).didSpawn
    }
}

// MARK: - Shared store
//
// There were two independent scanners: AppState kept a `securityScore` from a
// single launch-time scan, and ProtectionViewModel owned a second scanner and
// computed its own score from its own checks. After the user fixed a finding
// and tapped Refresh, the checklist went green while the Dashboard health score
// kept reflecting the launch value until the next relaunch — and the two could
// disagree indefinitely, in either direction.
//
// One store, one array, both readers. Matches `AlertLog.shared` next door.
@MainActor
final class SecurityPostureStore: ObservableObject {

    static let shared = SecurityPostureStore()

    /// App code uses `shared`; this exists so tests can drive an instance of
    /// their own.
    ///
    /// `HaloTests` is hosted *in* Halo, so `AppState.init()` has already
    /// started a scan on `shared` before the first test runs — asserting
    /// against it means asserting against a store the app host is concurrently
    /// refreshing, which is not a meaningful test of anything.
    init() {}

    @Published private(set) var checks: [SecurityCheck] = []
    @Published private(set) var isRefreshing = false
    /// False when the App Sandbox blocks the read-only tools outright, so the
    /// UI can say that rather than showing eight silent "unknown"s.
    @Published private(set) var automationAvailable = true

    /// Published rather than computed off `checks`.
    ///
    /// A computed property forces every reader to observe `objectWillChange`,
    /// which fires for *each* published property this type mutates — four per
    /// refresh — and to re-read the score each time. The Dashboard was being
    /// invalidated four times for one scan, three of them redundant, and one of
    /// those fired during the `await` below and re-published the *previous*
    /// score. Publishing the value lets a reader subscribe to `$score` and
    /// `removeDuplicates()`, so it hears once, and only when it actually moved.
    @Published private(set) var score: Int = 100

    private let scanner = SecurityPostureScanner()

    /// Re-entrant refreshes are collapsed, not queued.
    ///
    /// Opening Protection while the launch-time scan is still running used to
    /// start a second one: ten `posix_spawn`s instead of five, and whichever
    /// finished first cleared `isRefreshing` while the other was still in
    /// flight, so the spinner stopped early. The in-flight scan publishes to
    /// every reader anyway, so there is nothing for a second one to add.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let available = await scanner.automationAvailable()
        let fresh = await scanner.scan()
        checks = fresh
        score = SecurityPostureScanner.score(for: fresh)
        automationAvailable = available
    }
}
