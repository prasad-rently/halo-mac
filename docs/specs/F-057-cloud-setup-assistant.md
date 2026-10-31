# F-057 — Cloud Setup Assistant

> **Status:** 🔧 **Built on PR #63 (unmerged; head `c7a1d38`). The independent review was still in progress when this was written — no review result is recorded here.** Swift + Kotlin engines tested against stubs and a loopback stand-in only; **NOT verified against a real Firebase project, and neither UI has been looked at on a screen.** Not ✅ (V-2).
> **Extends:** F-044 / F-045 cloud line (`Halo/Core/Cloud`, `android/halocloud`, `android/app`) · **Raised:** 2026-10-28 (v2.6 BRD §9) · **Effort estimate:** ≈ 4 d (Swift + Kotlin)
> **Reserved pbxproj IDs:** `8285`–`8304` claimed by PR #63 (`8285`–`8294` used: 5 files × ref/build pair; `8295`–`8304` free). **`CLAUDE.md` does not yet carry this claim** — see the PR body follow-ups.
> **Carries decision:** D-01 (passphrase typed twice when the database cannot verify it) — implemented in v2.5 as H-12 · **Plan:** [`../V2_6_PLAN.md`](../V2_6_PLAN.md)

---

## 1. Summary

v2.5's real defects were all setup failures that looked like something else: a rules file missing `clipboard/` (clipboard silently denied), an open database, a wrong-region URL, Email/Password disabled. F-057 adds a **"Check my database"** diagnostic on the Mac and the phone that probes **each path the app uses**, plus smaller setup safety items: the pairing code hides itself after 60 s, and the Mac's Devices list shows last-seen and can retire a phone.

## 2. Goals / Non-Goals

