# HaloShare protocol reference (LocalSend v2.x)

> **Purpose:** the single cross-platform contract for HaloShare — desktop (Swift, `Halo/Core/LocalShare`),
> iOS (Swift, `ios/HaloShareKit`) and Android (Kotlin, `android/haloshare`). This is F-050's
> "Phase 0: protocol reference". Where the three implementations disagree, **this document wins** and the
> implementation is the bug.
>
> **Sources:** the published [LocalSend protocol](https://github.com/localsend/protocol) (checked
> 2026-10-23; the document is titled v2.2 and contains no v2.1-specific section, while examples show
> `"version": "2.0"`), plus what the shipped desktop code actually does. Where those differ it is called out in §8.

---

## 1. Transport

- **Port:** `53317`, TCP (HTTP) and UDP (multicast discovery).
- **Scheme:** `http` or `https`, announced per peer in its `protocol` field. **Halo desktop serves plain
  `http` and announces `"protocol": "http"`** (`LocalShareServer` is started with `httpParameters()`; the
  self-signed certificate `TLSManager` builds is used only to derive a fingerprint). A Halo mobile peer
  therefore talks plain HTTP to desktop. It must also *speak* `https` to peers that announce it (the official
  apps default to it) — see §6 for how that is pinned.
- All bodies are JSON (`application/json`) except `upload`, whose body is the raw file
  (`application/octet-stream`).
- **Framing:** requests carry `Content-Length`. `Transfer-Encoding: chunked` is **not** accepted
  (`411`) — LocalSend does not send it. A server must read the head up to `\r\n\r\n` and then the body by
  `Content-Length`; it **must not** assume the head and body arrive in separate network reads (§8.1).

## 2. Data types

```jsonc
// DeviceInfo — multicast announcement, register request, prepare-upload "info"
{ "alias": "Nice Orange",            // user-visible name
  "version": "2.1",                  // protocol version string
  "deviceModel": "Pixel 9",          // nullable
  "deviceType": "mobile",            // nullable; mobile | desktop | web | headless | server
  "fingerprint": "…",                // §6
  "port": 53317,
  "protocol": "http",                // http | https
  "download": false,                 // optional, default false (receive-only peers)
  "announce": true }                 // multicast only: true = announcement, false = reply
```

> **`/info` and `register` *responses* omit `port` and `protocol`.** A decoder must default them (53317 and the
> scheme it just used) rather than fail. Halo desktop's decoder used to require both (fixed — §8.2).

```jsonc
// FileMetadata (one entry of prepare-upload "files", keyed by id)
{ "id": "f1", "fileName": "photos/2026/a.jpg", "size": 123456, "fileType": "image/jpeg",
  "sha256": null, "preview": null,
  "metadata": { "modified": "2026-10-23T10:00:00Z", "accessed": null } }

// prepare-upload request / response
{ "info": DeviceInfo, "files": { "<fileId>": FileMetadata } }
{ "sessionId": "…", "files": { "<fileId>": "<token>" } }
```

## 3. Endpoints

| Purpose | Request | Notes |
|---|---|---|
| Identity | `GET /api/localsend/v2/info` | Debug/probe. Response: DeviceInfo (no port/protocol). |
| Register | `POST /api/localsend/v2/register` + DeviceInfo | Response: the callee's DeviceInfo. Used by the HTTP scan fallback. |
| Prepare | `POST /api/localsend/v2/prepare-upload[?pin=…]` | Triggers the **receiver's consent prompt**. `200` + `{sessionId, files:{id:token}}` to accept. |
| Upload | `POST /api/localsend/v2/upload?sessionId=&fileId=&token=` | Raw bytes. One request per file. |
| Cancel | `POST /api/localsend/v2/cancel?sessionId=` | Either side. Discards the session. |

`prepare-download` / `download` (the reverse-pull flow used by the web UI) are **out of scope** for HaloShare.

### Status codes

| Endpoint | Code | Meaning |
|---|---|---|
| prepare-upload | `200` | Accepted. |
|  | `204` | Finished; nothing to transfer. |
|  | `400` | Invalid body. |
|  | `401` | PIN required / wrong PIN. *(Halo does not implement PINs in v1.)* |
|  | `403` | **Rejected by the user** (or by policy). The sender must treat this as "declined", not as an error to retry. |
|  | `409` | Blocked by another session. |
|  | `429` | Too many requests. |
|  | `500` | Receiver error. |
| upload | `200` | File stored. |
|  | `400` | Missing params, or **incomplete body** (peer closed early). |
|  | `403` | Invalid token. |
|  | `404` | Unknown session / file. |
|  | `409`, `422`, `500` | Blocked / **sha256 mismatch** / receiver error. |

## 4. Sequence

```
Sender                                        Receiver
  │  GET /info  (probe)  ───────────────────────►│
  │◄──────────────────────────  DeviceInfo ──────│
  │  POST /prepare-upload {info, files} ────────►│  ── user sees "Accept N files from <alias>?"
  │◄──────  200 {sessionId, files:{id:token}} ───│      (declined → 403, nothing is written)
  │  POST /upload?sessionId&fileId&token  <bytes>►│  (one per file; may run concurrently)
  │◄──────────────────────────────  200 ─────────│
  │  … or POST /cancel?sessionId ───────────────►│  → receiver deletes partial files
```

