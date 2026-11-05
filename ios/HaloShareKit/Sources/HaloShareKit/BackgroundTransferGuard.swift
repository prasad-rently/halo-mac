import Foundation

// MARK: - Seams

/// `UIApplication.beginBackgroundTask`, behind a protocol so the policy is testable.
public protocol BackgroundTaskProviding: AnyObject {
    /// Returns a token, or `nil` if the system refused. `expiration` runs (on the main actor)
    /// when the system is about to suspend the app.
    func beginTask(name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    func endTask(_ token: Int)
}

/// Posts the local "come back and finish" notification. Its text must not carry file names.
public protocol InterruptionNotifying: AnyObject {
    func notifyInterrupted(_ work: Set<BackgroundTransferGuard.Work>)
}

// MARK: - BackgroundTransferGuard

/// iOS-best-effort background policy for HaloShare (F-050 D8).
///
/// What iOS actually allows: when the app leaves the foreground it can ask for a short grace
/// period (`beginBackgroundTask`, historically ~30 s) to finish what is in flight. It can **not**
/// keep a listener alive, so nothing here claims background receive. The policy:
///
/// - Leaving the foreground with a send/receive in flight → hold a background task so it can finish.
/// - It finishes in time → release the task and let the app stop its listener.
/// - The system expires the task first → post one local notification ("tap to finish"), stop.
/// - Nothing in flight → there is nothing to protect; the app stops its listener at once.
@MainActor
public final class BackgroundTransferGuard {

    public enum Work: String, Sendable, Hashable { case sending, receiving }

    private let provider: BackgroundTaskProviding
    private let notifier: InterruptionNotifying
    private var token: Int?
    private var inBackground = false
    private var active: Set<Work> = []

    /// Called when the grace period ends before the work did. The owner should stop the
    /// transfer / listener.
    public var onExpired: (Set<Work>) -> Void = { _ in }
    /// Called when work that was being protected finishes while the app is in the background.
    public var onIdleInBackground: () -> Void = {}

    public init(provider: BackgroundTaskProviding, notifier: InterruptionNotifying) {
        self.provider = provider; self.notifier = notifier
    }

    public var isHoldingTask: Bool { token != nil }
    public var activeWork: Set<Work> { active }

    /// The owner reports transfers starting and ending.
    public func setActive(_ work: Work, _ isActive: Bool) {
        if isActive { active.insert(work) } else { active.remove(work) }
        if !isActive, active.isEmpty, inBackground, token != nil {
            release()
            onIdleInBackground()
        }
    }

    /// Returns `true` if work is being kept alive (the caller must NOT tear the listener down yet).
    @discardableResult
    public func appDidEnterBackground() -> Bool {
        inBackground = true
        guard !active.isEmpty, token == nil else { return token != nil }
        token = provider.beginTask(name: "HaloShare transfer") { [weak self] in self?.expired() }
        if token == nil { expired() }          // refused by the system: same outcome as expiry
        return token != nil
    }

    public func appDidBecomeActive() {
        inBackground = false
        release()
    }

    private func expired() {
        let interrupted = active
        release()
        guard !interrupted.isEmpty else { return }
        notifier.notifyInterrupted(interrupted)
        onExpired(interrupted)
    }

    private func release() {
        if let t = token { provider.endTask(t); token = nil }
    }
}
