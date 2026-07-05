# F-049 — Halo Mobile App (Product Line)

> **Status:** 🗓 Planned · **Platform:** iOS + Android
> **Depends on:** [00-foundations](00-foundations.md); pairs with F-044, F-045, F-050
> **Reference:** `docs/MOBILE_PLATFORM_FEATURES.md`

---

## 1. Summary

A **companion mobile app** that extends Halo. It is the **device-side half** of
the cross-platform features: it syncs SMS (F-044), syncs clipboard (F-045), and
participates in HaloShare transfers (F-050) — all against the user's **own
configurable Firebase** (no default backend). It is not a full port of the
desktop system-maintenance tools (mobile OSes block most of those).

## 2. Goals / Non-Goals

**Goals**
- A shippable mobile app shell (iOS + Android) with Settings + Firebase config/pairing.
- **NFeat-122 (mobile):** read device SMS → sync to user's Firebase (**Android-only**).
- **NFeat-123 (mobile):** capture clipboard → publish/receive via user's Firebase (platform-limited).
- **NFeat-127:** act as a HaloShare peer (see F-050).

**Non-Goals (v1)**
- Porting Cleanup / Applications / Login Items / sensors (mobile-blocked — see feature matrix).
- A shared backend or account system (BYOB only).
- Feature parity with desktop.

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Native — Kotlin (Android) + Swift (iOS)** ✅ *confirmed* | No Flutter. **iOS Swift reuses the desktop `Halo/Core/Cloud` Swift** (crypto, RTDB client, models) — only Android needs a Kotlin port. Max platform fidelity for SMS/clipboard/mDNS. |
| D2 | **Android + iOS together in v1** ✅ *confirmed* | Android does the full set (SMS sync + clipboard + HaloShare). iOS v1 = SMS **viewer** (no read API) + limited clipboard + HaloShare. |
| D3 | Clipboard capture is **platform-limited** | Android: **AccessibilityService** (F-045 D7). iOS: foreground/manual push. |
| D4 | Firebase config via **QR pairing** with desktop (+ Email/Password auth carried in QR) | Secure storage (Keystore/Keychain). See F-044 §7.1. |
| D5 | Client-side encryption **byte-parity** with desktop | Android Kotlin crypto must match Swift AES-GCM/Argon2; iOS shares the Swift impl. Cross-language test vectors. |
| D6 | **Same monorepo** (halo-mac) ✅ *confirmed* | Android (Kotlin/Gradle) + iOS (Swift) live in the halo-mac repo alongside macOS; mixed tooling/CI accepted. |
| D7 | **No store publishing (v1)** ✅ *confirmed* | Direct/sideload distribution — APK for Android, direct install for iOS. Sidesteps Play Store `READ_SMS` policy AND App Store review. Store submission is a later decision. |

## 4. User Stories

- **US-1** As a user, I install Halo Mobile and connect my Firebase by scanning a QR from desktop.
- **US-2** As an Android user, I grant SMS permission and my messages sync to my Mac.
- **US-3** As a user, my clipboard syncs between phone and Mac (within OS limits).
- **US-4** As a user, I send a file from my phone to my Mac via HaloShare.
- **US-5** As a user, all my data is in my own Firebase — I trust it because it's mine.

## 5. Functional Requirements

**App shell**
- **FR-1** Cross-platform app (iOS + Android) with navigation, Settings, onboarding.
- **FR-2** Firebase config: paste credentials or **scan QR** from desktop; secure storage; "Test connection".
- **FR-3** Shared encryption passphrase setup (matches desktop).

**SMS sync (NFeat-122, Android)**
- **FR-3b** Register the device (`devices/{uid}/{deviceId}`) and enumerate **SIM lines** via `SubscriptionManager` (`READ_PHONE_STATE`/`READ_PHONE_NUMBERS`) — capture `subscriptionId` + carrier + own number, with **manual per-SIM labeling** when the number is unprovisioned (dual-SIM aware). See F-044 §7.5.
- **FR-4** Request `READ_SMS` with rationale; read via content resolver.
- **FR-5** Encrypt + upsert to `sms/{uid}/{deviceId}/messages` (device-namespaced), tagging each with its `subscriptionId` (SIM line); dedup + high-water mark.
- **FR-6** Sync triggers: real-time receiver + on-open + periodic (WorkManager); number allow/deny.

