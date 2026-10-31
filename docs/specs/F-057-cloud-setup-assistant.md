# F-057 — Cloud Setup Assistant

> **Status:** 🔧 **Built on PR #63 (unmerged; head `0228187`). Independently reviewed: 10 defects found, all fixed in `0228187` (verdict "changes needed, now fixed"); the fixes were re-verified by the reviewer but have had no separate second review.** Swift + Kotlin engines tested against stubs and a loopback stand-in only; **NOT verified against a real Firebase project, and neither UI has been looked at on a screen.** Not ✅ (V-2).
> **Extends:** F-044 / F-045 cloud line (`Halo/Core/Cloud`, `android/halocloud`, `android/app`) · **Raised:** 2026-10-28 (v2.6 BRD §9) · **Effort estimate:** ≈ 4 d (Swift + Kotlin)
> **Reserved pbxproj IDs:** `8285`–`8304` claimed by PR #63 (`8285`–`8294` used: 5 files × ref/build pair; `8295`–`8304` free). **`CLAUDE.md` does not yet carry this claim** — see the PR body follow-ups.
> **Carries decision:** D-01 (passphrase typed twice when the database cannot verify it) — implemented in v2.5 as H-12 · **Plan:** [`../V2_6_PLAN.md`](../V2_6_PLAN.md)

---

## 1. Summary

v2.5's real defects were all setup failures that looked like something else: a rules file missing `clipboard/` (clipboard silently denied), an open database, a wrong-region URL, Email/Password disabled. F-057 adds a **"Check my database"** diagnostic on the Mac and the phone that probes **each path the app uses**, plus smaller setup safety items: the pairing code hides itself after 60 s, and the Mac's Devices list shows last-seen and can retire a phone.

## 2. Goals / Non-Goals

