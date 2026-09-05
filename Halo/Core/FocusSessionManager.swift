import Foundation
import AppKit
import UserNotifications

// MARK: - FocusSessionManager (F-028)
//
// Pomodoro-style focus session. On start, hides a user-configured list of
// apps via NSRunningApplication.hide() — never .terminate()/.forceTerminate(),
// mirroring IdleAppMonitor's preference for reversible, non-destructive app
// management. Runs a 1s countdown Timer + a 5s sampling Timer that reuses the
// existing `ProcessMonitor` actor (same one behind Performance → Top
// Processes) to track the session's peak-RAM process, plus AppState's live
// `cpuUsage`, so the end-of-session summary is built from real samples.
//
// Session history is appended through the existing AlertLog (kindRaw:
// "focus") rather than inventing a parallel persisted store — this is the
// pattern the spec itself calls for and the one AlertManager already uses
// for every other kind of system event.
//
// NOTE — notification suppression (read before changing this file):
// The original F-028 idea sheet said this feature should "suppress macOS
// notification banners" via the Focus mode API (`INFocusStatusCenter`). That
// API only lets an app *report its own* busy/focused state so OTHER apps can
// voluntarily check `isFocused` and choose to hold back their own
// notifications — it does not let any app enable system-wide Do Not
// Disturb/Focus or silence other apps' banners. There is no public API for a
// third-party app to toggle system Focus/DND on the user's behalf. This
// manager does NOT implement or claim that capability. `openSystemFocusSettings()`
// below is the honest replacement: a one-click deep link to System Settings so
// the user can turn on a Focus mode themselves — a manual nudge, not automatic
// suppression.
@MainActor
final class FocusSessionManager: ObservableObject {

    static let shared = FocusSessionManager()

    // MARK: - Published state

    @Published private(set) var isActive: Bool = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var totalSeconds: Int = 0
    @Published private(set) var hiddenAppNames: [String] = []
    @Published var isOverlayVisible: Bool = false
    @Published private(set) var lastSummary: FocusSessionSummary?

    /// "MM:SS" — used by both the Dashboard card and the menu bar countdown.
    var remainingFormatted: String {
        let m = max(0, remainingSeconds) / 60
        let s = max(0, remainingSeconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Private state

    private var countdownTimer: Timer?
    private var sampleTimer: Timer?
    // `.shared` (P0.3). The focus session samples every 5 s while it runs; a
    // private instance would have been a third concurrent process enumeration
    // alongside Top Processes and F-023, and would bypass the 1 s coalescing
    // window that only collapses calls sharing an instance.
    private let processMonitor = ProcessMonitor.shared
    private var endDate: Date?
    private var hiddenApps: [NSRunningApplication] = []
    /// Bundle IDs of everything hidden this session. Survives an
    /// `NSRunningApplication` going away, and is what gets persisted.
    private var hiddenBundleIDs: [String] = []
    private var maxCPUUsage: Double = 0
    private var peakRAMByProcess: [String: Double] = [:]
    private var overlayController: FocusSessionOverlayController?
    /// Set when the end-of-session notification could not be delivered, so the
    /// Dashboard card can show the completed state prominently instead.
    @Published var notificationFailure: String?

    /// Bundle IDs hidden by the currently-active session, plus its end date.
    ///
    /// `hide()` is reversible, and the reversal has to be *guaranteed* — that is
    /// the whole reason hiding was acceptable here rather than terminating. It
    /// was not guaranteed: `unhide()` ran only from `finish(early:)`, so quitting
    /// Halo mid-session, crashing (Sentry is wired up precisely because that
    /// happens), or losing power left the user's apps hidden with nothing in
    /// Halo able to bring them back. On relaunch the manager started with
    /// `isActive == false` and an empty `hiddenApps`, so no state even recorded
    /// that anything had been hidden — leaving the user hunting through ⌘-Tab
    /// wondering where Slack went.
    private static let activeSessionKey = "haloFocusActiveSession"

    private struct PersistedSession: Codable {
        var bundleIDs: [String]
        var endDate: Date
    }

    /// A recovered session with enough time left to be worth continuing, parked
    /// for `resumeInterruptedSession()`. Never resumed from `init` — see there.
    private var pendingResume: PersistedSession?

    /// Minimum remaining time worth resuming for. Below this the session is
    /// treated as finished: the apps come back and nothing restarts.
    static let minimumResumableSeconds: TimeInterval = 60

    private init() {
        recoverInterruptedSession()
    }

    /// Called from `init`. Unhides whatever the last session hid, and parks the
    /// session for resumption if enough of it is left.
    ///
    /// **This must not start the session, and nothing it calls may read
    /// `FocusSessionManager.shared`.**
    ///
    /// It used to call `start()` directly. `start()` builds the overlay, and
    /// `FocusSessionOverlayView` read `FocusSessionManager.shared` in a stored
    /// property default — so constructing it re-entered the `static let` whose
    /// initializer was still on the stack. Swift lowers that to `swift_once`,
    /// which is not reentrant: the thread parks in `_dispatch_once_wait` and
    /// never wakes. `init` is private and `shared` is the only construction
    /// path, so once recovery decided to resume, the deadlock was unavoidable —
    /// the app hung during startup, on the main actor, with no window and no
    /// crash report.
    ///
    /// It triggered on exactly the case this recovery exists to serve: a clean
    /// quit clears the record via `observeAppTermination()`, so recovery only
    /// engages after a crash, force-quit or power loss.
    ///
    /// Unhiding is safe here — it touches only `NSWorkspace`.
    ///
    /// The overlay no longer reads `.shared` either (it is handed the manager),
    /// so the cycle is closed at both ends rather than only at this one.
    private func recoverInterruptedSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.activeSessionKey),
              let saved = try? JSONDecoder().decode(PersistedSession.self, from: data) else { return }

        UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)