**Clipboard sync (NFeat-123)**
- **FR-7** Capture copy events where allowed (Android strategy; iOS foreground/manual push).
- **FR-8** Encrypt + publish to `clipboard/{uid}/items`; subscribe + surface received items to paste.
- **FR-9** Sensitive-content exclusion consistent with desktop.

**HaloShare (NFeat-127 → F-050)**
- **FR-10** Discover peers + send/receive files via the LocalSend v2.1 protocol (detailed in F-050).

## 6. Non-Functional Requirements

- **Privacy/Security:** BYOB Firebase; client-side encryption; secure credential storage; least-privilege permissions with clear rationale.
- **Battery/network:** batched, cadence-configurable sync; respect Doze/background limits.
- **Distribution (v1):** **no store publishing** (D7) — direct APK (Android) + direct install (iOS). Sidesteps Play Store `READ_SMS` policy + App Store review. Store submission is a later decision.
- **Maintainability:** shared schema/protocol with desktop documented in `docs/specs`.

## 7. Architecture

```
Android app (Kotlin)                         iOS app (Swift)
├─ Settings + QR pairing                     ├─ Settings + QR pairing
├─ SMS: ContentResolver + SubscriptionMgr    ├─ SMS: viewer only (no read API)
├─ Clipboard: AccessibilityService           ├─ Clipboard: foreground/manual
├─ HaloShare: NSD/mDNS + TLS                  ├─ HaloShare: Bonjour/Network.framework + TLS
├─ FirebaseService (RTDB + Email/Pwd)        ├─ REUSES desktop Halo/Core/Cloud (Swift):
└─ CryptoService (Kotlin AES-GCM/Argon2)     └─   FirebaseRTDBClient + CryptoService + models
```
- **iOS reuses the desktop Swift `Halo/Core/Cloud`** (crypto, RTDB client, schema models) — shared as an internal Swift package in the monorepo. Only **Android** needs a Kotlin port of crypto + RTDB glue.
- Both use the **same RTDB schemas + Email/Password auth** as F-044/F-045 (single source of truth in those specs).

## 8. Acceptance Criteria

- App builds + runs on iOS and Android; Settings + QR pairing connect to a user's Firebase.
- Android SMS sync populates the desktop console (F-044).
- Clipboard round-trips within documented OS limits (F-045).
- Phone↔Mac file transfer works via HaloShare (F-050).
- All cloud data encrypted; permissions justified; security review passed.

## 9. Open Questions & Risks

- ~~Stack~~ → **native Kotlin + Swift** (D1); iOS reuses desktop Swift core.
- ~~Store distribution~~ → **no stores in v1** (D7); direct/sideload.
- **iOS scope** — confirmed in v1 (D2) but limited: SMS **viewer** only, limited clipboard, full HaloShare.
- ~~Repo structure~~ → **same monorepo** (D6).
- Clipboard capture mechanism on Android (accessibility/IME/foreground) + its UX/permission cost.
- QR-pairing security (Firebase config is sensitive) — short-lived display, encrypt payload?

## 10. Execution Plan

### Phase 0 — Foundation & decisions
- Scaffold **native** apps in the monorepo: Android (Kotlin/Gradle) + iOS (Swift). Extract desktop `Halo/Core/Cloud` into a Swift package the iOS app links; CI for both.
- Android `FirebaseService` + Kotlin `CryptoService` (byte-parity w/ Swift); Settings + **QR pairing** on both.

### Phase 1 — SMS sync (Android)
- `READ_SMS` flow, content-resolver reader, encrypt + upsert, high-water mark, periodic sync, allow/deny list. → validates F-044 end-to-end.

