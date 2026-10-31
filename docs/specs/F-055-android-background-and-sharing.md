# F-055 — Android Background Receiving & Sharing

> **Status:** 🔧 **Built on PR #62 (unmerged; stacked on PR #61, head `6d93b85` = #61 merged in). Independently reviewed (8 fixes).** Emulator-verified on API 36 for the service, consent and share-target paths — **on the pre-review code (`170fa93`/`90c79d1`); the review fixes in `e4966f1` (service start order, consent gate, server lifecycle) and the #61 merge were verified on the JVM only**; **real multicast, Doze/OEM behaviour and the background clipboard read are NOT verified** (V-6). Not ✅.
> **Extends:** F-050 HaloShare mobile (`android/haloshare`), F-049/F-045 Android app (`android/app`) · **Raised:** 2026-10-28 (v2.6 BRD §7) · **Effort estimate:** ≈ 8 d (Android only)
> **Closes:** [`F-049-F-050-mobile-requirements.md`](F-049-F-050-mobile-requirements.md) **MR-OS-1** (Sharesheet target), **MR-OS-2** (foreground service on Android), **MR-DI-4** (multicast announce + listen)
> **Reserved pbxproj IDs:** none — Kotlin only, no `project.pbxproj` change.
> **Depends on:** PR #61 (Android hardening — `ManifestExportTest`, sealed clipboard history, stream-close race) · **Plan:** [`../V2_6_PLAN.md`](../V2_6_PLAN.md)

---

## 1. Summary

Today the Android app receives HaloShare files and the clipboard stream only while it is visible or its process happens to be alive (MR-OS-2 unmet), cannot be a share target for files (MR-OS-1), and discovers peers only by a /24 HTTP scan or manual address (MR-DI-4 unmet). F-055 adds an opt-in **foreground service** that hosts the HaloShare receiver and the clipboard stream, a **Sharesheet target**, and **multicast announce/listen** — without adding an exported component that any other app can drive.

## 2. Goals / Non-Goals

**Goals:** background receiving that survives swipe-away, with a persistent notification and one-tap stop; explicit user control (default **off**); consent for every incoming offer still required; Sharesheet target that stages files for a deliberate send; multicast discovery with a scoped `MulticastLock`.

**Non-Goals (v2.6):** starting at boot (`BOOT_COMPLETED`); proactive network-change callbacks; periodic re-announce while idle; iOS (cannot run a background listener — deferred by design, MR-OS-2 iOS clause); TLS serving (v2.7, MD1/MD3); any change to the wire protocol.

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D1 | Foreground service type `dataSync`, **not exported**, no intent-filter, started **only from a user action** (Settings toggle, or the app opened with the toggle already on). | Android 14 foreground-service rules; keeps the always-on port an explicit user choice. |
| D2 | The receiver is **process-wide** (`ReceiverHost`), shared by the screen and the service — one server, one consent gate, one inbox. | A second implementation in the service would have forked the consent logic. |
| D3 | With the app not visible, consent is a **notification with Accept / Decline** showing sender, count and size — **never file names**. Unanswered after **90 s ⇒ declined**. | Lock-screen / mirrored-notification leak; silence must never accept. |
| D4 | The Sharesheet target **stages** items; nothing is sent without a chosen device and a tap. Only foreign **`content://`** URIs are accepted (cap 100). | A `file://` URI naming Halo's own storage would exfiltrate the pairing profile; other apps choose the URI. |
| D5 | Multicast peer **host = datagram source**, never the payload; each announcer is answered once (no ping-pong); one bounded window; `MulticastLock` held only for that window (`finally` release). | LAN datagrams are untrusted input; avoid holding the radio in high-power mode. |
| D6 | No `BOOT_COMPLETED` start. After a reboot the service resumes when the app is next opened with the toggle on. | A new exported receiver plus Android 14 limits; recorded as a deliberate gap. |

## 4. User Stories

- **US-1** As a phone owner I can leave Halo receiving files from my Mac while the app is closed, and stop it with one tap.
- **US-2** As a phone owner I can share a file from any app to Halo and choose which nearby device to send it to.
- **US-3** As a phone owner I find my Mac without typing its address, when multicast works on my network.

## 5. Functional Requirements

| ID | Requirement | Acceptance (as written in the BRD) |
|---|---|---|
| FR-B1 | Foreground service (`dataSync`) hosts the HaloShare receiver and, if clipboard sync is on and paired, the clipboard stream; persistent, explanatory notification with **Stop**. | Service survives app swipe-away; receive works with the app backgrounded; notification present; stop works |
| FR-B2 | "Keep receiving in the background" toggle (default **off**), clear battery note; stream reconnects after network loss. | Toggle persists; reconnect test with simulated network loss |
| FR-B3 | Sharesheet target (`SEND`/`SEND_MULTIPLE`, any mime) → choose a nearby device → send; consent rules unchanged. | Share a file from another app on the emulator → appears in the send flow |
| FR-B4 | Multicast announce + listen on `224.0.0.167:53317`; `MulticastLock` only during discovery; falls back to /24 scan + manual. | Unit test of the codec; two-emulator or emulator↔Mac run |
| FR-B5 | `POST_NOTIFICATIONS` (API 33+) requested with a rationale at the moment the service is first enabled. | Emulator API 36 flow |

## 6. Non-Functional Requirements

No new exported component without a permission or an intent-filter justification (`ManifestExportTest` is the lint); no plaintext logging; foreground service started only from a user action; no file names in notifications; no new network egress beyond the existing HaloShare port and the multicast group.

## 7. Architecture

