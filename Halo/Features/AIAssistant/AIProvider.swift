import Foundation

// MARK: - AIProvider  (F-046 D4)
//
// Unified streaming interface over the cloud providers. Concrete impls
// (AnthropicProvider first) build the vendor request + parse the vendor stream
// into provider-agnostic `AIStreamEvent`s. The agent loop drives this and
// executes tool calls between turns.

protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }

    /// Stream a completion. `system` is the system prompt; `tools` are the
    /// exposed tool schemas (may be empty). Emits text deltas, tool calls, and a
    /// terminal `.done`/`.failed`.
    func stream(model: String,
                system: String?,
                messages: [AIMessage],
                tools: [AITool],
                maxTokens: Int) -> AsyncThrowingStream<AIStreamEvent, Error>
}

enum AIProviderError: LocalizedError {
    case missingKey(AIProviderKind)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key set for \(p.displayName). Add one in AI settings."
        case .http(let code, let body): return "Provider error \(code): \(body)"
        case .badResponse: return "Unexpected response from the provider."
        }
    }
}
