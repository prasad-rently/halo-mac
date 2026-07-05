# F-045 — Cross-Device Clipboard Sync (NFeat-123)

> **Status:** 🗓 Planned · **Platform:** Desktop + Mobile
> **Depends on:** [00-foundations](00-foundations.md) (BYOB Firebase), existing Clipboard module, F-049 (mobile)
> **Supersedes:** F-013 "iCloud Clipboard Sync" (skipped) — replaced with a user-owned Firebase approach (no Pro tier, no iCloud lock-in)

---

## 1. Summary

Turn Halo's existing Clipboard module into a **common clipboard shared across the
user's devices** via their **own configurable Firebase**. Copy on any connected
device → the item is published to the user's Firebase → it becomes available in
the clipboard history on every other connected device.

## 2. Goals / Non-Goals

**Goals**
- Bi-directional sync of clipboard items across the user's devices.
- Reuse the existing `ClipboardMonitor` + history UI; add a "synced" surface.
- Configurable, user-owned Firebase (shared config with F-044).
- Strong privacy: encrypt before upload; easy per-item exclude + one-tap purge (opt-in secret filter).

**Non-Goals (v1)**
- Syncing large binary/file payloads (text/URL/code first; images optional/deferred).
- A separate backend or account system (BYOB only).
- Conflict "merging" — last-writer-wins ordering is acceptable.

## 3. Decisions & Assumptions

> **Backend aligned to F-044:** the *SMSArchiver* reference (`~/Github/SMSArchiver`)
> implements clipboard sync on **Realtime Database** + WorkManager, and F-044 is
> now RTDB. D1 uses **RTDB** for one consistent backend across cloud features.

| # | Decision | Note |
|---|----------|------|
| D1 | **Firebase Realtime Database** `clipboard/{uid}/{itemId}` ✅ *aligned w/ F-044* | `.observe` (`child_added`) pushes new items to all devices. One backend across F-044/F-045. |
| D2 | **Client-side encryption** of item content | Clipboard often holds secrets; encrypt with the shared passphrase key (per foundations). |
| D3 | **Per-device identity** (`deviceId`) | To ignore echoes of your own copy and show provenance. |
| D4 | **Cap-bounded retention, no time TTL** ✅ *confirmed* | Synced history bounded by the **500-item cap** (oldest evicted); **no time-based expiry**. Cloud mirrors the rolling window. |
| D5 | **Nothing excluded by default; opt-in filtering** ✅ *confirmed* | Everything syncs by default. The sensitive filter (concealed pasteboard type, secret-pattern regex) is **available but OFF** — user opts in. Privacy rests on E2E encryption (D2) + easy purge (D10). |
| D6 | Text/URL/code only in v1 ✅ *confirmed* | Images/files deferred (need Cloud Storage + larger encrypted blobs). |
| D7 | **Android capture = AccessibilityService** ✅ *resolved via ref* | Android 10+ blocks background `getPrimaryClip()` (returns null from a foreground service). An **AccessibilityService** retains background clipboard read; user enables it once in Settings → Accessibility. (SMSArchiver proves this; foreground-service path kept only for pre-10.) |
| D8 | **Content-hash dedup + WorkManager upload** ✅ *adopt from ref* | Skip repeat clip events via a `lastContentHash`; upload via WorkManager with network constraint + backoff (mirrors the SMS worker). Feeds echo suppression (D3). |
| D9 | **Receive = add to history, never auto-overwrite the active clipboard** ✅ *confirmed* | Remote copies land in the clipboard **history** to pick from; they do **not** replace the live paste buffer. Prevents a remote device from hijacking what you'll paste + avoids simultaneous-copy races. |
| D10 | **Easy per-item exclude + one-tap purge** ✅ *added* | Since nothing is excluded by default (D5), a "don't sync this" per item and "purge synced items" (local + cloud) must be prominent — the main privacy control. |

## 4. User Stories