### Phase 2 — Clipboard sync
- Android capture strategy + publish/subscribe; iOS foreground/manual push + receive; sensitive filter.

### Phase 3 — HaloShare peer (F-050)
- NSD/mDNS discovery + TLS transfer (LocalSend v2.1) — native (Android NSD, iOS Network.framework/Bonjour); interop with desktop.

### Phase 4 — Hardening & release
- Permission rationale screens, background/battery tuning, **security review**, docs, direct-distribution builds (APK/IPA). No store review (D7).

### Test plan
- Unit: crypto round-trip (Kotlin↔Swift test vectors), dedup/high-water, sensitive filter, schema mapping.
- Integration: Android→Firebase→desktop (SMS + clipboard); phone↔Mac HaloShare.
- Manual: QR pairing, permission flows, background sync, iOS limitations, store-build validation.

### Rough effort
Foundation ~5 d · SMS ~4 d · Clipboard ~4 d · HaloShare ~5 d · Hardening/release ~5 d. **~23 d** (new app; largest program item; parallelizes with desktop halves).

---

## 11. Implementation blueprint (native)

Native per platform (D1). iOS shares the desktop Swift core; Android is a Kotlin
port. Both mirror the RTDB schema/crypto exactly (shared contract in F-044/F-045).
Details settled at build.

```
halo-mac/ (monorepo, D6)
├─ Halo/               macOS desktop (existing) + Halo/Core/Cloud (Swift, shared with iOS)
├─ ios/               iOS app (Swift) — reuses Halo/Core/Cloud via an internal Swift package
│  ├─ Settings + QR pairing (scan config + auth cred + salt)
│  ├─ ClipboardSync (foreground) · HaloShare (Network.framework) · SMS viewer
└─ android/           Android app (Kotlin/Gradle)
   ├─ core/ FirebaseService (RTDB + Email/Pwd) + CryptoService (Kotlin, byte-parity w/ Swift)
   ├─ sms/ ContentResolver + SubscriptionManager (device/line registry, F-044)
   ├─ clipboard/ AccessibilityService capture (F-045 D7)
   └─ haloshare/ NSD/mDNS + TLS (LocalSend v2.1, F-050)
```
Legacy Flutter note (superseded by D1):
```
lib/  (NOT USED — native chosen)
├─ core/
│  ├─ firebase_service.dart      runtime Firebase.initializeApp(options) + RTDB + Email/Password auth
│  ├─ provisioning_service.dart  (optional) the mobile side usually inherits config via QR scan
│  ├─ crypto_service.dart        Argon2id + AES-GCM — byte-identical to desktop CryptoService
│  ├─ config_store.dart          secure storage (Keychain/Keystore)
│  └─ pairing.dart               scan QR { config, authEmail, authPassword, salt } → sign in
├─ features/
│  ├─ settings/                  Firebase status, passphrase, per-line toggles
│  ├─ sms/                       (Android) SubscriptionManager lines + SMS reader + reconcile (F-044)
│  ├─ clipboard/                 capture (Android AccessibilityService / iOS foreground) + sync (F-045)
│  ├─ expenditure/               Dart port of the parser over device SMS (F-048 D16, shared pattern pack)
│  └─ haloshare/                 LocalSend v2.1 peer (F-050)
└─ platform channels:
   ├─ android: ContentResolver (SMS), SubscriptionManager, ClipboardAccessibilityService, NSD/mDNS
   └─ ios:     Bonjour/Local Network, UIPasteboard (foreground)
```
- **Crypto parity is critical:** the **Kotlin** `CryptoService` (Android) must produce the same AES-GCM/Argon2 output as Swift; iOS shares the Swift impl directly. Cross-language test vectors required (F-044 D27).
- **Android-first** (SMS); iOS ships clipboard(limited) + HaloShare + SMS-viewer only.
- Build order: app shell + firebase_service + pairing → SMS sync (validates F-044 e2e) → clipboard → HaloShare → expenditure → store-policy review.
