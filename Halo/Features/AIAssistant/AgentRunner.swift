import Foundation

// MARK: - AgentRunner  (F-046 D7/D9 — the agent loop)
//
// Drives: model ↔ Halo tools. Streams a completion; when the model requests
// tools, runs them (reads auto; acts only after `confirm` returns true, D9),
// feeds the results back, and repeats until the model answers or the iteration
// cap is hit. Provider-agnostic and fully injectable (provider, tool executor,
// confirmation), so the loop is unit-testable without a live API key.

/// One observable step of a run, for the UI + tests.
enum AgentEvent: Equatable, Sendable {
    case textDelta(String)
    case toolProposed(name: String, inputJSON: String, requiresConfirmation: Bool)
    case toolResult(name: String, output: String, isError: Bool)
    case toolDenied(name: String)
    case finished(stopReason: String?)
    case failed(String)
}

@MainActor
final class AgentRunner {
    private let provider: AIProvider
    private let registry: ToolRegistry
    private let model: String
    private let system: String?
    private let maxTokens: Int
    private let maxIterations: Int

    /// Executes a tool call → result text. Real impl reads AppState / runs App
    /// Intents; tests inject a stub. Throwing surfaces as an `is_error` result.
    var execute: (_ name: String, _ inputJSON: String) async throws -> String
    /// Confirmation gate for `.act` tools (D9). Returns true to run.
    var confirm: (_ spec: AIToolSpec, _ inputJSON: String) async -> Bool

    init(provider: AIProvider, registry: ToolRegistry = .default,
         model: String = AICatalog.defaultModel.id, system: String? = nil,
         maxTokens: Int = 4096, maxIterations: Int = 6,
         execute: @escaping (String, String) async throws -> String = { _, _ in "" },
         confirm: @escaping (AIToolSpec, String) async -> Bool = { _, _ in true }) {
        self.provider = provider
        self.registry = registry
        self.model = model
        self.system = system
        self.maxTokens = maxTokens
        self.maxIterations = maxIterations
        self.execute = execute
        self.confirm = confirm
    }

    /// Run the loop over an existing conversation. Emits events as it goes.
    func run(messages: [AIMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var convo = messages
                do {
                    for _ in 0..<maxIterations {
                        // 1. Stream one model turn, collecting text + tool calls.
                        var assistantText = ""
                        var toolCalls: [(id: String, name: String, input: String)] = []
                        var stopReason: String?
                        var failed: String?

                        let tools = registry.tools()
                        for try await ev in provider.stream(model: model, system: system,
                                                            messages: convo, tools: tools,
                                                            maxTokens: maxTokens) {
                            switch ev {
                            case .textDelta(let t):
                                assistantText += t
                                continuation.yield(.textDelta(t))
                            case .toolCall(let id, let name, let input):
                                toolCalls.append((id, name, input))
                            case .done(let reason):
                                stopReason = reason
                            case .failed(let msg):
                                failed = msg
                            }
                        }
                        if let failed {
                            continuation.yield(.failed(failed))
                            continuation.finish(); return
                        }

                        // 2. Record the assistant turn (text + tool_use blocks).
                        var blocks: [AIContentBlock] = []
                        if !assistantText.isEmpty { blocks.append(.text(assistantText)) }
                        for c in toolCalls { blocks.append(.toolUse(id: c.id, name: c.name, inputJSON: c.input)) }
                        if !blocks.isEmpty { convo.append(AIMessage(role: .assistant, blocks: blocks)) }

                        // 3. No tools → we're done.
                        if toolCalls.isEmpty {
                            continuation.yield(.finished(stopReason: stopReason))
                            continuation.finish(); return
                        }

                        // 4. Execute each tool (reads auto; acts confirmed), collect results.
                        var resultBlocks: [AIContentBlock] = []
                        for c in toolCalls {
                            let spec = registry.spec(for: c.name)
                            let needsConfirm = spec?.requiresConfirmation ?? true   // unknown → confirm
                            continuation.yield(.toolProposed(name: c.name, inputJSON: c.input,
                                                             requiresConfirmation: needsConfirm))
                            if needsConfirm, let spec, !(await confirm(spec, c.input)) {
                                continuation.yield(.toolDenied(name: c.name))
                                resultBlocks.append(.toolResult(toolUseId: c.id,
                                    content: "User declined to run this action.", isError: true))
                                continue
                            }
                            do {
                                let output = try await execute(c.name, c.input)
                                continuation.yield(.toolResult(name: c.name, output: output, isError: false))
                                resultBlocks.append(.toolResult(toolUseId: c.id, content: output, isError: false))
                            } catch {
                                let msg = error.localizedDescription
                                continuation.yield(.toolResult(name: c.name, output: msg, isError: true))
                                resultBlocks.append(.toolResult(toolUseId: c.id, content: msg, isError: true))
                            }
                        }
                        // 5. Feed results back as a user turn and loop.
                        convo.append(AIMessage(role: .user, blocks: resultBlocks))
                    }
                    // Iteration cap reached.
                    continuation.yield(.finished(stopReason: "max_iterations"))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
