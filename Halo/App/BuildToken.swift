// ──────────────────────────────────────────────────────────────────────────────
// BuildToken.swift  —  the "Halo / v2.3" line under the app name in the sidebar,
// and the version shown in Settings → About.
//
// `token` and `commit` are rewritten by `scripts/update_build_token.sh` before a
// dev build, so you can confirm which binary is running by comparing the label
// with what the build printed. Do NOT edit those two by hand.
//
// Everything else here is derived at runtime from the bundle — see `isDevBuild`
// for why the configuration (`#if DEBUG`) must not be used for this.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation

enum Build {

    // MARK: - Per-build token (rewritten by scripts/update_build_token.sh)

    /// 6-char hex string, regenerated when the token script runs.
    static let token  = "8d90f1"

    /// Short git commit SHA at the time the token script last ran.
    static let commit = "5cc88e3"

    // MARK: - Identity

    /// True when this binary is a local dev copy rather than a shipped build.
    ///
    /// Deliberately **not** `#if DEBUG`. Every shipped Halo release — v2.0
    /// through the v2.3 beta — is cut from the **Debug** configuration, because
    /// the Release configuration signs with `Halo.entitlements`, which turns the
    /// App Sandbox on, and the sandbox denies `posix_spawn` and so ships the six
    /// shell-out features as empty panels. `DEBUG` is therefore defined in
    /// production too, and keying the label off it made the released v2.3 label
    /// itself `dev · 8d90f1` in its own sidebar.
    ///
    /// The bundle identifier is the honest signal: `scripts/build-dev.sh`
    /// installs dev copies as `com.halo.mac.dev` beside the release
    /// `com.halo.mac`, so the two can be told apart at runtime by what they
    /// actually are rather than by which compiler flag was set.
    static var isDevBuild: Bool { isDevBundle(Bundle.main.bundleIdentifier) }

    /// `CFBundleShortVersionString` — the marketing version, e.g. `2.3`.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// `CFBundleVersion` — the build number, e.g. `231`.
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    // MARK: - Display

    /// What appears in the Halo sidebar under the app name.
    static var displayLabel: String { displayLabel(bundleID: Bundle.main.bundleIdentifier,
                                                   version: version) }

    /// Full detail string (tooltip on the sidebar label).
    static var fullLabel: String { fullLabel(bundleID: Bundle.main.bundleIdentifier,
                                             version: version,
                                             buildNumber: buildNumber) }

    // MARK: - Pure forms (the above are thin wrappers so this stays testable)

    static func isDevBundle(_ bundleID: String?) -> Bool {
        bundleID?.hasSuffix(".dev") ?? false
    }

    static func displayLabel(bundleID: String?, version: String) -> String {
        isDevBundle(bundleID) ? "dev · \(token)" : "v\(version)"
    }

    static func fullLabel(bundleID: String?, version: String, buildNumber: String) -> String {
        let core = buildNumber.isEmpty ? "v\(version)" : "v\(version) (\(buildNumber))"
        return isDevBundle(bundleID)
            ? "Dev build · \(core) · token \(token) · commit \(commit)"
            : "\(core) · commit \(commit)"
    }
}
