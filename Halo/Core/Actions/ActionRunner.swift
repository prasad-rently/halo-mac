import Foundation
import AppKit

// MARK: - ActionRunner

/// Executes ActionItems asynchronously, maintains an in-session execution history,
/// and streams stdout/stderr back to the UI.
///
/// Privilege escalation: commands marked `requiresPrivilege = true` are executed via
/// `osascript do shell script … with administrator privileges`, which presents the
/// standard macOS credential dialog.
///
/// FIX: Uses `Task.detached { process.waitUntilExit() }` instead of
/// `terminationHandler` to avoid a race condition where the process can terminate
/// before the handler is assigned (causing the continuation to never resume).
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
            appendLine("Navigating to Performance → Network for live speed test…", to: execId)
            appState.selectedModule = .performance
            finish(execId, success: true, finalLine: "✓ Opened Performance → Network module.")

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

    // MARK: - Shell execution router

    private func runShell(_ command: String, requiresPrivilege: Bool, execId: UUID) async {
        if requiresPrivilege {
            await runPrivileged(command, execId: execId)
        } else {
            await runProcess(command, execId: execId)
        }
    }

    // MARK: - Unprivileged process (streams stdout live)

    private func runProcess(_ command: String, execId: UUID) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments     = ["-c", command]
        // Carry the current environment so PATH, HOME etc. are available
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        // Live-stream stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor [weak self] in
                lines.forEach { self?.appendLine($0, to: execId) }
            }
        }
        // Live-stream stderr (prefixed with ⚠)
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
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            finish(execId, success: false, finalLine: "Launch error: \(error.localizedDescription)")
            return
        }

        // Wait for completion on a background thread — does NOT block the main actor.
        // Using Task.detached + waitUntilExit() avoids the terminationHandler race
        // condition (handler set after process can already have exited).
        await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
        }.value

        // Stop streaming and drain anything still in the pipe buffer
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) {
            s.components(separatedBy: "\n")
             .filter { !$0.isEmpty }
             .forEach { appendLine($0, to: execId) }
        }
        let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !errRest.isEmpty, let s = String(data: errRest, encoding: .utf8) {
            s.components(separatedBy: "\n")
             .filter { !$0.isEmpty }
             .forEach { appendLine("⚠ \($0)", to: execId) }
        }

        let ok = process.terminationStatus == 0
        finish(execId, success: ok,
               finalLine: ok ? nil : "Process exited with code \(process.terminationStatus)")
    }

    // MARK: - Privileged process (admin auth dialog, no live streaming)

    private func runPrivileged(_ command: String, execId: UUID) async {
        appendLine("🔑 Requesting administrator privileges…", to: execId)

        // Collapse multi-line to semicolons, then escape for an AppleScript string literal
        let collapsed = command
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }  // drop blank lines and comments
            .joined(separator: "; ")

        let escaped = collapsed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments     = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do {
            try process.run()
        } catch {
            finish(execId, success: false, finalLine: "Launch error: \(error.localizedDescription)")
            return
        }

        // Same race-condition-free wait pattern
        await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
        }.value

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        if let s = String(data: outData, encoding: .utf8), !s.isEmpty {
            s.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { appendLine($0, to: execId) }
        }
        if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
            s.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { appendLine("⚠ \($0)", to: execId) }
        }

        let ok = process.terminationStatus == 0
        finish(execId, success: ok,
               finalLine: ok ? nil : "Command failed or authentication was cancelled.")
    }

    // MARK: - Execution state helpers

    private func prepend(_ exec: ActionExecution) {
        executions.insert(exec, at: 0)
        if executions.count > 50 { executions.removeLast() }
    }

    func appendLine(_ line: String, to id: UUID) {
        guard let idx = executions.firstIndex(where: { $0.id == id }) else { return }
        executions[idx].outputLines.append(line)
    }

    func finish(_ id: UUID, success: Bool, finalLine: String?) {
        guard let idx = executions.firstIndex(where: { $0.id == id }) else { return }
        if let line = finalLine { executions[idx].outputLines.append(line) }
        executions[idx].endDate  = Date()
        executions[idx].progress = success ? 1.0 : -1
        executions[idx].state    = success ? .completed : .failed(finalLine ?? "Error")
    }
}