        // Always unhide first. Whether or not the session is resumable, those
        // apps are currently hidden because Halo hid them.
        unhide(bundleIDs: saved.bundleIDs)

        guard Self.isResumable(endDate: saved.endDate, now: Date()) else { return }
        pendingResume = saved
    }

    /// Whether a recovered session has enough time left to be worth resuming.
    /// Pure, so the boundary can be tested without touching the singleton.
    nonisolated static func isResumable(endDate: Date, now: Date) -> Bool {
        endDate.timeIntervalSince(now) > minimumResumableSeconds
    }

    /// Whole minutes to resume for, rounded up. `nil` when the session has
    /// aged out since it was recovered.
    nonisolated static func resumeMinutes(endDate: Date, now: Date) -> Int? {
        guard isResumable(endDate: endDate, now: now) else { return nil }
        return Int((endDate.timeIntervalSince(now) / 60).rounded(.up))
    }

    /// Resumes a session that a crash or force-quit interrupted.
    ///
    /// Call once from `HaloApp` after launch — **not** from `init`; see
    /// `recoverInterruptedSession()` for why. Idempotent, and re-checks the
    /// deadline because time passes between recovery and this call.
    func resumeInterruptedSession() {
        guard let saved = pendingResume else { return }
        pendingResume = nil

        guard let minutes = Self.resumeMinutes(endDate: saved.endDate, now: Date()) else { return }
        // The user explicitly asked for this session and never cancelled it.
        start(minutes: minutes, bundleIDsToHide: saved.bundleIDs)
    }

    /// Idempotent. Safe to call from `finish`, from `willTerminate`, and from
    /// recovery on the next launch.
    private func unhide(bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, bundleIDs.contains(bid), app.isHidden else { continue }
            app.unhide()
        }
    }

    /// Restores everything the active session hid and forgets it. Shared by
    /// `finish` and the terminate handler so the two cannot drift.
    func restoreHiddenApps() {
        for app in hiddenApps where app.isHidden { app.unhide() }
        unhide(bundleIDs: hiddenBundleIDs)
        hiddenApps = []
        hiddenBundleIDs = []
        UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)
    }

    // MARK: - Session control

    /// Starts a session, hiding every currently-running app whose bundle
    /// identifier is in `bundleIDsToHide`. The caller (FocusSessionCard on
    /// the Dashboard) is responsible for confirming with the user first,
    /// listing the exact apps that will be hidden — per CLAUDE.md's "all
    /// deletions/disruptive actions require confirmation" rule.
    func start(minutes: Int, bundleIDsToHide: [String]) {
        guard !isActive, minutes > 0 else { return }

        totalSeconds = minutes * 60
        remainingSeconds = totalSeconds
        endDate = Date().addingTimeInterval(TimeInterval(totalSeconds))
        maxCPUUsage = 0
        peakRAMByProcess = [:]
        hiddenApps = []
        hiddenAppNames = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  bundleIDsToHide.contains(bid),
                  app.activationPolicy == .regular,
                  !app.isHidden else { continue }
            if app.hide() {
                hiddenApps.append(app)
                hiddenBundleIDs.append(bid)
                hiddenAppNames.append(app.localizedName ?? bid)
            }
        }

        // Written before the session begins, so a crash one second later is
        // still recoverable on the next launch.
        persistActiveSession()

        isActive = true
        isOverlayVisible = true

        if overlayController == nil { overlayController = FocusSessionOverlayController() }
        overlayController?.show(manager: self)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.sample() }
        }
        // One immediate sample so even a very short custom session has data.
        Task { await sample() }
    }

    /// Hides the floating overlay panel without ending the session — the
    /// countdown keeps running in the menu bar. Matches the spec's
    /// "dismissible minimal countdown overlay".
    func dismissOverlay() {
        isOverlayVisible = false
        overlayController?.hide()
    }

    func reopenOverlay() {
        guard isActive else { return }
        isOverlayVisible = true
        overlayController?.show(manager: self)
    }

    /// User-initiated early stop (from the overlay or the Dashboard card).
    func endSession() {
        guard isActive else { return }
        finish(early: remainingSeconds > 0)
    }

    // MARK: - Ticking / sampling

    private func tick() {
        guard let end = endDate else { return }
        remainingSeconds = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        if remainingSeconds <= 0 {
            finish(early: false)
        }
    }

    private func sample() async {
        guard isActive else { return }
        if let cpu = AppState.shared?.cpuUsage {
            maxCPUUsage = max(maxCPUUsage, cpu)
        }
        let top = await processMonitor.topProcesses(sortBy: .ram, limit: 10)
        for proc in top where proc.isUserApp {
            let prev = peakRAMByProcess[proc.name] ?? 0
            if proc.ramMB > prev { peakRAMByProcess[proc.name] = proc.ramMB }
        }
    }

    private func finish(early: Bool) {
        countdownTimer?.invalidate(); countdownTimer = nil
        sampleTimer?.invalidate(); sampleTimer = nil

        // Restore every app we hid — hide() is always paired with unhide(),
        // never terminate(). Nothing this feature does is destructive.
        restoreHiddenApps()

        let actualSeconds = totalSeconds - remainingSeconds
        let topEntry = peakRAMByProcess.max(by: { $0.value < $1.value })

        let summary = FocusSessionSummary(
            plannedMinutes: totalSeconds / 60,
            actualSeconds: actualSeconds,
            hiddenAppNames: hiddenAppNames,
            topRAMProcessName: topEntry?.key,
            topRAMProcessMB: topEntry?.value,
            maxCPUPercent: maxCPUUsage * 100,
            endedEarly: early
        )
        lastSummary = summary

        postEndNotification(summary: summary)
        AlertLog.shared.append(title: "Focus session ended",
                                body: summary.digestText,
                                kindRaw: "focus")

        isActive = false
        isOverlayVisible = false
        endDate = nil
        overlayController?.hide()
    }

    private func postEndNotification(summary: FocusSessionSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Focus Session Complete"
        content.body = summary.digestText
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "focus-session-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil // deliver immediately
        )
        // For a Pomodoro timer the end-of-session notification *is* the primary
        // output, so a silent failure is the feature not working. The summary
        // still reaches AlertLog either way, but the user gets told when macOS
        // refused to show it.
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                FocusSessionManager.shared.notificationFailure =
                    "Your focus session finished, but macOS wouldn't show the notification: \(error.localizedDescription)"
            }
        }
    }

    private func persistActiveSession() {
        guard let endDate, !hiddenBundleIDs.isEmpty else { return }
        let saved = PersistedSession(bundleIDs: hiddenBundleIDs, endDate: endDate)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.activeSessionKey)
    }

    /// Belt and braces alongside the persisted record: a clean ⌘Q gets the apps
    /// back immediately rather than on next launch. Call once from HaloApp.
    func observeAppTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { FocusSessionManager.shared.restoreHiddenApps() }
        }
    }

    // MARK: - Manual Focus-mode nudge
    //
    // Honest replacement for the infeasible "auto-suppress notifications"
    // bullet — see the file-header note. Opens System Settings' Notifications
    // pane (where Focus modes live on macOS 13+) so the user can turn one on
    // themselves in one click. This is a manual step, not automatic suppression.
    func openSystemFocusSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Focus Session app-list settings store (F-028)
