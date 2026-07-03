import Foundation
import AppKit

// MARK: - IdleApp

struct IdleApp: Identifiable, Equatable {
    let id: String               // bundle identifier
    let name: String
    let icon: NSImage?
    let ramMB: Double
    let idleSince: Date
    let pid: pid_t

    var idleDuration: TimeInterval {
        Date().timeIntervalSince(idleSince)
    }

    var idleDurationFormatted: String {
        let minutes = Int(idleDuration / 60)
        if minutes < 60 { return "\(minutes)m idle" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m idle"
    }

    var ramFormatted: String {
        if ramMB >= 1024 { return String(format: "%.1f GB", ramMB / 1024) }
        return String(format: "%.0f MB", ramMB)
    }
}

// MARK: - IdleAppMonitor

/// Monitors running apps for idle state (no visible windows + inactive past timeout).
/// Tracks last-active time via NSWorkspace notifications.
actor IdleAppMonitor {

    private var lastActiveTime: [String: Date] = [:]   // bundleID → last activation
    private var observerTokens: [NSObjectProtocol] = []

    /// System/menu-bar apps that should never be flagged as idle.
    private let systemBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.SystemUIServer",
        "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.halo.mac"
    ]

    // MARK: - Start / Stop

    func startMonitoring() {
        // Seed all running apps with current time
        let now = Date()
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            lastActiveTime[bid] = now
        }

        // Observe app activation events
        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            Task { await self?.recordActivation(bid) }
        }
        observerTokens.append(activateToken)
    }

    func stopMonitoring() {
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func recordActivation(_ bundleID: String) {
        lastActiveTime[bundleID] = Date()
    }

    // MARK: - Query

    /// Returns apps that have been idle (no activation) for longer than `timeout` seconds
    /// and have no visible windows.
    func idleApps(timeout: TimeInterval, excludeList: Set<String>) -> [IdleApp] {
        let now = Date()
        var result: [IdleApp] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  !bid.isEmpty,
                  app.activationPolicy == .regular,  // only regular apps (not accessories/daemons)
                  !systemBundleIDs.contains(bid),
                  !excludeList.contains(bid) else { continue }

            // Check idle time
            let lastActive = lastActiveTime[bid] ?? now
            let idleTime = now.timeIntervalSince(lastActive)
            guard idleTime >= timeout else { continue }

            // Check window count via Accessibility (rough check)
            let hasWindows = appHasVisibleWindows(pid: app.processIdentifier)
            guard !hasWindows else {
                // App has visible windows — reset idle timer
                lastActiveTime[bid] = now
                continue
            }

            // Get RAM usage via ps
            let ramMB = getProcessRAM(pid: app.processIdentifier)

            result.append(IdleApp(
                id: bid,
                name: app.localizedName ?? bid,
                icon: app.icon,
                ramMB: ramMB,
                idleSince: lastActive,
                pid: app.processIdentifier
            ))
        }

        return result.sorted { $0.ramMB > $1.ramMB }
    }

    // MARK: - Quit

    func quitApp(bundleID: String) -> (Bool, Double) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return (false, 0)
        }

        let ramBefore = getProcessRAM(pid: app.processIdentifier)
        let success = app.terminate()

        if success {
            lastActiveTime.removeValue(forKey: bundleID)
            return (true, ramBefore)
        }
        return (false, 0)
    }

    func forceQuitApp(bundleID: String) -> (Bool, Double) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return (false, 0)
        }

        let ramBefore = getProcessRAM(pid: app.processIdentifier)
        let success = app.forceTerminate()

        if success {
            lastActiveTime.removeValue(forKey: bundleID)
            return (true, ramBefore)
        }
        return (false, 0)
    }

    // MARK: - Private helpers

    private func appHasVisibleWindows(pid: pid_t) -> Bool {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return false
        }
        return !windows.isEmpty
    }

    private func getProcessRAM(pid: pid_t) -> Double {
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
                return kb / 1024.0  // Convert KB to MB
            }
        } catch {}
        return 0
    }
}
