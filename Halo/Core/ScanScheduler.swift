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
        guard let lastScan = appState?.lastSmartScanDate else { return nil }
        let interval = currentInterval
        guard interval > 0 else { return nil }
        return lastScan.addingTimeInterval(interval)
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

    private func applySchedule() {
        // Tear down any existing scheduler first
        activity?.invalidate()
        activity = nil

        let interval = currentInterval
        guard interval > 0 else { return }   // user turned scheduling off

        let scheduler = NSBackgroundActivityScheduler(identifier: "com.halo.mac.smartscan")
        scheduler.repeats   = true
        scheduler.interval  = interval
        scheduler.tolerance = interval * 0.10   // ±10 % jitter — power-efficient
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

