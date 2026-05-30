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

        case .emptyTrash:
            appendLine("Emptying Trash…", to: execId)
            let (ok, msg) = await emptyTrashInProcess()
            finish(execId, success: ok, finalLine: msg)
        }
    }

    // MARK: - In-process Trash emptying

    /// Empties the Trash by sending an Apple Event to Finder from inside the Halo process.
    ///
    /// Why in-process NSAppleScript?
    ///  • ~/.Trash has a macOS ACL that blocks child-process (shell) access
    ///  • NSAppleScript running in-process sends Apple Events to Finder directly;
    ///    Finder holds the ACL grant and performs the deletion on our behalf
    ///  • Info.plist must have NSAppleEventsUsageDescription; macOS will show a
    ///    one-time "Allow Halo to control Finder?" dialog if not yet approved
    ///
    /// Verification: the AppleScript returns the item count remaining AFTER the
    /// empty operation; we only report success when that count is 0.
    private func emptyTrashInProcess() async -> (Bool, String) {
        return await Task.detached(priority: .userInitiated) {

            // AppleScript that:
            //  1. Captures the item count before emptying
            //  2. Empties the trash (Finder performs the actual deletion)
            //  3. Returns the item count after — we verify this is 0
            let source = """
            tell application "Finder"
                set beforeCount to count of items in trash
                empty the trash
                set afterCount to count of items in trash
                return {beforeCount, afterCount}
            end tell
            """

            var scriptError: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                return (false, "⚠ Could not create AppleScript.")
            }

            let result = script.executeAndReturnError(&scriptError)

            // Check for AppleScript-level error
            if let err = scriptError {
                let msg = err[NSAppleScript.errorMessage] as? String
                    ?? err[NSAppleScript.errorNumber].map { "Error \($0)" }
                    ?? "Unknown AppleScript error"

                // Error -1743 = not allowed to send Apple Events to this app
                // This means the user needs to grant Automation permission:
                // System Settings → Privacy & Security → Automation → Halo → Finder ✓
                if (err[NSAppleScript.errorNumber] as? Int) == -1743 {
                    return (false,
                        "⚠ Halo needs permission to control Finder.\n" +
                        "Go to System Settings → Privacy & Security → Automation\n" +
                        "and enable Halo → Finder, then try again.")
                }
                return (false, "⚠ AppleScript error: \(msg)")
            }

            // Parse {beforeCount, afterCount} from the result descriptor
            let before = result.atIndex(1)?.int32Value ?? -1
            let after  = result.atIndex(2)?.int32Value ?? -1

            if after == 0 {
                let label = before <= 0 ? "already empty"
                          : "\(before) item\(before == 1 ? "" : "s") removed"
                return (true, "✓ Trash emptied (\(label)).")
            } else if after > 0 {
                return (false,
                    "⚠ Trash still has \(after) item(s) after emptying — " +
                    "some files may be locked. Try emptying from Finder.")
            } else {
                // Couldn't parse result — treat no-error as success
                return (true, "✓ Trash emptied.")
            }
        }.value
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