`HaloShareService` (foreground, `dataSync`, `onTimeout` handled for Android 15) → `ReceiverHost` (process-wide server + consent + inbox) · `ConsentActionReceiver` (not exported; Accept/Decline) · `MainActivity` (`singleTop`; `SEND`/`SEND_MULTIPLE` filters; `SharedUris` validation) · `MulticastCodec` / `MulticastDiscovery` (pure JVM, injectable transport) / `MulticastScope` (lock). Manifest delta: four permissions (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, `CHANGE_WIFI_MULTICAST_STATE`), one service, one receiver, two intent-filters on the launcher activity.

## 8. Acceptance (ship gate)

- **AC-1** Service starts only from a user action, is not exported, survives swipe-away, Stop closes the port — *emulator, API 36* ✓ recorded **before** the review fixes (`e4966f1`, which changed `HaloShareService.onStartCommand`, `ReceiverHost` and `Server` start/stop); **not re-run on the current head**.
- **AC-2** Accept/Decline notification works; unanswered ⇒ declined; no file names in notifications — *emulator (pre-review code) + unit tests* (the consent gate was rewritten in review; `ConsentGateTest` covers it on the JVM only).
- **AC-3** Sharesheet target stages only `content://` items; nothing sent without a device and a tap — *partly emulator-verified* (the end-to-end Sharesheet → device → send run was not driven).
- **AC-4** Multicast codec strict; one answer per announcer; lock released — *JVM only*.
- **AC-5 (owner / device, V-6)** Receiving survives Doze and the owner's OEM battery manager for a realistic idle period — **not verified**.
- **AC-6 (owner / device, V-10)** Interop with the official LocalSend app and a real Mac over Wi-Fi, including real multicast — **not verified**.

## 9. Open Questions & Risks

| # | Item | Notes |
|---|---|---|
| R-4 | Android 14/15 foreground-service policy | Mitigated by user-initiated start, declared `dataSync`, `onTimeout` handler. The six-hour `dataSync` timeout path is code-only. |
| OQ-1 | **POST_NOTIFICATIONS denied still enables the service** (review finding, not changed) | The listener then runs with its persistent notice hidden; the UI warns. FR-B1 says "persistent, explanatory notification". Decide: refuse to enable when denied. **v2.7 / owner decision.** |
| OQ-2 | Notification **Stop** flips the pref but the Settings switch re-syncs only on next `onStart` | Cosmetic; open. |
| OQ-3 | `ClipboardController` is not stopped by the service `onDestroy`; `UdpMulticastTransport` does not pin an outgoing interface | Shared with the accessibility service / functional on single-network phones; open. |
| OQ-4 | No `BOOT_COMPLETED` start; no periodic re-announce; no proactive network-change restart | Deliberate gaps (D6); the stream's own backoff covers reconnection. |

## 10. Execution Plan

| Task | Work | Est. | State |
|---|---|---|---|
| F55-1 | Foreground service + toggle + notification/stop | 2.5 d | 🔧 #62 |
| F55-2 | Notification permission (API 33+), FGS-type rules | 0.5 d | 🔧 #62 |
| F55-3 | Sharesheet target | 1.5 d | 🔧 #62 (partly verified) |
| F55-4 | Multicast codec + discovery + lock scope | 1.5 d | 🔧 #62 (JVM only) |
| F55-5 | Reconnect / Doze notes / battery copy | 1 d | 🔧 stream reconnect tested; Doze **unverified** |
| F55-6 | Independent review → fixes | 1 d | ✅ done (8 fixes, `e4966f1`); the post-merge head `6d93b85` was not re-reviewed |

## 11. Mobile Feasibility

Android-only by nature. **iOS: ❌ deferred** — an iPhone cannot hold a background listener, and multicast needs a restricted entitlement (already recorded for F-050). Row: [`../HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 *Android background receiving & sharing (F-055)*.

## 12. Implementation Record

**PR #62, branch `feat/v2.6-f055-android-background`** (stacked on #61; head `6d93b85` after #61 was merged in with no conflicts). Nothing merged or published.

**Built:** FR-B1…B5 as in §5 and §7. Review (8 fixes, `e4966f1`) included: a **port left open after Stop** (start/stop race in `Server`/`ReceiverHost`), consent gate and server-lifecycle tests (`ConsentGateTest`, `ServerLifecycleTest`), a multicast flood test, `setAuthenticationRequired(true)` on Accept/Decline on API 31+.

**Not built:** network-change callback; BOOT start; periodic re-announce; a Sharesheet → device → send run end to end; the share-to-device flow beyond staging.

**Verified:** JVM `halocloud` 95 / `haloshare` 70 / `app` 6 tests at the original two commits, both APKs build (mutation checks on multicast reply, own-echo drop, stream reconnect); on the current head `6d93b85` (after review fixes and the #61 merge) the PR comment reports **`halocloud` 101 / `haloshare` 80 / `app` 7, 0 failures, both APKs build** (JVM only). On an **API 36 emulator** (original commits only): `dumpsys` shows `isForeground=true types=0x1`; swipe-away leaves the process alive and `/info` answers over an adb-forwarded 53317; a `prepare-upload` raised the Accept/Decline notification and Accept led to a stored file; Stop closes the port; the permission rationale → system dialog → service start flow; a `file://` share staged nothing and a `content://` share staged "1 item". **Those emulator runs pre-date both the review fixes (`e4966f1`) and the #61 merge into this branch, and were not re-run on `6d93b85`.**

**NOT verified:** real multicast (emulator NAT, no second device); Doze / OEM battery managers / real-phone service lifetime / Android 14 sticky restart (**V-6**); the Android 15 six-hour timeout; the official LocalSend app or a real Mac over Wi-Fi (**V-10**).

**Known issues carried:** OQ-1…OQ-3 above.
