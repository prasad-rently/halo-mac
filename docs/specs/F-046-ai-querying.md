# F-046 — AI Assistant (Agentic, Cloud Providers) (NFeat-124)

> **Status:** 🛠 Phase 0 built (backend foundation) · **Platform:** Desktop
> **Depends on:** none (independent). Reuses F-042 App Intents + Actions module as its tool registry.
> **Related:** F-047 (on-device AI) — shares the "AI" surface + agent loop
>
> **Phase 0 done (2026-07, branch `feature/f-046-ai-assistant` off `feature/upcoming-features`):**
> `Halo/Features/AIAssistant/` — `AIModels` (provider/model catalog, message + tool
> + stream-event types; Claude default), `AIKeyStore` (Keychain per-provider keys, D2),
> `AIProvider` protocol (streaming, D4), `AnthropicProvider` (native URLSession client
> for the Messages API — request builder + SSE `AnthropicStreamDecoder`). Native Swift
> against the REST contract (no official Swift SDK). Deliberately never sends
> `temperature`/`top_p`/`budget_tokens` (removed on Opus 4.8/Sonnet 5 → HTTP 400).
> Default model `claude-opus-4-8`. **7 unit tests** pass (request-body shape incl. the
> forbidden-params guard, tool round-trip, SSE text-delta + tool-call accumulation).
> **Phase 1 done (2026-07):** `ToolRegistry` (D8/D12) — 7 read tools (auto-run) +
> 2 safe acts (confirmed); exports Anthropic tool schemas. `AgentRunner` (D7/D9) —
> the agent loop: stream a turn → collect tool calls → run reads auto / gate acts
> behind `confirm` → feed `tool_result`s back → repeat to an iteration cap. Fully
> injectable (provider/executor/confirm), so it's unit-tested with a scripted
> provider: read round-trip, act approve, act **deny**, and stream-failure paths.
> **13 F-046 unit tests pass** total.
>
> **Phase 2 done (2026-07):** `AIToolExecutor` (D8) — the real tool bridge backing
> `AgentRunner.execute`. Reads (health/CPU/RAM/disk/battery/clipboard) format live
> metrics via an `AIMetricsSource` protocol that `AppState` satisfies for free;
> `get_top_processes` shells `ps`; the two acts run the existing `AppState.runSmartScan()`
> and `ReportSnapshot`/`ReportGenerator` PDF paths. Read formatters are unit-tested
> against a fake metrics source (no full AppState needed). **16 F-046 unit tests pass.**
>
> **Phase 3 done (2026-07):** `AppModule.ai` sidebar module wired (enum + ContentView
> route). `AIAssistantViewModel` (owns provider + AgentRunner + `AIToolExecutor.live()`,
> streams `AgentEvent`s into a chat, drives the D9 confirmation via a
> `CheckedContinuation`) + `AIAssistantView` (BYO-key setup, model picker, streaming
> chat with tool-activity rows, input bar, **Approve/Decline confirmation sheet**).
> App builds; 16 F-046 unit tests still pass.
>
> **Phase 4 done (2026-07):** `OpenAIProvider` (D10) — native Chat Completions client
> behind the same `AIProvider` protocol (Bearer auth, `max_completion_tokens`,
> `function`-shaped tools, tool results as `role:"tool"` messages, `[DONE]`-terminated
> SSE via `OpenAIStreamDecoder`). VM/UI are now provider-aware: a **provider picker**
> (Claude/OpenAI) with per-provider Keychain keys + model lists; the agent loop /
> executor / confirmation are provider-agnostic and reused unchanged. **20 F-046 unit
> tests pass** (added OpenAI request-mapping + SSE decode). App builds.
>
> **Phase 5 done (2026-07):** `GeminiProvider` (D10) — native `streamGenerateContent`
> client (x-goog-api-key header, `contents`/`parts` with `user`/`model` roles,
> `systemInstruction`, `functionDeclarations`, SSE with no `[DONE]`). Gemini pairs
> tool calls/results by **function name** (no id), handled by using the name as the
> tool-call id within a Gemini run. **All 3 providers now shipped** (D10 complete);
> provider picker + per-provider keys cover Claude/OpenAI/Gemini. **24 F-046 unit
> tests pass.** App builds.
>
> **Not yet built:** conversation persistence across launches (D11); the ⌘ quick-ask
> overlay (second D5 surface). ⚠️ **UI/live streaming not runtime-verified** — needs
> real provider API keys + a display; only the pure cores are unit-tested.

---

## 1. Summary

