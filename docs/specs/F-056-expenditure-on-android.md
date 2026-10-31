# F-056 — Expenditure on the Phone (F-048 mobile half)

> **Status:** 🔧 **Built on PR #58 (unmerged; head `5982777`). Independently reviewed (1 real defect fixed).** JVM-verified only: **the real Android Keystore sealing, the Compose "Spend" screen, the permission flow, injected-SMS runs and on-device performance are NOT verified**, and the parser has **known false positives** (§9). Not ✅. Expenditure on the owner's real bank SMS is **V-7**.
> **Parent:** [`F-048-expenditure-tracker.md`](F-048-expenditure-tracker.md) (D16: mobile parses the device's own SMS and shares the pattern pack) · **Raised:** 2026-10-28 (v2.6 BRD §8) · **Effort estimate:** ≈ 7 d (Android)
> **Reserved pbxproj IDs:** none for the Kotlin work. (The shared fixture also adds a Swift test edit — no new Swift file.)
> **Depends on:** PR #55 (SMS permission, `CloudPrefs`) merged into `release/v2.5`; the shared pattern pack `docs/specs/pattern-packs/india-bank-sms.v1.json` · **Plan:** [`../V2_6_PLAN.md`](../V2_6_PLAN.md)

---

## 1. Summary

The phone parses its **own** SMS inbox into a month total, by-category list and recent transactions, **locally**, using the **same** pattern pack as the desktop. Derived amounts are sensitive, so nothing leaves the phone in v2.6 (no cloud sync — v2.7 decision, `V2.7-11`).

## 2. Goals / Non-Goals

**Goals:** one pattern pack and one fixture file shared by Swift and Kotlin; a sealed local ledger; incremental, cancellable parsing; honour the SMS sender filter and per-SIM toggles; a minimal screen.
**Non-Goals (v2.6):** cloud sync of derived data; force-including a non-transactional message (desktop-only UI); category re-assignment UI; background/automatic scanning; iOS; AI-assisted parsing (F-048 Phase 4).

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D1 | The Kotlin classifier is **pack-driven** (the BRD asks for it); the desktop `SmsClassifier.swift` remains a compact hard-coded port. They disagree on 2 of 59 fixtures; in both the parser rejects the message anyway. | Making desktop pack-driven too changes shipped behaviour — a **coordinated Swift + pack + fixture change**, not done here. |
| D2 | The SMS **body is never persisted** — only amount, merchant, category, account tail, sender, date. Category is computed at parse time. | Privacy; desktop keeps the body in memory only. |
| D3 | The ledger is sealed with the existing Keystore `SecretBox`, written temp + `fsync` + rename; an unreadable file reads as empty and rescans (overrides lost — see §9). | No new Keystore code; the seam is the `Sealer`. |
| D4 | Per-SIM toggles for expense are **local** to this feature (the cloud `syncEnabled` flag needs network; this feature has none). | No network in the parse path. |
| D5 | §12 category rules were **not in the pack** (the spec says they should be), so a `categories` block was added to the pack; Swift `ExpenseFixtures.packMatchesJSON` fails if the desktop's embedded copy drifts. | One source of truth. |

## 4. User Stories

- **US-1** I see this month's spend, received and net from my own bank SMS, on my phone.
- **US-2** I can exclude a message that is not a real transaction, and restore it.
- **US-3** I can turn the feature off and wipe the ledger.

## 5. Functional Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| FR-E1 | Kotlin port of `SmsClassifier` + `TransactionParser` driven by the same pack | A shared fixture set passes on Swift **and** Kotlin |
| FR-E2 | Transactional-only filter; F-048 §12 taxonomy; self-transfer and duplicate handling as desktop | Fixtures incl. false-positive cases (OTP with "Rs", promo with amounts) |
| FR-E3 | Local-only sealed store; **no cloud upload in v2.6** | File on disk is ciphertext; no network call in the parse path (test) |
| FR-E4 | Minimal UI: month total, by-category, recent, "exclude this" | Compose screen verified on emulator with injected SMS |
| FR-E5 | Respects the SMS sender filter and per-SIM toggles | Test |
| NFR | Incremental (high-water mark) and cancellable; 10 000 messages < 10 s on the emulator | Measurement |

## 6. Non-Functional Requirements

Amounts and merchants are sensitive: stored only sealed; `allowBackup=false` + extraction rules already exclude app data; no `INTERNET` use in the package (checked by a bytecode/import test); body never written; "Delete & turn off" wipes the ledger (and the `.tmp`). READ_SMS was already declared for F-044; no manifest change, no new exported component.

## 7. Architecture

`android/halocloud` (plain JVM) `app.halo.cloud.expense`: `PatternPack` (parsed from the JSON), `SmsClassifier`, `TransactionParser`, `TransactionPipeline` (self-transfers, ±120 s dedup, overrides), categoriser, `ExpenseLedger` over a `Sealer` seam, `ExpenseIngest`/`ExpenseRuntime`. `halocloud/build.gradle.kts` `processResources` packages only `india-bank-sms.v1.json` into the module (the APK contains it). `android/app` `app.halo.mobile.expense`: **Spend** tab (month stepper, spent/received/net, category bars, recent with Exclude/Restore, scan/stop, per-SIM switches, scan-older, delete & turn off). Shared contract: `docs/specs/pattern-packs/expense-fixtures.v1.json` (59 single-message cases + 7 pipeline cases).

## 8. Acceptance (ship gate)

- **AC-1** Fixtures green on **real Swift** (`HaloTests/ExpenseFixtures`, 3 tests) **and** Kotlin (singles + pipelines in 4 time zones) — ✓ recorded on the PR.
- **AC-2** Ledger on disk is ciphertext; body not persisted; wrong key/tamper reads empty — ✓ **JVM, software AES-GCM**.
- **AC-3** FR-E5 holds for rows already in the ledger (SIM off / deny entry added **after** a scan purges them; re-allowing re-reads) — ✓ JVM, after review fix `5982777`.
- **AC-4** No network in the parse path — ✓ structural.
- **AC-5** 10 000 messages < 10 s — JVM figure only (first scan ≈ 0.36 s, re-scan 21 ms); **emulator/device not measured**.
- **AC-6 (device)** Real Keystore sealing of the ledger; Compose screen, permission flow and injected SMS on an emulator — **not verified**.
- **AC-7 (owner, V-7)** Totals agree with the owner's real bank statements — **not verified**.

## 9. Open Questions & Risks (known issues — recorded, not fixed)

These are the review's **desktop-parity parser false positives**. They are identical on Swift by construction, so fixing any of them is a **coordinated Swift + pack + fixture change** (the fixtures' own rule: "fix desktop and fixture together") and is **v2.7** work unless the owner pulls it forward:

