# F-050 — HaloShare Mobile ↔ Desktop (NFeat-127)

> **Status:** 🗓 Planned · **Platform:** Desktop (exists) + Mobile (new)
> **Depends on:** existing HaloShare (LocalSend Protocol v2.1) in `Halo/Core/LocalShare/`; F-049 (mobile app)

---

## 1. Summary

Extend **HaloShare** — currently desktop↔desktop over the LocalSend-compatible
protocol — so transfers also work **between Halo mobile apps and desktop**
(mobile↔desktop) and **between mobile apps** (mobile↔mobile). Ideally remain
interoperable with the official LocalSend apps.

## 2. Goals / Non-Goals

**Goals**
- Implement LocalSend Protocol v2.1 on the Halo Mobile app: discovery, TLS, consent, transfer.
- Verified interop: desktop↔mobile and mobile↔mobile.
- Preserve LocalSend interoperability (transfer to/from the official app).

**Non-Goals (v1)**
- Changing the desktop implementation's protocol (reuse as-is).
- Cloud relay / internet transfers (LAN/peer only, like today).
- Resumable transfers if not already in the desktop impl (match current capability).

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Reuse LocalSend v2.1** exactly | Desktop already speaks it (`Core/LocalShare`); mobile implements the same wire protocol. |
| D2 | Mobile discovery via **mDNS/NSD + UDP multicast** | Matches LocalSend; platform channels on Flutter. |
| D3 | **TLS** with the same handshake/pin model as desktop | Reuse `TLSManager` semantics. |
| D4 | **Consent screen** on receive (mirror `ReceiveConsentView`) | User must accept incoming transfers. |
| D5 | Interop with official LocalSend = **acceptance gate** | Protocol fidelity, not a Halo-only dialect. |

## 4. User Stories

- **US-1** As a user, I send a photo from my phone to my Mac via HaloShare.
- **US-2** As a user, I send a file from my Mac to my phone.
- **US-3** As a user, I share between two phones running Halo.
- **US-4** As a user, incoming transfers ask my consent before saving.
- **US-5** As a user, I can still exchange files with someone using the official LocalSend app.

## 5. Functional Requirements

- **FR-1** Mobile: multicast/mDNS **discovery** — announce + browse peers on the LAN.
- **FR-2** Mobile: **TLS** session per the protocol (certs/pin as desktop).
- **FR-3** Mobile: **send** flow — select file(s), pick peer, transfer with progress + cancel.
- **FR-4** Mobile: **receive** flow — **consent prompt**, then save to a chosen location; progress + cancel.
- **FR-5** Cross-target interop: desktop↔mobile, mobile↔mobile, and Halo↔official LocalSend.
- **FR-6** Handle transient network drops gracefully (match desktop behavior); clean up partials.
- **FR-7** Keep device awake during transfer (power assertion equivalent), like desktop `TransferPowerAssertion`.

## 6. Non-Functional Requirements

- **Security:** TLS transport; explicit receive consent; no unsolicited writes.
- **Interoperability:** conforms to LocalSend v2.1 wire format (protocol-tested, not just Halo-to-Halo).
- **Platform:** iOS **Local Network** entitlement + Bonjour usage description; Android NSD + background/foreground handling.
- **Performance:** large-file transfer with accurate progress; comparable throughput to LocalSend.

## 7. Architecture

```
Desktop (existing)                         Mobile (new — Flutter + platform channels)
Core/LocalShare/                           HaloShareModule
├─ MulticastDiscovery  ◄── LAN mDNS/UDP ──► NSD/mDNS discovery
├─ LocalShareServer/Client ◄── TLS ──────► TLS transfer client/server
├─ TLSManager                              consent screen (mirror ReceiveConsentView)
└─ ReceiveConsentView                      power/foreground keep-alive
```
The **protocol models** (`LocalShareModels`) are the shared contract; document them
as the cross-platform source of truth so mobile mirrors them exactly.

## 8. Acceptance Criteria

- Send/receive works desktop↔mobile and mobile↔mobile with progress + cancel.
- Receiving prompts for consent; declining writes nothing.
- Interop verified with the official LocalSend app in both directions.
- Network-drop mid-transfer cleans up partial files on both ends.
- iOS Local Network entitlement + Android NSD function on real devices.

## 9. Open Questions & Risks

- **iOS Local Network** permission/entitlement + Bonjour service declaration; background discovery limits.
- **Android** NSD reliability across OEMs; background execution/foreground-service needs.
- Whether to extract a **shared protocol reference** doc from the desktop impl to guarantee parity.
- File-save UX on mobile (scoped storage on Android; Files integration on iOS).
- Multicast on some mobile networks/APs is blocked — fallback discovery?

## 10. Execution Plan

### Phase 0 — Protocol reference
- Extract/confirm the LocalSend v2.1 details from desktop `Core/LocalShare` into a shared reference (models, handshake, endpoints) so mobile matches exactly.

### Phase 1 — Discovery (mobile)
- mDNS/NSD announce + browse via platform channels (iOS Bonjour + Local Network entitlement; Android NSD). Show discovered peers.

### Phase 2 — Transfer (mobile)
- TLS session; send flow (pick files/peer, progress, cancel); receive flow (**consent**, save, progress, cancel); keep-alive during transfer.

### Phase 3 — Interop & hardening
- Verify desktop↔mobile, mobile↔mobile, and **official LocalSend** interop.
- Network-drop cleanup; large-file throughput; store entitlements/usage strings.

### Test plan
- Interop matrix: {desktop, iOS, Android, official LocalSend} × {send, receive}.
- Manual: consent accept/decline, cancel mid-transfer, network drop, large files, multicast-blocked network.
- Unit (Dart): protocol message encode/decode parity with desktop models.

### Rough effort
Protocol reference ~1.5 d · Discovery ~3 d · Transfer ~4 d · Interop/hardening ~3 d. **~11.5 d** (within the F-049 mobile program; depends on the app shell existing).

---

## 11. Implementation blueprint

Reuse the desktop `Core/LocalShare` **protocol contract** (LocalSend v2.1) as the
shared spec; implement the mobile peer in Flutter + platform channels. No Firebase
(LAN/peer only). Details settled at build.

```
lib/features/haloshare/
├─ discovery.dart          platform channel → mDNS/NSD announce + browse (iOS Bonjour + Local Network entitlement; Android NSD)
├─ transfer_client.dart    TLS send: pick files/peer, progress, cancel
├─ transfer_server.dart    TLS receive: consent screen → save, progress, cancel
├─ protocol.dart           LocalSend v2.1 messages — parity with desktop LocalShareModels
├─ consent_view.dart       mirrors desktop ReceiveConsentView
└─ keepalive.dart          foreground/power keep-alive during transfer
```
- **Interop gate:** verify desktop↔mobile, mobile↔mobile, and official-LocalSend both ways (protocol fidelity, not a Halo dialect).
- iOS needs the **Local Network** entitlement + Bonjour usage strings; Android NSD + foreground-service for background transfers.
- Build order: extract shared protocol reference → discovery → TLS transfer (send/receive + consent) → interop matrix + hardening.
