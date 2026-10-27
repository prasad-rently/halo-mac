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

---

## v2.5 addendum (2026-10) — what the July review did not catch

The July pass found no exploitable vulnerability. Verifying the branch before merging it found these, all fixed in v2.5:

| Finding | Severity | Fix |
|---|---|---|
| `CryptoService.randomBytes` / `PKCE.generate` ignored the `SecRandomCopyBytes` status → an RNG failure returned zero bytes that looked valid (zero KDF salt; constant, publicly known PKCE verifier) | Critical (PR #7 review #1, #2) | Throw; a test injects a failing RNG |
| No passphrase floor — `"a"` accepted | Critical (#3) | `PassphrasePolicy`; hard at creation, advisory at unlock |
| No envelope version; weak KDF preconditions; 200 000 rounds; key not wiped; wrong error type; over-broad hex filter | Medium/Low (#4–#10) | `v1:` envelope + AAD, preconditions, 600 000 rounds persisted with the salt, wipe, `encryptionFailed`, 64+ hex |
| **New-SMS notifications carried the first 120 characters of the decrypted message** — onto the lock screen, and via `AlertManager.fireExternal` into plaintext `AlertLog` and the PDF report. An SMS routinely holds an OTP or a balance, so this wrote exactly what the E2E encryption protects to disk in the clear | **High** | Sender only |
| **firebase-ios-sdk cannot sign in from a DMG** (data-protection keychain needs a restricted entitlement; the build carrying it is killed at launch) — the cloud features would have shipped non-functional | High (availability) | REST client, in-memory tokens |
| The ID token travels in the URL query and Sentry's network breadcrumbs record URLs | Medium (opt-in telemetry) | `CloudTelemetryScrubber` on every Sentry hook |
| Password-manager copies were recorded and, with F-045 on, uploaded | Medium | nspasteboard.org markers honoured |
| A database left in test mode was invisible to the user | Medium (config safety) | "Test connection" warns when an unauthenticated read succeeds (the review's item 2, partly: it *detects* open rules; it still does not *deploy* the safe ones) |
| CSV export formula guard (review item 1) | Low | `'` prefix on text cells |
| HaloShare desktop client trusted **any** TLS certificate from an https peer | Medium | Pinned to the announced fingerprint, fail-closed (§6/§8.9 of `HALOSHARE_PROTOCOL.md`) |

**Still true / not done:** no live end-to-end test against a real Firebase project; owner-only isolation still depends on the user publishing the rules (now *detected*, not *deployed*); `docs/specs/crypto-parity-vectors.v1.json` no longer exists — v2 carries the legacy vectors.
