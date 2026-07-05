# F-047 — On-Device AI & Custom RAG (NFeat-125)

> **Status:** 🗓 Planned · **Platform:** Desktop (Apple Silicon primary)
> **Depends on:** none · **Related:** F-046 (shares the "AI" surface)

---

## 1. Summary

An **on-device AI** assistant for quick local tasks — writing shell scripts,
regex, and other small snippets, plus suggesting quick responses — with a
**custom RAG** service that answers queries grounded in **user-provided context
files of any format**. The user **chooses the model** and **controls GPU/compute
usage**. Runs fully offline.

## 2. Goals / Non-Goals

**Goals**
- Local LLM inference on Apple Silicon; model download/management + picker.
- GPU/compute usage control.
- RAG over attached files (PDF, DOCX, TXT, MD, code, CSV, …) → grounded answers.
- Task helpers: generate scripts/regex/snippets; quick-reply suggestions.
- Offline-first, private (nothing leaves the device).

**Non-Goals (v1)**
- Cloud inference (that's F-046; shared UI, different backend).
- Training/fine-tuning models.
- Agentic multi-tool execution (generation only; execution stays in Actions with confirmation).

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **MLX** primary runtime (Apple Silicon) | llama.cpp/Metal as fallback/alt. Intel = degraded/CPU or unsupported (flag). |
| D2 | **Model picker + manager** | Curated list of quantized open models; download, disk usage, delete. |
| D3 | **GPU/compute control** | Expose compute setting (e.g., GPU on/off, thread/layer offload) surfaced from the runtime. |
| D4 | **Local RAG**: embeddings + local vector store | Small local embedding model; store vectors in SQLite (e.g., sqlite-vec) or on-disk index. |
| D5 | **Pluggable file parsers** | PDF (PDFKit), DOCX, TXT/MD, code, CSV; extensible per-format. |
| D6 | **Shared "AI" module** with F-046 | Backend toggle: local model ↔ cloud provider. |
| D7 | Generation-only for scripts/commands | Executing generated scripts routes through Actions with explicit confirmation (never auto-run). |

## 4. User Stories

- **US-1** As a user, I download a local model and ask it to write a zsh script / regex — offline.
- **US-2** As a user, I pick which model runs and cap GPU usage.
- **US-3** As a user, I attach files (any format) and ask questions answered from their content (RAG).
- **US-4** As a user, I get quick-reply suggestions for text I'm working with.
- **US-5** As a user, I'm assured nothing leaves my machine.
- **US-6** As a user, a generated script is shown for review and only runs if I confirm (via Actions).

## 5. Functional Requirements

**Inference**
- **FR-1** Model manager: list curated models, download with progress, show disk usage, delete.
- **FR-2** Load/unload a selected model; expose context length + capabilities.
- **FR-3** GPU/compute control (per D3) with sane defaults per machine.
- **FR-4** Streamed generation with cancel.
- **FR-5** Graceful behavior on unsupported hardware (Intel / low RAM) — clear messaging, CPU fallback if viable.

**RAG**
- **FR-6** Ingest attached files (multi-format parsers) → chunk → embed → store in local vector index.
- **FR-7** Query: retrieve top-k chunks, build grounded prompt, generate answer with citations to source chunks/files.
- **FR-8** Manage a "context set": add/remove files, re-index, clear.
- **FR-9** Show which sources informed each answer.

**Task helpers**
- **FR-10** Templates/intents for: shell script, regex, quick reply, small transforms — routed to the local model.
- **FR-11** "Send to Actions" for generated commands (with confirmation) / "Copy"/"Insert".

**Surface**
- **FR-12** Shared **AI** module with backend selector (local vs cloud F-046).

## 6. Non-Functional Requirements

- **Privacy:** 100% offline for local backend; no telemetry of prompts/files.
- **Performance:** first-token latency + tokens/sec surfaced; model load cached; RAG retrieval < ~1s for typical corpora.
- **Resource safety:** memory/GPU guards; warn before loading a model too large for RAM.
- **Hardware:** Apple Silicon primary; Intel path explicitly scoped (likely limited/unsupported).
- **Extensibility:** new file parser / new model = additive.

## 7. Architecture

```
AIView (shared w/ F-046) ─► AIViewModel ─► backend selector
                                            ├─ LocalInferenceEngine (MLX)  ← ModelManager (download/cache)
                                            └─ (cloud AIProvider — F-046)
RAG:  Files ─► Parser(per-format) ─► Chunker ─► Embedder(local) ─► VectorStore(SQLite)
      Query ─► Embed ─► retrieve top-k ─► grounded prompt ─► LocalInferenceEngine ─► answer + citations
```
- `ModelManager` (actor): downloads, disk cache, integrity, delete.
- `LocalInferenceEngine` (actor): wraps MLX; load/generate/cancel; compute settings.
- `RAGService` (actor): parsers, chunker, embedder, `VectorStore`.
- `@MainActor AIViewModel` shared with F-046.

## 8. Acceptance Criteria

- Download + run a local model on Apple Silicon; stream a generated script/regex offline.
- Model picker + GPU/compute control functional.
- Attach mixed-format files; ask a question; get a grounded answer citing sources.
- Generated commands never auto-execute (route via Actions confirmation).
- Clear, non-crashing behavior on unsupported hardware.

## 9. Open Questions & Risks

- **Runtime:** MLX vs llama.cpp/Metal vs Core ML — confirm via spike (perf, model availability, packaging size).
- Curated model list + licensing for redistribution/download links.
- Embedding model choice + vector store (sqlite-vec vs custom) + on-disk index format.
- Intel Mac support boundary (drop or CPU-only?).
- App size / first-run download UX; where models live (App Group? Application Support?).
- Sandbox (release) implications for large model files + compute.

## 10. Execution Plan

### Phase 0 — Spike (critical)
- Evaluate **MLX** (and fallback) on Apple Silicon: load a quantized model, measure tokens/sec, GPU control surface, packaging.
- Deliverable: runtime decision + `LocalInferenceEngine` skeleton.

### Phase 1 — Inference MVP
- `ModelManager` (download/cache/delete, progress, disk usage).
- `LocalInferenceEngine` (load/generate/cancel, compute settings).
- Shared **AI** module + backend selector (local); basic chat generation.

### Phase 2 — Task helpers
- Script/regex/quick-reply intents; Copy/Insert/"Send to Actions" (confirmation).

### Phase 3 — RAG
- File parsers (PDF/DOCX/TXT/MD/code/CSV), chunker, local embedder, `VectorStore`.
- Context-set management + grounded query + citations.

### Phase 4 — Hardening
- Resource guards, unsupported-hardware messaging, perf tuning, docs.

### Test plan
- Unit: chunker, parser output per format, retrieval ranking, prompt assembly, cancel.
- Perf: tokens/sec + retrieval latency benchmarks (tie into a benchmark harness).
- Manual: model download/switch, GPU control, RAG accuracy on sample corpora, Intel/low-RAM paths.

### Rough effort
Spike ~3 d · Inference MVP ~5 d · Task helpers ~2 d · RAG ~5 d · Hardening ~3 d. **~18 d** (largest of the set; phase-gated on the spike).
