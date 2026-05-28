import Foundation
import UserNotifications

// MARK: - ScanScheduler (F-005)
//
// Schedules periodic Smart Scans using NSBackgroundActivityScheduler — the macOS
// equivalent of iOS BGTaskScheduler.  When a background scan completes a local
// UNUserNotification is fired summarising the results.
//
// Frequency is read from the "scanFrequency" AppStorage key and re-applied
// whenever it changes.  Calling start() once from HaloApp.init() is sufficient.
//
// Usage:
//   ScanScheduler.shared.start(appState: appState)   // called once at app launch

@MainActor
final class ScanScheduler {

    // MARK: - Singleton
    static let shared = ScanScheduler()
    private init() {}

    // MARK: - State

    private var activity: NSBackgroundActivityScheduler?
    private weak var appState: AppState?

    /// Computed next-fire date — used by DashHeader countdown.
    var nextFireDate: Date? {
        nextScanDate(
            frequency: scanFrequency,
            weekday: UserDefaults.standard.integer(forKey: "scanPreferredWeekday") > 0
                ? UserDefaults.standard.integer(forKey: "scanPreferredWeekday") : 2,
            hour: UserDefaults.standard.integer(forKey: "scanPreferredHour")
        )
    }

    // MARK: - F-015: next-scan date calculator

    /// Returns the next fire date given frequency + preferred weekday (1=Sun…7=Sat) + hour.
    func nextScanDate(frequency: String, weekday: Int, hour: Int) -> Date? {
        guard frequency != "off" else { return nil }

        let cal = Calendar.current
        let now = Date()

        // Build DateComponents for the desired hour (minute=0)
        var comps = DateComponents()
        comps.hour   = max(0, min(23, hour))
        comps.minute = 0
        comps.second = 0

        switch frequency {
        case "daily":
            // Next occurrence of the preferred hour today-or-tomorrow
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)

        case "weekly":
            // Next occurrence of (weekday, hour) — may be today if still in future
            comps.weekday = max(1, min(7, weekday))
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)

        case "monthly":
            // Same weekday-of-month pattern; simplify to: next month on the weekday
            // Use Calendar.nextDate matching weekday + hour
            comps.weekday = max(1, min(7, weekday))
            // Skip to the matching day in ~4 weeks from now
            guard let candidate = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else { return nil }
            // If that's within a week, add ~3 more weeks to space it out to monthly
            if candidate.timeIntervalSince(now) < 7 * 24 * 3600 {
                return cal.nextDate(after: candidate.addingTimeInterval(21 * 24 * 3600),
                                    matching: comps, matchingPolicy: .nextTime)
            }
            return candidate

        default:
            return nil
        }
    }

    // MARK: - Public API

    /// Call once from HaloApp.  Observes UserDefaults so that settings changes
    /// take effect immediately without restarting the app.
    func start(appState: AppState) {
        self.appState = appState
        applySchedule()

        // Re-schedule whenever the user changes the frequency in Settings
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySchedule() }
        }
    }

    // MARK: - Private

    private var scanFrequency: String {
        UserDefaults.standard.string(forKey: "scanFrequency") ?? "weekly"
    }

    private var currentInterval: TimeInterval {
        switch scanFrequency {
        case "daily":   return 24 * 60 * 60
        case "weekly":  return 7  * 24 * 60 * 60
        case "monthly": return 30 * 24 * 60 * 60
        default:        return 0    // "off"
        }
    }

    private var scanPreferredWeekday: Int {
        let v = UserDefaults.standard.integer(forKey: "scanPreferredWeekday")
        return v > 0 ? v : 2   // default Monday
    }

    private var scanPreferredHour: Int {
        UserDefaults.standard.integer(forKey: "scanPreferredHour")
    }

    private func applySchedule() {
        // Tear down any existing scheduler first
        activity?.invalidate()
        activity = nil

        let freq = scanFrequency
        guard freq != "off" else { return }

        // F-015: compute exact time until next preferred day/hour
        let weekday = scanPreferredWeekday
        let hour    = scanPreferredHour
        let nextDate = nextScanDate(frequency: freq, weekday: weekday, hour: hour) ?? Date().addingTimeInterval(currentInterval)
        let interval = max(60, nextDate.timeIntervalSinceNow)
        let repeatInterval = currentInterval

        let scheduler = NSBackgroundActivityScheduler(identifier: "com.halo.mac.smartscan")
        scheduler.repeats   = true
        scheduler.interval  = repeatInterval > 0 ? repeatInterval : interval
        scheduler.tolerance = interval * 0.05   // ±5 % jitter
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.deferred); return }

            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else {
                    completion(.deferred)
                    return
                }
                await appState.runSmartScan()
                self.postScanCompletionNotification(result: appState.smartScanResult)
                completion(.finished)
            }
        }

        activity = scheduler
    }

    // MARK: - Local Notification

    private func postScanCompletionNotification(result: SmartScanResult?) {
        let content = UNMutableNotificationContent()
        content.title = "Smart Scan Complete"

        if let r = result {
            var parts: [String] = []
            if r.threatsFound > 0 {
                parts.append("\(r.threatsFound) threat\(r.threatsFound == 1 ? "" : "s") found")
            }
            if r.totalBytes > 1_000_000 {
                parts.append(r.totalBytesFormatted + " junk")
            }
            content.body = parts.isEmpty ? "Your Mac is in great shape!" : parts.joined(separator: " · ")
        } else {
            content.body = "Scan finished. Open Halo to view results."
        }

        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.halo.mac.scancomplete.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}

