# Phone wire contract fixtures

`phone-nodes.v1.json` is the set of Realtime Database nodes the **Android app** writes
(device registry, SIM lines, SMS messages, clipboard items), together with what the desktop
must read back from each (`expect`). Both sides test against the one file:

| Side | Test | Does |
|---|---|---|
| Swift (desktop) | `HaloTests/DesktopHardeningTests.swift` -> `WireContractTests` | decodes every `node` through `SMSWire` / `ClipboardSyncEnvelope.from`, decrypts, asserts `expect` |
| Kotlin (phone) | `android/halocloud` — H-20b (not on this branch) | reproduces every `node` and decrypts to `expect` |

## What is real and what is not

* Every `node` was produced by the **real Kotlin writers** in `android/halocloud`
  (`SmsWire.deviceNode`, `SmsWire.lineNode`, the message writer inside `SmsSyncEngine.sync()`,
  `ClipboardEnvelope.node()`) — not typed by hand. That is why `ownNumber` on line 2 reads
  `"Unknown"`: it is the writer's own `ifBlank { "Unknown" }` for a SIM with no number.
* **The one-off capture harness was not committed.** The procedure below is how the file was
  made and how to make it again; until the Kotlin regenerate-and-diff test (H-20b) exists on
  the android branch, "captured from Kotlin" is a statement about provenance, not something
  CI re-proves. Treat a hand edit to this file as a bug.
* Only **test values** are in it: passphrase `contract test passphrase 1`, a sequential salt
  (`01 02 … 10`), uid `uid-contract`, device `dev-A` / `Pixel 8`, a made-up Indian number, and
  example message / clipboard text. No real account, key, number or message. Keep it that way.

## Reading the file

* **Key derivation:** PBKDF2-HMAC-SHA256(`passphrase`, base64-decode(`saltBase64`), `iterations`) ->
  AES-256-GCM. Envelope: `v1:` + base64(nonce(12) | ciphertext | tag(16)). `iterations` is
  100 000, the minimum the app accepts (`CryptoService.MINIMUM_ITERATIONS`) — about 10 s per
  derivation in a Debug Swift build, so the Swift suite derives once and caches.
* **Random nonces.** Every `*Enc` field changes on every write. Never compare an `*Enc` value
  byte for byte: mask every field whose name ends in `Enc`, compare all other fields exactly,
  and compare the **decrypted** `*Enc` values to the entry's `expect`.
* `paths` documents the node locations (`{uid}`, `{deviceId}`, …) the keys hang off.
* `syncEnabledPresentInNode: false` marks a line the phone wrote before the desktop ever
  toggled it (no `syncEnabled` field in the node; the desktop reads that as `true`).

## Sent messages (`sent`)

The phone's opt-in "Also sync messages I send" writes the user's own outgoing SMS to
`sms/{uid}/{deviceId}/sent/{smsId}_{dateMs}` — a **sibling of `messages`**, deliberately not a `type: 2` row inside it. A desktop
build that predates this observes `messages` only and never looks at `sent`, so an old Mac cannot show (or notify for) the user's own
text as something they received. The node shape is the message node's with `type` 2 and `addressEnc` = the **recipient**; its
`threadKey` equals the one an inbox row from the same contact on the same line gets. The `sent` entry was produced by the real Kotlin
writer (`SmsWire.sentMessageNode`); `WireContractTests.sentMessages` decodes it with `SMSWire.message(..., node: .sent)`. No
Realtime Database rule change: `sms/$uid` already grants the owner read/write below it, and the desktop never queries `sent` by `date`.

## How it was captured / how to regenerate

Run from `android/` (JVM only, no emulator, no network, no Firebase):

1. Add a throwaway JUnit test under `android/halocloud/src/test/kotlin/app/halo/cloud/`
   (next to `SmsSyncEngineTest.kt`, which already has the `FakeSource` / `harness` shape to copy).
2. Build the crypto exactly as the fixture's `crypto` block says:
   `CryptoService.create("contract test passphrase 1", ByteArray(16) { (it + 1).toByte() }, CryptoService.MINIMUM_ITERATIONS)`.
3. `val db = FakeRtdb("uid-contract")`; build a `SmsSyncEngine(db, crypto, "dev-A", "Pixel 8", source, MemorySyncState(), clock = { 1_800_000_000_000L })`
   over a fake `SmsSource` with two SIM lines (subscription 1 `Personal` / `Airtel` / `+919876543210`;
   subscription 2 `Work` / `Jio` / no number) and the two inbox messages listed in the file.
   Before the sync, put `syncEnabled = false` on line 2 (`sms/uid-contract/dev-A/lines/2/syncEnabled`) to
   model the desktop having switched it off — that is the "desktop-toggled" line.
4. Call `engine.sync()`, then read back `db.dump("devices/uid-contract/dev-A")` and
   `db.dump("sms/uid-contract/dev-A")` — those are the `device`, `lines` and `messages` `node`s.
5. For clipboard, build `ClipboardEnvelope(...)` for the three items (`text`, `code`, `url`)
   with `crypto.encrypt(text)` as `contentEnc`, and take `envelope.node()`.
6. Write the `expect` blocks from the **plaintext you fed in** (not by decrypting the output —
   the point is that the output decrypts to what went in).
7. Emit the JSON in the same shape as the committed file and diff it. Everything except the
   `*Enc` values must match byte for byte; the `*Enc` values differ run to run (random nonce) —
   decrypt them and compare to `expect`.

If a wire field intentionally changes, change it in the Kotlin writer, regenerate, update the
Swift decoder and bump `version` in the same change. The Swift and Kotlin suites must never
disagree about what is in this file.

## Kotlin side (H-20b) — merged with the integrated Android app

* Kotlin (`android/halocloud/.../WireContractTest.kt`) re-runs the real writers over the fixture's scenario and
  requires every `node` to match (field names, value types, and the plaintext behind each `*Enc` field), and the
  fixture to open under its documented key. The table row above that says "not on this branch" predates this merge.
* Ciphertext is randomly nonced: never compare `*Enc` bytes.
* **Additive fields:** since H-21b a line node also carries `lineVersion` and `updatedAt` (the phone bumps them only
  when the label / carrier / own number change). The Kotlin test allows exactly those two extras on `lines` and
  asserts them separately; fold them into the fixture once both sides have merged (regenerate in BOTH languages in
  the same change).
