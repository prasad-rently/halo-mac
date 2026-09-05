import SwiftUI
import Combine
import AppKit
import WidgetKit
import UserNotifications

// MARK: - App State (Central Store)

@MainActor
final class AppState: ObservableObject {

    /// Shared reference set by HaloApp on launch so App Intents can read live metrics.
    static var shared: AppState?

    // MARK: Navigation
    @Published var selectedModule: AppModule = .dashboard
    @Published var isOnboardingComplete: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    // MARK: Module Order (user-customisable sidebar)
    /// The display order of the 6 reorderable sidebar modules.
    /// Persisted to UserDefaults["moduleOrder"] as [String] of rawValues.
    /// Dashboard is always pinned to "Overview" and is excluded from this list.
    @Published var moduleOrder: [AppModule] = {
        if let saved = UserDefaults.standard.array(forKey: "moduleOrder") as? [String] {
            let parsed = saved.compactMap(AppModule.init(rawValue:))
            // Forward-compat: any module added in a future version that isn't in
            // the saved list is appended at the end so it always appears.
            let missing = AppModule.reorderable.filter { !parsed.contains($0) }
            return parsed + missing
        }
        return AppModule.reorderable   // default — matches current hardcoded sidebar order
    }()

    func moveModules(from source: IndexSet, to destination: Int) {
        moduleOrder.move(fromOffsets: source, toOffset: destination)
        saveModuleOrder()
    }

    func saveModuleOrder() {
        UserDefaults.standard.set(moduleOrder.map(\.rawValue), forKey: "moduleOrder")
    }

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

    // MARK: Phase 3 — Battery Deep (P3-04)
    @Published var batteryIsCharging: Bool = false
    @Published var batteryIsOnAC: Bool = false
    @Published var batteryDesignCapMAh: Int = 0
    @Published var batteryMaxCapMAh: Int = 0
    @Published var batteryAmperageMa: Int = 0
    @Published var batteryVoltageMv: Int = 0
    @Published var batteryTemperatureC: Double = 0
    @Published var batteryTimeToFull: String = ""
    @Published var batteryIsLowPower: Bool = false

    // MARK: Phase 3 — Network Intelligence (P3-05)
    @Published var isVPNActive: Bool = false

    // MARK: Time Machine Backup Health (F-022)
    @Published var timeMachineStatus: TimeMachineStatus = .notConfigured
    @Published var isCheckingTimeMachine: Bool = false
    @Published var isStartingBackup: Bool = false
    /// Why the last "Back Up Now" failed, if it did. `tmutil startbackup` needs
    /// Full Disk Access on recent macOS; the button used to fail silently.
    @Published var backupStartError: String? = nil

    // MARK: Phase 3 — Bandwidth History (P3-10)
    /// Rolling 30-sample (60 s) buffers — appended in refreshMetrics(), max 30 entries.
    /// Must be @Published so NetworkSparklineCard re-renders on every tick.
    @Published private(set) var uploadHistory:   [Double] = []
    @Published private(set) var downloadHistory: [Double] = []

    // MARK: Pro State
    @Published var isPro: Bool = false

    // MARK: Shortcut Settings  (keyCode 9 = V, modifiers 1179648 = ⌘⇧)
    @Published var shortcutKeyCode: Int = UserDefaults.standard.object(forKey: "clipboardShortcutKeyCode") as? Int ?? 9
    @Published var shortcutModifiers: Int = UserDefaults.standard.object(forKey: "clipboardShortcutModifiers") as? Int ?? 1179648

    // MARK: Private
    private var systemMonitor: SystemMonitor?
    private var metricsTimer: AnyCancellable?
    private var widgetReloadTimer: AnyCancellable?
    // F-029: separate, much-slower timer for MetricsHistory — deliberately NOT
    // hooked into the 2 s metricsTimer above (see MetricsHistory.swift).
    private var metricsHistoryTimer: AnyCancellable?
    // `.shared` (P0.3). A private instance here would have been a fourth
    // overlapping process enumeration alongside Top Processes, F-023's sampler
    // and the Focus session sampler — and would defeat the 1 s coalescing
    // window, which only collapses calls that share an instance.
    private let historyProcessMonitor = ProcessMonitor.shared
    private var clipboardMonitor: ClipboardMonitor?
    private let hotkeyManager = HotkeyManager()
    private let quickPickerController  = ClipboardQuickPickerController()
    private let actionPickerController = QuickActionPickerController()
    private let aiQuickAskController   = AIQuickAskController()
    private var wasAxTrusted = false

