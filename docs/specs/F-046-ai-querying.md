# F-046 — AI Querying — Cloud Providers (NFeat-124)

> **Status:** 🗓 Planned · **Platform:** Desktop
> **Depends on:** none (independent; smallest standalone win)
> **Related:** F-047 (on-device AI) — should share one "AI" surface

---

## 1. Summary

Let the user ask questions and get answers inside Halo, backed by **leading cloud
AI providers** using the user's **own API keys** (BYO key). A provider-agnostic
layer lets the user pick a provider/model; a chat/query surface (integrated with
the existing Quick-picker / Actions paradigm) returns answers.

## 2. Goals / Non-Goals

**Goals**
- Provider abstraction over ≥3 providers (Anthropic Claude, OpenAI, Google Gemini).
- BYO API keys stored in Keychain; per-provider model selection.
- Streaming responses; a clean ask/answer UI + quick-ask from the menu bar.
- Reuse of context: send selected text / clipboard as context.

**Non-Goals (v1)**
- Agentic tool-use / multi-step workflows (later).
- Managing/paying for a shared key (BYO only).
- On-device inference (that's F-047).

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Default provider: Anthropic Claude**, latest models | Plus OpenAI + Gemini. Model list per provider, user-selectable. |
| D2 | Keys in **Keychain**; never logged/committed | One key per provider. |
| D3 | **Streaming** via each SDK/REST streaming endpoint | Token-by-token UI. |
| D4 | Unified **`AIProvider` protocol** | `send(messages, model, stream) -> AsyncStream<Token>`; concrete impls per vendor. |
| D5 | Surface = **new "AI" module** + **⌘-based quick-ask** | Shares module with F-047 backend toggle. |
| D6 | Context injection from **selection/clipboard** | Opt-in per query. |

## 4. User Stories

- **US-1** As a user, I add my Claude/OpenAI/Gemini API key and pick a model.
- **US-2** As a user, I ask a question and see a streamed answer.
- **US-3** As a user, I send my current clipboard/selection as context for the question.
- **US-4** As a user, I switch providers/models without losing my conversation.
- **US-5** As a user, my keys are stored securely and never leave my machine except to the provider.

## 5. Functional Requirements

- **FR-1** Settings **AI** pane: add/remove per-provider API keys (Keychain), choose default provider + model.
- **FR-2** `AIProvider` protocol with Anthropic/OpenAI/Gemini implementations; capability metadata (models, streaming, context window).
- **FR-3** Ask surface: prompt input, streamed answer, copy/insert answer, stop generation.
- **FR-4** Quick-ask entry (menu bar and/or ⌘ shortcut, consistent with existing pickers).
- **FR-5** Optional context: attach current clipboard item or selected text.
- **FR-6** Conversation history within a session; clear/reset.
- **FR-7** Error handling: invalid key, rate limit, network, model-unavailable — friendly messages.
- **FR-8** Respect the existing analytics opt-out; **never** send prompts to Sentry.

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

> **Claude integration note:** use the latest Claude model IDs and the current
> Anthropic Messages API (streaming). Verify model IDs against the Claude API
> reference at implementation time rather than hardcoding stale names.

## 8. Acceptance Criteria

- User can configure ≥3 providers with their own keys and query each.
- Answers stream; stop/copy/insert work.
- Clipboard/selection context can be attached.
- Keys stored in Keychain; nothing sensitive logged.
- Graceful errors for bad key / rate limit / offline.

## 9. Open Questions & Risks

- Exact provider set + priority order for v1.
- Shared module vs. standalone — confirm the unified "AI" surface with F-047.
- Token/cost display fidelity across providers (differing usage fields).
- Whether to support custom/self-hosted OpenAI-compatible endpoints (gateway) in v1.
- Prompt templates / system-prompt customization scope.

## 10. Execution Plan

### Phase 1 — Provider layer
- Define `AIProvider`, `AIMessage`, `AIModel`; implement **AnthropicProvider** first (Claude, streaming), then OpenAI, Gemini.
- Keychain key storage + Settings **AI** pane (keys, default provider/model).

### Phase 2 — Query UI
- `AppModule.ai` + `AIQueryView`/`AIQueryViewModel`: prompt, streamed answer, stop/copy/insert, session history.
- Provider/model switcher.

### Phase 3 — Context & quick-ask
- Attach clipboard/selection as context.
- Quick-ask entry point (menu bar / shortcut) reusing the picker pattern.

### Phase 4 — Hardening
- Error/rate-limit handling; cost/token display; docs for obtaining keys.
- Light security pass (key handling, no prompt leakage to logs/Sentry).

### Test plan
- Unit: provider request/stream mapping (mocked), error classification, context assembly.
- Integration: live smoke test per provider with a real key (manual/gated).
- Manual: streaming, cancel, provider switch, offline/invalid-key states.

### Rough effort
Provider layer ~3 d · Query UI ~2 d · Context/quick-ask ~1.5 d · Hardening ~1.5 d. **~8 d.** (Can ship provider-by-provider.)

---

## 11. Implementation blueprint

Shared **AI module** with F-047 (backend toggle: cloud provider ↔ local model).
Details (provider list order, prompt templates) decided at build.

```
Halo/Features/AI/
├─ AIProvider.swift            protocol — stream(messages, model) -> AsyncThrowingStream<String, Error>
├─ Providers/
│  ├─ AnthropicProvider.swift  Claude (default), Messages API streaming
│  ├─ OpenAIProvider.swift
│  └─ GeminiProvider.swift
├─ AIKeyStore.swift            Keychain — per-provider API keys
├─ AIContextProvider.swift     assemble clipboard/selection as context
├─ AIViewModel.swift           @MainActor — owns request Task, appends stream, backend selector
└─ AIView.swift                prompt + streamed answer + stop/copy/insert; quick-ask entry
AppModule.ai                   new sidebar module (shared with F-047)
```
- Keys in **Keychain** (never logged/Sentry). Requests go only to the chosen provider (TLS).
- **Claude first:** verify current model IDs against the Claude API reference at build (don't hardcode stale names).
- Quick-ask entry reuses the existing picker pattern (⌘ shortcut / menu bar).
- Build order: `AIProvider` + `AnthropicProvider` → `AIView` → context + quick-ask → OpenAI/Gemini → hardening.