**Goals:** per-path write/read/delete probe with a concrete fix per failure; detect open rules, wrong URL/region, disabled Email/Password; pairing code lifetime bounded on screen; last-seen + retire per device.
**Non-Goals:** assisted provisioning (S2 — Google restricted-scope verification, `V2.7-03`); an iOS client of the check; rules that grant only specific children (not fully caught — see §9); changing the encryption or key-check design.

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D-01 (accepted 2026-10-28) | On an empty database type the passphrase **twice** and say it could not be verified; with an encrypted sample, verify and refuse a mismatch. | An empty database cannot prove a passphrase. Already built in v2.5 (#55); **verified, not changed** by F-057. |
| D1 | Probes live at `<root>/{uid}/_haloCheck_<nonce>` and are **always deleted** on every failure path; a refused write issues no delete; an undeletable probe is a WARN naming the entry. | The check must never leave data behind. |
| D2 | The engine **never** logs and never puts password, API key, ID token, email or concrete uid in a report; network errors collapse to a body-less error type (the URL carries `?auth=<token>`). Probe nodes live in a reserved namespace (`DatabaseCheckEngine.probePrefix` / `isProbeKey`) that the Mac's observers, `reconcile` and `refreshDevices` filter out, so a check run while the Mac is connected cannot create a phantom phone (review fix). | Tokens in URLs leak through error text; the probe must not look like data. |
| D3 | Swift and Kotlin engines are **twins** with identical item kinds, problem codes and fix wording. | One support story. |
| D4 | Retire = existing `wipeDevice`, routed through `DeviceRetirement.retire`, which refuses an empty, whitespace-only, control-character, `/`-bearing, `.`/`..`, Firebase-illegal (`. $ # [ ]`) or > 768-byte device id **before removing anything** (and before detaching observers — review fix). | An empty id would have deleted the whole `sms/{uid}` tree. |

## 4. User Stories

- **US-1** After pasting my Firebase config I press "Check my database" and see exactly which of `meta`, `devices`, `sms`, `clipboard` is denied and what to publish.
- **US-2** The pairing code on screen disappears after a minute and I can get a new one.
- **US-3** I can see when each phone last synced and retire one I no longer use.

## 5. Functional Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| FR-S1 | "Check my database" on Mac (Cloud settings) and phone: sign in; write + read back + delete a probe under **each** path (`meta`, `devices`, `sms`, `clipboard`); per-path pass/fail with the fix ("publish `docs/specs/firebase-rules.json`"); detect open rules (unauthenticated shallow read of the root, then of each of `meta`/`devices`/`sms`/`clipboard` — review fix), wrong-region/URL (404), disabled Email/Password (`OPERATION_NOT_ALLOWED`), bad credentials / API key / disabled user / rate limit / offline | Stubbed-network tests incl. "clipboard denied" (the real v2.5 defect); manual run against the stand-in |
| FR-S2 | Passphrase entry per D-01 | Engine + UI tests (existing `PairingConfirmationTest`) |
| FR-S3 | Pairing code **auto-hides after 60 s** on the Mac, regenerates on demand; never written to logs, UserDefaults or AlertLog; the pasteboard copy is cleared on hide/expiry/leave if it is still ours (review fix) | Test + grep audit |
| FR-S4 | Mac "Devices" list shows last-seen (stale > 7 days in amber; refreshed when the pane opens) and lets the user retire one (wipe its `sms/{uid}/{id}` + `devices/{uid}/{id}` nodes) | Desktop test |
| X-2 | Mobile-parity row: the phone-side check is part of this feature | Row in `HALO_MOBILE_ROADMAP.md` (**added by the v2.6 docs PR**) |

## 6. Non-Functional Requirements

`https` only (Mac via `normalizedDatabaseURL`; phone via `normalizedDatabaseUrl`, debug loopback only in debug builds); the phone check reuses `DebugEndpoints` so a release build never sends credentials anywhere but Google; the unauthenticated open-rules probe sends no credentials (`shallow=true`, keys only); the pairing code is held in memory only (clock injectable; the countdown uses `ContinuousClock`, so Mac sleep counts). Request timeouts: 15 s idle plus a 25 s resource ceiling.

## 7. Architecture

Swift: `Halo/Core/Cloud/{DatabaseCheck,PairingCodeSession,DeviceRetirement}.swift`, `Halo/Features/SMSConsole/DatabaseCheckSection.swift`, edits to `CloudSettingsPane`, `SMSModels` (+`lastSeen`), `SMSSyncClient` (`mergeDevice` reads `lastSeen`; `wipeDevice` calls `DeviceRetirement.retire`). Kotlin: `android/halocloud/.../DatabaseCheck.kt`, `android/app/.../DatabaseCheckUi.kt`, one line in `CloudScreens.kt`. Pure engine over an injectable transport; live transport tested against a loopback HTTP stand-in whose rules forget `clipboard`.

## 8. Acceptance (ship gate)

- **AC-1** Per-path probe incl. clipboard-denied, healthy path, open rules (root **and** per-folder), wrong URL, bad API key, disabled Email/Password — **stub/loopback only** (Kotlin 165 tests; Swift 35 tests across the four new suites — both re-run after the review fixes).
- **AC-2** Probe cleanup on every failure path **including task cancellation** (cleanup runs detached; mutation-verified); no secret in any report — tested (Swift and Kotlin).
- **AC-3** Pairing code hides after 60 s and regenerates — tested with an injected clock and, after review, one real-timer test.
- **AC-4** `DeviceRetirement` refuses unsafe ids before removing anything — tested.
- **AC-5 (owner, V-2)** The check against the owner's **real** Firebase project: 401/403 vs 404 vs `OPERATION_NOT_ALLOWED` semantics (taken from the REST docs, exercised only on stubs) — **not verified**.
- **AC-6** Both UIs on screen — **not run** (compile-checked only).

## 9. Open Questions & Risks (known issues)

Recorded from the independent review of #63 (its "Left (not blocking)" list) — **not fixed**:

- **Probe fidelity.** The probe lives at `<root>/{uid}/_haloCheck_*` but real data is `clipboard/{uid}/items/…` (and `meta/{uid}`'s children). A rules file granting only `…/items` would be reported as a failure; the inverse — rules granting only specific children — is **not caught**.
- **Retire** removes `sms/{uid}/{id}` and `devices/{uid}/{id}` only; that phone's items under `clipboard/{uid}/items/*` remain (the spec says "its subtree"; as designed). A still-signed-in phone re-registers on its next sync (the confirmation text now says so).
- `?auth=<idToken>` in the request URL matches the existing `FirebaseRTDBClient.requestURL` (over TLS; error text is body-less). An `Authorization` header would be better but cannot be validated without real Firebase.
- Kotlin `http()` has no total deadline (read timeout is per read) and catches only `IOException`.
- Test weakness: `noSecrets` is close to vacuous (the stub never sees a secret — the live-transport test is the real check) and `noSinks` is a string grep; no test for the `SMSSyncClient` observer filter (needs an RTDB seam).
- Pre-existing, related: `Rtdb.kt` takes the first word of the error message as the sign-in code (same pattern the review fixed in the new engine); `CloudStore.load()` (Android) reports "not paired" on **any** exception, so a transient Keystore error looks like an unpaired phone until the next open (never auto-overwrites). Recorded on PR #61.
- Status-code semantics (401/403 vs 404 vs `OPERATION_NOT_ALLOWED`) are from the REST docs and **unverified against real Firebase** (AC-5).
- No iOS client of this check (v2.7 with the iOS client, `V2.7-08`).
- **Review state:** independent review of head `c7a1d38` done (10 defects, §12); the follow-up `0228187` was verified by the reviewer, not independently re-reviewed.

## 10. Execution Plan

| Task | Work | Est. | State |
|---|---|---|---|
| F57-1 | Per-path check engine (Kotlin + Swift) | 1.5 d | 🔧 #63 — stubs/loopback |
| F57-2 | Mac UI + phone UI | 1 d | 🔧 #63 — compiled only |
| F57-3 | Pairing code 60 s auto-hide + no-logging audit | 0.5 d | 🔧 #63 — tested; `DatabaseCheckTests.noSinks` re-runs the grep audit; pasteboard cleared on hide (review fix) |
| F57-4 | Devices last-seen + retire | 0.5 d | 🔧 #63 — tested |
| F57-5 | Mobile-parity row; review | 0.5 d | row ✅ (v2.6 docs PR); review ✅ done — 10 defects fixed in `0228187` (not re-reviewed) |

## 11. Mobile Feasibility

Both platforms — the phone-side check is part of this feature. Android ✅ built on #63; iOS deferred with the iOS client (`V2.7-08`). Row: [`../HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 *Cloud setup assistant (F-057)*.

## 12. Implementation Record

**PR #63, branch `feat/v2.6-f057-setup-assistant`** (3 commits: `b6f7581` Android engine + phone UI, `c7a1d38` Mac check / pairing code / devices, `0228187` review fixes; head `0228187`). Nothing merged or published. Mid-session the external SSD holding the author's worktree dropped off; the Swift half was re-applied from a fresh clone of the branch and re-tested there.

**Built:** FR-S1 (engine + both UIs), FR-S3, FR-S4; FR-S2 verified as already done in v2.5.

**Independent review of `c7a1d38` — verdict "changes needed, now fixed in `0228187`"; 10 defects, all fixed:**
1. The probe polluted the live device list (a phantom phone `_haloCheck_…` appeared while the Mac was connected) — probe namespace filtered in both observers, `reconcile` and the new `refreshDevices`.
2. Cleanup was not guaranteed on cancel (URLSession throws immediately in a cancelled task) — delete now runs detached; test added, mutation-verified red without the fix.
3. The write-drop path discarded the cleanup result — now names the entry that may remain (Swift + Kotlin).
4. Open-rules false negative (only the root was read anonymously, so rules opening just `clipboard` — the v2.5 shape — printed "Anonymous access is refused") — now root first, then each folder.
5. A bad API key was never classified (first word of the message was "API") — `signInErrorCode` added with tests.
6. A degenerate empty uid would have placed the probe outside `{uid}` — refused.
7. Timeouts — `timeoutIntervalForResource = 25` added (the 15 s value is an idle gap, not a ceiling).
8. FR-S3 hide was weaker than advertised — `ContinuousClock`, pasteboard cleared on hide/expiry/leave if `changeCount` still matches, a real-timer test.
9. FR-S4 — "Last seen" froze (devices observed `child_added` only; the pane now refreshes on open), the Retire copy was untrue (a signed-in phone re-registers), `wipeDevice` detached observers before validating the id, `isSafeDeviceID` widened, `lastSeen: true` no longer becomes 1970-01-01.
10. Android — `running` could stay `true` forever on an unexpected exception (try/finally).

**Not built:** the "specific children" rules case; iOS. (Pasteboard clearing, listed as not built in the PR body, **was built by the review fix**.)

**Verified (after `0228187`):** Kotlin `:halocloud:test :haloshare:test :app:assembleDebug --offline` — **165 tests, 0 failures**, build green (159 before the review fixes). Swift: the four new suites via `-only-testing` — **35 tests pass** (25 before). Mutation checks: engine probes only `meta`; no cleanup after read-back failure; pairing hide delayed ×100; `isSafeDeviceID → true`; and, after review, removing the detached cleanup turns "Cancelling the check mid-run still deletes the probe" red. Subprocess + entitlement audits OK (PR body, pre-review).

**NOT verified:** full `HaloTests` regression (only the 4 new suites were run, before and after review); both UIs on screen; **real Firebase** (the v2.5 "clipboard denied" defect is reproduced with a stub, not on a real project); a real phone; the `SMSSyncClient` observer filter (no test seam).

**pbxproj IDs:** `8285`–`8294` used (verified: the ten IDs `8285`…`8294` are the only new object IDs on the branch); `8295`–`8304` claimed free in the PR body, not in `CLAUDE.md`.
