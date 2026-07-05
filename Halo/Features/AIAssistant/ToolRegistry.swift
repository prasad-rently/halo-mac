import Foundation

// MARK: - ToolRegistry  (F-046 D8/D9/D12)
//
// The tool surface exposed to the model, mapped from Halo's existing read-only
// context + safe actions (F-042 App Intents + ActionLibrary). v1 scope (D12):
// all read-only context tools (auto-run) + non-destructive acts (confirmed).
// Destructive/sudo actions are deferred to a later phase — not registered here.
//
// This type is pure: it declares the schemas + safety class. Execution is
// injected (AgentRunner's `execute` closure) so the registry stays testable and
// decoupled from AppState/@MainActor.

enum AIToolKind: Equatable, Sendable {
    case read    // auto-runs (D9) — never mutates
    case act     // requires user confirmation before running (D9/D12)
}

struct AIToolSpec: Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let kind: AIToolKind

    var requiresConfirmation: Bool { kind == .act }
    func tool() -> AITool { AITool(name: name, description: description, inputSchema: inputSchema) }
}
extension AIToolSpec: @unchecked Sendable {}   // input schema is immutable JSON

struct ToolRegistry: Sendable {
    let specs: [AIToolSpec]

    /// The v1 default registry (D12): reads + non-destructive acts.
    static let `default` = ToolRegistry(specs: [
        // Read-only context (auto-run, D9)
        .init(name: "get_health_score",
              description: "Halo's overall Mac health score, 0–100.",
              inputSchema: emptyObject, kind: .read),
        .init(name: "get_cpu_usage",
              description: "Current CPU utilisation as a percentage.",
              inputSchema: emptyObject, kind: .read),
        .init(name: "get_ram_usage",
              description: "Current memory (RAM) usage: used, total, and percentage.",
              inputSchema: emptyObject, kind: .read),
        .init(name: "get_disk_space",
              description: "Disk usage: free and total space.",
              inputSchema: emptyObject, kind: .read),
        .init(name: "get_battery",
              description: "Battery percentage, charging state, and health summary.",
              inputSchema: emptyObject, kind: .read),
        .init(name: "get_top_processes",
              description: "The most resource-intensive running processes.",
              inputSchema: ["type": "object", "properties": [
                  "sortBy": ["type": "string", "enum": ["cpu", "memory"],
                             "description": "Sort key (default cpu)."]
              ]], kind: .read),
        .init(name: "get_clipboard_history",
              description: "Recent clipboard items (text/url/code).",
              inputSchema: ["type": "object", "properties": [
                  "count": ["type": "integer", "description": "How many recent items, 1–10."]
              ]], kind: .read),
        // Safe acts (confirmed, D9/D12)
        .init(name: "run_smart_scan",
              description: "Run a Smart Scan (non-destructive analysis of cleanup/health).",
              inputSchema: emptyObject, kind: .act),
        .init(name: "export_health_report",
              description: "Generate and export a PDF health report.",
              inputSchema: emptyObject, kind: .act)
    ])

    private static let emptyObject: [String: Any] = ["type": "object", "properties": [:]]

    func spec(for name: String) -> AIToolSpec? { specs.first { $0.name == name } }
    func tools() -> [AITool] { specs.map { $0.tool() } }
    /// Names of the confirmation-gated (mutating/acting) tools.
    var actToolNames: Set<String> { Set(specs.filter { $0.kind == .act }.map(\.name)) }
}