    // Phase 3
    private let alertManager = AlertManager.shared
    private let networkMonitor = NetworkDetailMonitor()

    // F-022
    private let timeMachineMonitor = TimeMachineMonitor()
    private var timeMachineTimer: AnyCancellable?
    // F-020: S.M.A.R.T. disk health — boot volume only, on a 5-minute cadence
    // (a `diskutil info` shell-out is cheap, but there's no reason to run it
    // on the 2 s metrics loop). Feeds the temperature sparkline history and
    // AlertManager's failing/warning rule.
    private let smartMonitor = SMARTDiskMonitor()
    private var smartMonitorTimer: AnyCancellable?

    init() {
        systemMonitor = SystemMonitor()
        startMetricsPolling()
        startWidgetReloadTimer()
        startMetricsHistoryTimer()
        loadStoredActivity()
        // Mock/sample clipboard seed data disabled — real history now comes only
        // from ClipboardMonitor picking up actual pasteboard changes.
        // loadClipboardHistory()
        startClipboardMonitoring()
        setupHotkeys()
        startNetworkMonitoring()
        startTimeMachineMonitoring()
        startSMARTMonitoring()
        AlertManager.requestPermission()
        // F-023: per-app RAM history sampling — runs continuously (not tied to
        // the Performance view's lifetime) since leak detection needs an
        // uninterrupted sample history.
        MemoryTrendTracker.shared.start()
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
        batteryIsCharging   = battery.isCharging
        batteryIsOnAC       = battery.isOnACPower
        batteryTimeRemaining = battery.timeRemainingString
        batteryHealth = battery.healthPercent
        batteryCycles = battery.cycleCount
        batteryDesignCapMAh = battery.designCapacityMAh
        batteryMaxCapMAh    = battery.maxCapacityMAh
        batteryAmperageMa   = battery.amperageMa
        batteryVoltageMv    = battery.voltageMv
        batteryTemperatureC = battery.temperatureCelsius
        batteryTimeToFull   = battery.timeToFullString
        batteryIsLowPower   = battery.isLowPowerMode
        let net = monitor.networkStats()
        networkUpMBps = net.upMBps
        networkDownMBps = net.downMBps
        // P3-10: rolling 60-second bandwidth buffer
        appendBandwidthHistory(up: net.upMBps, down: net.downMBps)
        systemHealthScore = calculateHealthScore()
        // P3-08: threshold alert evaluation (zero extra cost — just if-checks)
        alertManager.evaluate(
            cpuUsage: cpuUsage,
            ramUsage: ramUsage,
            diskFreeGB: diskFreeGB,
            batteryPercent: batteryPercent,
            isCharging: batteryIsCharging
        )
        writeWidgetData()
    }

    // MARK: - Bandwidth history (P3-10)

    private func appendBandwidthHistory(up: Double, down: Double) {
        uploadHistory.append(up)
        downloadHistory.append(down)
        if uploadHistory.count   > 30 { uploadHistory.removeFirst() }
        if downloadHistory.count > 30 { downloadHistory.removeFirst() }
    }

    // MARK: - VPN monitoring (P3-05)

    private func startNetworkMonitoring() {
        Task {
            await networkMonitor.startVPNMonitoring { [weak self] isVPN in
                Task { @MainActor in
                    self?.isVPNActive = isVPN
                }
            }
        }
    }

    // MARK: - Time Machine Backup Health (F-022)

