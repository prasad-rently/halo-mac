# Crypto Parity Contract (F-044 D27 / F-049 D5) — v2

> The one non-negotiable interop requirement for Halo's cross-device features: every
> platform must derive the **same key** and read each other's **ciphertext**. This
> doc + [`crypto-parity-vectors.v2.json`](crypto-parity-vectors.v2.json) are the
> canonical contract. The desktop Swift `CryptoService` is the reference
> implementation; the Android **Kotlin** port (`android/halocloud`) reproduces these
> vectors byte-for-byte (iOS reuses the Swift impl directly, so it is parity-free).
>
> **v2 supersedes v1** (v2.5). v1 had no envelope version, 200 000 PBKDF2 rounds and no
> passphrase floor; every v1 input is still *readable* under v2 — see "Legacy" below.

---

## 1. The algorithm (authoritative)

| Stage | Spec |
|-------|------|
| **KDF** | PBKDF2-HMAC-**SHA256**, **600 000** iterations by default, **32-byte** (256-bit) output |
| KDF floors | passphrase non-empty · salt **≥ 16 bytes** · iterations **≥ 100 000** — anything below is refused, never "made to work" |
| Passphrase → bytes | Unicode **NFC** normalization ("precomposed"), then **UTF-8** |
| Salt | raw bytes (16), non-secret; travels in the pairing QR / `meta/{uid}` |
| Iteration count | **stored with the salt** (`CloudConfigStore.kdfIterations`, pairing payload schema 2) so raising the default never orphans a key |
| **Cipher** | **AES-256-GCM** |
| Nonce | **12 random bytes** per message (never reused under a key) |
| **Envelope (v1)** | `"v1:"` + **base64**( `nonce(12) ‖ ciphertext ‖ tag(16)` ), **AAD = `halo.cloud.v1`** |
| Legacy envelope (v0) | base64( `nonce ‖ ciphertext ‖ tag` ), **no AAD** — **read-only**, nothing writes it |

The `v1:` prefix is *authenticated* (it selects the AAD). A v1 body with its prefix
stripped, or a v0 body wearing a `v1:` prefix, **fails authentication** — the prefix
cannot be removed or forged to downgrade a message. `rejectVectors` pins this.

### Passphrase policy (a floor for *choosing* a key, not for unlocking one)

≥ **12** characters and ≥ **6** distinct characters, counted as **user-perceived characters
(grapheme clusters) after NFC normalisation** — Swift's `String.count`, **not** UTF-16
length. A port that counts code units gets `"é" × 6` wrong (12 code units, 6
characters); `passphraseVectors` includes that case on purpose. Enforced where a key is
*created* (desktop setup, re-key); at unlock it only warns, so a pre-existing weak key is
never locked out. `deriveKey` itself does **not** enforce it.

### Pairing payload (the desktop → phone QR)

JSON, base64-encoded. Fields: `firebaseConfig`, `auth`, `saltBase64`, `schema`, `iterations`,
`checksum`. `checksum` = SHA-256 hex over the `|`-joined fields
`apiKey|projectID|googleAppID|gcmSenderID|databaseURL|storageBucket("" if none)|email|password|saltBase64|schema`
and, **from schema 2 only**, `|iterations`.

- **Schema 1** has no `iterations` and no `schema` it covers; a decoded schema-1 payload
  means **200 000** rounds, and its checksum formula is frozen so old payloads still validate.
- **Schema 2** covers `iterations`, so the cost cannot be downgraded in transit.

Reference: [`Halo/Core/Cloud/CryptoService.swift`](../../Halo/Core/Cloud/CryptoService.swift),
[`CloudModels.swift`](../../Halo/Core/Cloud/CloudModels.swift).
Kotlin: [`android/halocloud`](../../android/halocloud/src/main/kotlin/app/halo/cloud/).

## 2. The vectors

[`crypto-parity-vectors.v2.json`](crypto-parity-vectors.v2.json):

