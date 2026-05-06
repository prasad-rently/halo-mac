import SwiftUI
import Combine
import AppKit
import WidgetKit

// MARK: - App State (Central Store)

@MainActor
final class AppState: ObservableObject {

    // MARK: Navigation
    @Published var selectedModule: AppModule = .dashboard
    @Published var isOnboardingComplete: Bool = CommandLine.arguments.contains("--uitesting")
        ? true
        : UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    // MARK: System Metrics (live)
    @Published var cpuUsage: Double = 0
    @Published var ramUsage: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var networkUpMBps: Double = 0
    @Published var networkDownMBps: Double = 0
    @Published var batteryPercent: Int = 0
    @Published var batteryTimeRemaining: String = ""
    @Published var batteryHealth: Double = 0
    @Published var batteryCycles: Int = 0
    @Published var systemHealthScore: Int = 0

    // MARK: Scan State
    @Published var lastSmartScanDate: Date? = UserDefaults.standard.object(forKey: "lastSmartScanDate") as? Date
    @Published var isSmartScanRunning: Bool = false
    @Published var smartScanResult: SmartScanResult?

    // MARK: Cleanup State
    @Published var cleanupCategories: [CleanupCategory] = []
    @Published var isCleanupScanning: Bool = false
    @Published var totalCleanableBytes: Int64 = 0

    // MARK: Clipboard State
    @Published var clipboardItems: [ClipboardItem] = []

    // MARK: Recent Activity
    @Published var recentActivities: [ActivityEvent] = []

    // MARK: Pro State
    @Published var isPro: Bool = false

    // MARK: Shortcut Settings  (keyCode 9 = V, modifiers 1179648 = ⌘⇧)
    @Published var shortcutKeyCode: Int = UserDefaults.standard.object(forKey: "clipboardShortcutKeyCode") as? Int ?? 9
    @Published var shortcutModifiers: Int = UserDefaults.standard.object(forKey: "clipboardShortcutModifiers") as? Int ?? 1179648

    // MARK: Private
    private var systemMonitor: SystemMonitor?
    private var metricsTimer: AnyCancellable?
    private var widgetReloadTimer: AnyCancellable?
    private var clipboardMonitor: ClipboardMonitor?
    private let hotkeyManager = HotkeyManager()
    private let quickPickerController = ClipboardQuickPickerController()
    private var wasAxTrusted = false

    init() {
        systemMonitor = SystemMonitor()
        startMetricsPolling()
        startWidgetReloadTimer()
        loadStoredActivity()
        loadClipboardHistory()
        startClipboardMonitoring()
        setupHotkeys()
    }

    // MARK: - Metrics Polling

