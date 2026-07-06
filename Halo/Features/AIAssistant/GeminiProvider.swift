import Foundation

// MARK: - GeminiProvider  (F-046 D10 — third provider)
//
// Native URLSession client for Google's Gemini generateContent API. Same
// AIProvider surface, a third wire contract:
//   POST .../v1beta/models/{model}:streamGenerateContent?alt=sse
//   header: x-goog-api-key: <key>
//   contents: [{role:"user"|"model", parts:[{text}|{functionCall}|{functionResponse}]}]
//   systemInstruction: {parts:[{text}]}
//   tools: [{functionDeclarations:[{name,description,parameters}]}]
//   streaming SSE: candidates[].content.parts[], finishReason; stream just ends.
//
// Gemini has no tool-call id — function calls/results pair by NAME. We therefore
// set the tool-call id == function name within a Gemini run, so AgentRunner's
// id-keyed round-trip maps back to a name-keyed functionResponse.

struct GeminiProvider: AIProvider {
    let kind: AIProviderKind = .gemini
    private let keyStore: AIKeyStore
    private let session: URLSession

    init(keyStore: AIKeyStore = .shared, session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    static func endpoint(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
    }

    // MARK: Request construction (pure — unit-tested). Model goes in the URL.

    static func requestBody(system: String?, messages: [AIMessage],
                            tools: [AITool], maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "contents": contentNodes(messages),
            "generationConfig": ["maxOutputTokens": maxTokens]
        ]
        if let system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if !tools.isEmpty { body["tools"] = [["functionDeclarations": tools.map(functionDecl)]] }
        return body
    }

    static func functionDecl(_ t: AITool) -> [String: Any] {
        ["name": t.name, "description": t.description, "parameters": t.inputSchema]
    }

    static func contentNodes(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.compactMap { m in
            switch m.role {
            case .system:
                return ["role": "user", "parts": [["text": m.text]]]   // rare; systemInstruction preferred
            case .user:
                let fnResponses: [[String: Any]] = m.blocks.compactMap { b in
                    if case let .toolResult(id, content, _) = b {
                        return ["functionResponse": ["name": id, "response": ["content": content]]]
                    }
                    return nil
                }
                if !fnResponses.isEmpty { return ["role": "user", "parts": fnResponses] }
                return ["role": "user", "parts": [["text": m.text]]]
            case .assistant:
                var parts: [[String: Any]] = []
                if !m.text.isEmpty { parts.append(["text": m.text]) }
                for b in m.blocks {
                    if case let .toolUse(_, name, inputJSON) = b {
                        parts.append(["functionCall": ["name": name, "args": jsonObject(inputJSON) ?? [:]]])
                    }
                }
                return ["role": "model", "parts": parts]
            }
        }
    }

    private static func jsonObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func makeRequest(model: String, system: String?, messages: [AIMessage],
                             tools: [AITool], maxTokens: Int) throws -> URLRequest {
        guard let key = keyStore.key(for: .gemini), !key.isEmpty else {
            throw AIProviderError.missingKey(.gemini)
        }
        var req = URLRequest(url: Self.endpoint(model: model))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            system: system, messages: messages, tools: tools, maxTokens: maxTokens))
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
                    let decoder = GeminiStreamDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        for e in decoder.consume(dict) { continuation.yield(e) }
                    }
                    for e in decoder.finish() { continuation.yield(e) }   // stream just ends
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - GeminiStreamDecoder  (pure — unit-tested)
//
// candidates[0].content.parts[] carry text and/or whole functionCall objects
// (Gemini does not fragment function args across chunks). finishReason on the
// last chunk; there is no [DONE] sentinel.

final class GeminiStreamDecoder {
    private var finishReason: String?

    func consume(_ chunk: [String: Any]) -> [AIStreamEvent] {
        guard let cand = (chunk["candidates"] as? [[String: Any]])?.first else { return [] }
        if let fr = cand["finishReason"] as? String { finishReason = fr }
        guard let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return [] }

        var out: [AIStreamEvent] = []
        for p in parts {
            if let text = p["text"] as? String, !text.isEmpty { out.append(.textDelta(text)) }
            if let fc = p["functionCall"] as? [String: Any], let name = fc["name"] as? String {
                let args = fc["args"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                out.append(.toolCall(id: name, name: name, inputJSON: json))   // id == name (D10)
            }
        }
        return out
    }

    func finish() -> [AIStreamEvent] { [.done(stopReason: finishReason)] }
}