**Goals:** per-path write/read/delete probe with a concrete fix per failure; detect open rules, wrong URL/region, disabled Email/Password; pairing code lifetime bounded on screen; last-seen + retire per device.
**Non-Goals:** assisted provisioning (S2 — Google restricted-scope verification, `V2.7-03`); an iOS client of the check; rules that grant only specific children (not caught — see §9); changing the encryption or key-check design.

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D-01 (accepted 2026-10-28) | On an empty database type the passphrase **twice** and say it could not be verified; with an encrypted sample, verify and refuse a mismatch. | An empty database cannot prove a passphrase. Already built in v2.5 (#55); **verified, not changed** by F-057. |
| D1 | Probes live at `<root>/{uid}/_haloCheck_<nonce>` and are **always deleted** on every failure path; a refused write issues no delete; an undeletable probe is a WARN naming the entry. | The check must never leave data behind. |
| D2 | The engine **never** logs and never puts password, API key, ID token, email or concrete uid in a report; network errors collapse to a body-less error type (the URL carries `?auth=<token>`). | Tokens in URLs leak through error text. |
| D3 | Swift and Kotlin engines are **twins** with identical item kinds, problem codes and fix wording. | One support story. |
| D4 | Retire = existing `wipeDevice`, routed through `DeviceRetirement.retire`, which refuses an empty, `/`-bearing, `.` or `..` device id **before removing anything**. | An empty id would have deleted the whole `sms/{uid}` tree. |

## 4. User Stories

- **US-1** After pasting my Firebase config I press "Check my database" and see exactly which of `meta`, `devices`, `sms`, `clipboard` is denied and what to publish.
- **US-2** The pairing code on screen disappears after a minute and I can get a new one.
- **US-3** I can see when each phone last synced and retire one I no longer use.

## 5. Functional Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| FR-S1 | "Check my database" on Mac (Cloud settings) and phone: sign in; write + read back + delete a probe under **each** path (`meta`, `devices`, `sms`, `clipboard`); per-path pass/fail with the fix ("publish `docs/specs/firebase-rules.json`"); detect open rules (unauthenticated shallow read), wrong-region/URL (404), disabled Email/Password (`OPERATION_NOT_ALLOWED`), bad credentials / API key / disabled user / rate limit / offline | Stubbed-network tests incl. "clipboard denied" (the real v2.5 defect); manual run against the stand-in |
| FR-S2 | Passphrase entry per D-01 | Engine + UI tests (existing `PairingConfirmationTest`) |
| FR-S3 | Pairing code **auto-hides after 60 s** on the Mac, regenerates on demand; never written to logs, UserDefaults or AlertLog | Test + grep audit |
| FR-S4 | Mac "Devices" list shows last-seen (stale > 7 days in amber) and lets the user retire one (wipe its subtree) | Desktop test |
| X-2 | Mobile-parity row: the phone-side check is part of this feature | Row in `HALO_MOBILE_ROADMAP.md` (**added by the v2.6 docs PR**) |

## 6. Non-Functional Requirements

`https` only (Mac via `normalizedDatabaseURL`; phone via `normalizedDatabaseUrl`, debug loopback only in debug builds); the phone check reuses `DebugEndpoints` so a release build never sends credentials anywhere but Google; the unauthenticated open-rules probe sends no credentials (`shallow=true`, keys only); the pairing code is held in memory only (clock injectable for tests).

## 7. Architecture

Swift: `Halo/Core/Cloud/{DatabaseCheck,PairingCodeSession,DeviceRetirement}.swift`, `Halo/Features/SMSConsole/DatabaseCheckSection.swift`, edits to `CloudSettingsPane`, `SMSModels` (+`lastSeen`), `SMSSyncClient` (`mergeDevice` reads `lastSeen`; `wipeDevice` calls `DeviceRetirement.retire`). Kotlin: `android/halocloud/.../DatabaseCheck.kt`, `android/app/.../DatabaseCheckUi.kt`, one line in `CloudScreens.kt`. Pure engine over an injectable transport; live transport tested against a loopback HTTP stand-in whose rules forget `clipboard`.

## 8. Acceptance (ship gate)

- **AC-1** Per-path probe incl. clipboard-denied, healthy path, open rules, wrong URL, disabled Email/Password — **stub/loopback only** (Kotlin 159 tests incl. 18 new; Swift 25 new tests).
- **AC-2** Probe cleanup on every failure path; no secret in any report — tested (Swift and Kotlin).
- **AC-3** Pairing code hides after 60 s and regenerates — tested with an injected clock.
- **AC-4** `DeviceRetirement` refuses unsafe ids before removing anything — tested.
- **AC-5 (owner, V-2)** The check against the owner's **real** Firebase project: 401/403 vs 404 vs `OPERATION_NOT_ALLOWED` semantics (taken from the REST docs, exercised only on stubs) — **not verified**.
- **AC-6** Both UIs on screen — **not run** (compile-checked only).

## 9. Open Questions & Risks (known issues)

- Rules granting only specific children (not the whole `{uid}` node) are **not caught** — probes live at `<root>/{uid}/_haloCheck_*`.
- **Pasteboard clearing:** "Copy code" still leaves the (concealed) code on the pasteboard after the on-screen code hides. Follow-up.
- Pre-existing, related: `CloudStore.load()` (Android) reports "not paired" on **any** exception, so a transient Keystore error looks like an unpaired phone until the next open (never auto-overwrites). Recorded on PR #61; not changed.
- No iOS client of this check (v2.7 with the iOS client, `V2.7-08`).
- **Review state:** an independent review of #63 was in progress when this record was written; this section must be updated from it.

## 10. Execution Plan

| Task | Work | Est. | State |
|---|---|---|---|
| F57-1 | Per-path check engine (Kotlin + Swift) | 1.5 d | 🔧 #63 — stubs/loopback |
| F57-2 | Mac UI + phone UI | 1 d | 🔧 #63 — compiled only |
| F57-3 | Pairing code 60 s auto-hide + no-logging audit | 0.5 d | 🔧 #63 — tested; `DatabaseCheckTests.noSinks` re-runs the grep audit |
| F57-4 | Devices last-seen + retire | 0.5 d | 🔧 #63 — tested |
| F57-5 | Mobile-parity row; review | 0.5 d | row ✅ (v2.6 docs PR); review **in progress** |

## 11. Mobile Feasibility

Both platforms — the phone-side check is part of this feature. Android ✅ built on #63; iOS deferred with the iOS client (`V2.7-08`). Row: [`../HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 *Cloud setup assistant (F-057)*.

## 12. Implementation Record

**PR #63, branch `feat/v2.6-f057-setup-assistant`** (2 commits; head `c7a1d38`). Nothing merged or published. Mid-session the external SSD holding the author's worktree dropped off; the Swift half was re-applied from a fresh clone of the branch and re-tested there.

**Built:** FR-S1 (engine + both UIs), FR-S3, FR-S4; FR-S2 verified as already done in v2.5.

**Not built:** pasteboard clearing; the "specific children" rules case; iOS.

**Verified:** Kotlin `:halocloud:test :haloshare:test` — 159 tests, 0 failures (141 existing + 18 new), incl. the live transport against the loopback stand-in; `:app:assembleDebug` compiles. Swift: 4 new suites (engine 14, live transport via stubbed URLSession 1, pairing code 5, devices 5 = 25 tests) pass via `-only-testing`. Mutation checks (engine probes only `meta`; no cleanup after read-back failure; pairing hide delayed ×100; `isSafeDeviceID → true`) each turned the matching tests red on both sides where applicable. Subprocess + entitlement audits OK.

**NOT verified:** full `HaloTests` regression (only the 4 new suites were run); both UIs on screen; **real Firebase** (the v2.5 "clipboard denied" defect is reproduced with a stub, not on a real project); a real phone.
