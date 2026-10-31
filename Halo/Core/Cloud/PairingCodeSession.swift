import Foundation

// MARK: - PairingCodeSession  (F-057 FR-S3)
//
// The pairing code carries the Firebase sign-in, so it must not sit on screen forever. This owns the
// "is the code showing" state: it is built only when asked for, hides itself after `lifetime` seconds
// (60 by default) and is rebuilt from scratch on the next `show()` — never cached.
//
// The code itself lives ONLY in `code` (memory). It is never written to a log, UserDefaults or AlertLog;
// `HaloTests/DatabaseCheckTests` greps this file and the pane for those sinks.
//
// The clock is injected so the hide is testable without waiting a minute: `schedule` takes a delay and
// an action and returns a cancel closure. The default uses a sleeping Task.

@MainActor
final class PairingCodeSession: ObservableObject {

    typealias Schedule = (_ after: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (() -> Void)

    /// The code while it is showing; nil otherwise.
    @Published private(set) var code: String?
    /// True after the code hid itself (as opposed to never having been shown) — the UI says why it went.
    @Published private(set) var expired = false
    /// There is nothing to pair yet (no config / credential / salt stored).
    @Published private(set) var unavailable = false
    /// When the showing code will hide, for a countdown. nil when hidden.
    @Published private(set) var hidesAt: Date?

    static let defaultLifetime: TimeInterval = 60

    private let lifetime: TimeInterval
    private let generate: () -> String?
    private let schedule: Schedule
    private let now: () -> Date
    private var cancelTimer: (() -> Void)?

    init(lifetime: TimeInterval = PairingCodeSession.defaultLifetime,
         generate: @escaping () -> String? = PairingCodeSession.buildCodeFromKeychain,
         schedule: @escaping Schedule = PairingCodeSession.sleepingSchedule,
         now: @escaping () -> Date = Date.init) {
        self.lifetime = lifetime
        self.generate = generate
        self.schedule = schedule
        self.now = now
    }

    /// Build a fresh code and start the countdown. Calling it while a code is showing regenerates it and restarts the 60 s.
    func show() {
        cancelTimer?(); cancelTimer = nil
        expired = false
        guard let fresh = generate() else {
            code = nil; hidesAt = nil; unavailable = true
            return
        }
        unavailable = false
        code = fresh
        hidesAt = now().addingTimeInterval(lifetime)
        cancelTimer = schedule(lifetime) { [weak self] in
            guard let self, self.code != nil else { return }
            self.hide(expired: true)
        }
    }

    /// Hide immediately (the Hide button, leaving the pane, re-keying).
    func hide() { hide(expired: false) }

    private func hide(expired: Bool) {
        cancelTimer?(); cancelTimer = nil
        code = nil; hidesAt = nil
        self.expired = expired
        if !expired { unavailable = false }
    }

    /// Whole seconds left on a showing code, for the countdown label.
    func secondsRemaining(at date: Date) -> Int {
        guard let hidesAt else { return 0 }
        return max(0, Int(hidesAt.timeIntervalSince(date).rounded(.up)))
    }

    // MARK: Defaults

    /// The payload the phone scans or pastes; nil until a config, credential and salt are all stored.
    nonisolated static func buildCodeFromKeychain() -> String? {
        let store = CloudConfigStore.shared
        guard let config = store.firebaseConfig, let auth = store.authCredential, let salt = store.salt else { return nil }
        let payload = CloudPairingPayload(firebaseConfig: config, auth: auth, salt: salt,
                                          iterations: store.kdfIterations ?? CryptoService.legacyIterations)
        return try? payload.encoded()
    }

    static let sleepingSchedule: Schedule = { after, action in
        let task = Task { @MainActor in
            // ContinuousClock keeps counting while the Mac sleeps. Task.sleep(nanoseconds:) is not guaranteed to,
            // and a code that outlived a lid-close by "however long was left" would be a hide in name only.
            try? await ContinuousClock().sleep(for: .seconds(after))
            if !Task.isCancelled { action() }
        }
        return { task.cancel() }
    }
}