| Section | Contract |
|---|---|
| `kdfVectors` | `{passphrase, saltB64, iterations} → derivedKeyB64`. Deterministic — must match **exactly**. Includes the legacy 200 000 cost and a passphrase typed **decomposed** (so skipping NFC fails). |
| `decryptVectors` | v1 envelopes sealed by Swift → must decrypt to `plaintext`. (Random nonce, so parity is by *decrypting*, not re-encrypting.) |
| `legacyDecryptVectors` | v0 boxes (200 000 rounds, no prefix, no AAD) → must still decrypt. |
| `rejectVectors` | prefix-stripped v1 and prefix-forged v0 → must fail with *decryptionFailed*. |
| `passphraseVectors` | `passphrase → "ok" \| "tooShort:N" \| "tooRepetitive"`. |
| `pairingVectors` | QR payloads → `valid`, `schema`, `iterations`, `saltB64` (incl. a schema-2 payload whose iterations were downgraded after the checksum was made → `valid: false`). |

**Regenerate:** `swift scripts/gen_crypto_vectors.swift` (from the repo root; mirrors `CryptoService`).

**Authorities — drift on either side fails a test:**
- Swift: `HaloTests/CloudFoundationTests.swift` → `CryptoParityTests` re-checks the committed JSON against the **real** `CryptoService` / `PassphrasePolicy` / `CloudPairingPayload`.
- Kotlin: `android/halocloud` → `ParityTest` reads the **same file** (`./gradlew :halocloud:test`).

### Both directions

Swift → Kotlin is the vectors file. **Kotlin → Swift** is an opt-in pair, because it needs one
suite to run before the other:

```bash
# 1. Kotlin seals a box and writes it out
cd android && HALO_KOTLIN_SEALED_OUT=/tmp/k.json ./gradlew :halocloud:test
# 2. Swift opens it
TEST_RUNNER_HALO_KOTLIN_SEALED=/tmp/k.json xcodebuild test -project Halo.xcodeproj -scheme HaloTests \
  -destination 'platform=macOS' -only-testing:HaloTests/CryptoParityTests   # (+ the unsigned-test flags in CLAUDE.md)
```

Verified once for v2.5: both directions pass.

## 3. Kotlin (Android) implementation notes — the landmines

These are exactly what the vectors catch. Get them wrong and keys/ciphertext diverge.

1. **PBKDF2 password bytes.** The JCE `PBKDF2WithHmacSHA256` + `PBEKeySpec(char[])` path
   differs between JDK and Android providers in how the password `char[]` becomes bytes.
   **Do not** rely on it. `halocloud` implements PBKDF2 directly over `HmacSHA256` with the
   UTF-8 bytes of the NFC-normalised passphrase (a single block, since dkLen = hLen = 32).
2. **NFC first** — `java.text.Normalizer.normalize(pass, NFC)` **then** UTF-8. The
   `nfc-decomposed` KDF vector fails without it (mutation-checked).
3. **AES-GCM layout.** `nonce = bytes[0..<12]`, `ctAndTag = bytes[12...]`;
   `AES/GCM/NoPadding`, `GCMParameterSpec(128, nonce)`. Java expects the tag **appended**,
   which matches CryptoKit's combined box. **v1 calls `updateAAD("halo.cloud.v1")`; v0 does not.**
4. **Encrypt direction.** Fresh random 12-byte nonce, prepend it, base64, and add the `"v1:"` prefix.
5. **Grapheme counting.** `PassphrasePolicy` must count grapheme clusters (`java.text.BreakIterator`),
   not `String.length`. JDK 17's `BreakIterator` is *not* full extended-grapheme aware (JDK 20+ is), so
   exotic sequences — emoji ZWJ families, flags — can count differently from Swift. The shared vectors
   pin the common cases (combining marks, symbols); treat the policy as a floor, not a bit-exact rule.
6. **Argon2id** remains the documented future KDF upgrade (F-044 §7.1). When adopted: add `v3`
   vectors, keep v2's legacy sections for migration.

## 4. iOS

iOS links the desktop `Halo/Core/Cloud` Swift sources unchanged — same `CryptoService`, so it is
parity-correct by construction. No separate vectors needed.

## 5. Transport note (affects F-049 Android)

The desktop cloud client does **not** use firebase-ios-sdk: it speaks the Identity Toolkit and RTDB
REST APIs directly (see the header of `FirebaseRTDBClient.swift` — the SDK cannot sign in from a
DMG signed without a provisioning profile). Android may use the Firebase Android SDK or the same
REST calls; either interoperates, because the **data** contract is the one above and the RTDB
paths in `docs/specs/F-044-shared-sms-console.md`.
