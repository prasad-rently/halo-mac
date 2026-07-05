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

// MARK: - ToolRegistry + AgentRunner (F-046 D8/D9)

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("Read tools auto-run; act tools are confirmation-gated")
    func kinds() {
        let r = ToolRegistry.default
        #expect(r.spec(for: "get_cpu_usage")?.kind == .read)
        #expect(r.spec(for: "get_cpu_usage")?.requiresConfirmation == false)
        #expect(r.spec(for: "run_smart_scan")?.kind == .act)
        #expect(r.spec(for: "run_smart_scan")?.requiresConfirmation == true)
        #expect(r.actToolNames.contains("export_health_report"))
    }
    @Test("Every tool exports a valid Anthropic tool schema")
    func schemas() {
        let tools = ToolRegistry.default.tools()
        #expect(!tools.isEmpty)
        for t in tools {
            #expect(!t.name.isEmpty)
            #expect(t.inputSchema["type"] as? String == "object")
        }
    }
}

/// Scripted provider: returns a queued list of stream-events per `stream()` call,
/// letting us drive the agent loop deterministically without a network/key.
private final class ScriptedProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind = .claude
    private var turns: [[AIStreamEvent]]
    private(set) var callCount = 0
    init(_ turns: [[AIStreamEvent]]) { self.turns = turns }

    func stream(model: String, system: String?, messages: [AIMessage],
                tools: [AITool], maxTokens: Int) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let events = callCount < turns.count ? turns[callCount] : [.done(stopReason: "end_turn")]
        callCount += 1
        return AsyncThrowingStream { cont in
            for e in events { cont.yield(e) }
            cont.finish()
        }
    }
}

@Suite("AgentRunner")
@MainActor
struct AgentRunnerTests {

    private func collect(_ runner: AgentRunner, _ messages: [AIMessage]) async throws -> [AgentEvent] {
        var out: [AgentEvent] = []
        for try await ev in runner.run(messages: messages) { out.append(ev) }
        return out
    }

    @Test("Read tool: model calls it, loop executes + feeds back, then answers")
    func readToolRoundTrip() async throws {
        let provider = ScriptedProvider([
            // Turn 1: brief text + a read tool call.
            [.textDelta("Checking…"),
             .toolCall(id: "t1", name: "get_cpu_usage", inputJSON: "{}"),
             .done(stopReason: "tool_use")],
            // Turn 2: final answer.
            [.textDelta("Your CPU is at 42%."), .done(stopReason: "end_turn")]
        ])
        var executed: [String] = []
        let runner = AgentRunner(provider: provider,
                                 execute: { name, _ in executed.append(name); return "42%" },
                                 confirm: { _, _ in true })
        let out = try await collect(runner, [AIMessage(role: .user, text: "cpu?")])

        #expect(executed == ["get_cpu_usage"])            // auto-ran, no confirm needed
        #expect(provider.callCount == 2)                  // looped after tool result
        #expect(out.contains(.toolResult(name: "get_cpu_usage", output: "42%", isError: false)))
        let text = out.compactMap { if case let .textDelta(t) = $0 { return t } else { return nil } }.joined()
        #expect(text.contains("Your CPU is at 42%."))
        #expect(out.last == .finished(stopReason: "end_turn"))
    }

    @Test("Act tool denied: no execution, error result fed back, loop continues")
    func actToolDenied() async throws {
        let provider = ScriptedProvider([
            [.toolCall(id: "s1", name: "run_smart_scan", inputJSON: "{}"), .done(stopReason: "tool_use")],
            [.textDelta("Okay, I won't run it."), .done(stopReason: "end_turn")]
        ])
        var executed: [String] = []
        let runner = AgentRunner(provider: provider,
                                 execute: { name, _ in executed.append(name); return "scanned" },
                                 confirm: { _, _ in false })   // user declines
        let out = try await collect(runner, [AIMessage(role: .user, text: "scan")])

        #expect(executed.isEmpty)                          // act tool never ran
        #expect(out.contains(.toolDenied(name: "run_smart_scan")))
        #expect(out.last == .finished(stopReason: "end_turn"))
    }

    @Test("Act tool approved: runs after confirmation")
    func actToolApproved() async throws {
        let provider = ScriptedProvider([
            [.toolCall(id: "s1", name: "run_smart_scan", inputJSON: "{}"), .done(stopReason: "tool_use")],
            [.textDelta("Done."), .done(stopReason: "end_turn")]
        ])
        var confirmedSpec: String?
        let runner = AgentRunner(provider: provider,
                                 execute: { _, _ in "3.8 GB found" },
                                 confirm: { spec, _ in confirmedSpec = spec.name; return true })
        let out = try await collect(runner, [AIMessage(role: .user, text: "scan")])
        #expect(confirmedSpec == "run_smart_scan")
        #expect(out.contains(.toolResult(name: "run_smart_scan", output: "3.8 GB found", isError: false)))
    }

    @Test("A stream failure surfaces as .failed and stops")
    func streamFailure() async throws {
        let provider = ScriptedProvider([[.failed("overloaded")]])
        let runner = AgentRunner(provider: provider)
        let out = try await collect(runner, [AIMessage(role: .user, text: "hi")])
        #expect(out.contains(.failed("overloaded")))
    }
}
