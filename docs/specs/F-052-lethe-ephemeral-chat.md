# F-052 — Lethe: Anonymous Ephemeral Chat in Halo (NFeat-128)

> **Status:** 📝 Requirements draft · **Platform:** Desktop (+ existing Lethe mobile/web clients)
> **Source project:** [`~/Github/Lethe`](https://github.com/prasad-rently/Lethe) — private · Flutter app + Node.js relay, relay live at `wss://lethe-relay.onrender.com`
> **Relates to:** [00-foundations](00-foundations.md) (BYOB Firebase), [F-045](F-045-clipboard-sync.md) (clipboard sync), [F-050](F-050-haloshare-mobile.md) (HaloShare mobile), existing `.localShare` module
> **F-id note:** `F-051` is claimed by the Lucky Draw spinner wheel (branch `feat/f051-lucky-draw`, unpushed at time of writing). This takes `F-052`.

---

## 1. Summary

Lethe is an existing, working product: anonymous ephemeral group chat with no
accounts, no phone numbers, and no server-side storage. Messages are encrypted
on-device with a per-room AES-256-GCM key; a stateless Node.js relay broadcasts
the opaque blob and discards it. It ships today as a Flutter app for iOS,
Android and Web, against a relay already live on Render.

This document specifies bringing Lethe into Halo as a **native macOS client** —
a new sidebar module speaking the same wire protocol as the existing mobile
clients, so a Mac and a phone can sit in the same room.

It also identifies a **second, larger opportunity** that fell out of the
analysis and is specified separately in §7.4: Lethe's relay is a credible
**zero-configuration transport for Halo's own cross-device features**, where the
current plan (F-044/F-045) requires the user to provision their own Firebase.
These are independent decisions and can be taken independently.

---

## 2. Goals / Non-Goals

**Goals**

- A native Swift/SwiftUI Lethe client as a Halo module (`.lethe`), matching the
  design system and module conventions.
- Wire-compatible with the existing relay and the Flutter clients — a Mac and a
  phone in the same room, no protocol fork.
- Create room, join by invite link or QR, send/receive, leave — the v1 surface
  the mobile app already has.
- Preserve Lethe's security guarantee unchanged: **the relay never sees
  plaintext, the room key never leaves the device.**
- Work under the **App Store sandbox** — unlike six existing Halo features, this
  one can (see §6.3).

**Non-Goals (v1)**

- Any change to the relay. Halo is a new client against the protocol as it
  stands.
- Direct/1-to-1 messaging, media/file sharing, reactions, threads — all
  explicitly out of scope in the Lethe BRD v1 and inherited as such here.
- Push notifications. Lethe's BRD rules these out as conflicting with the
  anonymity model; Halo uses **local** notifications only (§5.4).
- Tor / IP anonymity (Lethe v3).
- Replacing HaloShare. LocalShare is LAN file transfer over LocalSend; Lethe is
  WAN text chat. Different problems (see §7.3).

---

## 3. Decisions & Assumptions

Defaults chosen so the spec is concrete. Anything genuinely unresolved is in §9.

| # | Decision | Rationale |
|---|----------|-----------|
| **D1** | **Reimplement the client natively in Swift.** Do not embed Flutter. | Halo is pure SwiftUI/AppKit with an established design system, `AppModule` sidebar routing, and actor-based concurrency. A Flutter view embedded in that is a foreign body — separate rendering, separate state, separate theming, and it would defeat the dark-only design tokens. The protocol is small enough that a port is cheaper than the embed (§7.1). |
| **D2** | **Crypto via CryptoKit `AES.GCM`.** | Already a dependency (`DuplicateDetector`, `TLSManager`). Lethe's payload is `nonce(12) ‖ ciphertext ‖ tag(16)`, which is exactly `AES.GCM.SealedBox`'s combined representation — a byte-for-byte match, no custom framing. |
| **D3** | **Room keys in the Keychain**, not `UserDefaults` or a JSON file. | Precedent exists in this codebase: `AIKeyStore` (`com.halo.mac.ai`) and `TLSManager` both use the Keychain. A room key is a secret of the same class. |
| **D4** | **Message history as JSON in `Application Support/Halo/lethe/`**, not SQLCipher. | Lethe mobile uses Drift + SQLCipher; **Halo has no SQLite or CoreData dependency at all** (verified: no `import SQLite3`, no `import CoreData`, no GRDB). `MemoryTrendTracker` set the precedent for per-feature JSON files when data outgrows `UserDefaults`. Adding SQLCipher for one module is disproportionate. See §9 OQ-3 for the at-rest consequence. |
| **D5** | **`URLSessionWebSocketTask`**, not a third-party WebSocket library. | Native since macOS 10.15; Halo's deployment target is 13.0. Avoids adding a dependency for a protocol with five message types. |
| **D6** | **Per-room history capped at 1,000 messages**, oldest evicted. | Matches the Lethe BRD's NFR so desktop and mobile agree on retention. |
| **D7** | **Local notifications via the existing `AlertManager` / `AlertLog`.** | Halo already owns a notification+history pipeline with a cooldown contract. A parallel one would violate the shared-singleton rule in CLAUDE.md. Needs a new `AlertKind` case — see §6.4 for the icon/colour obligation. |
| **D8** | **Handle is per-device and local**, generated on first use, editable. | Lethe F-01/F-02. Halo's handle is independent of the phone's; the relay never sees either. |
| **D9** | **Sentry is disabled for this module's failures.** | Lethe BRD F-23/F-24 forbid analytics and crash reporting that transmits device data. Halo ships Sentry (opt-in, default off). Even opted in, no Lethe breadcrumb may carry room ids, handles, message text or invite links. See §6.2. |
| **D10** | **`lethe://` deep links registered on macOS**, matching the mobile URL scheme. | The mobile app already registers it. A link shared to a Mac should open Halo, not fail. Requires a `CFBundleURLTypes` entry. |

---

## 4. User Stories

| ID | Story |
|----|-------|
| **US-1** | As someone already using Lethe on my phone, I can scan or paste an invite link on my Mac and join the same room, so I can type on a keyboard instead of a phone. |
| **US-2** | As a Mac user, I can create a room and share its invite by QR or copy-link, so someone across the table can join without me knowing anything about them. |
| **US-3** | As a privacy-conscious user, I can confirm the relay learns nothing — the module states plainly what it does and does not transmit. |
| **US-4** | As someone in several rooms, I see unread counts in the sidebar and get a local notification when a message arrives while Halo is in the background. |
| **US-5** | As someone who is done, I can leave a room and have its key and history removed from this Mac. |
| **US-6** | As someone on a flaky connection, I can see whether I'm connected, and messages I send while offline are queued and delivered on reconnect rather than silently lost. |

---

## 5. Functional Requirements

IDs are namespaced `FR-L-x` to avoid collision with Lethe's own `F-xx` BRD ids,
which this document references rather than renumbers.

### 5.1 Identity & onboarding

| ID | Requirement | Lethe BRD |
|----|-------------|-----------|
| FR-L-01 | Generate a random display handle (`ghost_7f3a` shape) on first use of the module. | F-01 |
| FR-L-02 | Handle stored locally; **never** transmitted outside an encrypted payload. | F-02 |
| FR-L-03 | Handle is user-editable at any time. | F-01 |
| FR-L-04 | No registration, login, or account surface anywhere in the module. | F-03 |

### 5.2 Room management

| ID | Requirement | Lethe BRD |
|----|-------------|-----------|
| FR-L-05 | Create a room — generate `roomKey` (AES-256) and derive `roomId` locally, with no network call. | F-05 |
| FR-L-06 | Name a room locally; the name is encrypted into the invite link, never sent to the relay. | F-06 |
| FR-L-07 | Join by pasting a `lethe://join#…` link. | F-07 |
| FR-L-08 | Join by scanning a QR code shown on another screen, via the Mac camera. | F-07 |
| FR-L-09 | Generate and display a QR code for an invite. | F-10 |
| FR-L-10 | Copy an invite link to the clipboard, and share via `NSSharingServicePicker`. | F-10 |
| FR-L-11 | Room list persists across launches. | F-08 |
| FR-L-12 | Leave a room: drop the socket, delete the key from the Keychain, delete local history. Behind a confirmation dialog (CLAUDE.md destructive-action rule). | F-09 |
| FR-L-13 | Opening a `lethe://` link from outside Halo activates the app and offers the join flow. | — (new, D10) |

### 5.3 Messaging

| ID | Requirement | Lethe BRD |
|----|-------------|-----------|
| FR-L-14 | Encrypt with AES-256-GCM and a **fresh random 12-byte nonce per message** before transmission. | F-11 |
| FR-L-15 | Transmit as `{ type: 'SEND', roomId, payload }` where payload is base64 of `nonce ‖ ciphertext ‖ tag`. | F-12 |
| FR-L-16 | Decrypt received blobs locally; a blob that fails authentication is **dropped, never rendered** (it is not from a key-holder). | F-14 |
| FR-L-17 | Persist messages locally, indexed by room, capped per D6. | F-15 |
| FR-L-18 | Render handle, text and a relative timestamp. | F-16 |
| FR-L-19 | Input capped at 2,000 characters, with the limit visible as it is approached. | F-18 |
| FR-L-20 | Reject an outbound payload exceeding the relay's 64 KB limit with a clear message rather than a silent failure. | R-09 |

### 5.4 Connection

| ID | Requirement | Lethe BRD |
|----|-------------|-----------|
| FR-L-21 | Auto-reconnect with exponential backoff. | F-19 |
| FR-L-22 | Connection state surfaced in the UI: connected / reconnecting / offline. | F-20 |
| FR-L-23 | Messages composed while offline are queued and sent on reconnect. | F-21 |
| FR-L-24 | Rejoin all active rooms after reconnect. | F-22 |
| FR-L-25 | **Cold-start is communicated, not hidden.** The relay runs on Render's free tier and spins down after ~15 min idle; the first connection can take ~50 s. Show "waking the relay…" rather than an indefinite spinner. | §10 relay note |
| FR-L-26 | Respect the relay's 10 msg/sec rate limit client-side. | R-08 |

### 5.5 Notifications

| ID | Requirement |
|----|-------------|
| FR-L-27 | A message arriving while the module is not frontmost fires a **local** `UNUserNotification` via `AlertManager`, and appends to `AlertLog` (D7). |
| FR-L-28 | The notification body contains the room name and handle, **never the message text** — notification content is rendered by the OS and may be mirrored, logged or shown on a lock screen. |
| FR-L-29 | Unread count per room in the module; aggregate badge on the sidebar item, matching the existing `.clipboard` / `.performance` badge pattern. |

### 5.6 Privacy surface

| ID | Requirement |
|----|-------------|
| FR-L-30 | An in-module panel states exactly what the relay does and does not learn, mirroring README/BRD §9 — and is kept in agreement with it. |
| FR-L-31 | No `print` / `NSLog` / `os_log` call in this module may take a room key, plaintext, handle or invite link as an argument. Same discipline as `PrivacyPatternDatabase`'s redaction rule. |
| FR-L-32 | The relay URL is user-configurable, so a self-hosted relay can be used. The BRD's claim that the relay is verifiable is only meaningful if the user can point at their own. |
| FR-L-33 | Camera is requested **only** when the user opens the QR scanner, with `NSCameraUsageDescription` explaining why. | 

---

## 6. Non-Functional Requirements

### 6.1 Performance

| Category | Requirement |
|----------|-------------|
| Latency | Round-trip to an online member < 500 ms on WiFi, excluding relay cold start (BRD NFR). |
| Idle cost | Zero polling. One WebSocket per active relay, not one per room — the protocol multiplexes rooms over a single socket via `roomId`. |
| Main thread | Crypto and persistence off `@MainActor`; the module follows the actor pattern (`actor LetheClient`) with `await MainActor.run` for published state. |

### 6.2 Privacy & telemetry

Lethe BRD **F-23/F-24 forbid analytics and crash reporting that transmits device
data**. Halo ships Sentry. These are reconcilable but only deliberately:

- Sentry is already **opt-in and off by default** (`enableAnalytics`), and
  `sendDefaultPii = false`.
- **Additional obligation for this module:** no Sentry breadcrumb, event, tag or
  extra may carry a room id, room key, handle, invite link or message content —
  even when the user has opted in. A crash inside Lethe reports the stack, not
  the conversation.
- The in-module privacy panel (FR-L-30) must say Sentry exists and how to check
  it, rather than implying the module is telemetry-free when the host app is not.

### 6.3 Sandbox — this feature is not blocked by it

Verified in the entitlement files:

| Entitlement file | Sandbox | `network.client` |
|---|---|---|
| `Halo.entitlements` (release / App Store) | ON | **present** |
| `Halo-Debug.entitlements` | OFF | present |

This matters. Six existing Halo features (#21/#20/#17/#16/#10/#9) shell out via
`ShellReader` and are **inert under the release sandbox**, because it denies
`posix_spawn` — the unresolved decision B4. Lethe needs no subprocess, no
filesystem access outside its own container, and no privileged helper. It is
network + crypto + local storage.

**Lethe would therefore be one of the few Halo modules that works fully in a
sandboxed App Store build.** That is an argument for building it, independent of
the feature's own merit.

### 6.4 Codebase conventions this must honour

Non-optional, from `CLAUDE.md`:

- **`AlertKind.rawValue` is a persisted format.** Adding a case requires a
  matching arm in **both** `AlertEntry.icon` and `AlertEntry.accentColor`, or
  every Lethe alert renders as a generic bell. `HaloTests`' `AlertManagerTests`
  enforces this.
- **Shared singletons.** Use `AlertManager.shared`; do not construct one.
- **Dark-only design tokens.** No adaptive colours.
- **Destructive actions need confirmation.** Leaving a room destroys a key that
  cannot be recovered (FR-L-12).
- **pbxproj UUIDs.** Claim a block in the CLAUDE.md reservation table *before*
  adding files. `8181`–`8200` is taken by F-051 (Lucky Draw, unpushed);
  **`8201`–`8220` is the next free block.**
- **Mobile parity rule (MANDATORY).** A row in `HALO_MOBILE_ROADMAP.md` §3 plus a
  feasibility study before this is "done" — see §7.5.

---

## 7. Architecture

### 7.1 Why a native port rather than embedding Flutter

The protocol surface is genuinely small. The entire client contract is:

```
Client → Relay:  { type: 'JOIN',  roomId }
Client → Relay:  { type: 'SEND',  roomId, payload }
Relay  → Client: { type: 'MESSAGE', roomId, payload, ts }
Relay  → Client: { type: 'CONNECTED' }
Relay  → Client: { type: 'ERROR', code, message }
```

…plus one payload format that maps **exactly** onto a CryptoKit primitive:

```
bytes  0–11   AES-GCM nonce            → AES.GCM.Nonce
bytes 12–N    ciphertext               │ together: AES.GCM.SealedBox
bytes  N–N+16 auth tag                 │ .combined
```

Five message types and one sealed box is a smaller cost than embedding a second
UI toolkit into a SwiftUI app — and it keeps the module inside Halo's design
system, actor model, and test suite.

### 7.2 Proposed layout

Mirrors `Core/LocalShare` + `Features/LocalShare`, the closest existing analogue.

```
Halo/Core/Lethe/
├── Models/LetheModels.swift        Room, LetheMessage, ConnectionState, wire DTOs
├── Crypto/RoomKey.swift            AES-256-GCM seal/open; Keychain read/write (D3)
├── Crypto/InviteLink.swift         lethe:// encode/decode; roomId derivation
├── Network/LetheRelayClient.swift  actor; URLSessionWebSocketTask, backoff, queue
└── Manager/LetheManager.swift      @MainActor singleton; rooms, unread, routing

Halo/Features/Lethe/
├── LetheView.swift                 module view — room list + transcript
├── RoomListView.swift
├── ChatTranscriptView.swift
├── CreateRoomSheet.swift
├── JoinRoomSheet.swift             paste link + QR scan
├── InviteShareSheet.swift          QR render + copy + share
└── PrivacyPanel.swift              FR-L-30
```

New `AppModule` case `.lethe`, added to `reorderable` so the user can place it.
Forward-compat in `AppState.moduleOrder` appends unknown modules automatically,
so existing users get it after upgrade.

### 7.3 Relationship to HaloShare (`.localShare`)

These are complementary, not overlapping, and the distinction should be visible
to the user so the two modules do not read as duplicates:

| | HaloShare (`.localShare`) | Lethe (`.lethe`) |
|---|---|---|
| Problem | Move **files** between devices | Exchange **text** with people |
| Range | Same LAN (multicast `224.0.0.167`) | Anywhere (WAN relay) |
| Protocol | LocalSend 2.1 over HTTPS | Lethe WebSocket + AES-GCM |
| Identity | Device fingerprint from TLS cert | **None, by design** |
| Persistence | Transfer history | Ephemeral; relay 50 msg / 6 h |

### 7.4 The larger opportunity — Lethe's relay as Halo transport

**This is a separate decision from §1–§7.3 and should be taken separately.** It
is recorded here because the analysis surfaced it, not because this spec
proposes committing to it.

F-044 and F-045 both depend on **BYOB Firebase**: the user provisions their own
Firebase project, and `00-foundations.md` concedes that full zero-interaction
automation is *"not"* achievable — a guided wizard is the fallback. That is a
real onboarding cost for a system-utility app, and it gates two planned features
behind the user standing up a backend.

Lethe's relay is the opposite trade: **zero configuration, zero accounts, live
already, and self-hostable.** For a subset of Halo's cross-device needs it is a
strictly easier fit:

| Halo need | Lethe relay suitable? | Why |
|---|---|---|
| **F-045 clipboard sync** | **Plausible.** Clipboard is a rolling 500-item window with no time TTL; the relay's 50-message / 6 h buffer covers live sync between simultaneously-online devices. | Ephemeral by nature; already E2E encrypted in F-045's own design (D2). |
| **F-050 HaloShare beyond the LAN** | **Plausible as a signalling channel** — exchange connection details over a room, transfer the bytes directly. | Multicast discovery is LAN-only today; this is the missing piece, not the transfer itself. |
| **F-044 SMS console** | **No.** | An SMS archive must persist and be queryable. The relay forgets in 6 h — that is its entire point. |

If pursued, the honest framing is a **transport choice offered to the user**:
Firebase when they want durable history, Lethe-style relay when they want
zero-setup ephemeral sync. It is not a replacement for the foundations work.

### 7.5 Mobile parity (mandatory rule)

Halo's `CLAUDE.md` and `HALO_MOBILE_ROADMAP.md` §0 both require a feasibility
study and a §3 portability row before a desktop feature is "done."

This feature is the **easiest case the rule has ever had: the mobile client
already exists and ships.** Lethe is Flutter for iOS and Android today, against
the same relay.

| Platform | Verdict | Mechanism |
|---|---|---|
| iOS | ✅ Port | Already built (Flutter). Halo-mobile (F-049) either embeds the Lethe module or ships alongside it. |
| Android | ✅ Port | Same. |
| Web | 🟡 Adapt | Exists, but Lethe's own BRD flags it as a lower-assurance client (no secure enclave, no SQLCipher; keys in IndexedDB exposed to XSS). |

The open question is **product, not technical**: whether Lethe stays a separate
app on mobile while becoming a module inside Halo on desktop, or whether the two
converge. Recorded as OQ-5.

---

## 8. Acceptance Criteria

1. A Mac running Halo and a phone running the Lethe Flutter app exchange messages
   in the same room, in both directions, **against the unmodified production
   relay**. This is the ship gate — protocol compatibility is the whole point.
2. A packet capture of the relay connection shows **no plaintext**: no message
   text, handle, room name or key.
3. Killing and relaunching Halo restores the room list and history; the key is
   read from the Keychain, not from a file.
4. Pulling the network mid-session shows "reconnecting", queues a typed message,
   and delivers it on reconnect without duplication.
5. First connection after relay idle shows the cold-start state (FR-L-25), not a
   hung spinner.
6. Leaving a room removes the Keychain item and the history file; verified on
   disk, not just in the UI.
7. A tampered or wrong-key blob is dropped silently — no crash, no placeholder
   row, nothing rendered.
8. `AlertKind` case has arms in both `AlertEntry.icon` and `.accentColor`;
   `AlertManagerTests` passes.
9. Builds and runs **sandboxed** (`Halo.entitlements`) with full functionality —
   the claim in §6.3 is verified, not assumed.
10. `HALO_MOBILE_ROADMAP.md` §3 row added.

---

## 9. Open Questions & Risks

| # | Question / Risk | Notes |
|---|---|---|
| **OQ-1** | **Is the relay's free tier acceptable as a product dependency?** | Render free tier: ~50 s cold start after 15 min idle, 500 concurrent connections. Fine for a side project; thin for a shipped Halo feature. Mitigations: self-host, paid tier, or set expectations in-app (FR-L-25). |
| **OQ-2** | **Does Halo shipping Lethe change Lethe's threat model?** | Lethe's appeal is that it is a small, auditable, single-purpose app. Inside a 15-module system utility with Sentry, an AI assistant and cloud sync, "no telemetry" is harder to assert. §6.2 constrains it; whether that is sufficient is a judgement call. |
| **OQ-3** | **At-rest protection for history without SQLCipher.** | D4 uses JSON in Application Support. Mobile uses SQLCipher. So desktop history is **weaker at rest than mobile** — readable by anything running as the user. Options: encrypt the JSON with a Keychain-held key (recommended), accept and document, or add SQLCipher. Must be decided before build; it changes an advertised property. |
| **OQ-4** | **Room key rotation and member removal.** | Lethe has none — anyone with the link is in forever. Inherited as-is; worth stating in the UI rather than leaving users to assume otherwise. |
| **OQ-5** | **Product relationship between Lethe-the-app and Lethe-in-Halo.** | Separate products sharing a protocol, or does Halo become the desktop client of record? Affects branding, docs, and whether the Flutter web client is still needed. |
| **OQ-6** | **Does §7.4 get pursued?** | Independent decision. If yes it likely reshapes F-045's transport and should be settled before F-045 is built, not after. |
| **R-1** | **Relay is a single point of failure and a correlation point.** | It cannot read messages, but it sees IPs and room-membership timing. Lethe's BRD accepts this for v1 (Tor is v3). Halo users may have a different expectation than Lethe users; say so plainly (FR-L-30). |
| **R-2** | **Protocol drift.** | Two independent clients now implement one wire format with no shared test vectors. Mitigation: port `relay/scripts/chat-demo.mjs` (the BRD calls it the reference crypto/wire format) into a Halo test as fixed vectors, so a Dart-side change that breaks Swift fails a test rather than a conversation. |

---

## 10. Execution Plan

Estimates are relative sizing, not calendar commitments.

### Phase 0 — Spike (gate before committing)

| # | Task | Output |
|---|------|--------|
| 0.1 | Swift `AES.GCM` round-trip against fixtures generated by `chat-demo.mjs` | Proof the payload format maps to `SealedBox.combined` with no custom framing |
| 0.2 | `URLSessionWebSocketTask` JOIN + SEND against the live relay, from a throwaway CLI | Proof of wire compatibility before any UI work |
| 0.3 | Decide OQ-3 (at-rest) and OQ-1 (relay tier) | Written decision in this doc |

**Gate:** if 0.1 and 0.2 do not both pass, the native-port decision (D1) is wrong
and should be revisited before Phase 1.

### Phase 1 — Core, no UI

| # | Task |
|---|------|
| 1.1 | Claim pbxproj block `8201`–`8220` in the CLAUDE.md table |
| 1.2 | `LetheModels`, `RoomKey` (+ Keychain), `InviteLink` encode/decode |
| 1.3 | `actor LetheRelayClient` — connect, JOIN, SEND, receive, backoff, offline queue |
| 1.4 | Persistence (JSON, per D4/OQ-3), 1,000-message cap |
| 1.5 | Unit tests incl. the §9 R-2 cross-implementation vectors |

### Phase 2 — Module UI

| # | Task |
|---|------|
| 2.1 | `.lethe` AppModule + sidebar entry + `reorderable` |
| 2.2 | Room list, transcript, composer (2,000-char cap) |
| 2.3 | Create / join sheets; invite QR render + copy + share |
| 2.4 | QR scan via camera (`NSCameraUsageDescription`) |
| 2.5 | Connection-state banner incl. cold-start copy |
| 2.6 | Privacy panel (FR-L-30) |

### Phase 3 — Integration

| # | Task |
|---|------|
| 3.1 | `AlertManager` case + `AlertEntry.icon` / `.accentColor` arms + test |
| 3.2 | Unread badges |
| 3.3 | `lethe://` URL type + handler |
| 3.4 | Sentry scrubbing guarantee (§6.2) + a test that no Lethe log path takes a secret |
| 3.5 | Sandboxed build verification (AC-9) |

### Phase 4 — Cross-platform validation & docs

| # | Task |
|---|------|
| 4.1 | Mac ↔ iOS and Mac ↔ Android live sessions against production relay (AC-1) |
| 4.2 | Packet capture review (AC-2) |
| 4.3 | `HALO_MOBILE_ROADMAP.md` §3 row + feasibility study (§7.5) |
| 4.4 | `CLAUDE.md` module section; `FEATURE_ROADMAP.md` F-052 row; `MANUAL_TEST_PLAN.md` cases |

---

## Appendix — source material

Read before implementing; this document summarises rather than replaces them.

| Document | Location |
|---|---|
| Lethe BRD (requirements, security model, threat model) | `~/Github/Lethe/BRD.md` |
| Lethe working memory (wire format, payload layout, relay URLs) | `~/Github/Lethe/CLAUDE.md` |
| Reference crypto / wire implementation | `~/Github/Lethe/relay/scripts/chat-demo.mjs` |
| Relay server (entire implementation) | `~/Github/Lethe/relay/src/relay.js` |
| Agent rules for the Lethe codebase | `~/Github/Lethe/AGENT_RULES.md` |
| Halo cross-device foundations (BYOB Firebase) | [`00-foundations.md`](00-foundations.md) |
| Closest existing Halo analogue (networked module) | `docs/LOCALSHARE_IMPLEMENTATION_PLAN.md` |
