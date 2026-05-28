import Foundation

// MARK: - HaloHelperProtocol  (F-002)
//
// XPC service contract shared between the main Halo app and the HaloHelper XPC bundle.
// Compiled into BOTH targets — see project.pbxproj UUID refs 003022/003023.
//
// Two-tier protocol design:
//
//   HelperProxying      — pure Swift, no @objc.  Used by HelperClient.init(proxy:)
//                         and by MockHelper in tests.  Avoids ObjC completion-
//                         handler bridging that deadlocks the SPM test runner.
//
//   HaloHelperProtocol  — @objc (required by NSXPCInterface).  Used ONLY in
//                         production code: HelperClient wraps the real XPC
//                         proxy in its own @MainActor path.
//
// Rules:
//  • Every method takes exactly one completion/reply block (XPC requirement).
//  • Primitive parameter types only — no custom types cross the XPC boundary.
//  • The main app is the client; HaloHelper is the server.

// MARK: - Swift-only proxy protocol  (tests + HelperClient internal API)
//
// Keeping this non-@objc prevents ObjC runtime bridging from dispatching
// completion-handler callbacks back to the main thread, which would deadlock
// the SPM swift-testing runner.

public protocol HelperProxying {
    func flushDNS(reply: @escaping (Bool) -> Void)
    func purgeRAM(reply: @escaping (Double) -> Void)
    func rebuildSpotlightIndex(reply: @escaping (Bool) -> Void)
    func clearFontCache(reply: @escaping (Bool) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
}

// MARK: - ObjC-compatible XPC protocol  (NSXPCInterface + HaloHelper target)

@objc public protocol HaloHelperProtocol {

    /// Flushes the DNS resolver cache.
    /// Equivalent to: `dscacheutil -flushcache && killall -HUP mDNSResponder`
    /// - Parameter reply: `true` on success, `false` on error.
    func flushDNS(reply: @escaping (Bool) -> Void)

    /// Pressures memory zones to release inactive pages.
    /// - Parameter reply: estimated MB freed (0 if unmeasurable).
    func purgeRAM(reply: @escaping (Double) -> Void)

    /// Triggers a Spotlight metadata re-index for the boot volume.
    /// - Parameter reply: `true` if mdutil command accepted, `false` otherwise.
    func rebuildSpotlightIndex(reply: @escaping (Bool) -> Void)

    /// Removes macOS font cache files and signals fontd to rebuild.
    /// - Parameter reply: `true` on success.
    func clearFontCache(reply: @escaping (Bool) -> Void)

    /// Returns the helper's bundle version for diagnostics.
    /// - Parameter reply: version string e.g. "1.2.0".
    func helperVersion(reply: @escaping (String) -> Void)
}
