import AppIntents
import Foundation

// MARK: - HaloAction Entity

struct HaloAction: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Halo Action")
    static var defaultQuery = HaloActionQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

// MARK: - HaloAction Query

struct HaloActionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HaloAction] {
        let all = await allActions()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [HaloAction] {
        await allActions()
    }

    private func allActions() async -> [HaloAction] {
        await MainActor.run {
            ActionLibrary.shared.actions.map { HaloAction(id: $0.stableKey, name: $0.name) }
        }
    }
}

// MARK: - RunAction Intent

struct RunActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Action"
    static var description = IntentDescription("Runs a Halo action by name (e.g. Flush DNS Cache, Clear Derived Data).")

    @Parameter(title: "Action")
    var action: HaloAction

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action) in Halo")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = await MainActor.run(body: { AppState.shared }) else {
            return .result(value: "Halo is not running. Please open the app first.")
        }

        let matchedAction = await MainActor.run { () -> ActionItem? in
            ActionLibrary.shared.actions.first { $0.stableKey == action.id }
        }

        guard let actionItem = matchedAction else {
            throw IntentError.actionNotFound
        }

        let output = await runAndCapture(actionItem, appState: appState)
        return .result(value: output)
    }

    private func runAndCapture(_ actionItem: ActionItem, appState: AppState) async -> String {
        await MainActor.run {
            ActionRunner.shared.run(actionItem, appState: appState)
        }

        // Wait for the execution to finish (poll the runner's execution list)
        let startTime = Date()
        let timeout: TimeInterval = 60
        while Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let finished = await MainActor.run { () -> (Bool, String?) in
                guard let exec = ActionRunner.shared.executions.first(where: { $0.actionName == actionItem.name }) else {
                    return (true, nil)
                }
                if exec.state.isFinished {
                    let output = exec.outputLines.joined(separator: "\n")
                    switch exec.state {
                    case .completed: return (true, output.isEmpty ? "Completed successfully." : output)
                    case .failed(let msg): return (true, "Failed: \(msg)")
                    default: return (true, output)
                    }
                }
                return (false, nil)
            }
            if finished.0 {
                return finished.1 ?? "Completed."
            }
        }
        return "Action timed out after 60 seconds."
    }
}
