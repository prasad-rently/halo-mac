import Foundation
import PDFKit

// MARK: - AIToolExecutor  (F-046 D8 — the real tool bridge)
//
// Backs `AgentRunner.execute`: turns a tool name + JSON input into a result
// string by reading live Halo metrics (via `AIMetricsSource`, which AppState
// conforms to for free) and running the two safe acts through the existing
// Smart Scan + ReportGenerator paths. Reads are pure formatting over injected
// metrics, so they're unit-testable without constructing a full AppState.

/// The live-metrics surface the read tools need. AppState satisfies it as-is.
@MainActor
protocol AIMetricsSource: AnyObject {
    var systemHealthScore: Int { get }
    var cpuUsage: Double { get }          // 0…1
    var ramUsage: Double { get }          // 0…1
    var ramUsedGB: Double { get }
    var ramTotalGB: Double { get }
    var diskFreeGB: Double { get }
    var diskTotalGB: Double { get }
    var batteryPercent: Int { get }
    var batteryIsCharging: Bool { get }
    var batteryHealth: Double { get }     // 0…1
    var batteryCycles: Int { get }
    var clipboardItems: [ClipboardItem] { get }
}

enum AIToolError: LocalizedError {
    case unknownTool(String)
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unknownTool(let n): return "Unknown tool: \(n)"
        case .unavailable(let m): return m
        }
    }
}

@MainActor
final class AIToolExecutor {
    private let metrics: AIMetricsSource
    private weak var appState: AppState?   // for the two acts (Smart Scan / report)

    init(metrics: AIMetricsSource, appState: AppState?) {
        self.metrics = metrics
        self.appState = appState
    }
    /// Convenience — bind to the running app.
    static func live() -> AIToolExecutor? {
        guard let app = AppState.shared else { return nil }
        return AIToolExecutor(metrics: app, appState: app)
    }

    /// The closure to hand to `AgentRunner.execute`.
    func asExecute() -> (String, String) async throws -> String {
        { [weak self] name, input in
            guard let self else { throw AIToolError.unavailable("Assistant is not running.") }
            return try await self.run(name, input)
        }
    }

    func run(_ name: String, _ inputJSON: String) async throws -> String {
        let input = Self.parse(inputJSON)
        switch name {
        case "get_health_score":
            return "Mac health score: \(metrics.systemHealthScore)/100."
        case "get_cpu_usage":
            return String(format: "CPU usage: %.0f%%.", metrics.cpuUsage * 100)
        case "get_ram_usage":
            return String(format: "RAM: %.0f%% used (%.1f GB of %.1f GB).",
                          metrics.ramUsage * 100, metrics.ramUsedGB, metrics.ramTotalGB)
        case "get_disk_space":
            let used = max(0, metrics.diskTotalGB - metrics.diskFreeGB)
            return String(format: "Disk: %.1f GB free of %.1f GB (%.1f GB used).",
                          metrics.diskFreeGB, metrics.diskTotalGB, used)
        case "get_battery":
            let charge = metrics.batteryIsCharging ? "charging" : "on battery"
            return String(format: "Battery: %d%%, %@. Health %.0f%%, %d cycles.",
                          metrics.batteryPercent, charge, metrics.batteryHealth * 100, metrics.batteryCycles)
        case "get_clipboard_history":
            let count = min(max((input["count"] as? Int) ?? 5, 1), 10)
            return clipboardSummary(count: count)
        case "get_top_processes":
            let sortBy = (input["sortBy"] as? String) == "memory" ? "mem" : "cpu"
            return try topProcesses(sortBy: sortBy)
        case "run_smart_scan":
            return try await runSmartScan()
        case "export_health_report":
            return try exportReport()
        default:
            throw AIToolError.unknownTool(name)
        }
    }

    // MARK: Reads

    private func clipboardSummary(count: Int) -> String {
        let items = metrics.clipboardItems.prefix(count)
        if items.isEmpty { return "Clipboard history is empty." }
        let lines = items.enumerated().map { i, item -> String in
            let preview = item.preview.replacingOccurrences(of: "\n", with: " ")
            let clipped = preview.count > 100 ? String(preview.prefix(100)) + "…" : preview
            return "\(i + 1). [\(item.kind.rawValue)] \(clipped)"
        }
        return "Recent clipboard items:\n" + lines.joined(separator: "\n")
    }

    private func topProcesses(sortBy: String) throws -> String {
        // pcpu-sorted by default; -m sorts by memory. Read-only, non-destructive.
        let flag = sortBy == "mem" ? "-m" : "-r"
        let out = try Self.shell("/bin/ps", ["-Aceo", "pid,pcpu,pmem,comm", flag])
        let rows = out.split(separator: "\n").prefix(6)   // header + top 5
        return "Top processes (by \(sortBy == "mem" ? "memory" : "CPU")):\n" + rows.joined(separator: "\n")
    }

    // MARK: Acts (confirmed upstream by AgentRunner)

    private func runSmartScan() async throws -> String {
        guard let app = appState else { throw AIToolError.unavailable("Smart Scan is unavailable.") }
        await app.runSmartScan()
        if let r = app.smartScanResult, r.totalBytes > 0 {
            return "Smart Scan complete — \(r.totalBytesFormatted) of reclaimable space found."
        }
        return "Smart Scan complete — your Mac looks clean."
    }

    private func exportReport() throws -> String {
        guard let app = appState else { throw AIToolError.unavailable("Report export is unavailable.") }
        let snapshot = ReportSnapshot.capture(from: app)
        let doc = ReportGenerator.shared.generate(snapshot: snapshot)
        ReportGenerator.presentSavePanel(document: doc)
        return "Health report generated — a save dialog was opened for the PDF."
    }

    // MARK: Helpers

    static func parse(_ json: String) -> [String: Any] {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    private static func shell(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// AppState already exposes every property AIMetricsSource requires.
extension AppState: AIMetricsSource {}
