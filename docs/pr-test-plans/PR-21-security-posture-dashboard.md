# Manual Test Plan — PR #21: F-019 Security Posture Dashboard

> **Branch:** `feat/f019-security-posture` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/21
> **Diff size:** 13 files changed, +649/-4
> **Master regression doc:** this PR's test cases also appear at [`§4.3`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Protection**.

## How to test this PR

```bash
git fetch origin feat/f019-security-posture
git checkout feat/f019-security-posture
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/AppState.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/SecurityPostureScanner.swift`
- `Halo/Features/Protection/ProtectionView.swift`

## Detailed test cases

**Files:** `SecurityPostureScanner.swift`, `ProtectionView.swift` (`SecurityPostureSection` / `SecurityCheckRow`), `Models.swift` (`SecurityCheck`, `SecurityCheckKind`, `SecurityCheckState`), `AppState.swift` (`calculateHealthScore()`).

8 read-only checks via public CLI tools (`fdesetup`, `spctl`, `defaults read`) — no entitlements, no writes, no privilege escalation. 4 are genuinely auto-verified (FileVault, Gatekeeper, Application Firewall, Automatic Updates); 4 have no reliable non-interactive read path on macOS and always surface as `.unknown` with manual-check guidance (SIP, Secure Boot, Find My Mac, Login Window Security) — Halo never guesses these.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | Section renders on Protection load | Open Protection | "Security Posture" section appears below the scanner cards; loading spinner while `loadSecurityPosture()` runs, then all 8 rows render |
| TC-PROT-09 | P0 | FileVault — On | Run on a FileVault-encrypted Mac | Row shows pass state (green check), detail "On — your disk is encrypted at rest." |
| TC-PROT-10 | P0 | FileVault — Off | Run on a Mac with FileVault disabled | Row shows fail state (red X), detail "Off — your disk isn't encrypted." |
| TC-PROT-11 | P1 | FileVault — unreadable | Simulate `fdesetup status` producing unexpected output | Row shows `.unknown` (grey `?`), detail "Couldn't read FileVault status." — never guessed as pass or fail |
| TC-PROT-12 | P0 | Gatekeeper — enabled | `spctl --status` reports assessments enabled | Row shows pass, "Enabled — unsigned apps are blocked by default." |
| TC-PROT-13 | P0 | Gatekeeper — disabled | `sudo spctl --master-disable` | Row shows fail, "Disabled — any app can run unchecked." |
| TC-PROT-14 | P1 | Gatekeeper — unreadable | Non-matching `spctl` output | Row shows `.unknown` |
| TC-PROT-15 | P0 | Application Firewall — on | Enable in System Settings → Network → Firewall | `globalstate` ≠ 0 → row shows pass |
| TC-PROT-16 | P0 | Application Firewall — off | Disable firewall | `globalstate` == 0 → row shows fail |
| TC-PROT-17 | P1 | Firewall — unreadable | `defaults read` returns non-integer / errors | Row shows `.unknown`, never a guessed pass/fail |
| TC-PROT-18 | P0 | Automatic Updates — on | `AutomaticallyInstallMacOSUpdates` = 1 | Row shows pass |
| TC-PROT-19 | P1 | Automatic Updates — off | Value = 0 | Row shows **warn** (amber), not fail — "Off — you'll need to install updates manually." |
| TC-PROT-20 | P1 | Automatic Updates — unreadable | Any other/missing value | Row shows `.unknown` |
| TC-PROT-21 | P0 | SIP — always manual guidance | View SIP row regardless of actual `csrutil status` | Always `.unknown` state with guidance text pointing to System Report / `csrutil status` in Terminal — never a guessed verdict |
| TC-PROT-22 | P0 | Secure Boot — always manual guidance | View Secure Boot row | Always `.unknown`, guidance: "Only viewable from Recovery Mode → Startup Security Utility." |
| TC-PROT-23 | P0 | Find My Mac — always manual guidance | View Find My row | Always `.unknown`, guidance points to System Settings → Apple ID → Find My |
| TC-PROT-24 | P0 | Login Window Security — always manual guidance | View Login Window row | Always `.unknown`, guidance points to Users & Groups → Login Options |
| TC-PROT-25 | P1 | "Fix →" link where a Settings pane exists | Click the arrow-up-right button on FileVault/Gatekeeper/Firewall/Automatic Updates/Find My/Login Window rows | `NSWorkspace.shared.open(_:)` invoked with the correct `x-apple.systempreferences:` URL; no crash |
| TC-PROT-26 | P0 | No "Fix" button for SIP/Secure Boot | Inspect SIP and Secure Boot rows | No arrow-up-right button rendered — `SecurityCheckKind.settingsURL` is `nil` for both, since no System Settings pane exists for either |
| TC-PROT-27 | P0 | Score badge — all pass | All 4 verifiable checks pass | Badge reads `100/100`, green |
| TC-PROT-28 | P1 | Score badge — degraded | One check fails, one warns | Badge reflects `100 - 15 - 7 = 78/100`, amber (50–79 range) |
| TC-PROT-29 | P0 | Score badge — unknowns never drag it down | All 4 manual checks `.unknown` + all 4 verifiable checks pass | Badge stays `100/100` — unknown states contribute zero |
| TC-PROT-30 | P1 | Manual refresh | Click the refresh (↻) button next to the score badge | `loadSecurityPosture()` re-runs; spinner shown briefly, rows update |
| TC-PROT-31 | P0 | Health Score integration — quarter weight | Force `securityScore` to 60 (40 points below full) via a failing check | `AppState.calculateHealthScore()` subtracts `(100 - 60) / 4 = 10` points, not the full 40 |
| TC-PROT-32 | P0 | Health Score integration — never double-penalizes unknowns | All 4 manual checks unknown, all verifiable checks pass | `securityScore == 100`; health score deduction for security is `0` |
| TC-PROT-33 | P2 | Launch-time optimistic default | Kill and relaunch app; check health score before the one-time async scan resolves | `AppState.securityScore` defaults to `100` (never shows a false "unhealthy" score before the check completes) |
| **Unit** TC-PROT-U5 | P0 | `score(for:)` — all pass | Synthetic all-`.pass` array | Returns `100` |
| **Unit** TC-PROT-U6 | P0 | `score(for:)` — single fail / warn | One `.fail` (rest pass); one `.warn` (rest pass) | Returns `85`; returns `93` respectively |
| **Unit** TC-PROT-U7 | P1 | `score(for:)` — multiple fails/warns sum and clamp | 2 fails + 1 warn; all 8 fail | Returns `63`; clamps to `0` (never negative) |
| **Unit** TC-PROT-U8 | P0 | `score(for:)` — all-unknown never penalizes | Synthetic all-`.unknown` array | Returns `100` — the core invariant of this feature |
| **Unit** TC-PROT-U9 | P0 | `score(for:)` — mixed fail/warn + unknown | 1 fail + 7 unknown; 1 warn + 7 unknown | Only the fail/warn counts (`85` / `93`); unknowns contribute nothing to the sum |
| **Unit** TC-PROT-U10 | P2 | `SecurityCheckKind.settingsURL` | Check each of the 8 kinds | `nil` only for `.sip` and `.secureBoot`; non-nil for the other 6 |

## Regression spot-check

This PR only *adds* a new section to **Protection** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Protection test cases from [`§4` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
