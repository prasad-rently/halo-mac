import Foundation

// MARK: - OpenAIProvider  (F-046 D10 — second provider)
//
// Native URLSession client for the OpenAI Chat Completions API. Same
// AIProvider surface as AnthropicProvider, but a different wire contract:
//   POST https://api.openai.com/v1/chat/completions
//   headers: Authorization: Bearer <key>, Content-Type: application/json
//   tools:   {type:"function", function:{name, description, parameters}}
//   messages: system/user/assistant(+tool_calls)/tool(tool_call_id)
//   streaming SSE chunks: choices[].delta{content, tool_calls[]}, "data: [DONE]"
//
// Uses `max_completion_tokens` (the current param) and omits `temperature`
// (some current models reject non-default sampling), matching the model surface.

struct OpenAIProvider: AIProvider {
    let kind: AIProviderKind = .openai
    private let keyStore: AIKeyStore
    private let session: URLSession

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(keyStore: AIKeyStore = .shared, session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    // MARK: Request construction (pure — unit-tested)

    static func requestBody(model: String, system: String?, messages: [AIMessage],
                            tools: [AITool], maxTokens: Int, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messageNodes(system: system, messages: messages),
            "stream": stream,
            "max_completion_tokens": maxTokens
        ]
        if !tools.isEmpty { body["tools"] = tools.map(toolNode) }
        return body
    }

    static func toolNode(_ t: AITool) -> [String: Any] {
        ["type": "function",
         "function": ["name": t.name, "description": t.description, "parameters": t.inputSchema]]
    }

    /// Map Halo messages to OpenAI's role model. Tool-result blocks expand to
    /// separate `role:"tool"` messages; tool-use blocks become assistant
    /// `tool_calls`.
    static func messageNodes(system: String?, messages: [AIMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let system, !system.isEmpty { out.append(["role": "system", "content": system]) }
        for m in messages {
            switch m.role {
            case .system:
                out.append(["role": "system", "content": m.text])
            case .user:
                let toolResults: [[String: Any]] = m.blocks.compactMap { b in
                    if case let .toolResult(id, content, _) = b {
                        return ["role": "tool", "tool_call_id": id, "content": content]
                    }
                    return nil
                }
                if toolResults.isEmpty {
                    out.append(["role": "user", "content": m.text])
                } else {
                    out.append(contentsOf: toolResults)
                    if !m.text.isEmpty { out.append(["role": "user", "content": m.text]) }
                }
            case .assistant:
                var node: [String: Any] = ["role": "assistant"]
                let toolCalls: [[String: Any]] = m.blocks.compactMap { b in
                    if case let .toolUse(id, name, inputJSON) = b {
                        return ["id": id, "type": "function",
                                "function": ["name": name, "arguments": inputJSON.isEmpty ? "{}" : inputJSON]]
                    }
                    return nil
                }
                node["content"] = m.text.isEmpty ? NSNull() : m.text
                if !toolCalls.isEmpty { node["tool_calls"] = toolCalls }
                out.append(node)
            }
        }
        return out
    }

    private func makeRequest(model: String, system: String?, messages: [AIMessage],
                             tools: [AITool], maxTokens: Int) throws -> URLRequest {
        guard let key = keyStore.key(for: .openai), !key.isEmpty else {
            throw AIProviderError.missingKey(.openai)
        }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            model: model, system: system, messages: messages, tools: tools,
            maxTokens: maxTokens, stream: true))
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
                    let decoder = OpenAIStreamDecoder()
                    var finalized = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            for e in decoder.finish() { continuation.yield(e) }
                            finalized = true
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        for e in decoder.consume(dict) { continuation.yield(e) }
                    }
                    if !finalized { for e in decoder.finish() { continuation.yield(e) } }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAIStreamDecoder  (pure — unit-tested)
//
// Chat-completions deltas: text arrives on `delta.content`; tool calls arrive as
// `delta.tool_calls[]` fragments keyed by `index` (id + name on the first
// fragment, `arguments` string appended across fragments). Finalized on `[DONE]`.

final class OpenAIStreamDecoder {
    private struct Buf { var id: String; var name: String; var args: String }
    private var bufs: [Int: Buf] = [:]
    private var finishReason: String?

    /// Feed one decoded chunk; returns text-delta events (tool calls accumulate).
    func consume(_ chunk: [String: Any]) -> [AIStreamEvent] {
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
        if let fr = choice["finish_reason"] as? String { finishReason = fr }
        guard let delta = choice["delta"] as? [String: Any] else { return [] }

        var events: [AIStreamEvent] = []
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for tc in calls {
                let idx = tc["index"] as? Int ?? 0
                let fn = tc["function"] as? [String: Any]
                if bufs[idx] == nil {
                    bufs[idx] = Buf(id: tc["id"] as? String ?? "",
                                    name: fn?["name"] as? String ?? "", args: "")
                } else {
                    if let id = tc["id"] as? String, !id.isEmpty { bufs[idx]?.id = id }
                    if let name = fn?["name"] as? String, !name.isEmpty { bufs[idx]?.name = name }
                }
                if let args = fn?["arguments"] as? String { bufs[idx]?.args += args }
            }
        }
        return events
    }

    /// Emit accumulated tool calls (ordered) + the terminal `.done`.
    func finish() -> [AIStreamEvent] {
        var out: [AIStreamEvent] = bufs.keys.sorted().map { idx in
            let b = bufs[idx]!
            return .toolCall(id: b.id, name: b.name, inputJSON: b.args.isEmpty ? "{}" : b.args)
        }
        out.append(.done(stopReason: finishReason))
        return out
    }
}
