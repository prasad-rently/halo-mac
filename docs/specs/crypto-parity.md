# Crypto Parity Contract (F-044 D27 / F-049 D5)

> The one non-negotiable interop requirement for Halo's cross-device features: every
> platform must derive the **same key** and read each other's **ciphertext**. This
> doc + [`crypto-parity-vectors.v1.json`](crypto-parity-vectors.v1.json) are the
> canonical contract. The desktop Swift `CryptoService` is the reference
> implementation; the Android **Kotlin** port must reproduce these vectors
> byte-for-byte (iOS reuses the Swift impl directly, so it's parity-free).

---

## 1. The algorithm (authoritative)

| Stage | Spec |
|-------|------|
| **KDF** | PBKDF2-HMAC-**SHA256**, **200 000** iterations, **32-byte** (256-bit) output |
| Passphrase → bytes | Unicode **NFC** normalization ("precomposed"), then **UTF-8** |
| Salt | raw bytes (16), non-secret; travels in the pairing QR / `meta/{uid}` |
| **Cipher** | **AES-256-GCM** |
| Nonce | **12 random bytes** per message (never reused under a key) |
| Wire format | `nonce(12) ‖ ciphertext ‖ tag(16)`, then **base64** (CryptoKit "combined" box) |
| AAD | **none** |

Reference: [`Halo/Core/Cloud/CryptoService.swift`](../../Halo/Core/Cloud/CryptoService.swift).

## 2. The vectors

[`crypto-parity-vectors.v1.json`](crypto-parity-vectors.v1.json) has two kinds:

- **`kdfVectors`** — `{passphrase, saltB64, iterations} → derivedKeyB64`. Deterministic:
  the Kotlin KDF must produce **exactly** `derivedKeyB64`. This is the strongest anchor.
- **`decryptVectors`** — `{passphrase, saltB64, ciphertextB64} → plaintext`. The Kotlin
  cipher must **decrypt** `ciphertextB64` to `plaintext`. Because the nonce is random,
  parity is validated by *decrypting Swift-sealed data*, not by re-encrypting.

**Regenerate:** `swift scripts/gen_crypto_vectors.swift` (mirrors `CryptoService`).
**Authority:** `HaloTests/CryptoParityTests.verify` re-checks the committed JSON against
the real `CryptoService` — if the file or the code drifts, that test fails.

## 3. Kotlin (Android) implementation notes — the landmines

These are exactly what the vectors catch. Get them wrong and keys/ciphertext diverge.

1. **PBKDF2 password bytes.** The JCE `PBKDF2WithHmacSHA256` + `PBEKeySpec(char[])`
   path has historically been inconsistent about how the password `char[]` becomes
   bytes. **Do not** rely on it. Feed the **UTF-8 bytes** of the NFC-normalized
   passphrase to a byte-oriented PBKDF2 — e.g. BouncyCastle
   `PKCS5S2ParametersGenerator(SHA256Digest())` with `.init(utf8Bytes, salt, 200_000)`
   and `generateDerivedParameters(256)`. Verify against `kdfVectors` before anything else.
2. **NFC first.** `java.text.Normalizer.normalize(pass, Normalizer.Form.NFC)` **then**
   `.toByteArray(Charsets.UTF_8)`. (The `café☕` vector fails if you skip NFC.)
3. **AES-GCM layout.** Split the base64 blob as `nonce = bytes[0..<12]`,
   `ctAndTag = bytes[12...]`. `Cipher.getInstance("AES/GCM/NoPadding")` with
   `GCMParameterSpec(128, nonce)` (128-bit tag). Java expects the **tag appended to
   the ciphertext**, which matches CryptoKit's combined box — so pass `ctAndTag`
   directly. No AAD (`updateAAD` not called).
4. **Encrypt direction.** When Android encrypts, generate a fresh 12-byte random nonce,
   prepend it, append is automatic (Java GCM appends the tag), base64 the whole thing.
   A Swift test will later decrypt Kotlin-produced samples to validate the reverse.
5. **Argon2id** is the documented future KDF upgrade (F-044 §7.1). When adopted, bump
   the vectors to `v2` and keep `v1` for migration.

## 4. iOS

iOS links the desktop `Halo/Core/Cloud` Swift package unchanged — same `CryptoService`,
so it is parity-correct by construction. No separate vectors needed.
