# Halo — Feature Specifications & Execution Plans

Detailed requirements and phased execution plans for the upcoming feature set
(NFeat-122 → NFeat-127 / F-044 → F-050). Each document is **self-contained**:
it opens with a Requirements Specification and closes with an Execution Plan.

> **Status:** planning artifacts. No code is written from these yet — they exist
> to align on scope and sequencing before implementation. Where a decision was
> needed to write a coherent spec, a sensible **default** was chosen and flagged
> in that document's *Decisions & Assumptions* section; anything still genuinely
> open is listed under *Open Questions*.

## Documents

| Doc | ID | NFeat | Feature | Platform |
|-----|----|-------|---------|----------|
| [00-foundations.md](00-foundations.md) | — | — | Cross-cutting architecture (BYOB Firebase, security, mobile stack, AI) | — |
| [firebase-setup.md](firebase-setup.md) | — | — | Runtime config (no rebuild) + backend-provisioning automation feasibility | — |
| [F-044-shared-sms-console.md](F-044-shared-sms-console.md) | F-044 | 122 | Shared SMS Console | Desktop + Mobile |
| [F-045-clipboard-sync.md](F-045-clipboard-sync.md) | F-045 | 123 | Cross-Device Clipboard Sync | Desktop + Mobile |
| [F-046-ai-querying.md](F-046-ai-querying.md) | F-046 | 124 | AI Querying — Cloud Providers | Desktop |
| [F-047-on-device-ai-rag.md](F-047-on-device-ai-rag.md) | F-047 | 125 | On-Device AI & Custom RAG | Desktop |
| [F-048-expenditure-tracker.md](F-048-expenditure-tracker.md) | F-048 | 126 | Personal Expenditure Tracker | Desktop |
| [F-049-halo-mobile-app.md](F-049-halo-mobile-app.md) | F-049 | 122/123/127 | Halo Mobile App (product line) | Mobile |
| [F-050-haloshare-mobile.md](F-050-haloshare-mobile.md) | F-050 | 127 | HaloShare Mobile ↔ Desktop | Desktop + Mobile |

## Document structure (each feature)

1. **Summary** — one-paragraph intent.
2. **Goals / Non-Goals** — scope boundaries.
3. **Decisions & Assumptions** — defaults chosen to make the spec concrete.
4. **User Stories** — `US-x` who/what/why.
5. **Functional Requirements** — `FR-x`, testable.
6. **Non-Functional Requirements** — privacy, security, performance, config.
7. **Architecture & Data Model** — components, schemas, flows.
8. **Acceptance Criteria** — ship gate.
9. **Open Questions & Risks** — to resolve before/while building.
10. **Execution Plan** — phased milestones, task breakdown, effort, test plan.

## Recommended build order

```
F-044 (SMS console) ─┐
                     ├─► needs the shared Firebase/BYOB foundation (00-foundations)
F-045 (clipboard) ───┘
F-049 (mobile app) ── device-side of F-044/F-045/F-050; unblocks their mobile halves
F-050 (HaloShare mobile) ── extends existing desktop HaloShare
F-046 (AI cloud) ── independent; quick win
F-047 (on-device AI/RAG) ── independent; larger
F-048 (expenditure) ── depends on F-044 data; can reuse F-046/F-047 for parsing
```

Rationale: the Firebase foundation (00) is a prerequisite for F-044/F-045/F-049,
so it is specced once and referenced. F-046 is the smallest standalone win.
F-048 is intentionally last — it consumes F-044's data.
