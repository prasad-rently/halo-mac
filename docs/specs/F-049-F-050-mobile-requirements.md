# Halo Mobile (iOS + Android) — Requirements for F-049 / F-050

> **Status:** 🔧 In progress — HaloShare MVP being built on `feat/f049-f050-mobile`; cloud features blocked (§6)
> **Platform:** iOS + Android · **Distribution (v1):** sideload only (no store submission) — F-049 D7
> **Supersedes nothing.** [F-049](F-049-halo-mobile-app.md) and [F-050](F-050-haloshare-mobile.md) remain the
> feature specs. This document is the **mobile build contract**: it turns them into numbered, testable
> requirements, records where reading the *code* contradicted the specs, and states exactly what is in the
> first milestone and what is blocked and why.
> **Protocol contract:** [`docs/HALOSHARE_PROTOCOL.md`](../HALOSHARE_PROTOCOL.md)

---

## 1. What was verified before writing this (and what it changed)

The specs were written before the code was read closely. Reading `Halo/Core/LocalShare` and the build state
changed five things, and each is a requirement below, not a footnote.

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| V1 | **Desktop HaloShare could not receive a file from a phone.** Its request parser decoded the first socket read as a UTF-8 `String`; a binary body sharing a read with the headers returned `400`. It only worked with URLSession's write pattern. | `HaloShareServerBinaryTests` — reproduced with a raw-socket client, then fixed | F-050's headline acceptance criterion was unachievable. Fixed on `fix/haloshare-binary-upload`. |
| V2 | **Path traversal + silent overwrite on desktop receive.** `fileName` was appended to the destination unchanged. | Mutation check: the test fails on the old code (a file outside the folder was overwritten) | Fixed; receiver obligations are now MR-RX-3/4. |
| V3 | **Desktop speaks plain HTTP, not TLS.** `protocol: "http"`, `httpParameters()`. The certificate is used only to derive a fingerprint. | `LocalShareManager.swift:54`, `TLSManager.deviceInfoDTO()` | F-050 D3 ("TLS, same pin model as desktop") describes something that doesn't exist. See MD1. |
| V4 | **Desktop couldn't decode an official peer's `/info`** (required `port`/`protocol`, which the spec omits there). | Checked against the published LocalSend protocol | Fixed. Mobile decoders must be lenient the same way (MR-PR-3). |
| V5 | **iOS cannot do multicast discovery** without Apple's restricted multicast entitlement. | Platform rule; see protocol doc §5 | F-050 D2 ("mDNS + multicast on iOS") is not buildable. See MD2. |
| V6 | **F-044's `Halo/Core/Cloud` foundation is not on the integration line** (open PR #7 on a side branch, spikes S1/S2 unresolved). | `git`, `docs/specs/BUILD_PLAN.md` | Every Firebase-dependent F-049 feature is blocked. See §6. |

## 2. Product statement

A phone you can drop a file on and a Mac that accepts it — and the reverse — with no account, no cloud and no
setup beyond being on the same network. **v1 is HaloShare.** The Firebase-backed features (SMS, clipboard) come
after the cloud foundation exists.

**Personas**
- **P1** has a Mac and an iPhone/Android and wants to move a photo or document without email.
- **P2** has the official LocalSend app on another device and expects Halo to just work with it.
- **P3** is on a guest/corporate Wi-Fi that blocks multicast and expects to still be able to type an address.

## 3. Decisions (revisions to F-049/F-050 are marked ⟲)

| ID | Decision | Why |
|----|----------|-----|
| **MD1 ⟲ D3** | **v1 transport is plain HTTP**, matching what desktop actually serves and announces. Clients *also* speak `https` to peers that announce it, pinning the certificate's SHA-256 to the announced fingerprint. | Serving TLS from iOS needs on-device X.509 generation (no public API) and would make mobile↔desktop *less* compatible, since desktop doesn't serve it. **This is a security downgrade from the spec's intent**; consent remains the only gate on `http`. Needs the owner's explicit acceptance — §8. |
| **MD2 ⟲ D2** | **iOS discovery = HTTP /24 scan + manual address.** Multicast is Android/macOS only. | V5. iOS is findable only by others' scans. |
| **MD3** | One written contract (`HALOSHARE_PROTOCOL.md`); one native implementation per platform; **desktop is not refactored onto the shared Kit in this milestone.** | Refactoring shipped desktop transfer code is its own risk. Duplication is accepted and tracked (R3). |
| **MD4** | **F-049's cloud features are not started.** The app shell reserves their place and says so. | V6. Building them against an unresolved Firebase spike would be building on sand. |
| **MD5** | **Layout:** `ios/HaloShareKit` (SwiftPM) + `ios/HaloMobile` (SwiftUI app); `android/` Gradle with `:haloshare` (pure Kotlin, JVM-testable) + `:app` (Compose). Monorepo, per F-049 D6. | F-049 D1/D6. |
| **MD6** | **Every behaviour is verified against an independent HTTP client** (`curl`), not only against our own client — see §7. | V1 was invisible to Halo-to-Halo testing for exactly this reason. |

