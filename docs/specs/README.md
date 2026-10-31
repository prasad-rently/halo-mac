# Halo — Feature Specifications & Execution Plans

Detailed requirements and phased execution plans for the upcoming feature set
(NFeat-122 → NFeat-131 / F-044 → F-054, plus the v2.6 additions F-055 → F-058). Each document is **self-contained**:
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
| [BUILD_PLAN.md](BUILD_PLAN.md) | — | — | Cross-feature execution sequence, spikes, milestones, critical path | — |
| [F-044-shared-sms-console.md](F-044-shared-sms-console.md) | F-044 | 122 | Shared SMS Console | Desktop + Mobile |
| [F-045-clipboard-sync.md](F-045-clipboard-sync.md) | F-045 | 123 | Cross-Device Clipboard Sync | Desktop + Mobile |
| [F-046-ai-querying.md](F-046-ai-querying.md) | F-046 | 124 | AI Querying — Cloud Providers | Desktop |
| [F-047-on-device-ai-rag.md](F-047-on-device-ai-rag.md) | F-047 | 125 | On-Device AI & Custom RAG | Desktop |
| [F-048-expenditure-tracker.md](F-048-expenditure-tracker.md) | F-048 | 126 | Personal Expenditure Tracker | Desktop |
| [F-049-halo-mobile-app.md](F-049-halo-mobile-app.md) | F-049 | 122/123/127 | Halo Mobile App (product line) | Mobile |
| [F-050-haloshare-mobile.md](F-050-haloshare-mobile.md) | F-050 | 127 | HaloShare Mobile ↔ Desktop | Desktop + Mobile |
| [F-051-lucky-draw-spinner.md](F-051-lucky-draw-spinner.md) | F-051 | 128 | Lucky Draw Spinner Wheel | Desktop (mobile ✅ Port) |
| [F-052-lethe-ephemeral-chat.md](F-052-lethe-ephemeral-chat.md) | F-052 | 129 | Lethe — Anonymous Ephemeral Chat | Desktop (mobile client already exists) |
| [F-053-lucky-draw-avatars.md](F-053-lucky-draw-avatars.md) | F-053 | 130 | Lucky Draw Avatars (core merged v2.5; completion 🔧 on PR #57) | Desktop (mobile ✅ Port, P2) |
| [F-054-build-artifact-cleaner.md](F-054-build-artifact-cleaner.md) | F-054 | 131 | Build Artifact Cleaner (🔧 built on PR #59, unmerged) | Desktop (mobile ❌ Won't do) |
| [F-055-android-background-and-sharing.md](F-055-android-background-and-sharing.md) | F-055 | — | Android Background Receiving & Sharing (🔧 PR #62) | Android (iOS ❌ deferred) |
| [F-056-expenditure-on-android.md](F-056-expenditure-on-android.md) | F-056 | — | Expenditure on the Phone — F-048 mobile half (🔧 PR #58) | Android (iOS via cloud, v2.7) |
| [F-057-cloud-setup-assistant.md](F-057-cloud-setup-assistant.md) | F-057 | — | Cloud Setup Assistant (🔧 PR #63) | Desktop + Android |
| [F-058-release-engineering.md](F-058-release-engineering.md) | F-058 | — | Release Engineering — CI, DMG, APK signing (🔧 PR #56) | Repo (mobile n/a) |
| [../V2_6_PLAN.md](../V2_6_PLAN.md) | — | — | **v2.6 plan and record** — scope, H-xx hardening, decisions D-01…D-08, verification debt V-1…V-10, risks | — |
| [BUG-001-cleanup-stale-state.md](BUG-001-cleanup-stale-state.md) | BUG-001 | — | Cleanup: no rescan + stale cross-category items (🔧 fix merged v2.5, #53; hardening on #60) | Desktop |

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
F-051 (lucky draw) ── fully independent; no Firebase, no OS access — buildable at any point
```

Rationale: the Firebase foundation (00) is a prerequisite for F-044/F-045/F-049,
so it is specced once and referenced. F-046 is the smallest standalone win.
F-048 is intentionally last — it consumes F-044's data.

F-051 sits outside the Firebase wave entirely: it touches no cloud foundation and no
macOS system API, so it can be slotted in wherever a self-contained, high-delight piece
of work is wanted without blocking or being blocked by anything above.

### v2.6 build order (2026-11-01 — see [`../V2_6_PLAN.md`](../V2_6_PLAN.md))

```
#53 ─► F-054 (Build Artifact Cleaner)                      #54 ─► H-07…H-11 ─► F-053 completion
#55 ─► H-13…H-16 ─► F-055 (background/sharing) ─► F-056 (expenditure on the phone)
D-01 ─► H-12 ─► F-057 (setup assistant)          H-20a (Swift) ─► H-20b (Kotlin) ─► H-21
F-058 (release engineering): independent after the RC
```

Desktop and Android tracks touch disjoint files except `docs/*`, `CLAUDE.md` and the wire-contract fixture; docs and `CLAUDE.md` edits are kept to the end and merged serially. As of 2026-11-01 every v2.6 item is **built on an open, unmerged PR (#56–#63)** — the order above describes dependencies, not what has landed.
