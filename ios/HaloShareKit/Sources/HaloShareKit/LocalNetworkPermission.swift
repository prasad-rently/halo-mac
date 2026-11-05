import Foundation
import Network

/// What we know about iOS's *Local Network* privacy permission.
public enum LocalNetworkAccess: Equatable, Sendable {
    case granted
    /// The user said no (or a profile did). Every probe to a LAN address then fails and
    /// every incoming LAN connection is dropped — silently.
    case denied
    /// No answer yet (the prompt is on screen, or the check timed out).
    case undetermined
}

/// iOS has no API that *reads* the Local Network permission. The documented-in-practice way to
/// learn it is to start an `NWBrowser` for a Bonjour type the app declares in
/// `NSBonjourServices` and look at the state it settles in: `.ready` once allowed, and
/// `.waiting(.dns(kDNSServiceErr_PolicyDenied))` when refused.
///
/// This is *only* a permission probe — nothing is browsed for, advertised, or sent (HaloShare
/// discovery itself is an HTTP scan; iOS has no multicast without a restricted entitlement).
public enum LocalNetworkPermission {

    /// Must also appear in the app's `NSBonjourServices`, or the browser fails differently.
    public static let probeServiceType = "_halosharecheck._tcp"
    /// `kDNSServiceErr_PolicyDenied`
    static let policyDenied: Int32 = -65570

    /// Pure: what a browser state means, or `nil` while it means nothing yet.
    public static func classify(_ state: NWBrowser.State) -> LocalNetworkAccess? {
        switch state {
        case .ready:
            return .granted
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == policyDenied { return .denied }
            return nil
        default:
            return nil
        }
    }

    /// Asks the system. **First use raises the OS permission prompt**, so call it only after the
    /// app has explained why (requirements MR-SH-4); `timeout` should then be long, because the
    /// browser sits there until the person answers.
    public static func check(timeout: TimeInterval = 3) async -> LocalNetworkAccess {
        await withCheckedContinuation { (cont: CheckedContinuation<LocalNetworkAccess, Never>) in
            let once = Once<LocalNetworkAccess>(cont)
            let browser = NWBrowser(for: .bonjour(type: probeServiceType, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                if let verdict = classify(state) { once.resume(returning: verdict); browser.cancel() }
            }
            browser.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(returning: .undetermined)
                browser.cancel()
            }
        }
    }

    /// The sentence to show when a scan found nobody, or `nil` when permission isn't the
    /// likely reason. MR-DI-5: an empty list must never come without an explanation.
    public static func explanationForEmptyScan(access: LocalNetworkAccess) -> String? {
        switch access {
        case .denied:
            return "Local Network access is off for Halo, so it can't see other devices. Turn it on in Settings → Privacy & Security → Local Network → Halo."
        case .granted, .undetermined:
            return nil
        }
    }
}

private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Never>
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(returning value: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true; cont.resume(returning: value)
    }
}