- **US-1** As a user, I copy on my phone and paste on my Mac (and vice-versa).
- **US-2** As a user, synced items appear in my existing clipboard history, marked with their source device.
- **US-3** As a user, my clipboard content is encrypted in the cloud.
- **US-4** As a user, passwords/secrets are not synced (or I can exclude them).
- **US-5** As a user, I can turn sync off and purge synced items instantly.
- **US-6** As a user, a remote copy shows up in my history to pick from — it doesn't silently change what I'm about to paste.
- **US-7** As a user, I can exclude a specific item from sync, and purge all synced items in one tap.

## 5. Functional Requirements

**Desktop**
- **FR-1** On new local clipboard item (via `ClipboardMonitor`), if sync enabled and not sensitive: encrypt + publish to `clipboard/{uid}/items`.
- **FR-2** Subscribe to RTDB (`.observe`); on remote item from another `deviceId`, decrypt + insert into local **history** (deduped, 500 cap) — **never overwrite the active clipboard** (D9).
- **FR-3** Do **not** re-publish items received from the cloud (echo suppression via `deviceId`).
- **FR-4** Mark synced items in the UI with source device + timestamp.
- **FR-5** Sensitive-content filter (concealed type, secret-pattern regex) — **available but OFF by default** (D5); user opts in.
- **FR-6** Retention by **500-item cap** (oldest evicted local + cloud); **no time TTL** (D4). Plus a per-item **"don't sync this"** exclude (D10).
- **FR-7** Prominent "Disable sync" + **"Purge synced items"** (local + cloud) with confirmation — the primary privacy control (D10).

**Mobile (detailed in F-049)**
- **FR-8** Capture copy events where the platform allows (Android foreground/IME; iOS foreground/manual), encrypt + publish.
- **FR-9** Receive remote items; make them available to paste (respecting OS constraints).

**Config (both)**
- **FR-10** Shared Firebase config + passphrase (reuse F-044 setup).
- **FR-11** Toggles: enable sync, opt-in sensitive-filter rules. (No TTL; images deferred.)

## 6. Non-Functional Requirements

- **Privacy/Security:** encrypt-before-upload (D2); owner-only RTDB rules (F-044 §7.2). Nothing excluded by default (D5) — privacy leans on E2E encryption + easy per-item exclude & purge (D10). Retention bounded by the 500-item cap (D4).
- **Performance:** publish is async/non-blocking on copy; listener merges without UI jank; respects the in-memory 500-item cap.
- **Battery/network (mobile):** batched writes; sync cadence configurable.
- **Correctness:** echo suppression prevents loops; last-writer-wins ordering by server timestamp.

## 7. Architecture & Data Model

```
Device A copy ─► ClipboardMonitor ─► [sensitive? skip] ─► encrypt ─► RTDB
                                                                        │ snapshot
Device B  ◄──────── insert into history ◄─ decrypt ◄─ (deviceId != self)┘
```

**RTDB** `clipboard/{uid}/{itemId}`:
```json
{
  "uid": "…",
  "itemId": "uuid",
  "deviceId": "device-uuid",
  "deviceName": "Gokul's iPhone",
  "kind": "text|url|code",
  "contentEnc": "…",          // AES-GCM ciphertext
  "createdAt": 1720000000000,
  "schema": 1
}
```

**Desktop:** extend `ClipboardMonitor`/`ClipboardViewModel`; add `ClipboardSyncService` (actor: publish + subscribe + echo-suppress + cap-eviction; receive = history-only per D9). Reuse `FirebaseRTDBClient` from foundations.

## 8. Acceptance Criteria

- Copy on device A appears in device B's history within seconds (listener) or the polling interval.
- Cloud stores ciphertext only; sensitive filter excludes items only when the user enables it (D5).
- No echo loops; no duplicates; 500-cap eviction (local + cloud).
- Remote copies enter history only (active clipboard never auto-overwritten, D9).
- Per-item exclude works; disable+purge clears local + cloud.
- Security review passed.

## 9. Open Questions & Risks

