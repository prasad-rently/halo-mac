import Foundation

// MARK: - Security Posture Scanner (F-019)

/// Read-only checks of key macOS security settings via public CLI tools —
/// no entitlements, no writes, no elevation. Three of the eight checks
/// (SIP, Secure Boot, Find My, Login Window — see `SecurityCheckKind`)
/// have no reliable sandbox-safe read path, so they're surfaced as
/// `.unknown` with guidance instead of a guessed verdict.
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

    private func checkAutomaticUpdates() -> SecurityCheck {
        let output = run("/usr/bin/defaults",
                          ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates"])
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return SecurityCheck(kind: .automaticUpdates, state: .pass, detail: "On — macOS installs security updates automatically.")
        case "0": return SecurityCheck(kind: .automaticUpdates, state: .warn, detail: "Off — you'll need to install updates manually.")
        default:  return SecurityCheck(kind: .automaticUpdates, state: .unknown, detail: "Couldn't read the automatic update setting.")
        }
    }

    private func manualCheck(_ kind: SecurityCheckKind, _ guidance: String) -> SecurityCheck {
        SecurityCheck(kind: kind, state: .unknown, detail: guidance)
    }

    // MARK: - Process helper

    private func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
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
