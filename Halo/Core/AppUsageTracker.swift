import Foundation
import Darwin.sys.proc_info
import AppKit

// MARK: - AppUsageTracker (F-021)
//
// Tracks per-app foreground time via NSWorkspace activation notifications,
// exactly like `IdleAppMonitor` (F-039) already does for its own idle-detection
// purpose — this is the same event source, put to a different use.
//
// HONESTY CONSTRAINT (read before touching this file):
// There is no macOS API available to a third-party app that retroactively
// retrieves OS-level Screen Time history. Apple's real Screen Time data lives
// behind the private `FamilyControls`/`ManagedSettings` frameworks, gated by a
// parental-control entitlement Halo does not have. So this tracker can only
// ever know about time IT PERSONALLY OBSERVED while running:
//   • if the Mac was asleep, that time is not counted (a sleeping Timer can't
//     fire, so no tick ever attributes seconds to it — this is correct, not a
//     bug: it stops a sleeping Mac with Chrome frontmost from reporting hours
//     of fake "usage").
//   • if Halo wasn't launched (quit, not set to launch at login), that time
//     is not counted either.
// Every surface that shows this data must say so explicitly. Do not present
// any number here as "your Mac's screen time" — it is "time Halo has been
// running and watching."
//
// Sampling model: a single repeating timer (30 s) is the source of truth for
// all durations. Every tick, every currently-running regular app accrues
// `observedRunningSeconds`; whichever app is frontmost at that instant also
// accrues `foregroundSeconds` and one RAM sample (correlates with the same
// `ps -p <pid> -o rss=` technique `IdleAppMonitor`/`ProcessMonitor` use).
// Deliberately NOT elapsed-time-since-activation math — that would double as
// "time asleep" if the Mac slept while an app was frontmost. Context switches
// (`switchCount`) are the one thing tracked event-for-event, since an
// activation notification is either genuinely observed or it isn't.

@MainActor
final class AppUsageTracker: ObservableObject {

    static let shared = AppUsageTracker()

    // MARK: - Published state

    @Published private(set) var records: [AppUsageRecord] = []
    @Published private(set) var isTracking: Bool = false

    // MARK: - Config

    private static let defaultsKey = "haloAppUsageHistory"
    static let enabledDefaultsKey = "haloAppUsageTrackingEnabled"
    private static let sampleInterval: TimeInterval = 30
    private static let headlineWindowDays = 7     // "past 7 days" bar chart / background hogs
    private static let retentionWindowDays = 14   // kept so week-over-week has a "last week" to compare

