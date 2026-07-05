# Build Plan — NFeat-122 → NFeat-127 (F-044 → F-050)

Cross-feature execution sequence, dependencies, spikes, and milestones. Turns the
seven individual specs into one ordered plan. Effort figures are rough
order-of-magnitude (per-spec §10); the **spikes gate** the estimates.

---

## 1. Dependency graph

```
                 ┌─────────────────────────────┐
                 │  Halo/Core/Cloud (shared)    │  ← F-044 Phase 0/1
                 │  FirebaseRTDBClient, Crypto, │
                 │  CloudConfig, Provisioning   │
                 └───────┬───────────┬──────────┘
                         │           │
              F-044 SMS console   F-045 Clipboard
                         │
                   F-048 Expenditure (reads F-044 cache)
                         │
        ┌────────────────┴─────────────┐
   Halo Mobile app (F-049) ── device side of F-044/F-045
        └── F-050 HaloShare mobile (reuses desktop LocalShare)

   F-046 Agentic AI ── independent ── shares module + agent loop with ──▶ F-047 On-device AI
```

**Key structural fact:** F-044 Phase 0/1 produces the shared **`Halo/Core/Cloud`**
layer that F-045 and F-048 reuse. Build it once, well.

---

## 2. Spikes (do first — they gate everything)

| Spike | Question | Gates | Fallback |
|-------|----------|-------|----------|
| **S1 — Firebase on macOS** | firebase-ios-sdk RTDB + Email/Password at runtime, under sandbox/entitlements | F-044/F-045/F-048 | none — required |
| **S2 — Assisted provisioning** | OAuth scope + Google app-verification for in-app project creation | F-044 setup UX | guided wizard (still no rebuild) |
| **S3 — MLX inference** | tokens/sec, GPU control, packaging on Apple Silicon | F-047 | llama.cpp/Metal |
| **S4 — Android SMS + clipboard** | READ_SMS + SubscriptionManager lines; AccessibilityService clipboard | F-049 mobile | — (validates feasibility) |

S1+S2 unblock the whole cloud line; run them first. S3/S4 can run in parallel.

---

## 3. Milestones

### M0 — Spikes (S1, S2)  ·  ~1 wk
Go/no-go on Firebase-macOS + provisioning. Deliverable: a throwaway proof + the
runtime-config + auth path validated.

### M1 — Cloud foundation (`Halo/Core/Cloud`)  ·  F-044 Phase 0/1  ·  ~1 wk
`FirebaseRTDBClient`, `CryptoService` (Argon2id+AES-GCM), `CloudConfigStore`
(Keychain), `FirebaseProvisioningService`, Settings **Cloud** pane + QR pairing,
deployable RTDB rules. **Shared by F-044/F-045/F-048.**

### M2 — SMS Console (F-044 desktop)  ·  ~1 wk
`SMSSyncClient` + `SMSLocalCache` + `SMSConsoleView` (Device→Line→per-line thread
grouping, categorization, search). Read side; validated later by the mobile sync.

### M3 — Clipboard Sync (F-045 desktop)  ·  ~0.5–1 wk
`ClipboardSyncService` on the M1 core (publish/subscribe, echo-suppress, history-only
receive, cap eviction, per-item exclude + purge).

### M4 — Expenditure (F-048 desktop)  ·  ~1.5 wk
Pattern pack + `TransactionParser` (+ classifier, self-transfer, cross-device dedup),
`Categorizer` (§12 taxonomy), `TxnStore` over the F-044 cache, insights UI.

### M5 — AI (F-046 then F-047)  ·  ~3 wk  ·  *parallelizable with M1–M4*
F-046 agentic assistant (providers + tool-use, agent loop reusing F-042 intents +
ActionLibrary, quick-ask + module, persisted chat, read→safe-act confirmation),
then F-047 (MLX local backend + RAG) sharing the same module/loop. Gated on S3.

### M6 — Halo Mobile app (F-049)  ·  ~4 wk  ·  *starts after M1 contract is stable*
Native Android (Kotlin) + iOS (Swift, reusing `Halo/Core/Cloud`). App shell +
QR pairing → **SMS sync (Android)** validates F-044 end-to-end → clipboard → device/line
registry. Gated on S4.

### M7 — HaloShare mobile (F-050)  ·  ~2 wk  ·  within the M6 program
LocalSend v2.1 native peer, share-sheet, background (Android FG service; iOS
best-effort), interop with official LocalSend.

---

## 4. Critical path & parallelization

```
S1,S2 ─► M1 ─► M2 ─► M4                     (cloud line, sequential-ish)
             └► M3
        M6 (mobile) starts once M1 contract is frozen ─► M7
S3 ─► M5 (AI) runs fully in parallel (no cloud dependency)
```
- **Two independent tracks:** the **cloud/mobile track** (M1→M2/M3→M4, M6→M7) and the **AI track** (M5). They share no code, so they can run concurrently.
- **F-046 is the best standalone first win** (no deps) if you want early user-visible value while the cloud spikes derisk.

---

## 5. Suggested order (single-threaded)

1. **S1 + S2** (spikes) — derisk cloud.
2. **F-046** agentic AI (ship value while cloud settles; no deps) — or defer if focusing cloud.
3. **M1** cloud foundation → **F-044** → **F-045** → **F-048**.
4. **F-049** mobile (Android SMS validates F-044) → **F-050** HaloShare.
5. **F-047** on-device AI (after S3).

---

## 6. Cross-cutting gates (every cloud/mobile feature)

- **Security review** before shipping any feature touching PII/secrets (F-044/F-045/F-048/F-049).
- **Crypto parity** test vectors (Swift ↔ Kotlin) before mobile encrypts/decrypts shared data.
- **No secrets in logs/Sentry**; Keychain/Keystore for all credentials + keys.
- **Runtime config, no rebuild** honored on every platform.

---

## 7. Rough total

Cloud line (M1–M4) ~4–5 wk · AI (M5) ~3 wk (parallel) · Mobile (M6–M7) ~6 wk
(parallel after M1). **Calendar ~2–3 months** with the two tracks overlapping;
more if single-threaded. Spikes can still change these materially.

> This plan is a starting sequence, not a contract — reorder freely. The one hard
> rule: **M1 (`Halo/Core/Cloud`) before F-044/F-045/F-048**, and **S1 before M1**.
