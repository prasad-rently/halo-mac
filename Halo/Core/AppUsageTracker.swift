import Foundation
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
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.SystemUIServer",
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
        observerTokens = [activateToken]

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
        timer?.invalidate()
        timer = nil
        activeBundleID = nil
        activeAppName = nil
        activePID = nil
        isTracking = false
    }

    // MARK: - Event handling

    private func handleActivation(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              let bid = app.bundleIdentifier, !bid.isEmpty,
              !Self.excludedBundleIDs.contains(bid) else { return }

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

        pruneOldRecords()
        persistToDefaults()
    }

    // MARK: - Record mutation

    private func todayIndex(bundleID: String, appName: String) -> Int {
        let day = Calendar.current.startOfDay(for: Date())
        if let idx = records.firstIndex(where: { $0.bundleID == bundleID && Calendar.current.isDate($0.day, inSameDayAs: day) }) {
            records[idx].appName = appName   // keep the display name fresh
            return idx
        }
        records.append(AppUsageRecord(bundleID: bundleID, appName: appName, day: day))
        return records.count - 1
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

    /// Apps observed running continuously for a long stretch (default 8 h)
    /// over the last 7 days while almost never being brought to the front.
    func backgroundHogs(minObservedHours: Double = 8, maxForegroundRatio: Double = 0.02) -> [BackgroundHogApp] {
        Self.backgroundHogs(from: records, minObservedHours: minObservedHours, maxForegroundRatio: maxForegroundRatio,
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

    static func recordsInWindow(_ records: [AppUsageRecord], days: Int, now: Date) -> [AppUsageRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now)) else { return records }
        return records.filter { $0.day >= cutoff }
    }

    static func topApps(from records: [AppUsageRecord], limit: Int, windowDays: Int, now: Date) -> [AppUsageSummary] {
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

    static func backgroundHogs(from records: [AppUsageRecord], minObservedHours: Double, maxForegroundRatio: Double,
                                windowDays: Int, now: Date) -> [BackgroundHogApp] {
        var byBundle: [String: (name: String, observed: TimeInterval, fg: TimeInterval, ramSum: Double, ramCount: Int)] = [:]
        for r in recordsInWindow(records, days: windowDays, now: now) {
            var entry = byBundle[r.bundleID] ?? (r.appName, 0, 0, 0, 0)
            entry.observed += r.observedRunningSeconds
            entry.fg += r.foregroundSeconds
            entry.ramSum += r.ramSampleSumMB
            entry.ramCount += r.ramSampleCount
            entry.name = r.appName
            byBundle[r.bundleID] = entry
        }
        return byBundle
            .compactMap { bid, v -> BackgroundHogApp? in
                let hog = BackgroundHogApp(id: bid, appName: v.name, observedRunningSeconds: v.observed,
                                            foregroundSeconds: v.fg,
                                            averageRAMMB: v.ramCount > 0 ? v.ramSum / Double(v.ramCount) : 0)
                guard hog.observedRunningSeconds >= minObservedHours * 3600,
                      hog.foregroundRatio <= maxForegroundRatio else { return nil }
                return hog
            }
            .sorted { $0.observedRunningSeconds > $1.observedRunningSeconds }
    }

    static func contextSwitchesPerHour(from records: [AppUsageRecord], firstObservedDay: Date?,
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

    static func weekOverWeekChange(from records: [AppUsageRecord], firstObservedDay: Date?, now: Date) -> WeekOverWeek? {
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
        records.removeAll { $0.day < cutoff }
    }

    // MARK: - RAM sampling (same `ps -p <pid> -o rss=` technique as IdleAppMonitor)

    private static func processRAMMB(pid: pid_t) -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let kb = Double(str) {
                return kb / 1024.0   // KB → MB
            }
        } catch {}
        return 0
    }
}