## 4. Functional requirements

IDs are stable; the **Status** column is kept current in §9.

### Discovery
- **MR-DI-1** Probe the local /24 over HTTP (`GET /info`), bounded concurrency, ≤ 2 s per host, cancellable.
- **MR-DI-2** Manual `host[:port]` entry; always available.
- **MR-DI-3** Ignore self (own fingerprint). De-duplicate by fingerprint; last-seen wins.
- **MR-DI-4** *(Android, macOS)* Multicast announce + listen on `224.0.0.167:53317`; Android holds a `MulticastLock` only while discovery is active.
- **MR-DI-5** Discovery failure is explained to the user (Local Network permission denied; multicast-blocked Wi-Fi) — never an empty list with no reason.

### Send
- **MR-TX-1** Pick one or more files (system picker); show name/size.
- **MR-TX-2** `prepare-upload` → on `403` show "declined" (not an error); on `409/429` show "receiver busy"; on `204` show "nothing to send".
- **MR-TX-3** Upload each file with real progress (bytes), per-file and overall, streaming from disk — never loading a whole file into memory.
- **MR-TX-4** Cancel at any time → stop uploads, `POST /cancel`, leave nothing half-claimed.
- **MR-TX-5** Large files (≥ 1 GB) must not exhaust memory.

### Receive
- **MR-RX-1** A listening server on `53317` while the app is foregrounded (iOS) / while the foreground service runs (Android).
- **MR-RX-2** **Consent before anything is written.** Show sender alias/device, file count, total size, names. Accept / Decline. Declining returns `403` and creates no session and no file.
- **MR-RX-3** File names are untrusted: confine to the destination (protocol §7.2).
- **MR-RX-4** Never overwrite (protocol §7.3). A truncated/cancelled upload deletes its partial (protocol §7.4).
- **MR-RX-5** Tokens: per file, per session, unguessable; wrong token ⇒ `403` and no write.
- **MR-RX-6** Save location is visible to the user and reachable from the app (Files on iOS; scoped storage on Android).
- **MR-RX-7** Optional: verify `sha256` and answer `422` on mismatch.

### Protocol conformance
- **MR-PR-1** Wire format exactly per the protocol doc; JSON key names and optionality are the contract.
- **MR-PR-2** Server reads the request head up to `\r\n\r\n` then the body by `Content-Length`, **independent of how the bytes are split across reads** (V1).
- **MR-PR-3** Decoders tolerate a missing `port`/`protocol` in `/info` and `register` responses (V4) and ignore unknown fields.
- **MR-PR-4** `Transfer-Encoding: chunked` ⇒ `411`; `Expect: 100-continue` is honoured.
- **MR-PR-5** Interoperates with: Halo desktop, the other mobile platform, and the official LocalSend app, in both directions (D5).

### App shell
- **MR-SH-1** Tabs: **Share** (peers, send, receive), **Inbox** (received files), **Settings** (device name, save location, about).
- **MR-SH-2** A persisted device alias (default derived from the device name) and a persisted random fingerprint.
- **MR-SH-3** The Firebase/SMS/clipboard areas appear as clearly-labelled *"needs the Halo cloud foundation (F-044)"* rows, not as dead buttons.
- **MR-SH-4** First-run explains the Local Network permission *before* the OS prompt appears (iOS).

### OS integration
- **MR-OS-1** *(Android)* Sharesheet target (`ACTION_SEND`/`SEND_MULTIPLE`). *(iOS)* Share Extension. — **Deferred past the MVP**, §9.
- **MR-OS-2** *(Android)* Foreground service keeps receive + transfer alive in the background with a notification. *(iOS)* Best-effort: stay alive for a transfer in flight while foregrounded; disable the idle timer; no promise when suspended.
- **MR-OS-3** Keep the device awake for the duration of a transfer.

## 5. Non-functional requirements

- **Security:** consent gate; confinement + no-overwrite; no secrets in logs; Local Network permission requested only when needed. `http` is accepted as a stated trade-off (MD1).
- **Privacy:** nothing leaves the LAN. No analytics, no Firebase in this milestone.
- **Performance:** throughput within ~20 % of the official app on the same network; bounded memory independent of file size.
- **Reliability:** a dropped connection ends the session cleanly on both ends (no zombie sessions, no partial files).
- **Compatibility:** iOS 16+; Android 8.0+ (API 26+).
- **Mobile parity rule:** this document *is* the mobile feasibility artefact for F-050; the portability rows already exist in `HALO_MOBILE_ROADMAP.md`.

