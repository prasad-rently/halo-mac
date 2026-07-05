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
- Strong privacy: encrypt before upload; sensible exclusion of secrets.

**Non-Goals (v1)**
- Syncing large binary/file payloads (text/URL/code first; images optional/deferred).
- A separate backend or account system (BYOB only).
- Conflict "merging" — last-writer-wins ordering is acceptable.

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Cloud Firestore** `clipboard/{uid}/items/{itemId}` | Snapshot listeners push new items to all devices. |
| D2 | **Client-side encryption** of item content | Clipboard often holds secrets; encrypt with the shared passphrase key (per foundations). |
| D3 | **Per-device identity** (`deviceId`) | To ignore echoes of your own copy and show provenance. |
| D4 | **Capped, TTL'd** synced history | Mirror the 500-item cap; add a TTL (e.g., 24 h/7 d, configurable) to limit exposure. |
| D5 | **Sensitive-content guard** | Skip items flagged sensitive (concealed pasteboard type, password-manager hints, matches for tokens) — configurable. |
| D6 | Text/URL/code first | Images/files behind a toggle later (Cloud Storage). |

## 4. User Stories

- **US-1** As a user, I copy on my phone and paste on my Mac (and vice-versa).
- **US-2** As a user, synced items appear in my existing clipboard history, marked with their source device.
- **US-3** As a user, my clipboard content is encrypted in the cloud.
- **US-4** As a user, passwords/secrets are not synced (or I can exclude them).
- **US-5** As a user, I can turn sync off and purge synced items instantly.
- **US-6** As a user, old synced items auto-expire after my chosen TTL.

## 5. Functional Requirements

**Desktop**
- **FR-1** On new local clipboard item (via `ClipboardMonitor`), if sync enabled and not sensitive: encrypt + publish to `clipboard/{uid}/items`.
- **FR-2** Subscribe to Firestore; on remote item from another `deviceId`, decrypt + insert into local history (deduped, respecting the 500 cap).
- **FR-3** Do **not** re-publish items received from the cloud (echo suppression via `deviceId`).
- **FR-4** Mark synced items in the UI with source device + timestamp.
- **FR-5** Sensitive-content filter (concealed type, regex for secrets) — configurable allow/deny.
- **FR-6** TTL cleanup: purge cloud items older than the configured TTL.
- **FR-7** "Disable sync" + "Purge synced items" (local + cloud) with confirmation.

**Mobile (detailed in F-049)**
- **FR-8** Capture copy events where the platform allows (Android foreground/IME; iOS foreground/manual), encrypt + publish.
- **FR-9** Receive remote items; make them available to paste (respecting OS constraints).

**Config (both)**
- **FR-10** Shared Firebase config + passphrase (reuse F-044 setup).
- **FR-11** Toggles: enable sync, TTL, sync images (off by default), sensitive-filter rules.

## 6. Non-Functional Requirements

- **Privacy/Security:** encrypt-before-upload (D2); owner-only Firestore rules; secrets excluded by default (D5); TTL limits exposure (D4).
- **Performance:** publish is async/non-blocking on copy; listener merges without UI jank; respects the in-memory 500-item cap.
- **Battery/network (mobile):** batched writes; sync cadence configurable.
- **Correctness:** echo suppression prevents loops; last-writer-wins ordering by server timestamp.

## 7. Architecture & Data Model

```
Device A copy ─► ClipboardMonitor ─► [sensitive? skip] ─► encrypt ─► Firestore
                                                                        │ snapshot
Device B  ◄──────── insert into history ◄─ decrypt ◄─ (deviceId != self)┘
```

**Firestore** `clipboard/{uid}/items/{itemId}`:
```json
{
  "uid": "…",
  "itemId": "uuid",
  "deviceId": "device-uuid",
  "deviceName": "Gokul's iPhone",
  "kind": "text|url|code",
  "contentEnc": "…",          // AES-GCM ciphertext
  "createdAt": 1720000000000,
  "expiresAt": 1720086400000,
  "schema": 1
}
```

**Desktop:** extend `ClipboardMonitor`/`ClipboardViewModel`; add `ClipboardSyncService` (actor: publish + subscribe + echo-suppress + TTL). Reuse `FirebaseClient` from foundations.

## 8. Acceptance Criteria

- Copy on device A appears in device B's history within seconds (listener) or the polling interval.
- Cloud stores ciphertext only; secrets excluded per filter.
- No echo loops; no duplicates; 500-cap respected.
- TTL purges expired items; disable+purge clears local + cloud.
- Security review passed.

## 9. Open Questions & Risks

- **iOS capture** — `UIPasteboard` has no background change events; realistic UX is foreground/manual "push clipboard". Confirm acceptable.
- **Android capture** — clipboard access restricted in 10+ (foreground/IME). Determine capture strategy (accessibility service? IME? foreground service?) and its trade-offs.
- Sensitive detection heuristics — false negatives could leak secrets; conservative defaults.
- Multi-device ordering + rapid-copy bursts — debounce strategy.
- Shared passphrase across F-044/F-045 — one key for all cloud data vs. per-feature.

## 10. Execution Plan

### Phase 0 — Shared with F-044
- Reuse the Firebase-macOS spike, `FirebaseClient`, crypto util, and Settings **Cloud** pane. No separate spike needed if F-044 Phase 0/1 done.

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