A session is complete when every file in it has been uploaded. Tokens are **per file, per session** and
single-purpose; an upload with a wrong token writes nothing.

## 5. Discovery

1. **Multicast (UDP `224.0.0.167:53317`).** On start, announce a DeviceInfo with `announce: true`. A peer that
   hears an announcement replies — preferably by `POST /register` to the sender, else by a UDP datagram with
   `announce: false`. Re-announce periodically (desktop: every 30 s).
2. **HTTP scan (fallback).** Probe every host in the local /24 with `GET /info` (or `POST /register`) on 53317,
   short timeout, bounded concurrency. Slower, but needs no multicast.
3. **Manual address.** The user types `host[:port]`. Always available; required on networks that block both of
   the above and in simulators/emulators whose network is NATed.

Ignore your own fingerprint when you see yourself.

**Platform reality (decides what each mobile client can do):**

| | Announce (multicast send) | Listen (multicast receive) | HTTP scan | Manual |
|---|---|---|---|---|
| macOS | ✅ | ✅ | ✅ | ✅ |
| **iOS** | ❌ needs the restricted `com.apple.developer.networking.multicast` entitlement (Apple approval) | ❌ same | ✅ (needs Local Network permission) | ✅ |
| Android | ✅ (hold a `MulticastLock`) | ✅ (`MulticastLock`) | ✅ | ✅ |

So an iPhone running Halo is **found by others only through *their* HTTP scan**, and finds others by scanning.
That is a degraded-but-working design, not a bug; it is why the HTTP scan is a first-class path here.

## 6. Fingerprint and trust

- **`http` peers:** the fingerprint is an arbitrary random string. It is an *identity for de-duplication*, not a
  credential — anyone on the LAN can claim any value. Receive consent is the only gate.
- **`https` peers:** the fingerprint is the lower-case hex **SHA-256 of the peer's DER certificate**. A Halo
  client connecting to an `https` peer **must** compare the presented certificate's SHA-256 to the fingerprint
  that peer announced, and refuse on mismatch. (Desktop's current `URLSession` delegate trusts every
  certificate unconditionally — acceptable only because desktop never uses `https` today; §8.3.)
- Halo peers generate their fingerprint once and persist it.

## 7. Receiver obligations

1. **Consent first.** Nothing is written, and no session exists, until the user accepts. Declined ⇒ `403`.
2. **File names are untrusted.** Keep legitimate sub-folders; drop `..`, `.`, empty components, absolute
   prefixes and NUL; treat `\` as a separator; verify the final path is inside the chosen folder.
3. **Never overwrite.** If the destination exists, pick `name (1).ext`, `name (2).ext`, …
4. **Partials don't survive.** A truncated or cancelled upload deletes its partial file and is not
   acknowledged `200`.
5. **Verify when told.** If `sha256` is supplied, hash what was written and answer `422` on mismatch.
6. Keep the device awake during a transfer (desktop: power assertion; Android: wake lock/foreground
   service; iOS: idle-timer disabled while foregrounded).

## 8. Where Halo desktop differed from this contract

Found while starting F-050 and **fixed on `fix/haloshare-binary-upload`** (each with a test that drives the real
server over a real socket, and — for the traversal — a mutation check that the test fails on the old code).

1. **Request framing.** The server did one `receive()`, decoded it as a UTF-8 `String`, and split on a blank line.
   It only worked when headers and body arrived in separate reads (URLSession writes them that way); a binary
   body sharing a read with the headers made `String(data:encoding:)` return `nil` and the server answered
   `400`. Every other HTTP client — curl, OkHttp, Dart's stack, i.e. **a phone and the official app** — sends
   small bodies in one write. Desktop could not receive a file from a phone.
2. **`/info` decoding.** `DeviceInfoDTO` required `port` and `protocol`, which official responses omit.
3. **Path traversal and overwrite.** The sender-supplied `fileName` was appended to the destination directory
   unchanged: `../victim.txt` wrote outside the approved folder, and existing files were overwritten.
4. **Truncated uploads** left a partial file on disk that looked like the real one.

Fixed separately on `fix/haloshare-sha256-verify` (PR #40, stacked on #37):

5. **`sha256` was not verified** on the desktop receive path — the field was carried into the session and
   never compared, so `422` could never be returned and a file that arrived whole but damaged looked normal.
   The receive loop now hashes as it writes (one pass) when the sender supplies a digest; a mismatch answers
   `422` and deletes the file. (Both mobile implementations already verified; this brought desktop in line.)

**Not fixed (tracked as risks in the requirements doc):**

- **§8.6** Desktop's client trusts any TLS certificate; harmless while desktop only uses `http`, wrong the day it
  talks to an `https` peer.
- **§8.7** The desktop's hand-assembled X.509 certificate is built but never used for transport.
- **§8.8** No sender computes a digest yet — desktop forwards `ShareFile.sha256` only if already set, and neither
  mobile app sends one — so verification protects only transfers whose sender supplies it. Receivers all verify
  whenever it is present.
