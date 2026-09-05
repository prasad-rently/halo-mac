import Foundation
import UserNotifications

// MARK: - AlertManager  (P3-08)
//
// Zero background overhead — evaluate() is called from AppState.refreshMetrics()
// which already fires every 2 s. Each check is a simple Double comparison (~ns).
// Debouncing via a [AlertKind: Date] dictionary prevents notification spam.

@MainActor
final class AlertManager {

    // MARK: - Singleton
    //
    // One instance, app-wide — matching `AlertLog.shared` beside it, which this
    // class already writes every alert into.
    //
    // The cooldowns in `lastFired` are the whole point of this type, and they
    // are per-instance state: a second `AlertManager` carries its own empty
    // dictionary, so the same alert can fire from both within the cooldown
    // window and the user gets it twice. Features queued behind this one add
    // their own `evaluate*` entry points (SMART disk health, Time Machine
    // staleness, per-app memory), each called from a different subsystem — so
    // they must all reach the same instance for "once per hour" to mean once
    // per hour. `init` is private so it stays that way.
    static let shared = AlertManager()
    private init() {}

    // MARK: - Alert kinds

    enum AlertKind: String, CaseIterable {
        case cpuHigh        = "cpu_high"
        case ramHigh        = "ram_high"
        case diskLow        = "disk_low"
        case batteryLow     = "battery_low"
        case batteryCritical = "battery_critical"
        case chargingDone   = "charging_done"
        case diskSmartWarning = "disk_smart_warning"
        case diskSmartFailing = "disk_smart_failing"
    }

    // MARK: - State

    private var lastFired: [AlertKind: Date] = [:]

    // Tracks whether we've already fired the "CPU sustained high" state
    // (needs 10 consecutive seconds > threshold before firing)
    private var cpuHighStarted: Date? = nil
    private var wasBatteryLow = false
    private var wasCharged = false

    // MARK: - Public entry point

    /// Called every 2 s from AppState.refreshMetrics() — no new timers needed.
    func evaluate(
        cpuUsage: Double,
        ramUsage: Double,
        diskFreeGB: Double,
        batteryPercent: Int,
        isCharging: Bool
    ) {
        checkCPU(cpuUsage)
        checkRAM(ramUsage)
        checkDisk(diskFreeGB)
        checkBattery(batteryPercent, isCharging: isCharging)
    }

    // MARK: - Individual checks

    private func checkCPU(_ cpu: Double) {
        let threshold = UserDefaults.standard.double(forKey: "alertCPUThreshold").nonZero ?? 0.85
        if cpu > threshold {
            if cpuHighStarted == nil { cpuHighStarted = Date() }
            if let start = cpuHighStarted, Date().timeIntervalSince(start) >= 10 {
                fire(.cpuHigh,
                     title: "CPU Under Heavy Load",
                     body: String(format: "CPU usage has been above %.0f%% for 10+ seconds.", threshold * 100),
                     cooldown: 300)
                cpuHighStarted = nil
            }
        } else {
            cpuHighStarted = nil
        }
    }

    private func checkRAM(_ ram: Double) {
        let threshold = UserDefaults.standard.double(forKey: "alertRAMThreshold").nonZero ?? 0.85
        guard ram > threshold else { return }
        fire(.ramHigh,
             title: "Memory Pressure High",
             body: String(format: "%.0f%% RAM in use. Consider closing unused apps.", ram * 100),
             cooldown: 300)
    }

    private func checkDisk(_ freeGB: Double) {
        let thresholdGB = UserDefaults.standard.double(forKey: "alertDiskFreeGB").nonZero ?? 5.0
        guard freeGB < thresholdGB, freeGB > 0 else { return }
        fire(.diskLow,
             title: "Low Disk Space",
             body: String(format: "Only %.1f GB remaining. Run Halo Cleanup to reclaim space.", freeGB),
             cooldown: 86400) // once per day
    }

    private func checkBattery(_ percent: Int, isCharging: Bool) {
        let lowThreshold = UserDefaults.standard.integer(forKey: "alertBatteryLow").nonZero ?? 20
        let critThreshold = UserDefaults.standard.integer(forKey: "alertBatteryCritical").nonZero ?? 10

        if isCharging {
            if percent >= 100 {
                fire(.chargingDone,
                     title: "Charging Complete",
                     body: "Your Mac is fully charged. You can unplug the charger.",
                     cooldown: 3600)
            }
            wasCharged = percent >= 100
            wasBatteryLow = false
            return
        }

        // Discharging
        if percent <= critThreshold {
            fire(.batteryCritical,
                 title: "Battery Critical — \(percent)%",
                 body: "Connect your charger immediately to prevent data loss.",
                 cooldown: 600)
        } else if percent <= lowThreshold {
            fire(.batteryLow,
                 title: "Battery Low — \(percent)%",
                 body: "Connect your charger soon.",
                 cooldown: 1800)
        }
    }

    // MARK: - S.M.A.R.T. disk health (F-020)

    /// Called from AppState's 5-minute SMART poll (not the 2 s metrics loop —
    /// `diskutil info` is cheap but there's no reason to shell out that often).
    /// Only ever fires for health levels Halo actually verified; `.unknown`
    /// (SMART data unreadable) never fires an alert — an unreadable status
    /// isn't evidence of a problem.
    ///
    /// Callers should pass `SMARTDiskInfo.alertLevel`, not `healthLevel` — the
    /// former is deliberately stricter, so a condition that merely colours the
    /// Drive Health card doesn't also push a banner at the user.
    ///
    /// `model` is nil when diskutil reported no MediaName; the title then omits
    /// the dash rather than reading "Drive Health Critical — your internal drive".
    func evaluateSMART(model: String?, healthLevel: SMARTDiskMonitor.DriveHealthLevel) {
        let suffix = model.map { " — \($0)" } ?? ""
        switch healthLevel {
        case .failing:
            fire(.diskSmartFailing,
                 title: "Drive Health Critical\(suffix)",
                 body: "S.M.A.R.T. reports a failing condition on your drive. Back up your data immediately.",
                 cooldown: 3600)
        case .warning:
            fire(.diskSmartWarning,
                 title: "Drive Health Warning\(suffix)",
                 body: "S.M.A.R.T. attributes show early signs of wear. Consider backing up important files soon.",
                 cooldown: 86400)
        case .good, .unknown:
            break
        }
    }

    // MARK: - Fire helper

    private func fire(_ kind: AlertKind, title: String, body: String, cooldown: TimeInterval) {
        if let last = lastFired[kind], Date().timeIntervalSince(last) < cooldown { return }
        lastFired[kind] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)

        // F-011: persist to in-app alert history log
        AlertLog.shared.append(title: title, body: body, kindRaw: kind.rawValue)
    }

    // MARK: - Permission request

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Helpers

private extension Double {
    /// Returns self unless zero (which means "not set").
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
