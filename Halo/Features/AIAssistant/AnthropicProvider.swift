import Foundation

// MARK: - AnthropicProvider  (F-046 — Claude, default provider)
//
// Native URLSession client for the Anthropic Messages API (there is no official
// Swift SDK, so we target the documented REST contract):
//   POST https://api.anthropic.com/v1/messages
//   headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//   streaming SSE: message_start / content_block_start / content_block_delta
//                  (text_delta | input_json_delta) / content_block_stop /
//                  message_delta (stop_reason) / message_stop
//
// IMPORTANT (Opus 4.8 / Sonnet 5 / 4.7): temperature/top_p/top_k and
// thinking.budget_tokens are REMOVED — sending any of them returns HTTP 400. The
// request builder deliberately never sets them.

struct AnthropicProvider: AIProvider {
    let kind: AIProviderKind = .claude
    private let keyStore: AIKeyStore
    private let session: URLSession

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    init(keyStore: AIKeyStore = .shared, session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    // MARK: Request construction (pure — unit-tested)

    /// The JSON request body. `stream` is set by the caller. Never includes
    /// temperature/top_p/top_k/budget_tokens (400 on current Claude models).
    static func requestBody(model: String, system: String?, messages: [AIMessage],
                            tools: [AITool], maxTokens: Int, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.map(messageNode),
            "stream": stream
        ]
        if let system, !system.isEmpty { body["system"] = system }
        if !tools.isEmpty { body["tools"] = tools.map { $0.node() } }
        return body
    }

    /// One Anthropic message dict from an `AIMessage`.
    static func messageNode(_ m: AIMessage) -> [String: Any] {
        // Plain-text messages can use the string-content shorthand.
        if m.blocks.count == 1, case let .text(s) = m.blocks[0] {
            return ["role": m.role.rawValue, "content": s]
        }
        let content: [[String: Any]] = m.blocks.map { block in
            switch block {
            case .text(let s):
                return ["type": "text", "text": s]
            case .toolUse(let id, let name, let inputJSON):
                return ["type": "tool_use", "id": id, "name": name,
                        "input": (jsonObject(inputJSON) ?? [:])]
            case .toolResult(let toolUseId, let content, let isError):
                return ["type": "tool_result", "tool_use_id": toolUseId,
                        "content": content, "is_error": isError]
            }
        }
        return ["role": m.role.rawValue, "content": content]
    }

    private static func jsonObject(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    private func makeRequest(model: String, system: String?, messages: [AIMessage],
                             tools: [AITool], maxTokens: Int) throws -> URLRequest {
        guard let key = keyStore.key(for: .claude), !key.isEmpty else {
            throw AIProviderError.missingKey(.claude)
        }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let body = Self.requestBody(model: model, system: system, messages: messages,
                                    tools: tools, maxTokens: maxTokens, stream: true)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: Streaming

    func stream(model: String, system: String?, messages: [AIMessage],
                tools: [AITool], maxTokens: Int) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try makeRequest(model: model, system: system, messages: messages,
                                              tools: tools, maxTokens: maxTokens)
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        continuation.finish(throwing: AIProviderError.http(http.statusCode, body))
                        return
                    }
                    let decoder = AnthropicStreamDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let data = json.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        for event in decoder.consume(dict) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - AnthropicStreamDecoder  (pure SSE-event → AIStreamEvent, unit-tested)
//
// Stateful because tool-call inputs arrive as `input_json_delta` fragments that
// must be accumulated per content-block index and finalized on block stop.

final class AnthropicStreamDecoder {
    private struct ToolBuf { let id: String; let name: String; var input: String }
    private var tools: [Int: ToolBuf] = [:]     // by content-block index
    private var stopReason: String?

    /// Feed one decoded SSE `data:` object; returns any resulting events.
    func consume(_ e: [String: Any]) -> [AIStreamEvent] {
        switch e["type"] as? String {
        case "content_block_start":
            if let block = e["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let idx = e["index"] as? Int,
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                tools[idx] = ToolBuf(id: id, name: name, input: "")
            }
            return []

        case "content_block_delta":
            guard let delta = e["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let t = delta["text"] as? String { return [.textDelta(t)] }
            case "input_json_delta":
                if let idx = e["index"] as? Int, let partial = delta["partial_json"] as? String {
                    tools[idx]?.input += partial
                }
            default: break
            }
            return []

        case "content_block_stop":
            if let idx = e["index"] as? Int, let buf = tools.removeValue(forKey: idx) {
                return [.toolCall(id: buf.id, name: buf.name,
                                  inputJSON: buf.input.isEmpty ? "{}" : buf.input)]
            }
            return []

        case "message_delta":
            if let delta = e["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String { stopReason = reason }
            return []

        case "message_stop":
            return [.done(stopReason: stopReason)]

        case "error":
            let msg = (e["error"] as? [String: Any])?["message"] as? String ?? "stream error"
            return [.failed(msg)]

        default:
            return []
        }
    }
}