//
// Backs the "Apps to Hide During a Session" list in Settings → Focus.
// Persists by bundle identifier (survives the target app not currently
// running) — same JSON-in-UserDefaults pattern as AlertLog / SnippetManager.
@MainActor
final class FocusSessionSettingsStore: ObservableObject {

    static let shared = FocusSessionSettingsStore()

    @Published private(set) var apps: [FocusAppConfig] = []

    private static let defaultsKey = "focusSessionAppConfigs"

    private init() { load() }

    func add(_ app: FocusAppConfig) {
        guard !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        apps.append(app)
        persist()
    }

    func remove(_ app: FocusAppConfig) {
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        persist()
    }

    /// Currently-running, regular (Dock-visible) apps that aren't Halo itself
    /// and aren't already configured — feeds the "Add App" picker in Settings.
    func candidateRunningApps() -> [FocusAppConfig] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> FocusAppConfig? in
                guard let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier else { return nil }
                return FocusAppConfig(bundleIdentifier: bid, name: app.localizedName ?? bid)
            }
            .filter { candidate in !apps.contains(where: { $0.bundleIdentifier == candidate.bundleIdentifier }) }
            .sorted { $0.name < $1.name }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([FocusAppConfig].self, from: data) else { return }
        apps = saved
    }
}
