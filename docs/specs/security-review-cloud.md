# Security Review — Cloud Branch (F-044 / F-045 / F-048 / F-049)

> Focused security review of the `feature/f-044-cloud-foundation` branch (cloud
> foundation, SMS console, clipboard sync, expenditure tracker, crypto-parity
> contract). Scope: vulnerabilities *newly introduced* by this branch.
> **Date:** 2026-07 · **Reviewer:** security-review pass.

---

## Summary

**No HIGH or MEDIUM findings at ≥8 confidence.** The new cloud code follows sound
practices for its threat model (BYOB Firebase, client-side end-to-end encryption).

| Area | Assessment |
|------|-----------|
| **Crypto** (`CryptoService`) | PBKDF2-HMAC-SHA256 (200k iters, 32-byte key) + AES-256-GCM (CryptoKit, random per-message nonce, combined box). No nonce reuse, no hardcoded keys, no weak algorithms, `SecRandomCopyBytes` for randomness. Sound. |
| **Secret storage** (`CloudConfigStore`) | config/auth/salt/passphrase in Keychain (`kSecAttrAccessibleAfterFirstUnlock`), wiped on disconnect. Correct secure storage. |
| **OAuth** (`GoogleOAuthPKCE`) | S256 PKCE, loopback redirect (custom URI schemes avoided), `state` carried. Request builders only — no callback-handling code to attack yet. |
| **RTDB paths** | built from Firebase child keys / UUIDs within the user's own `{uid}` namespace; Firebase rejects `/ . $ # [ ]` in keys → no path traversal, no cross-tenant surface. |
| **Deserialization** | remote data parsed as `[String: Any]` dicts + JSON `Codable`; decryption failures handled (`try?`); no `NSKeyedUnarchiver`/unsafe unarchiving → no RCE surface. |
| **Committed test vectors** | `crypto-parity-vectors.v1.json` holds *test* passphrases/keys/ciphertext, not real secrets — intended. |

---

## Below reporting threshold (informational, not blocking)

### 1. CSV formula injection — `ExpenditureViewModel.exportCSV()`
`merchant`/`sender` reach an exported CSV a user may open in Excel. Normally a
formula-injection candidate, but exploitability is **low**: `merchant` is
regex-anchored to a leading `[A-Z0-9]`, `sender` is a DLT header
(alphanumeric/hyphen), and `body` isn't exported — so cells can't begin with
`= + - @` in practice. **Optional hardening:** prefix any cell starting with those
characters with a `'`. (Confidence < 8 → not a formal finding.)

### 2. Reliance on user-deployed RTDB rules
Owner-only isolation of `sms|clipboard|devices|meta/{uid}` depends on the user
deploying the firebase-setup §7.2 rules. A user who leaves their RTDB in "test
mode" exposes their own data to any authenticated principal. This is a documented
BYOB deployment step, not a client-code defect — but the setup UI could **deploy
the rules for the user** (it currently doesn't). Worth folding into the F-049
assisted-provisioning work as a real-world hardening.

---

## Verdict

Branch is clean from an exploitable-vulnerability standpoint. The one substantive
real-world hardening opportunity is **automated RTDB-rules deployment** (item 2) —
a configuration-safety improvement, not a code vulnerability. The CSV cell-prefix
guard (item 1) is optional defense-in-depth.
