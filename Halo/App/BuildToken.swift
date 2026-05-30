// ──────────────────────────────────────────────────────────────────────────────
// BuildToken.swift  —  Auto-updated by the build script before each xcodebuild
// run.  Do NOT edit manually.
//
// DEBUG builds: shows a short random token + git commit so you can instantly
//   confirm which binary is running by comparing it with the Claude console
//   output that was printed during the build.
//
// RELEASE builds: shows the semantic version from CFBundleShortVersionString.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation

enum Build {

    // MARK: - Unique per-build token (DEBUG only)

    /// 6-char hex string regenerated each time `xcodebuild` is invoked.
    /// Compare this with the value printed in the Claude console to confirm
    /// the running binary matches the latest build.
    static let token  = "60047c"

    /// Short git commit SHA at the time of the last build.
    static let commit = "9c1bc01"

    // MARK: - Computed display label

    /// What appears in the Halo sidebar under the app name.
    static var displayLabel: String {
        #if DEBUG
        return "dev · \(token)"
        #else
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
        #endif
    }

    /// Full detail string (shown in a tooltip or Cmd+click).
    static var fullLabel: String {
        #if DEBUG
        return "Debug  token:\(token)  commit:\(commit)"
        #else
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "v\(version) (\(build))"
        #endif
    }
}
