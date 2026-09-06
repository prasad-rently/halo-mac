import Foundation
import UserNotifications
import AppKit

// MARK: - WeeklyDigestGenerator (F-029)
//
// Composes a WeeklyDigestSummary from existing stores (MetricsHistory,
// AlertLog, AppState) and delivers it as a local notification on the
// schedule the user picks in Settings → General → Weekly Digest (day + hour
// picker — the exact same pattern as ScanScheduler's "Scheduled Scans"
// section).
//
// Honesty note (see docs/FEATURE_ROADMAP.md's F-029 "As actually built"):
//   • Health score trend       — REAL (MetricsHistory hourly samples)
//   • Disk-free week-over-week — REAL (MetricsHistory hourly samples),
//                                 standing in for "top storage growers"
//   • Top-RAM apps             — REAL but coarse (hourly ProcessMonitor
//                                 samples aggregated, not continuous tracking)
//   • Threats / scans / alerts — REAL (AlertLog, filtered to the period)
//   • "Backup status"          — NOT built. Halo has no Time Machine
//     integration yet (that's F-022, still a Future Idea) so it is omitted
//     from the digest rather than faked.

@MainActor
enum WeeklyDigestGenerator {

    /// Deletes any weekly-digest PDFs left in the temp directory by previous
    /// runs. The share sheet copies what it needs, but nothing ever removed the
    /// original, so one accumulated per share, forever.
    static func cleanUpOldSharedReports() {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in contents where url.lastPathComponent.hasPrefix("HaloWeeklyDigest-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Composition

    static func composeSummary(from appState: AppState, days: Int = 7) -> WeeklyDigestSummary {
        let history = MetricsHistory.shared.recent(days: days)
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let alertsInPeriod = AlertLog.shared.entries.filter { $0.date >= cutoff }

        // Per-app average RAM across the window.
        //
        // The divisor is the number of samples in the *period*, not the number
        // in which the app happened to make that hour's top 5. Dividing by the
        // latter meant an app that ran once at 8 GB averaged 8000 MB and ranked
        // first, while one sitting at 4 GB every hour all week averaged 4000 MB
        // and ranked second — so a section titled "Apps with high average RAM"
        // systematically promoted brief spikes over the sustained consumers the
        // user can actually act on. Hours where an app was not in the top 5 count
        // as zero, which understates it slightly but never inverts the ranking.
        //
        // `hoursObserved` is carried through so the UI can show a spike as a
        // spike rather than silently averaging it away.
        var ramTotals: [String: (sum: Double, hours: Int)] = [:]
        for sample in history {
            for proc in sample.topRAMProcesses {
                var entry = ramTotals[proc.name] ?? (sum: 0, hours: 0)
                entry.sum += proc.ramMB
                entry.hours += 1
                ramTotals[proc.name] = entry
            }
        }
        let periodSamples = max(history.count, 1)
        let topRAMApps = ramTotals
            .map { RankedApp(name: $0.key,
                             avgRAMMB: $0.value.sum / Double(periodSamples),
                             hoursObserved: $0.value.hours,
                             hoursInPeriod: periodSamples) }
            .sorted { $0.avgRAMMB > $1.avgRAMMB }
            .prefix(5)

        // Only quote a start-of-period figure when the history actually spans
        // one. On a fresh install `history.first` is the launch sample, so the
        // "weekly" delta was really "since Halo opened" — presented as a week's
        // change. Sibling #10 already refuses to show a comparison until it has
        // the data, for exactly this reason.
        let hasFullPeriod = Self.spansEnoughOfPeriod(history, days: days)

        return WeeklyDigestSummary(
            generatedDate: Date(),
            periodDays: days,
            healthScoreStart: hasFullPeriod ? history.first?.healthScore : nil,
            healthScoreEnd: appState.systemHealthScore,
            healthSamples: history,
            diskFreeStartGB: hasFullPeriod ? history.first?.diskFreeGB : nil,
            diskFreeEndGB: appState.diskFreeGB,
            topAverageRAMApps: Array(topRAMApps),
            alertsInPeriod: alertsInPeriod,
            // `kindRaw`, not the notification prose. Matching on the word
            // "threat" in `body` counted the *negative* case too: "No threats
            // found" and "0 threats detected" are exactly what a clean week
            // produces, so a week of clean scans reported "N threats flagged".
            // It also broke the moment the copy was localized. `AlertEntry`
            // carries `kindRaw` precisely so consumers never parse prose —
            // `scansCompletedCount` on the next line already did it right.
            threatsDetectedCount: alertsInPeriod.filter { Self.threatKindRaws.contains($0.kindRaw) }.count,
            scansCompletedCount: alertsInPeriod.filter { $0.kindRaw == "scan" }.count
        )
    }

    /// Alert kinds that represent a real detection. Kept as an explicit set so
    /// adding a threat kind is a deliberate act rather than a substring
    /// coincidence.
    nonisolated static let threatKindRaws: Set<String> = ["threat", "threat_found", "malware", "adware"]

    /// Whether the sample history genuinely covers most of the period.
    ///
    /// `MetricsHistory` samples on a main-runloop `Timer`, so sleep and quit
    /// gaps are simply absent with no markers — `recent(days: 7)` cannot tell 7
    /// days of hourly samples from 3 samples taken 7 days apart. Requiring both
    /// a minimum count and a minimum span makes both failure shapes fall out.
    nonisolated static func spansEnoughOfPeriod(_ history: [MetricsSample], days: Int) -> Bool {
        guard let first = history.first, let last = history.last else { return false }
        guard history.count >= 24 else { return false }
        let spanDays = last.date.timeIntervalSince(first.date) / 86_400
        return spanDays >= Double(days) * 0.85
    }

    // MARK: - Notification body

    static func notificationBody(for summary: WeeklyDigestSummary) -> String {
        var parts: [String] = []

        if let delta = summary.healthScoreDelta {
            let direction = delta > 0 ? "up" : delta < 0 ? "down" : "steady"
            parts.append("Health score \(direction) \(abs(delta)) pts (now \(summary.healthScoreEnd))")
        } else {
            parts.append("Health score: \(summary.healthScoreEnd)")
        }

        if let deltaDisk = summary.diskFreeDeltaGB, abs(deltaDisk) >= 0.1 {
            if deltaDisk < 0 {
                parts.append(String(format: "%.1f GB less free space", abs(deltaDisk)))
            } else {
                parts.append(String(format: "%.1f GB freed up", deltaDisk))
            }
        }

        if summary.scansCompletedCount > 0 {
            parts.append("\(summary.scansCompletedCount) scan\(summary.scansCompletedCount == 1 ? "" : "s") completed")
        }
        if summary.threatsDetectedCount > 0 {
            parts.append("\(summary.threatsDetectedCount) threat\(summary.threatsDetectedCount == 1 ? "" : "s") flagged")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Notification delivery

    static let categoryIdentifier = "com.halo.mac.weeklydigest"
    static let viewReportActionIdentifier = "VIEW_REPORT"

    /// Registers the "View Report" action button. Call once, before the first
    /// digest can possibly fire (WeeklyDigestScheduler.start does this).
    static func registerNotificationCategory() {
        let viewAction = UNNotificationAction(
            identifier: viewReportActionIdentifier,
            title: "View Report",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        // Read-modify-write. `setNotificationCategories` *replaces* the whole
        // set, and this runs from `WeeklyDigestScheduler.start` on every launch
        // — so it discarded any category another feature had registered.
        // Nothing else registers one today, which is exactly what makes it a
        // landmine: the next actionable notification would either be silently
        // stripped or strip this one, depending on registration order.
        Task {
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories()
            categories = categories.filter { $0.identifier != categoryIdentifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    static func postDigestNotification(summary: WeeklyDigestSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Your Weekly Halo Digest"
        content.body = notificationBody(for: summary)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        let request = UNNotificationRequest(
            identifier: "com.halo.mac.weeklydigest.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil   // deliver immediately when this is called (schedule already gated it)
        )
        // "Generated", not "Sent". If notification authorization was denied the
        // digest never appears, and the old copy had Alert History asserting it
        // had been delivered. The wording is now true either way, and a genuine
        // delivery failure is recorded rather than swallowed.
        let body = notificationBody(for: summary)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                AlertLog.shared.append(
                    title: "Weekly Digest Not Delivered",
                    body: "Halo generated your digest but macOS refused to show it: \(error.localizedDescription)",
                    kindRaw: "digest"
                )
            }
        }

        AlertLog.shared.append(
            title: "Weekly Digest Generated",
            body: body,
            kindRaw: "digest"
        )
    }

    // MARK: - Report export / share (F-029's "optional PDF attachment" bullet)

    /// Generates the standard PDF health report and presents the save panel —
    /// used by the digest notification's "View Report" action. Identical flow
    /// to the Dashboard's existing "Export Report" button.
    static func exportAndPresentReport(appState: AppState) {
        let snapshot = ReportSnapshot.capture(from: appState)
        Task.detached(priority: .userInitiated) {
            let doc = ReportGenerator.shared.generate(snapshot: snapshot)
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                ReportGenerator.presentSavePanel(document: doc)
            }
        }
    }

    /// Generates the PDF and opens the native macOS share sheet (Mail,
    /// AirDrop, Messages, …) instead of a save panel — the "shareable via
    /// NSSharingService" half of the F-029 spec. Wired to a button in
    /// Settings → General → Weekly Digest.
    /// `onFailure` is how the caller learns the share sheet never appeared.
    /// Every path that can fail silently reports through it.
    static func shareReportPDF(appState: AppState, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        let snapshot = ReportSnapshot.capture(from: appState)
        Task.detached(priority: .userInitiated) {
            let doc = ReportGenerator.shared.generate(snapshot: snapshot)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("HaloWeeklyDigest-\(formatter.string(from: Date())).pdf")
            guard doc.write(to: url) else {
                await MainActor.run { onFailure("Halo couldn't write the report to disk.") }
                return
            }
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let picker = NSSharingServicePicker(items: [url])

                // `keyWindow` alone was not enough: this is invoked from
                // Settings, and if the click path leaves it nil (Settings as a
                // sheet, focus moving after `NSApp.activate`, or a
                // notification-driven call) the PDF was written and then
                // nothing at all happened on screen — no sheet, no error.
                let anchor = NSApp.keyWindow?.contentView
                    ?? NSApp.mainWindow?.contentView
                    ?? NSApp.windows.first(where: { $0.isVisible })?.contentView

                guard let anchor else {
                    onFailure("Halo couldn't find a window to show the share sheet. Open Halo's main window and try again.")
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            }
        }
    }
}

// MARK: - WeeklyDigestScheduler
//
// NSBackgroundActivityScheduler wrapper for the digest — the same pattern as
// ScanScheduler (F-005/F-015), with its own identifier so the digest and
// Smart Scan schedules are fully independent (each has its own frequency,
// day, and hour prefs).

@MainActor
final class WeeklyDigestScheduler {

    static let shared = WeeklyDigestScheduler()
    private init() {}

    private var activity: NSBackgroundActivityScheduler?
    private weak var appState: AppState?
    private let notificationDelegate = DigestNotificationDelegate()

    /// Computed next-fire date — mirrors ScanScheduler.nextFireDate for Settings display.
    var nextFireDate: Date? {
        nextDigestDate(frequency: frequency, weekday: weekday, hour: hour)
    }

    // MARK: - Public API

    /// Call once from HaloApp, right alongside ScanScheduler.shared.start(appState:).
    func start(appState: AppState) {
        self.appState = appState
        UNUserNotificationCenter.current().delegate = notificationDelegate
        WeeklyDigestGenerator.registerNotificationCategory()
        applySchedule()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySchedule() }
        }
    }

    /// Composes and posts a digest immediately, bypassing the schedule.
    /// Wired to the Settings "Send Test Digest Now" button — not called
    /// automatically anywhere else.
    func sendNow() {
        guard let appState else { return }
        let summary = WeeklyDigestGenerator.composeSummary(from: appState)
        WeeklyDigestGenerator.postDigestNotification(summary: summary)
    }

    /// Returns the next fire date given frequency + preferred weekday (1=Sun…7=Sat) + hour.
    /// "off" (digest disabled) returns nil.
    func nextDigestDate(frequency: String, weekday: Int, hour: Int) -> Date? {
        guard frequency != "off" else { return nil }

        let cal = Calendar.current
        let now = Date()

        var comps = DateComponents()
        comps.hour   = max(0, min(23, hour))
        comps.minute = 0
        comps.second = 0

        switch frequency {
        case "daily":
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        case "weekly":
            comps.weekday = max(1, min(7, weekday))
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        default:
            return nil
        }
    }

    // MARK: - Private

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: "weeklyDigestEnabled") }

    private var frequency: String {
        UserDefaults.standard.string(forKey: "weeklyDigestFrequency") ?? "weekly"
    }

    private var weekday: Int {
        let v = UserDefaults.standard.integer(forKey: "weeklyDigestWeekday")
        return v > 0 ? v : 2   // default Monday
    }

    private var hour: Int {
        UserDefaults.standard.object(forKey: "weeklyDigestHour") as? Int ?? 9
    }

    private var repeatInterval: TimeInterval {
        frequency == "daily" ? 24 * 60 * 60 : 7 * 24 * 60 * 60
    }

    private func applySchedule() {
        // Tear down any existing scheduler first — mirrors ScanScheduler.applySchedule().
        activity?.invalidate()
        activity = nil

        guard isEnabled else { return }

        let nextDate = nextDigestDate(frequency: frequency, weekday: weekday, hour: hour)
            ?? Date().addingTimeInterval(repeatInterval)
        let interval = max(60, nextDate.timeIntervalSinceNow)

        let scheduler = NSBackgroundActivityScheduler(identifier: "com.halo.mac.weeklydigest")
        scheduler.repeats   = true
        scheduler.interval  = repeatInterval
        scheduler.tolerance = interval * 0.05
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            guard let self, let appState = self.appState else { completion(.deferred); return }
            Task { @MainActor in
                let summary = WeeklyDigestGenerator.composeSummary(from: appState)
                WeeklyDigestGenerator.postDigestNotification(summary: summary)
                completion(.finished)
            }
        }

        activity = scheduler
    }
}

// MARK: - DigestNotificationDelegate
//
// Handles the "View Report" action button tap on the digest notification. A
// small dedicated NSObject subclass (rather than making AppState itself
// NSObject-based) since UNUserNotificationCenterDelegate requires
// NSObjectProtocol conformance. Uses AppState.shared (the existing static
// reference App Intents already rely on) rather than holding its own copy.
@MainActor
final class DigestNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tappedViewReport = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == WeeklyDigestGenerator.viewReportActionIdentifier

        if tappedViewReport, let appState = AppState.shared {
            Task { @MainActor in
                WeeklyDigestGenerator.exportAndPresentReport(appState: appState)
            }
        }
        completionHandler()
    }

    /// Show the notification banner even while Halo is already in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