- **iOS capture** — `UIPasteboard` has no background change events; realistic UX is foreground/manual "push clipboard". Confirm acceptable.
- **Android capture — RESOLVED (D7):** AccessibilityService (proven by SMSArchiver). Remaining risk is **Play Store policy**: accessibility services for non-accessibility use are heavily scrutinised and may block store distribution → plan for F-Droid/sideload, and a clear in-app rationale + toggle.
- Sensitive filter is **off by default** (D5) — so privacy leans on E2E encryption + purge; revisit if users want a safer default.
- Multi-device ordering + rapid-copy bursts — debounce strategy (content-hash dedup D8 helps).
- Shared passphrase across F-044/F-045 — **decided: one shared key** for all cloud features, set once via the F-044 pairing.

### Reference (SMSArchiver clipboard)
`~/Github/SMSArchiver` ships a working Android clipboard sync: `ClipboardAccessibilityService` (background reads via system-trust), `ClipboardMonitorService` (foreground fallback, returns null on 10+ — kept only for pre-10), `lastContentHash` dedup, text+image content types, and a `ClipboardUploadWorker` (WorkManager + backoff) writing to RTDB. F-045's Android half ports this directly; the desktop half is new (built on Halo's existing `ClipboardMonitor`).

## 10. Execution Plan

### Phase 0 — Shared with F-044
- Reuse the Firebase-macOS spike, `FirebaseRTDBClient`, crypto util, and Settings **Cloud** pane. No separate spike needed if F-044 Phase 0/1 done.

### Phase 1 — Desktop publish/subscribe
- `ClipboardSyncService` (actor): publish new local items (encrypt), subscribe + merge remote, echo suppression via `deviceId`.
- UI: mark synced items with source device; sync on/off in Clipboard/Settings.

### Phase 2 — Safety & lifecycle
- Sensitive-content filter (concealed type + regex rules, configurable).
- TTL config + cloud cleanup job (client-side sweep on launch/interval).
- "Purge synced items" (local + cloud).

### Phase 3 — Mobile (lands with F-049)
- Android capture strategy + publish/subscribe; iOS foreground/manual push + receive.

### Phase 4 — Hardening
- Echo/dup stress tests; burst debounce; **security review**; user setup docs.

### Test plan
- Unit: echo suppression, dedup, TTL expiry, sensitive-filter matching, encrypt/decrypt round-trip.
- Integration: 2-device round-trip with a test Firebase project.
- Manual: secret exclusion, disable+purge, rapid-copy bursts, offline/reconnect.

### Rough effort
Desktop pub/sub ~3 d · Safety/TTL ~2 d · Mobile ~3 d (within F-049) · Hardening/review ~2 d. **~10 d** (assumes F-044 foundation exists).

---

## 11. Implementation blueprint

**Reuses `Halo/Core/Cloud/*`** (FirebaseRTDBClient, CryptoService, CloudConfigStore,
provisioning) built in F-044 §13 — F-045 adds only the clipboard glue. **One shared
E2E key** (F-044 D27); **Email/Password auth**; **RTDB** backend.

### Desktop
```
Halo/Features/ClipboardSync/
├─ ClipboardSyncService.swift   actor — publish local items (encrypt) + observe remote + echo-suppress (deviceId) + TTL sweep
└─ (extends existing ClipboardMonitor / ClipboardViewModel to mark synced items + source device)
```
- Publish: on new local item (not sensitive, D5) → `CryptoService.encrypt` → RTDB `clipboard/{uid}/{itemId}`.
- Receive: `.observe(child_added)` → skip own `deviceId` (echo) → decrypt → insert into existing history (500 cap).
- Settings: reuse the F-044 **Cloud** pane (config/pairing/key already shared); add sync toggle, TTL, image toggle, sensitive rules.

### Mobile (native — Kotlin/Swift, F-049 D1)
- **Android capture = AccessibilityService** (D7) + `lastContentHash` dedup (D8) → encrypt → RTDB; receive via `.observe`.
- **iOS** = foreground/manual push + receive (platform limit).

### Build order
Cloud core (from F-044) → `ClipboardSyncService` publish/subscribe → sensitive filter + TTL → mobile capture. Security review before ship.