## 6. Blocked — and what unblocks it

| Feature | Blocked by | Unblocked when |
|---|---|---|
| F-049 QR pairing + Firebase config | F-044 Phase 0/1 `Halo/Core/Cloud` (not on `release/v2.4`; PR #7) and spikes **S1** (Firebase on macOS) / **S2** (provisioning) | M1 of `BUILD_PLAN.md` is merged and the QR payload format is frozen |
| SMS sync (Android, F-044) | the above + Kotlin↔Swift crypto test vectors | same, plus `READ_SMS` rationale + security review |
| Clipboard sync (F-045) | the above + the Android capture strategy decision (AccessibilityService vs IME) | same |

None of these are started. Starting them against an unfrozen contract would produce code that has to be thrown away.

## 7. Verification strategy

1. **Unit:** protocol codec, filename confinement, HTTP head parsing, session/token logic — on every platform, same cases.
2. **Loopback integration:** our server ⇄ our client, with binary payloads that are not valid UTF-8, large files, cancel, decline, wrong token, truncated body.
3. **Independent client:** `curl` against our server — one-write and `Expect: 100-continue` shapes. This is the test that would have caught V1.
4. **Cross-implementation:** our client ⇄ the **real desktop server** (opt-in live test, as AC-1 did for Lethe); our server ⇄ the **real desktop client**.
5. **On device:** iOS Simulator and Android emulator running the real apps against a Mac-side peer. *Physical devices and the official LocalSend app are not available to this build environment and remain open.*
6. Rendering/visual: screenshots of the real screens.

## 8. Open decisions for the owner

1. **MD1 — accept plain HTTP for v1?** It matches shipped desktop and keeps interop; it means a hostile peer on the same Wi-Fi who is *accepted by the user* can read the transfer in transit. The alternative (HTTPS serving on mobile) is a larger build and breaks mobile→desktop until desktop also serves TLS.
2. **MD3 — unify desktop onto `HaloShareKit`?** Cheaper now than later, riskier to do blind.
3. **F-044 sequencing** — decide when the cloud foundation (and therefore the rest of F-049) gets built.

## 9. Implementation status

*(kept current as the work lands)*

| Area | iOS | Android |
|---|---|---|
| Protocol contract written | ✅ `HALOSHARE_PROTOCOL.md` | ✅ (shared) |
| Desktop receive fixed (V1–V4) | ✅ `fix/haloshare-binary-upload` | — |
| Protocol core + tests | ✅ `ios/HaloShareKit` — 56 tests | ⏳ |
| Discovery (scan + manual) | ✅ HTTP /24 scan + manual address (multicast: not on iOS, §3 MD2) | ⏳ |
| Send / Receive + consent | ✅ library **and app**: Mac→phone (consent, SHA-256 identical), decline (exit 3, nothing written), phone→Mac (5 MB exact) — iOS Simulator | ⏳ |
| App shell | ✅ `ios/HaloMobile` — Share / Inbox / Settings, consent sheet, cloud placeholders | ⏳ |
| Share extension / Sharesheet | ❌ deferred | ❌ deferred |
| Background receive | ❌ deferred | ❌ deferred |
| Official-LocalSend interop | ❌ not testable here | ❌ not testable here |
| Cloud features (SMS, clipboard, pairing) | 🚫 blocked (§6) | 🚫 blocked (§6) |

### 9.1 iOS verification record (2026-10-23, iOS Simulator, iPhone 17)

Driven through the real app UI against the Kit's CLI peer on the Mac:

| Flow | Result |
|------|--------|
| Launch | "Ready to receive · port 53317"; cloud rows labelled "Not yet" (MR-SH-3) |
| Mac → phone, 3 MB binary | Consent sheet showed sender, file name and size; **nothing in `Documents/Received` before Accept**; after Accept the file's SHA-256 matched the original |
| Mac → phone, declined | Sender got "declined by receiver" (exit 3); **no file, no partial** |
| Phone → Mac, 5 MB | Added the Mac by address, selected it, sent; app showed "Sent halo-test-5MB.bin"; Mac held exactly 5,242,880 bytes |
| Manual address | `127.0.0.1:53318` → found "Gokul's Mac" |

A usability defect found by driving it: the keyboard could not be dismissed once the address field was focused and covered the Send button. Fixed (Done button, interactive scroll-dismiss, dismiss on Add).

**Not verified:** the system file picker (the Debug "send test file" exercises the same send path), the HTTP /24 scan against a real LAN peer, Local Network permission prompts, physical devices, the official LocalSend app.