    /// `tmutil` shell calls are tens of ms each — far too heavy for the 2 s
    /// metrics tick, and backup status doesn't change that fast anyway.
    /// Runs once at launch, then every 15 minutes, which is frequent enough
    /// for the 48 h "stale" alert to fire in a timely way without any real cost.
    private func startTimeMachineMonitoring() {
        Task { await refreshTimeMachineStatus() }
        timeMachineTimer = Timer.publish(every: 900.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refreshTimeMachineStatus() }
            }
    }

    func refreshTimeMachineStatus() async {
        isCheckingTimeMachine = true
        let status = await timeMachineMonitor.status()
        timeMachineStatus = status
        isCheckingTimeMachine = false
        alertManager.evaluateBackup(status: status)
    }

    /// "Back Up Now" — a normal, user-initiated Time Machine backup identical
    /// to the menu bar icon's own action. Re-checks status afterward so the
    /// card reflects the in-progress state without waiting for the next tick.
    func startTimeMachineBackupNow() async {
        guard !isStartingBackup else { return }
        isStartingBackup = true
        let result = await timeMachineMonitor.startBackupNow()
        if case .failed(let reason) = result {
            backupStartError = reason
        } else {
            backupStartError = nil
        }
        await refreshTimeMachineStatus()
        isStartingBackup = false
    }

    // MARK: - S.M.A.R.T. disk health monitoring (F-020)

    private func startSMARTMonitoring() {
        Task { await runSMARTCheck() }   // one check at launch
        smartMonitorTimer = Timer.publish(every: 300.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.runSMARTCheck() }
            }
    }

    private func runSMARTCheck() async {
        // Boot volume only — see SMARTTemperatureHistory's header comment for why.
        // AppState is itself @MainActor, so no extra hop is needed after the await.
        let info = await smartMonitor.scan(path: "/", id: "/")
        if let temp = info.temperatureCelsius {
            SMARTTemperatureHistory.shared.record(celsius: temp)
        }
        // `alertLevel`, not `healthLevel` — a notification has to clear a higher
        // bar than the card does. See SMARTDiskInfo.alertLevel.
        alertManager.evaluateSMART(model: info.model, healthLevel: info.alertLevel)
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

    // MARK: - Metrics History (F-029)
    //
    // Samples once/hour into MetricsHistory — powers the Dashboard's 7-day
    // health sparkline and the Weekly Digest. This is a SEPARATE, much slower
    // timer from metricsTimer (2 s) — see MetricsHistory.swift for why hooking
    // into the fast tick would be the wrong move.

    private func startMetricsHistoryTimer() {
        metricsHistoryTimer = Timer.publish(every: 3600.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.recordMetricsHistorySample() }
            }
        // Seed one sample immediately so the sparkline / digest aren't
        // completely empty right after a fresh launch.
        Task { await recordMetricsHistorySample() }
    }

    private func recordMetricsHistorySample() async {
        let topRAM = await historyProcessMonitor.topProcesses(sortBy: .ram, limit: 5)
            .filter(\.isUserApp)
            .map { ProcessRAMSample(name: $0.name, ramMB: $0.ramMB) }
        MetricsHistory.shared.record(
            healthScore: systemHealthScore,
            diskFreeGB: diskFreeGB,
            topRAMProcesses: topRAM
        )
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
        // ⌘⇧A → Quick Action Picker
        actionPickerController.onRun = { [weak self] action in
            guard let self else { return }
            ActionRunner.shared.run(action, appState: self)
        }
        hotkeyManager.onActionShortcut = { [weak self] in
            guard let self else { return }
            if self.actionPickerController.isVisible {
                self.actionPickerController.hide()
            } else {
                self.actionPickerController.show()
            }
        }
        // ⌘⇧I → AI quick-ask overlay (F-046 second surface)
        hotkeyManager.onAIShortcut = { [weak self] in
            self?.aiQuickAskController.toggle()
        }
        wasAxTrusted = AXIsProcessTrusted()
        // Restore persisted action-picker shortcut from ActionSettingsStore
        let acs = ActionSettingsStore.shared
        hotkeyManager.updateActionShortcut(
            keyCode:   UInt16(acs.shortcutKeyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(acs.shortcutModifiers))
        )
        hotkeyManager.start(keyCode: UInt16(shortcutKeyCode),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(shortcutModifiers)))
    }

    // Called from Settings when the user picks a new clipboard shortcut.
    func updateShortcut(keyCode: Int, modifiers: Int) {
        shortcutKeyCode   = keyCode
        shortcutModifiers = modifiers
        UserDefaults.standard.set(keyCode,   forKey: "clipboardShortcutKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "clipboardShortcutModifiers")
        hotkeyManager.start(keyCode: UInt16(keyCode),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    /// Called from Action Settings tab when the user records a new action-picker shortcut.
    func updateActionShortcut(keyCode: Int, modifiers: Int) {
        hotkeyManager.updateActionShortcut(
            keyCode:   UInt16(keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )
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
        guard !isSmartScanRunning else { return }
        isSmartScanRunning = true
        defer { isSmartScanRunning = false }

        let coordinator = ScanCoordinator()
        let result = await coordinator.runFullScan()

        // Populate central state so Cleanup module and Quick Actions reflect real data
        smartScanResult = result
        cleanupCategories = result.categoryResults
        totalCleanableBytes = result.totalBytes

        lastSmartScanDate = Date()
        UserDefaults.standard.set(lastSmartScanDate, forKey: "lastSmartScanDate")

        let summary: String
        if result.totalBytes > 0 {
            summary = "Smart Scan completed — \(result.totalBytesFormatted) found"
        } else {
            summary = "Smart Scan completed — your Mac looks clean"
        }

        logActivity(ActivityEvent(
            kind: .scanCompleted,
            message: summary,
            date: Date()
        ))

        // Post persistent alert so it appears in Alert History
        AlertLog.shared.append(
            title: "Smart Scan Complete",
            body: summary,
            kindRaw: "scan"
        )
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
    case actions
    case localShare
    case ports
    case ai
    case menuBarPreview

    var id: String { rawValue }

    /// The modules that appear in the "Modules" sidebar section and can be
    /// freely reordered by the user. Dashboard is always pinned to "Overview".
    static var reorderable: [AppModule] {
        [.cleanup, .protection, .performance, .applications, .files, .clipboard, .actions, .ports, .localShare, .ai]
    }

    var title: String {
        switch self {
        case .dashboard:     return "Dashboard"
        case .cleanup:       return "Cleanup"
        case .protection:    return "Protection"
        case .performance:   return "Performance"
        case .applications:  return "Applications"
        case .files:         return "Files"
        case .clipboard:     return "Clipboard"
        case .actions:       return "Actions"
        case .localShare:    return "HaloShare"
        case .ports:         return "Ports"
        case .ai:            return "AI Assistant"
        case .menuBarPreview: return "Menu Bar"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:     return "house.fill"
        case .cleanup:       return "sparkles"
        case .protection:    return "shield.fill"
        case .performance:   return "bolt.fill"
        case .applications:  return "square.stack.3d.up.fill"
        case .files:         return "folder.fill"
        case .clipboard:     return "doc.on.clipboard.fill"
        case .actions:       return "bolt.circle.fill"
        case .localShare:    return "antenna.radiowaves.left.and.right"
        case .ports:         return "network.badge.shield.half.filled"
        case .ai:            return "sparkle"
        case .menuBarPreview: return "menubar.rectangle"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .dashboard:     return [Color.haloAccent, Color.haloAccent2]
        case .cleanup:       return [Color(hex: "#1e3a5f"), Color(hex: "#1e4080")]
        case .protection:    return [Color(hex: "#1c3a2a"), Color(hex: "#1a4030")]
        case .performance:   return [Color(hex: "#3b2260"), Color(hex: "#2d1a4a")]
        case .applications:  return [Color(hex: "#2a1a3e"), Color(hex: "#1e1040")]
        case .files:         return [Color(hex: "#1a3020"), Color(hex: "#1e3828")]
        case .clipboard:     return [Color(hex: "#3a2010"), Color(hex: "#4a2a08")]
        case .actions:       return [Color(hex: "#2a1a0e"), Color(hex: "#3a1e08")]
        case .localShare:    return [Color(hex: "#0e2a3a"), Color(hex: "#1a3a4a")]
        case .ports:         return [Color(hex: "#0e3a2a"), Color(hex: "#1a4a3a")]
        case .ai:            return [Color(hex: "#3a1e5a"), Color(hex: "#221040")]
        case .menuBarPreview: return [Color(hex: "#1a2a3a"), Color(hex: "#0e1f30")]
        }
    }
}