    private func startMetricsPolling() {
        metricsTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshMetrics()
            }
        refreshMetrics()
    }

    private func refreshMetrics() {
        // Re-register global hotkey monitor the moment AX permission is granted.
        let trusted = AXIsProcessTrusted()
        if trusted && !wasAxTrusted { hotkeyManager.registerGlobalMonitor() }
        wasAxTrusted = trusted

        guard let monitor = systemMonitor else { return }
        cpuUsage = monitor.cpuUsage()
        let ram = monitor.ramStats()
        ramUsedGB = ram.usedGB
        ramTotalGB = ram.totalGB
        ramUsage = ram.totalGB > 0 ? ram.usedGB / ram.totalGB : 0
        let disk = monitor.diskStats()
        diskFreeGB = disk.freeGB
        diskTotalGB = disk.totalGB
        let battery = monitor.batteryStats()
        batteryPercent = battery.percent
        batteryTimeRemaining = battery.timeRemainingString
        batteryHealth = battery.healthPercent
        batteryCycles = battery.cycleCount
        let net = monitor.networkStats()
        networkUpMBps = net.upMBps
        networkDownMBps = net.downMBps
        systemHealthScore = calculateHealthScore()
        writeWidgetData()
    }

    private func writeWidgetData() {
        let previews = clipboardItems.prefix(5).compactMap { item -> String? in
            if case .text(let s) = item.content { return s }
            if case .code(let c, _) = item.content { return c }
            if case .url(let u) = item.content { return u.absoluteString }
            return nil
        }
        // Write fresh data every 2 s so the widget always has up-to-date values
        // when the timeline is next fetched. Do NOT call reloadAllTimelines() here —
        // macOS throttles that call aggressively; we use a dedicated 60-second timer instead.
        HaloWidgetData(cpuUsage: cpuUsage, ramUsage: ramUsage,
                       ramUsedGB: ramUsedGB, ramTotalGB: ramTotalGB,
                       networkUpMBps: networkUpMBps, networkDownMBps: networkDownMBps,
                       clipboardPreviews: Array(previews)).save()
    }

    // Reload the widget timeline every 60 seconds. macOS allows ~40-70 reloads/hour
    // per widget; 1/min keeps us well inside budget and gives near-live updates.
    private func startWidgetReloadTimer() {
        widgetReloadTimer = Timer.publish(every: 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                WidgetCenter.shared.reloadAllTimelines()
            }
        // Fire once immediately so the widget shows data right after launch.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func calculateHealthScore() -> Int {
        var score = 100
        if cpuUsage > 0.8 { score -= 15 }
        else if cpuUsage > 0.5 { score -= 7 }
        if ramUsage > 0.85 { score -= 15 }
        else if ramUsage > 0.7 { score -= 7 }
        let diskUsedRatio = diskTotalGB > 0 ? (diskTotalGB - diskFreeGB) / diskTotalGB : 0
        if diskUsedRatio > 0.9 { score -= 20 }
        else if diskUsedRatio > 0.75 { score -= 10 }
        if batteryHealth < 0.7 { score -= 10 }
        else if batteryHealth < 0.85 { score -= 5 }
        return max(0, min(100, score))
    }

    // MARK: - Activity Log

    private func loadStoredActivity() {
        // Seed with example activity if empty
        if recentActivities.isEmpty {
            recentActivities = ActivityEvent.sampleEvents
        }
    }

    func logActivity(_ event: ActivityEvent) {
        recentActivities.insert(event, at: 0)
        if recentActivities.count > 50 { recentActivities.removeLast() }
    }

    // MARK: - Clipboard

    private func loadClipboardHistory() {
        clipboardItems = ClipboardItem.sampleItems
    }

    private func startClipboardMonitoring() {
        let monitor = ClipboardMonitor { [weak self] item in
            self?.addClipboardItem(item)
        }
        clipboardMonitor = monitor
        monitor.start()
    }

    private func setupHotkeys() {
        quickPickerController.onPaste = { [weak self] item in
            self?.pasteToSystemClipboard(item)
        }
        hotkeyManager.onClipboardShortcut = { [weak self] in
            guard let self else { return }
            self.quickPickerController.show(allItems: self.clipboardItems)
        }
        wasAxTrusted = AXIsProcessTrusted()
        hotkeyManager.start(keyCode: UInt16(shortcutKeyCode),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(shortcutModifiers)))
    }

    // Called from Settings when the user picks a new shortcut.
    func updateShortcut(keyCode: Int, modifiers: Int) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        UserDefaults.standard.set(keyCode, forKey: "clipboardShortcutKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "clipboardShortcutModifiers")
        hotkeyManager.start(keyCode: UInt16(keyCode),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    func pasteToSystemClipboard(_ item: ClipboardItem) {
        clipboardMonitor?.suppressNext = true
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.content {
        case .text(let s):        pb.setString(s, forType: .string)
        case .url(let u):         pb.setString(u.absoluteString, forType: .string)
        case .code(let c, _):    pb.setString(c, forType: .string)
        case .image(let d, _):   pb.setData(d, forType: .tiff)
        case .color(let hex):    pb.setString(hex, forType: .string)
        }
    }

    func addClipboardItem(_ item: ClipboardItem) {
        clipboardItems.insert(item, at: 0)
        if clipboardItems.count > 500 { clipboardItems.removeLast() }
    }

    func deleteClipboardItem(_ item: ClipboardItem) {
        clipboardItems.removeAll { $0.id == item.id }
    }

    func clearAllClipboard() {
        clipboardItems.removeAll()
    }

    func togglePinClipboard(_ item: ClipboardItem) {
        if let idx = clipboardItems.firstIndex(where: { $0.id == item.id }) {
            clipboardItems[idx].isPinned.toggle()
        }
    }

    // MARK: - Smart Scan

    func runSmartScan() async {
        isSmartScanRunning = true
        defer { isSmartScanRunning = false }

        let coordinator = ScanCoordinator()
        let result = await coordinator.runFullScan()
        smartScanResult = result
        lastSmartScanDate = Date()
        UserDefaults.standard.set(lastSmartScanDate, forKey: "lastSmartScanDate")

        logActivity(ActivityEvent(
            kind: .scanCompleted,
            message: "Smart Scan completed — \(result.totalBytesFormatted) found",
            date: Date()
        ))
    }
}

// MARK: - App Module Enum

enum AppModule: String, CaseIterable, Identifiable {
    case dashboard
    case cleanup
    case protection
    case performance
    case applications
    case files
    case clipboard
    case menuBarPreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cleanup: return "Cleanup"
        case .protection: return "Protection"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .files: return "Files"
        case .clipboard: return "Clipboard"
        case .menuBarPreview: return "Menu Bar"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .cleanup: return "sparkles"
        case .protection: return "shield.fill"
        case .performance: return "bolt.fill"
        case .applications: return "square.stack.3d.up.fill"
        case .files: return "folder.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .menuBarPreview: return "menubar.rectangle"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .dashboard: return [Color.haloAccent, Color.haloAccent2]
        case .cleanup: return [Color(hex: "#1e3a5f"), Color(hex: "#1e4080")]
        case .protection: return [Color(hex: "#1c3a2a"), Color(hex: "#1a4030")]
        case .performance: return [Color(hex: "#3b2260"), Color(hex: "#2d1a4a")]
        case .applications: return [Color(hex: "#2a1a3e"), Color(hex: "#1e1040")]
        case .files: return [Color(hex: "#1a3020"), Color(hex: "#1e3828")]
        case .clipboard: return [Color(hex: "#3a2010"), Color(hex: "#4a2a08")]
        case .menuBarPreview: return [Color(hex: "#1a2a3a"), Color(hex: "#0e1f30")]
        }
    }
}
