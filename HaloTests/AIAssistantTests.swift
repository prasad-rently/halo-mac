import Testing
import Foundation
@testable import Halo

// MARK: - AI Assistant tests  (F-046)
//
// The two pure, network-free cores: the Anthropic request builder (must NOT send
// temperature/budget_tokens — they 400 on current Claude models) and the SSE
// stream decoder (text deltas + tool-call accumulation).

@Suite("AnthropicRequestBuilder")
struct AnthropicRequestBuilderTests {

    @Test("Body carries model, max_tokens, system, messages; never temperature/top_p/budget_tokens")
    func bodyShape() {
        let msgs = [AIMessage(role: .user, text: "Why is my Mac slow?")]
        let body = AnthropicProvider.requestBody(
            model: "claude-opus-4-8", system: "You are Halo.", messages: msgs,
            tools: [], maxTokens: 1024, stream: true)

        #expect(body["model"] as? String == "claude-opus-4-8")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["system"] as? String == "You are Halo.")
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] == nil)   // removed on Opus 4.8 → would 400
        #expect(body["top_p"] == nil)
        #expect(body["thinking"] == nil)       // no budget_tokens
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "Why is my Mac slow?")
    }

    @Test("Body is valid JSON and omits an empty system + empty tools")
    func serializable() throws {
        let body = AnthropicProvider.requestBody(
            model: "claude-opus-4-8", system: "", messages: [AIMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 512, stream: false)
        #expect(body["system"] == nil)   // empty system omitted
        #expect(body["tools"] == nil)    // empty tools omitted
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(!data.isEmpty)
    }

    @Test("Tools serialize to the Anthropic tool-definition shape")
    func toolNode() {
        let tool = AITool(name: "get_cpu_usage", description: "Current CPU %",
                          inputSchema: ["type": "object", "properties": [:]])
        let body = AnthropicProvider.requestBody(
            model: "claude-opus-4-8", system: nil, messages: [AIMessage(role: .user, text: "x")],
            tools: [tool], maxTokens: 256, stream: true)
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "get_cpu_usage")
        #expect((tools?.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test("Tool-use + tool-result blocks round-trip into the content array")
    func toolBlocks() {
        let assistant = AIMessage(role: .assistant, blocks: [
            .text("Let me check."),
            .toolUse(id: "toolu_1", name: "get_cpu_usage", inputJSON: "{\"detail\":true}")
        ])
        let node = AnthropicProvider.messageNode(assistant)
        let content = node["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?[1]["type"] as? String == "tool_use")
        #expect((content?[1]["input"] as? [String: Any])?["detail"] as? Bool == true)

        let userResult = AIMessage(role: .user, blocks: [
            .toolResult(toolUseId: "toolu_1", content: "42%", isError: false)
        ])
        let rnode = AnthropicProvider.messageNode(userResult)
        let rcontent = rnode["content"] as? [[String: Any]]
        #expect(rcontent?.first?["type"] as? String == "tool_result")
        #expect(rcontent?.first?["tool_use_id"] as? String == "toolu_1")
    }
}

@Suite("AnthropicStreamDecoder")
struct AnthropicStreamDecoderTests {

    private func emit(_ decoder: AnthropicStreamDecoder, _ events: [[String: Any]]) -> [AIStreamEvent] {
        events.flatMap { decoder.consume($0) }
    }

    @Test("Text deltas stream through and message_stop yields done + stop reason")
    func textStream() {
        let d = AnthropicStreamDecoder()
        let out = emit(d, [
            ["type": "message_start"],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hello"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": ", Halo"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
            ["type": "message_stop"]
        ])
        let text = out.compactMap { if case let .textDelta(t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "Hello, Halo")
        #expect(out.last == .done(stopReason: "end_turn"))
    }

    @Test("input_json_delta fragments accumulate into one tool call on block stop")
    func toolCallStream() {
        let d = AnthropicStreamDecoder()
        let out = emit(d, [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "tool_use", "id": "toolu_9", "name": "run_smart_scan"]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "{\"deep\":"]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "true}"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
            ["type": "message_stop"]
        ])
        guard case let .toolCall(id, name, inputJSON) = out.first(where: {
            if case .toolCall = $0 { return true } else { return false }
        }) else { Issue.record("expected a tool call"); return }
        #expect(id == "toolu_9")
        #expect(name == "run_smart_scan")
        #expect(inputJSON == "{\"deep\":true}")
        #expect(out.last == .done(stopReason: "tool_use"))
    }

    @Test("An error event surfaces as .failed")
    func errorEvent() {
        let d = AnthropicStreamDecoder()
        let out = d.consume(["type": "error", "error": ["message": "overloaded"]])
        #expect(out == [.failed("overloaded")])
    }
}
