import Foundation
import UserNotifications

// MARK: - AlertManager  (P3-08)
//
// Zero background overhead — evaluate() is called from AppState.refreshMetrics()
// which already fires every 2 s. Each check is a simple Double comparison (~ns).
// Debouncing via a [AlertKind: Date] dictionary prevents notification spam.

@MainActor
final class AlertManager {

    // MARK: - Alert kinds

    enum AlertKind: String, CaseIterable {
        case cpuHigh        = "cpu_high"
        case ramHigh        = "ram_high"
        case diskLow        = "disk_low"
        case batteryLow     = "battery_low"
        case batteryCritical = "battery_critical"
        case chargingDone   = "charging_done"
        case appMemoryHigh  = "app_memory_high"   // F-023
    }

    // MARK: - State

    private var lastFired: [AlertKind: Date] = [:]

    // F-023 — per-app cooldown, keyed by bundle ID rather than `AlertKind` so
    // one app crossing the RAM threshold doesn't suppress another's alert.
    private var lastFiredPerApp: [String: Date] = [:]

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

    // MARK: - F-023 — per-app RAM threshold check
    //
    // Called from MemoryTrendTracker after every 30 s sample round — a
    // separate entry point from evaluate() because it fires per-app rather
    // than once per system-wide metric, and needs its own cooldown dictionary
    // keyed by bundle ID (see `lastFiredPerApp`) instead of the shared
    // `lastFired` dictionary, which only has room for one Date per `AlertKind`.
    func checkAppMemory(appName: String, bundleID: String, ramMB: Double) {
        let thresholdGB = UserDefaults.standard.double(forKey: "memoryLeakAlertThresholdGB").nonZero
            ?? MemoryTrendTracker.defaultAlertThresholdGB
        guard ramMB >= thresholdGB * 1024 else { return }

        let cooldown: TimeInterval = 1800   // 30 min — same order as the other high-usage alerts
        if let last = lastFiredPerApp[bundleID], Date().timeIntervalSince(last) < cooldown { return }
        lastFiredPerApp[bundleID] = Date()

        post(
            title: "\(appName) Using High Memory",
            body: String(format: "%@ is using %.1f GB of RAM. Consider restarting it.", appName, ramMB / 1024),
            kindRaw: AlertKind.appMemoryHigh.rawValue
        )
    }

    // MARK: - Fire helpers

    private func fire(_ kind: AlertKind, title: String, body: String, cooldown: TimeInterval) {
        if let last = lastFired[kind], Date().timeIntervalSince(last) < cooldown { return }
        lastFired[kind] = Date()
        post(title: title, body: body, kindRaw: kind.rawValue)
    }

    private func post(title: String, body: String, kindRaw: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(kindRaw)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)

        // F-011: persist to in-app alert history log
        AlertLog.shared.append(title: title, body: body, kindRaw: kindRaw)
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