An **agentic AI assistant** inside Halo: the user asks questions in natural
language, and the assistant — backed by **leading cloud providers** (BYO key) —
can both **read Halo's live Mac context** (health, CPU/RAM, disk, battery,
processes, clipboard) and **act on the Mac through Halo's tools** (run actions,
scans, exports) via provider tool-use/function-calling. Every acting step that
mutates or executes is gated by user confirmation.

## 2. Goals / Non-Goals

**Goals**
- Provider abstraction over 3 providers (Claude default, OpenAI, Gemini), all with **tool-use**.
- BYO API keys in Keychain; per-provider model selection; streaming.
- **Agent loop:** model ↔ Halo tools (read context + run confirmed actions/scans).
- **Tool registry from existing Halo capabilities** (F-042 App Intents + `ActionLibrary`).
- Quick-ask overlay (⌘) + a sidebar AI module; **locally persisted** conversations.

**Non-Goals (v1)**
- Fully autonomous / unattended action execution (mutating tools always confirm).
- Managing/paying for a shared key (BYO only).
- On-device inference (that's F-047; shares the agent loop where the local model supports tools).

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Default provider: Anthropic Claude**, latest models | Plus OpenAI + Gemini. Model list per provider, user-selectable. |
| D2 | Keys in **Keychain**; never logged/committed | One key per provider. |
| D3 | **Streaming** via each SDK/REST streaming endpoint | Token-by-token UI. |
| D4 | Unified **`AIProvider` protocol** | `send(messages, model, stream) -> AsyncStream<Token>`; concrete impls per vendor. |
| D5 | Surface = **quick-ask overlay (⌘) + sidebar AI module** ✅ *confirmed* | Overlay matches the ⌘⇧V/⌘⇧A picker DNA; module for longer sessions. Shares module + backend toggle with F-047. |
| D6 | Context injection from **selection/clipboard + live Halo state** | Opt-in; Mac-context via read-only tools (D8). |
| D7 | **Agentic** — tool-use/function-calling ✅ *confirmed* | All 3 providers support tools. Agent loop: model requests tool → Halo runs (read auto; mutate confirmed) → result → repeat → answer. |
| D8 | **Tool registry reuses F-042 App Intents + `ActionLibrary`** ✅ *decided* | Read tools (get health/CPU/RAM/disk/battery/processes/clipboard) + act tools (run action, smart scan, export report). Build once, expose as provider tool schemas. |
| D9 | **Safety: read-only tools auto-run; mutating/executing tools require confirmation** ✅ *confirmed* | Reuse the Actions confirmation/`ActionRunner` pattern (incl. sudo auth dialog). Confirmation shows the exact tool + command before it runs. See §12. |
| D10 | **Providers: Claude + OpenAI + Gemini** ✅ *confirmed* | Each natively integrated with streaming + tool-use. |
| D11 | **Conversations persisted locally** ✅ *confirmed* | Saved sessions (like clipboard history) with clear/delete; a privacy surface to manage. |
| D12 | **v1 tool scope = read + safe acts; destructive/sudo deferred** ✅ *confirmed* | v1 tools: all read-only context + non-destructive acts (smart scan, export report, cleanup **preview**, non-sudo actions), each confirmed. Destructive/sudo actions (delete, kill, cleanup apply, sudo) are a **later phase**, not in the v1 toolset. See §12 taxonomy. |

## 4. User Stories

- **US-1** As a user, I add my Claude/OpenAI/Gemini API key and pick a model.
- **US-2** As a user, I ask a question and see a streamed answer.
- **US-3** As a user, I send my current clipboard/selection as context for the question.
- **US-4** As a user, I switch providers/models without losing my conversation.
- **US-5** As a user, my keys are stored securely and never leave my machine except to the provider.
- **US-6** As a user, I ask "why is my Mac slow?" and the assistant reads my live metrics/processes and explains with real data.
- **US-7** As a user, I say "run a smart scan and export a report" — the assistant proposes each step and runs it after I confirm.
- **US-8** As a user, my past conversations are saved so I can revisit them; I can clear them anytime.
- **US-9** As a user, the assistant can never run a destructive/sudo action in v1, and every action shows me the exact command first.

## 5. Functional Requirements

- **FR-1** Settings **AI** pane: add/remove per-provider API keys (Keychain), choose default provider + model.
- **FR-2** `AIProvider` protocol with Anthropic/OpenAI/Gemini implementations; capability metadata (models, streaming, context window).
- **FR-3** Ask surface: prompt input, streamed answer, copy/insert answer, stop generation.
- **FR-4** Quick-ask entry (menu bar and/or ⌘ shortcut, consistent with existing pickers).
- **FR-5** Optional context: attach current clipboard item or selected text.
- **FR-6** Conversation history within a session; clear/reset.
- **FR-7** Error handling: invalid key, rate limit, network, model-unavailable — friendly messages.
- **FR-8** Respect the existing analytics opt-out; **never** send prompts to Sentry.
- **FR-9** **Tool-use** in the provider layer: send tool schemas, receive tool-call turns, return tool results (Claude/OpenAI/Gemini).
- **FR-10** **AgentOrchestrator** loop: stream text + tool events until a final answer; cancel at any point (§12.1).
- **FR-11** **ToolRegistry** built from F-042 App Intents + curated `ActionLibrary`, exposing only v1-eligible tools (D8/D12).
- **FR-12** **Confirmation** for act tools via the `ActionRunner` pattern (exact command shown; Deny → "declined" result) (D9).
- **FR-13** **ChatStore**: persist conversations locally with clear/delete (D11).
- **FR-14** Tool-call **cards** in the UI (name + args + Confirm/Deny + result), inline in the stream.

## 6. Non-Functional Requirements

- **Security:** keys in Keychain; requests go only to the chosen provider over TLS; no proxying through Halo infra.
- **Privacy:** prompts/answers never logged externally; local-only history; clear disclosure of what's sent.
- **Performance:** streaming first-token latency surfaced; cancellation stops the request promptly.
- **Extensibility:** adding a provider = implementing `AIProvider`.
- **Cost transparency:** show model + approximate token usage where the API returns it.

## 7. Architecture

```
AIQueryView ─► AIQueryViewModel ─► AIProvider (protocol)
                                    ├─ AnthropicProvider  (Claude)
                                    ├─ OpenAIProvider
                                    └─ GeminiProvider
Keychain ◄─ API keys       Context: ClipboardMonitor / selection
```
- `AIProvider`: `func stream(_ messages: [AIMessage], model: AIModel) -> AsyncThrowingStream<String, Error>`.
- Concrete providers wrap each vendor's streaming REST/SDK.
- `@MainActor AIQueryViewModel` owns the request `Task`, appends streamed tokens.
- New `AppModule.ai` (shared with F-047 via a backend selector: cloud provider ↔ local model).
- **Agent layer** (`AgentOrchestrator`, `ToolRegistry`, `ToolInvoker`) sits between the ViewModel and providers — full detail in **§12**.

> **Claude integration note:** use the latest Claude model IDs and the current
> Anthropic Messages API (streaming). Verify model IDs against the Claude API
> reference at implementation time rather than hardcoding stale names.

## 8. Acceptance Criteria

- User can configure ≥3 providers with their own keys and query each.
- Answers stream; stop/copy/insert work.
- Clipboard/selection context can be attached.
- Keys stored in Keychain; nothing sensitive logged.
- Graceful errors for bad key / rate limit / offline.
- Agent answers a "why is my Mac slow?" question using real Halo read-tools.
- An act tool (e.g. Run Smart Scan) executes only after explicit confirmation; Deny is handled.
- No destructive/sudo tool is even offered to the model in v1 (D12).
- Conversations persist across launches; clear/delete works.

## 9. Open Questions & Risks

- ~~Provider set~~ → **Claude + OpenAI + Gemini** (D10); custom/self-hosted OpenAI-compatible endpoints **deferred** (F-047 covers local).
- ~~Shared module~~ → **yes**, shared AI surface + agent loop with F-047 (D5).
- Token/cost display fidelity across providers (differing usage fields).
- System-prompt / tool-description tuning for reliable tool selection across the 3 providers.
- Agent latency/cost of multi-step tool loops (each step is a round-trip) — surface + allow cancel.

## 10. Execution Plan

### Phase 1 — Provider layer (+ tool-use)
- `AIProvider`/`AIMessage`/`AIModel` with **tool schemas + tool-call turns**; AnthropicProvider first (Claude), then OpenAI, Gemini.
- Keychain keys + Settings **AI** pane.

### Phase 2 — Agent core (read-only first)
- `ToolRegistry` from F-042 intents + `ActionLibrary`; `ToolTaxonomy`; `AgentOrchestrator` loop.
- Ship **read-only tools** end-to-end (agent observes + advises).

### Phase 3 — Surfaces + persistence
- Quick-ask overlay (⌘) + sidebar AI module; tool-call cards; `ChatStore` persisted conversations.

### Phase 4 — Safe acts + confirmation
- Add **safe act** tools with the `ActionRunner` confirmation pattern (D9/D12). Destructive/sudo stay deferred.

### Phase 5 — Hardening
- Error/rate-limit; cost/token display; cross-provider tool-selection tuning; security pass (keys, no prompt leakage).

### Test plan
- Unit: provider request/stream + **tool-call** mapping (mocked), taxonomy classification, confirmation gating, ChatStore roundtrip.
- Integration: live smoke test per provider with a real key (manual/gated).
- Manual: streaming, cancel, provider switch, offline/invalid-key states.

### Rough effort
Provider layer + tool-use ~4 d · Agent loop + tool registry (reuse F-042/Actions) ~4 d · Quick-ask overlay + module + persisted chat ~3 d · Safety/confirmation + hardening ~3 d. **~14 d** (agentic ~doubles the original chat-only estimate; can ship read-only agent first, then safe acts).

---

## 11. Implementation blueprint

Shared **AI module** with F-047 (backend toggle: cloud provider ↔ local model).
Details (provider list order, prompt templates) decided at build.

```
Halo/Features/AI/
├─ AIProvider.swift            protocol — stream(messages, model, tools) -> events (text | tool_call)
├─ Providers/
│  ├─ AnthropicProvider.swift  Claude (default) — Messages API streaming + tool use
│  ├─ OpenAIProvider.swift     function calling
│  └─ GeminiProvider.swift     function calling
├─ Agent/
│  ├─ AgentOrchestrator.swift  actor — the tool-call loop (model↔tools), streaming + cancel
│  ├─ ToolRegistry.swift       maps F-042 App Intents + curated ActionLibrary → provider tool schemas
│  ├─ ToolInvoker.swift        runs a tool: read→auto; act→confirm via ActionRunner pattern (D9)
│  └─ ToolTaxonomy.swift       read | safe-act | destructive(deferred) classification (D12)
├─ AIKeyStore.swift            Keychain — per-provider API keys
├─ AIContextProvider.swift     clipboard/selection + live Halo state (via read tools)
├─ ChatStore.swift             locally persisted conversations (D11) + clear/delete
├─ AIViewModel.swift           @MainActor — owns agent Task, streams text + tool events, backend selector
├─ AIQuickAskPanel.swift       ⌘ floating overlay (ClipboardQuickPicker pattern)
└─ AIView.swift                sidebar module: chat, tool-call cards (with Confirm/Deny), history
AppModule.ai                   new sidebar module (shared with F-047)
```
- Keys in **Keychain** (never logged/Sentry). Requests go only to the chosen provider (TLS).
- **Claude first:** verify current model IDs against the Claude API reference at build (don't hardcode stale names).
- Quick-ask entry reuses the existing picker pattern (⌘ shortcut / menu bar).
- Build order: `AIProvider` + `AnthropicProvider` → `AIView` → context + quick-ask → OpenAI/Gemini → hardening.


---

## 12. Agent architecture & tool registry

### 12.1 The agent loop
```
user prompt ─► AgentOrchestrator ─► provider.stream(messages, tools)
   ├─ text delta ─────────────────► stream to UI
   └─ tool_call ─► ToolInvoker
        ├─ READ tool  → run immediately → result → back to model
        └─ ACT tool   → show confirmation card (exact tool + args) → on Confirm run → result → back to model
   (loop until the model returns a final answer)
```
- Streaming + **cancel** at any point. Tool results are appended to the conversation and the model continues.
- Local models (F-047) that support tools plug into the same loop; those that don't fall back to plain chat.

### 12.2 Tool taxonomy (D9/D12)
| Class | Runs | v1? | Examples (from F-042 intents + `ActionLibrary`) |
|-------|------|-----|--------------------------------------------------|
| **Read** | auto | ✅ | GetHealthScore, GetCPUUsage, GetBatteryHealth, GetDiskSpace, GetClipboardHistory, list processes/ports |
| **Safe act** | **confirm** | ✅ | RunSmartScan, ExportReport, cleanup **preview**, non-sudo `ActionLibrary` actions |
| **Destructive/sudo** | confirm | ⏭ deferred | delete/trash, kill process, cleanup **apply**, sudo actions — later phase |

- Classification lives in `ToolTaxonomy`; the registry only *exposes* v1-eligible tools to the model, so the agent can't even request a deferred tool in v1.

### 12.3 Reuse (D8) & safety (D9)
- **Registry = F-042 App Intents + curated `ActionLibrary`** → provider tool schemas (name, description, JSON args). One source of truth; already permission-aware.
- **Confirmation reuses the Actions pattern** (`ActionRunner`, incl. the osascript sudo auth dialog). The card shows the exact tool + resolved command; Deny returns a "user declined" result to the model.
- **No prompt/tool output to Sentry**; keys in Keychain; requests only to the chosen provider.

### 12.4 Provider tool-use notes
- Anthropic **tool use**, OpenAI **function calling**, Gemini **function calling** — the `AIProvider` protocol normalizes tool definitions + tool-call/tool-result turns across all three. Verify current model IDs + tool schemas against each provider's API at build.
