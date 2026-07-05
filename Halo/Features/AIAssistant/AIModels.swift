import Foundation

// MARK: - AI Assistant models  (F-046)
//
// Provider-agnostic value types for the agentic assistant. v1 ships the Claude
// provider (default) with OpenAI/Gemini as later concrete impls behind the same
// `AIProvider` protocol. Requests/responses are built as dynamic JSON
// (`[String: Any]`) because the raw HTTP surface is dynamic — Swift has no
// official Anthropic SDK, so we target the documented REST contract.

enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, openai, gemini
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini (Google)"
        }
    }

    /// Default model id per provider. Halo defaults to the latest Claude.
    var defaultModelID: String {
        switch self {
        case .claude: return "claude-opus-4-8"
        case .openai: return "gpt-5"
        case .gemini: return "gemini-2.5-pro"
        }
    }
}

struct AIModelInfo: Identifiable, Hashable, Sendable {
    let id: String            // the API model id
    let displayName: String
    let provider: AIProviderKind
    let supportsTools: Bool
}

/// The curated, user-selectable model catalog. Claude first (D1 default).
enum AICatalog {
    static let models: [AIModelInfo] = [
        // Anthropic — exact ids, no date suffixes (latest first).
        .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8", provider: .claude, supportsTools: true),
        .init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", provider: .claude, supportsTools: true),
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: .claude, supportsTools: true),
        // OpenAI + Gemini — wired when their providers land.
        .init(id: "gpt-5", displayName: "GPT-5", provider: .openai, supportsTools: true),
        .init(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini, supportsTools: true)
    ]

    static let defaultModel = models[0]   // claude-opus-4-8

    static func models(for provider: AIProviderKind) -> [AIModelInfo] {
        models.filter { $0.provider == provider }
    }
    static func model(id: String) -> AIModelInfo? { models.first { $0.id == id } }
}

enum AIRole: String, Codable, Sendable { case user, assistant, system }

/// A content block within a message. Mirrors the Anthropic block model so tool
/// round-trips are lossless; simpler providers use only `.text`.
enum AIContentBlock: Equatable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)   // input as raw JSON string
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct AIMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    var role: AIRole
    var blocks: [AIContentBlock]

    init(id: UUID = UUID(), role: AIRole, blocks: [AIContentBlock]) {
        self.id = id; self.role = role; self.blocks = blocks
    }
    /// Convenience for the common plain-text case.
    init(role: AIRole, text: String) { self.init(role: role, blocks: [.text(text)]) }

    /// Concatenated text of all `.text` blocks (for display).
    var text: String {
        blocks.compactMap { if case let .text(s) = $0 { return s } else { return nil } }.joined()
    }
}

/// A tool Claude may call. `inputSchema` is a JSON-Schema object as `[String: Any]`.
struct AITool: Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    // Sendable across the dynamic dict — the value is treated as immutable JSON.
    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
    /// The Anthropic tool-definition dict.
    func node() -> [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }
}

/// One event from a streamed completion.
enum AIStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(id: String, name: String, inputJSON: String)
    case done(stopReason: String?)
    case failed(String)
}

extension AITool: @unchecked Sendable {}   // dynamic JSON schema is immutable in practice
