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

    // MARK: - Composition

    static func composeSummary(from appState: AppState, days: Int = 7) -> WeeklyDigestSummary {
        let history = MetricsHistory.shared.recent(days: days)
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let alertsInPeriod = AlertLog.shared.entries.filter { $0.date >= cutoff }

        // Aggregate real per-app average RAM across all hourly samples in the window.
        var ramTotals: [String: (sum: Double, count: Int)] = [:]
        for sample in history {
            for proc in sample.topRAMProcesses {
                var entry = ramTotals[proc.name] ?? (sum: 0, count: 0)
                entry.sum += proc.ramMB
                entry.count += 1
                ramTotals[proc.name] = entry
            }
        }
        let topRAMApps = ramTotals
            .map { RankedApp(name: $0.key, avgRAMMB: $0.value.sum / Double($0.value.count)) }
            .sorted { $0.avgRAMMB > $1.avgRAMMB }
            .prefix(5)

        return WeeklyDigestSummary(
            generatedDate: Date(),
            periodDays: days,
            healthScoreStart: history.first?.healthScore,
            healthScoreEnd: appState.systemHealthScore,
            healthSamples: history,
            diskFreeStartGB: history.first?.diskFreeGB,
            diskFreeEndGB: appState.diskFreeGB,
            topAverageRAMApps: Array(topRAMApps),
            alertsInPeriod: alertsInPeriod,
            threatsDetectedCount: alertsInPeriod.filter { $0.body.localizedCaseInsensitiveContains("threat") }.count,
            scansCompletedCount: alertsInPeriod.filter { $0.kindRaw == "scan" }.count
        )
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
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        UNUserNotificationCenter.current().add(request)

        // Mirrors ScanScheduler's completion notification — also lands in Alert History.
        AlertLog.shared.append(
            title: "Weekly Digest Sent",
            body: notificationBody(for: summary),
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
    static func shareReportPDF(appState: AppState) {
        let snapshot = ReportSnapshot.capture(from: appState)
        Task.detached(priority: .userInitiated) {
            let doc = ReportGenerator.shared.generate(snapshot: snapshot)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("HaloWeeklyDigest-\(formatter.string(from: Date())).pdf")
            guard doc.write(to: url) else { return }
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let picker = NSSharingServicePicker(items: [url])
                if let window = NSApp.keyWindow, let view = window.contentView {
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
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
