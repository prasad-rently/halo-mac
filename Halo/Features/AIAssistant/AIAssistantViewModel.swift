import SwiftUI

// MARK: - AIAssistantViewModel  (F-046 D5/D7/D9/D11)
//
// Owns the provider + AgentRunner + executor and streams AgentEvents into the
// chat UI. The confirmation gate (D9) is driven from here: `confirm` suspends on
// a continuation while the view presents the approval sheet.

@MainActor
final class AIAssistantViewModel: ObservableObject {

    struct ChatItem: Identifiable, Equatable {
        enum Kind: Equatable { case user, assistant, tool, error }
        enum ToolStatus: Equatable { case running, done, denied, failed }
        let id = UUID()
        var kind: Kind
        var text: String
        var toolName: String? = nil
        var toolStatus: ToolStatus? = nil
    }

    struct PendingConfirm: Identifiable, Equatable {
        let id = UUID()
        let toolName: String
        let description: String
        let inputJSON: String
    }

    @Published var items: [ChatItem] = []
    @Published var input: String = ""
    @Published private(set) var isStreaming = false
    @Published var pendingConfirm: PendingConfirm?
    @Published var selectedModelID: String = AICatalog.defaultModel.id
    @Published var selectedProvider: AIProviderKind = .claude {
        didSet {
            guard selectedProvider != oldValue else { return }
            selectedModelID = AICatalog.models(for: selectedProvider).first?.id ?? selectedProvider.defaultModelID
            hasKey = AIKeyStore.shared.hasKey(for: selectedProvider)
        }
    }
    @Published private(set) var hasKey: Bool = AIKeyStore.shared.hasKey(for: .claude)

    /// Providers with a concrete implementation (D10).
    let providers = AICatalog.implementedProviders
    private var history: [AIMessage] = []
    private var runTask: Task<Void, Never>?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var currentAssistantID: UUID?

    private let systemPrompt = """
    You are Halo's built-in assistant for macOS. You can read the user's live Mac \
    context (health, CPU, RAM, disk, battery, processes, clipboard) and run safe \
    actions (Smart Scan, export health report) through tools. Prefer reading real \
    data over guessing. Be concise. Every acting tool is confirmed by the user \
    before it runs — never claim you ran an action that was declined.
    """

    var models: [AIModelInfo] { AICatalog.models(for: selectedProvider) }

    // MARK: Key management (per provider)

    func saveKey(_ key: String) {
        AIKeyStore.shared.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: selectedProvider)
        hasKey = AIKeyStore.shared.hasKey(for: selectedProvider)
    }
    func clearKey() {
        AIKeyStore.shared.clear(selectedProvider)
        hasKey = false
    }

    // MARK: Send / stream

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, hasKey else { return }
        input = ""
        items.append(ChatItem(kind: .user, text: text))
        history.append(AIMessage(role: .user, text: text))

        let assistant = ChatItem(kind: .assistant, text: "")
        currentAssistantID = assistant.id
        items.append(assistant)
        isStreaming = true

        let runner = makeRunner()
        runTask = Task { @MainActor in
            var finalText = ""
            do {
                for try await ev in runner.run(messages: history) {
                    switch ev {
                    case .textDelta(let t):
                        finalText += t
                        appendAssistant(t)
                    case .toolProposed(let name, _, let needsConfirm):
                        // A confirmation sheet (if needed) is presented by `confirm`.
                        items.append(ChatItem(kind: .tool, text: needsConfirm ? "Requested" : "Running",
                                              toolName: name, toolStatus: .running))
                    case .toolResult(let name, let output, let isError):
                        updateTool(name, status: isError ? .failed : .done, detail: output)
                    case .toolDenied(let name):
                        updateTool(name, status: .denied, detail: "Declined by you")
                    case .finished:
                        break
                    case .failed(let msg):
                        items.append(ChatItem(kind: .error, text: msg))
                    }
                }
            } catch {
                items.append(ChatItem(kind: .error, text: error.localizedDescription))
            }
            if !finalText.isEmpty { history.append(AIMessage(role: .assistant, text: finalText)) }
            // Drop an empty streaming bubble if the turn produced only tool rows/errors.
            if let id = currentAssistantID, let idx = items.firstIndex(where: { $0.id == id }),
               items[idx].text.isEmpty { items.remove(at: idx) }
            currentAssistantID = nil
            isStreaming = false
        }
    }

    func stop() {
        runTask?.cancel()
        resolveConfirm(false)
        isStreaming = false
    }

    func clearConversation() {
        stop(); items.removeAll(); history.removeAll()
    }

    // MARK: Confirmation (D9)

    func resolveConfirm(_ approved: Bool) {
        pendingConfirm = nil
        confirmContinuation?.resume(returning: approved)
        confirmContinuation = nil
    }

    private func provider(for kind: AIProviderKind) -> AIProvider {
        switch kind {
        case .openai: return OpenAIProvider()
        case .gemini: return GeminiProvider()
        case .claude: return AnthropicProvider()
        }
    }

    private func makeRunner() -> AgentRunner {
        let runner = AgentRunner(provider: provider(for: selectedProvider), registry: .default,
                                 model: selectedModelID, system: systemPrompt)
        if let executor = AIToolExecutor.live() {
            runner.execute = executor.asExecute()
        }
        runner.confirm = { [weak self] spec, inputJSON in
            await self?.requestConfirmation(spec: spec, inputJSON: inputJSON) ?? false
        }
        return runner
    }

    private func requestConfirmation(spec: AIToolSpec, inputJSON: String) async -> Bool {
        await withCheckedContinuation { cont in
            confirmContinuation = cont
            pendingConfirm = PendingConfirm(toolName: spec.name, description: spec.description,
                                            inputJSON: inputJSON)
        }
    }

    // MARK: Item mutation

    private func appendAssistant(_ delta: String) {
        guard let id = currentAssistantID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text += delta
    }
    private func updateTool(_ name: String, status: ChatItem.ToolStatus, detail: String) {
        if let idx = items.lastIndex(where: { $0.kind == .tool && $0.toolName == name && $0.toolStatus == .running }) {
            items[idx].toolStatus = status
            items[idx].text = detail
        }
    }
}