| # | Message shape | Result | Note |
|---|---|---|---|
| K-1 | `Payment of Rs 1,200 received towards your credit card XX4321` | counted as a **DEBIT 1200** | recorded as fixture `fp-credit-card-payment-received` |
| K-2 | `Your A/C XX1234 has been debited. Available balance in your account is INR 5,000.00` (no transaction amount) | counted as a **DEBIT 5000** | **new known issue.** `balanceLookbehindChars` is 14; "AVAILABLE BALANCE IN YOUR ACCOUNT IS " puts "BAL" 20+ chars before the figure. Needs a larger look-behind or a balance-word check in the pack, plus a fixture. |
| K-3 | `Rs.500 debited … credited to A/C XX9999 IMPS` | category **Financial** because trigger `CRED` matches inside "CREDITED" | short triggers (`CRED`, `OLA`, `LIC`, `SIP`, `CAFE`) match inside ordinary words ("COLA", "PUBLIC"). Category quality only; totals unaffected. |
| K-4 | Delivery notice from a non-listed DLT header mentioning UPI/"paid" | parses as a Rs 799 debit | recorded as fixture `fp-delivery` |
| K-5 | Classifier divergence | 2 of 59 fixtures (`fp-refund-initiated`, `fp-telecom-recharge`) classify differently Swift vs Kotlin | a Kotlin test pins that every diverging message is a `notTransaction` on the parse side; follow-up: make the desktop classifier pack-driven |

Other open items: an unreadable ledger (Keystore error or tamper) reads as empty and the next flush overwrites it, **losing user overrides** — a transient Keystore failure is indistinguishable from tamper (a "keep the old file as `.bad`" mitigation is not built; compare the H-13 fix on #61); rows inserted with an old date after the mark need "Scan older"; self-transfer pairing is per local calendar day (a 23:59 debit / 00:01 credit never pair — matches desktop); the "couldn't read" tally is not purged for a disabled SIM; **Spend is a 6th bottom-bar tab** (Material discourages more than five) and has **not been looked at on a screen**; the month stepper has no upper bound.

## 10. Execution Plan

| Task | Work | Est. | State |
|---|---|---|---|
| F56-1 | Shared fixture set; Swift test uses it | 1 d | 🔧 #58 — Swift **and** Kotlin green |
| F56-2 | Kotlin classifier + parser + categoriser | 2.5 d | 🔧 #58 |
| F56-3 | Sealed store, incremental parse | 1 d | 🔧 #58 (JVM) |
| F56-4 | Compose UI | 1.5 d | 🔧 #58 — compiles only |
| F56-5 | Perf + review | 1 d | 🔧 review done (`5982777`); perf JVM only |

## 11. Mobile Feasibility

This **is** the mobile half of F-048. Android ✅ (device SMS); iOS: no SMS read API — via cloud later (`V2.7-11`). Row: [`../HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 *Expenditure (F-048)* and *Expenditure on the phone (F-056)*.

## 12. Implementation Record

**PR #58, branch `feat/v2.6-f056-expenditure-android`** (8 commits; head `5982777`). Nothing merged or published.

**Built:** as §7. Review defect fixed (`5982777`): **FR-E5 only held for a fresh ledger** — rows already stored were never removed when a SIM was switched off or a sender denied; added `StoredTxn.line`, `ExpenseLedger.purge`, purge at the end of a completed run (also forgets the lines' marks so re-allowing re-reads), SIM switch triggers a scan; plus an `fsync` before the ledger rename, a separate ledger lock (so Exclude/Restore do not queue behind a long first scan) and `.tmp` removal on wipe.

**Not built:** cloud sync; force-include; category-reassignment screen (ledger and view model support `setCategory`); background scan; iOS.

**Verified:** Swift `ExpenseFixtures` (3 tests) against the real Swift implementation, with mutations (a pack category trigger → drift test red; a fixture amount → singles red); Kotlin singles + 7 pipelines in 4 time zones; `halocloud` 103 / `haloshare` 65 tests, `:app:assembleDebug` OK; mutation checks (identity sealer, no high-water write, balance filter, self-transfer, dedup, OTP gate, body appended, cancel polling, `java.net` import) all turn red.

**NOT verified:** real Android Keystore sealing; the pack loaded via classpath **on a device**; the Compose screen, permission flow, injected SMS; emulator/device performance; the 6-tab layout; the owner's real bank SMS (**V-7**).