    /// Menu-bar agents / system UI processes that would otherwise pollute
    /// per-app usage stats. Mirrors `IdleAppMonitor.systemBundleIDs` plus Halo
    /// itself (watching your own dashboard isn't "app usage").
    // Finder is deliberately NOT in this set. It is a regular, Dock-visible app
    // that users genuinely spend time in; excluding it meant Finder time was
    // both uncounted *and* — before the activation fix in `handleActivation` —
    // misattributed to whatever happened to be in front beforehand. Everything
    // that remains is a menu-bar agent or system UI chrome, which is a
    // different thing, and Halo itself (watching your own dashboard is not
    // "app usage").
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.SystemUIServer",
        "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow",
        "com.halo.mac"
    ]

    // MARK: - Live session state (not persisted)

    private var activeBundleID: String?
    private var activeAppName: String?
    private var activePID: pid_t?
    private var timer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var todayIndexCache: [String: Int] = [:]
    private var todayIndexCacheDay: Date?
    private var ticksSincePersist = 0
    private var lockToken: NSObjectProtocol?
    private var unlockToken: NSObjectProtocol?

    private init() {
        loadFromDefaults()
        pruneOldRecords()
    }

    // MARK: - Start / stop

    /// Called once at launch (`HaloApp`). No-op unless the user has opted in.
    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) {
            start()
        }
    }

    /// Called from the Settings toggle.
    func setTrackingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy == .regular,
           let bid = frontmost.bundleIdentifier,
           !Self.excludedBundleIDs.contains(bid) {
            activeBundleID = bid
            activeAppName = frontmost.localizedName ?? bid
            activePID = frontmost.processIdentifier
        }

        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.handleActivation(app) }
        }
        // Screen lock and display sleep both leave the timer running while the
        // user is demonstrably not using anything. Without these the last
        // foreground app accrues time for the whole locked period — hours of
        // "usage" for a Mac sitting untouched.
        let screensSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.clearActiveApp() } }

        let screensWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeFromFrontmost() } }

        observerTokens = [activateToken, screensSleep, screensWake]

        // Lock and unlock are distributed notifications, not NSWorkspace ones.
        let dnc = DistributedNotificationCenter.default()
        lockToken = dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.clearActiveApp() } }
        unlockToken = dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeFromFrontmost() } }

        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard isTracking else { return }
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        let dnc = DistributedNotificationCenter.default()
        if let lockToken { dnc.removeObserver(lockToken) }
        if let unlockToken { dnc.removeObserver(unlockToken) }
        lockToken = nil
        unlockToken = nil
        timer?.invalidate()
        timer = nil
        activeBundleID = nil
        activeAppName = nil
        activePID = nil
        isTracking = false
    }

    /// Re-reads the frontmost app after unlock or display wake, so tracking
    /// resumes against whatever is genuinely in front now rather than whatever
    /// happened to be there before the screen went away.
    private func resumeFromFrontmost() {
        guard isTracking, let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        handleActivation(frontmost)
    }

    /// Nothing is in the foreground — the screen is locked, the display slept,
    /// or the frontmost app is one Halo deliberately doesn't attribute time to.
    private func clearActiveApp() {
        activeBundleID = nil
        activeAppName = nil
        activePID = nil
    }

    // MARK: - Event handling

    private func handleActivation(_ app: NSRunningApplication) {
        // Returning early here used to leave `activeBundleID` naming the
        // *previous* app, so `tick()` kept crediting it foreground time every
        // 30 s. The excluded set is Finder, Dock, SystemUIServer, WindowManager,
        // Control Center, Notification Center, loginwindow and Halo — exactly the
        // things users bounce into and linger in. Ten minutes copying files in
        // Finder credited ten minutes to whatever was in front beforehand.
        //
        // `loginwindow` is the worst case: locking the screen activates it, so
        // the last app accrued foreground time for the entire locked period. The
        // header claims the design avoids precisely this, and it did for system
        // sleep — but not for lock or display sleep, where the timer keeps firing.
        //
        // Clearing rather than returning means "nothing is in the foreground",
        // which is the truth.
        guard app.activationPolicy == .regular,
              let bid = app.bundleIdentifier, !bid.isEmpty,
              !Self.excludedBundleIDs.contains(bid) else {
            clearActiveApp()
            return
        }

        activePID = app.processIdentifier
        guard bid != activeBundleID else { return }   // refocusing the same app isn't a "switch"

        let name = app.localizedName ?? bid
        activeBundleID = bid
        activeAppName = name
        recordSwitch(bundleID: bid, appName: name)
        persistToDefaults()
    }

    /// The 30 s heartbeat. Source of truth for every duration this tracker reports.
    private func tick() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !Self.excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }

        for app in running {
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            let name = app.localizedName ?? bid
            accrueObservedRunning(bundleID: bid, appName: name, seconds: Self.sampleInterval)

            if bid == activeBundleID {
                accrueForeground(bundleID: bid, appName: name, seconds: Self.sampleInterval)
                if let pid = activePID {
                    let ramMB = Self.processRAMMB(pid: pid)
                    if ramMB > 0 {
                        accrueRAMSample(bundleID: bid, appName: name, ramMB: ramMB)
                    }
                }
            }
        }

        // Both used to run on every 30 s tick. Pruning only matters at a day
        // boundary, and re-encoding the whole record set twice a minute is work
        // the UI thread should not be doing — losing at most a few minutes of
        // buckets to an unclean exit is immaterial against a 14-day window.
        ticksSincePersist += 1
        if ticksSincePersist >= Self.ticksPerPersist {
            ticksSincePersist = 0
            pruneOldRecords()
            persistToDefaults()
        }
    }

    /// Persist every Nth tick rather than every tick. 10 x 30 s = 5 minutes.
    private static let ticksPerPersist = 10

    // MARK: - Record mutation

    private func todayIndex(bundleID: String, appName: String) -> Int {
        let day = Calendar.current.startOfDay(for: Date())
        // Was an O(records) scan doing a Calendar comparison per element, run
        // once per running app per tick and again for each accrue* call. With
        // 14-day retention and ~30 apps that is roughly 12,600 calendar
        // comparisons every 30 s on the main thread. The index is rebuilt only
        // when the day rolls over.
        if todayIndexCacheDay != day {
            todayIndexCache = [:]
            todayIndexCacheDay = day
            for (i, r) in records.enumerated() where Calendar.current.isDate(r.day, inSameDayAs: day) {
                todayIndexCache[r.bundleID] = i
            }
        }

        if let idx = todayIndexCache[bundleID], idx < records.count,
           records[idx].bundleID == bundleID,
           Calendar.current.isDate(records[idx].day, inSameDayAs: day) {
            records[idx].appName = appName   // keep the display name fresh
            return idx
        }

        records.append(AppUsageRecord(bundleID: bundleID, appName: appName, day: day))
        let idx = records.count - 1
        todayIndexCache[bundleID] = idx
        return idx
    }

    /// Invalidated whenever `records` is reordered or filtered.
    private func invalidateTodayIndexCache() {
        todayIndexCache = [:]
        todayIndexCacheDay = nil
    }

    private func accrueForeground(bundleID: String, appName: String, seconds: TimeInterval) {
        let idx = todayIndex(bundleID: bundleID, appName: appName)
        records[idx].foregroundSeconds += seconds
    }

    private func accrueObservedRunning(bundleID: String, appName: String, seconds: TimeInterval) {
        let idx = todayIndex(bundleID: bundleID, appName: appName)
        records[idx].observedRunningSeconds += seconds
    }

    private func accrueRAMSample(bundleID: String, appName: String, ramMB: Double) {
        let idx = todayIndex(bundleID: bundleID, appName: appName)
        records[idx].ramSampleSumMB += ramMB
        records[idx].ramSampleCount += 1
    }

    private func recordSwitch(bundleID: String, appName: String) {
        let idx = todayIndex(bundleID: bundleID, appName: appName)
        records[idx].switchCount += 1
    }

    // MARK: - Aggregation (consumed by AppUsageInsightsSection)

    /// The earliest day Halo has any real observation for — the honest anchor
    /// for "how long has Halo actually been watching", used to gate stats that
    /// need enough history to be meaningful instead of guessing.
    var firstObservedDay: Date? { records.map(\.day).min() }

    private func recordsInWindow(days: Int) -> [AppUsageRecord] {
        Self.recordsInWindow(records, days: days, now: Date())
    }

    /// Top apps by foreground time over the last 7 days.
    func topApps(limit: Int = 5) -> [AppUsageSummary] {
        Self.topApps(from: records, limit: limit, windowDays: Self.headlineWindowDays, now: Date())
    }

    /// Apps that ran for a long stretch on most days of the week while almost
    /// never being brought to the front.
    ///
    /// The rule used to be "8 cumulative hours over the whole 7-day window",
    /// which is a bit over an hour a day — every menu-bar utility, sync client
    /// and app left open during the workday cleared it, and
    /// `maxForegroundRatio` cannot exclude them because a background helper has
    /// near-zero foreground time by definition. So the section listed most of
    /// the user's normal background apps as "hogs", which is not actionable.
    /// The doc comment and PR text both claimed "continuously", which the
    /// implementation never did.
    ///
    /// It is now per-day, which `AppUsageRecord` already buckets for: at least
    /// `minHoursPerDay` observed on at least `minQualifyingDays` separate days.
    func backgroundHogs(minHoursPerDay: Double = 4,
                        minQualifyingDays: Int = 4,
                        maxForegroundRatio: Double = 0.02) -> [BackgroundHogApp] {
        Self.backgroundHogs(from: records, minHoursPerDay: minHoursPerDay,
                             minQualifyingDays: minQualifyingDays,
                             maxForegroundRatio: maxForegroundRatio,
                             windowDays: Self.headlineWindowDays, now: Date())
    }

    /// Context switches per hour of tracked time — `nil` until there's at
    /// least an hour of real history, rather than reporting a wild number
    /// from a couple of minutes of data.
    func contextSwitchesPerHour() -> Double? {
        Self.contextSwitchesPerHour(from: records, firstObservedDay: firstObservedDay,
                                     windowDays: Self.headlineWindowDays, now: Date())
    }

    struct WeekOverWeek: Equatable {
        let thisWeekSeconds: TimeInterval
        let lastWeekSeconds: TimeInterval
        var percentChange: Double? {
            guard lastWeekSeconds > 0 else { return nil }
            return ((thisWeekSeconds - lastWeekSeconds) / lastWeekSeconds) * 100
        }
    }

    /// `nil` until Halo has observed at least 14 days — otherwise "last week"
    /// would be silently zero and every result would show a fake +100%.
    func weekOverWeekChange() -> WeekOverWeek? {
        Self.weekOverWeekChange(from: records, firstObservedDay: firstObservedDay, now: Date())
    }

    // MARK: - Pure aggregation logic (F-021)
    //
    // Extracted from the instance methods above, parameterized on `records`
    // and `now`, so `HaloTests` can exercise the exact same math against
    // synthetic `[AppUsageRecord]` arrays and a fixed date — no live
    // NSWorkspace/timer/UserDefaults required. No behavior change: the
    // instance methods above just forward to these with `self.records` and
    // `Date()`.

    nonisolated static func recordsInWindow(_ records: [AppUsageRecord], days: Int, now: Date) -> [AppUsageRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now)) else { return records }
        return records.filter { $0.day >= cutoff }
    }

    nonisolated static func topApps(from records: [AppUsageRecord], limit: Int, windowDays: Int, now: Date) -> [AppUsageSummary] {
        var byBundle: [String: (name: String, fg: TimeInterval, ramSum: Double, ramCount: Int, switches: Int)] = [:]
        for r in recordsInWindow(records, days: windowDays, now: now) {
            var entry = byBundle[r.bundleID] ?? (r.appName, 0, 0, 0, 0)
            entry.fg += r.foregroundSeconds
            entry.ramSum += r.ramSampleSumMB
            entry.ramCount += r.ramSampleCount
            entry.switches += r.switchCount
            entry.name = r.appName
            byBundle[r.bundleID] = entry
        }
        return byBundle
            .map { bid, v in
                AppUsageSummary(id: bid, appName: v.name, totalForegroundSeconds: v.fg,
                                 averageRAMMB: v.ramCount > 0 ? v.ramSum / Double(v.ramCount) : 0,
                                 switchCount: v.switches)
            }
            .filter { $0.totalForegroundSeconds > 0 }
            .sorted { $0.totalForegroundSeconds > $1.totalForegroundSeconds }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated static func backgroundHogs(from records: [AppUsageRecord],
                                minHoursPerDay: Double,
                                minQualifyingDays: Int,
                                maxForegroundRatio: Double,
                                windowDays: Int, now: Date) -> [BackgroundHogApp] {
        var byBundle: [String: (name: String, observed: TimeInterval, fg: TimeInterval,
                                ramSum: Double, ramCount: Int, qualifyingDays: Int)] = [:]
        for r in recordsInWindow(records, days: windowDays, now: now) {
            var entry = byBundle[r.bundleID] ?? (r.appName, 0, 0, 0, 0, 0)
            entry.observed += r.observedRunningSeconds
            entry.fg += r.foregroundSeconds
            entry.ramSum += r.ramSampleSumMB
            entry.ramCount += r.ramSampleCount
            entry.name = r.appName
            // Counted per day-bucket, which is what makes this "most days"
            // rather than "an hour a day adds up over a week".
            if r.observedRunningSeconds >= minHoursPerDay * 3600 {
                entry.qualifyingDays += 1
            }
            byBundle[r.bundleID] = entry
        }
        return byBundle
            .compactMap { bid, v -> BackgroundHogApp? in
                guard v.qualifyingDays >= minQualifyingDays else { return nil }
                let hog = BackgroundHogApp(id: bid, appName: v.name, observedRunningSeconds: v.observed,
                                            foregroundSeconds: v.fg,
                                            averageRAMMB: v.ramCount > 0 ? v.ramSum / Double(v.ramCount) : 0,
                                            qualifyingDays: v.qualifyingDays)
                guard hog.foregroundRatio <= maxForegroundRatio else { return nil }
                return hog
            }
            .sorted { $0.observedRunningSeconds > $1.observedRunningSeconds }
    }

    nonisolated static func contextSwitchesPerHour(from records: [AppUsageRecord], firstObservedDay: Date?,
                                        windowDays: Int, now: Date) -> Double? {
        guard let first = firstObservedDay else { return nil }
        let hoursTracked = max(0, now.timeIntervalSince(first) / 3600)
        guard hoursTracked >= 1 else { return nil }

        let window = recordsInWindow(records, days: windowDays, now: now)
        let totalSwitches = window.reduce(0) { $0 + $1.switchCount }
        let windowHours = min(hoursTracked, Double(windowDays * 24))
        guard windowHours > 0 else { return nil }
        return Double(totalSwitches) / windowHours
    }

    nonisolated static func weekOverWeekChange(from records: [AppUsageRecord], firstObservedDay: Date?, now: Date) -> WeekOverWeek? {
        guard let first = firstObservedDay else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        guard let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -6, to: today),
              let fourteenDaysAgo = Calendar.current.date(byAdding: .day, value: -13, to: today) else { return nil }
        guard first <= fourteenDaysAgo else { return nil }

        let thisWeek = records.filter { $0.day >= sevenDaysAgo }.reduce(0) { $0 + $1.foregroundSeconds }
        let lastWeek = records.filter { $0.day >= fourteenDaysAgo && $0.day < sevenDaysAgo }.reduce(0) { $0 + $1.foregroundSeconds }
        return WeekOverWeek(thisWeekSeconds: thisWeek, lastWeekSeconds: lastWeek)
    }

    /// Settings-panel "Clear Usage History" action.
    func clearHistory() {
        records.removeAll()
        persistToDefaults()
    }

    // MARK: - Persistence

    private func persistToDefaults() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([AppUsageRecord].self, from: data) else { return }
        records = saved
    }

    private func pruneOldRecords() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -(Self.retentionWindowDays - 1), to: Calendar.current.startOfDay(for: Date())) else { return }
        let before = records.count
        records.removeAll { $0.day < cutoff }
        // Removing shifts every later index, so the cache must go with it.
        if records.count != before { invalidateTodayIndexCache() }
    }

    // MARK: - RAM sampling
    //
    // This used to fork/exec `/bin/ps -p <pid> -o rss=` and block on
    // `waitUntilExit()` — from `tick()`, which runs on the MainActor. That is a
    // process spawn plus teardown (10-30 ms) on the UI thread twice a minute,
    // forever, for a number the kernel will hand over directly. It also carried
    // the `waitUntilExit()`-before-read ordering that deadlocks elsewhere in
    // this batch; `ps -o rss=` output is a few bytes so it never bit here, but
    // it was the same copied shape.
    //
    // `proc_pidinfo` is one syscall, no subprocess, and no main-thread stall.

    private static func processRAMMB(pid: pid_t) -> Double {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTASKINFO_HALO, 0, &info, Int32(size)) > 0 else { return 0 }
        return Double(info.pti_resident_size) / 1_048_576
    }
}

/// `PROC_PIDTASKINFO`. Declared here because the Darwin overlay does not
/// surface the constant to Swift; `ProcessMonitor` declares its own copy for the
/// same reason.
private let PROC_PIDTASKINFO_HALO: Int32 = 4
