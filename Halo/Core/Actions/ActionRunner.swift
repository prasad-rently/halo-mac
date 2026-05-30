import Foundation
import AppKit

// MARK: - ActionRunner

/// Executes ActionItems asynchronously, maintains an in-session execution history,
/// and streams stdout/stderr back to the UI.
///
/// Privilege escalation: commands marked `requiresPrivilege = true` are executed via
/// `osascript do shell script … with administrator privileges`, which presents the
/// standard macOS credential dialog.
@MainActor
final class ActionRunner: ObservableObject {

    static let shared = ActionRunner()

    /// Ordered most-recent-first. Capped at 50 entries.
    @Published private(set) var executions: [ActionExecution] = []

    private init() {}

    // MARK: - Public

    func run(_ action: ActionItem, appState: AppState) {
        let exec = ActionExecution(
            actionId:        action.id,
            actionName:      action.name,
            actionIcon:      action.icon,
            actionIconColor: action.iconColorHex,
            startDate:       Date(),
            state:           .running
        )
        prepend(exec)
        let execId = exec.id
        ActionLibrary.shared.recordUsage(of: action)

        Task {
            switch action.command {
            case .builtIn(let b): await runBuiltIn(b, execId: execId, appState: appState)
            case .shell(let cmd): await runShell(cmd, requiresPrivilege: action.requiresPrivilege, execId: execId)
            }
        }
    }

    func clearHistory() { executions.removeAll() }

    // MARK: - Built-in dispatch

    private func runBuiltIn(_ builtin: BuiltInAction, execId: UUID, appState: AppState) async {
        switch builtin {

        case .runSmartScan:
            appendLine("Starting Smart Scan…", to: execId)
            await appState.runSmartScan()
            finish(execId, success: true, finalLine: "✓ Smart Scan complete.")

        case .runSpeedTest:
            appendLine("Navigate to Performance → Network to see live results.", to: execId)
            // Navigate to performance module
            appState.selectedModule = .performance
            finish(execId, success: true, finalLine: "✓ Opened Performance module.")

        case .clearClipboard:
            appState.clearAllClipboard()
            finish(execId, success: true, finalLine: "✓ Clipboard history cleared.")

        case .exportReport:
            appendLine("Generating PDF report…", to: execId)
            let snapshot = ReportSnapshot.capture(from: appState)
            let pdf = ReportGenerator.shared.generate(snapshot: snapshot)
            await ReportGenerator.presentSavePanel(document: pdf)
            finish(execId, success: true, finalLine: "✓ Report exported.")
        }
    }

    // MARK: - Shell execution

    private func runShell(_ command: String, requiresPrivilege: Bool, execId: UUID) async {
        if requiresPrivilege {
            await runPrivileged(command, execId: execId)
        } else {
            await runProcess(command, execId: execId)
        }
    }

    private func runProcess(_ command: String, execId: UUID) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments     = ["-c", command]
        process.environment   = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        // Stream stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor [weak self] in
                lines.forEach { self?.appendLine($0, to: execId) }
            }
        }
        // Merge stderr into same output
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor [weak self] in
                lines.forEach { self?.appendLine("⚠ \($0)", to: execId) }
            }
        }

        do {
            try process.run()
            // Await termination without blocking the main actor
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
            // Drain remaining buffered data
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) {
                s.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { appendLine($0, to: execId) }
            }
            let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !errRest.isEmpty, let s = String(data: errRest, encoding: .utf8) {
                s.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { appendLine("⚠ \($0)", to: execId) }
            }
            let ok = process.terminationStatus == 0
            finish(execId, success: ok,
                   finalLine: ok ? nil : "Exit code \(process.terminationStatus)")
        } catch {
            finish(execId, success: false, finalLine: error.localizedDescription)
        }
    }

    private func runPrivileged(_ command: String, execId: UUID) async {
        appendLine("🔑 Requesting administrator privileges…", to: execId)

        // Escape the command for embedding inside an AppleScript string literal
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "; ")   // collapse multi-line for osascript
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments     = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        do {
            try process.run()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
            let data   = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            output.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { appendLine($0, to: execId) }
            let ok = process.terminationStatus == 0
            finish(execId, success: ok,
                   finalLine: ok ? nil : "Command failed or authentication was cancelled.")
        } catch {
            finish(execId, success: false, finalLine: error.localizedDescription)
        }
    }

    // MARK: - Execution state helpers

    private func prepend(_ exec: ActionExecution) {
        executions.insert(exec, at: 0)
        if executions.count > 50 { executions.removeLast() }
    }

    private func appendLine(_ line: String, to id: UUID) {
        guard let idx = executions.firstIndex(where: { $0.id == id }) else { return }
        executions[idx].outputLines.append(line)
    }

    private func finish(_ id: UUID, success: Bool, finalLine: String?) {
        guard let idx = executions.firstIndex(where: { $0.id == id }) else { return }
        if let line = finalLine { executions[idx].outputLines.append(line) }
        executions[idx].endDate  = Date()
        executions[idx].progress = success ? 1.0 : -1
        executions[idx].state    = success ? .completed : .failed(finalLine ?? "Error")
    }
}
