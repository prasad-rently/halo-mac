# Code review — PR #21 · F-019 Security Posture Dashboard

- **PR:** [prasad-rently/halo-mac#21](https://github.com/prasad-rently/halo-mac/pull/21)
- **Branch:** `feat/f019-security-posture` → `main`
- **Reviewed at:** commit `a85c9e5d` · 13 files, +649 / −4
- **Inline comments:** posted on the PR ([review 5113150967](https://github.com/prasad-rently/halo-mac/pull/21#pullrequestreview-5113150967))

## Verdict: **Request changes**

The core design decision is the right one and worth stating plainly: refusing to guess at
SIP / Secure Boot / Find My / Login Window, and making `.unknown` *structurally* unable to
affect the score, is exactly the discipline this feature needed. The test suite pins that
invariant properly (`testAllUnknownNeverPenalizes`, `testMixedFailAndUnknownOnlyFailCounts`).
The stable `idSlug` for accessibility identifiers — deliberately decoupled from the display
`rawValue` — is a good call that will save UI-test churn later.

Three things block merge: a description/diff mismatch, a wrong preference key producing false
warnings, and the release-sandbox gap that makes all four "auto-verified" checks inert in the
shipping configuration.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/SecurityPostureScanner.swift:73` | Business requirement | Reads `AutomaticallyInstallMacOSUpdates` (full macOS *version upgrades*) but the check is labelled "Automatic Security Updates". Users who deliberately leave OS auto-upgrade off while keeping security responses on get a false `.warn` — *"Off — you'll need to install updates manually"* — plus a real deduction from the overall health score for a correctly-hardened machine. | High | Read `CriticalUpdateInstall` (Security Responses and system files) and/or `ConfigDataInstall`. Alternatively rename the check to "Automatic macOS Updates" and downgrade it to informational. |
| 2 | `SecurityPostureScanner.swift:25` | Business requirement | Under `Halo.entitlements` (sandbox on — the App Store configuration) `posix_spawn` of `/usr/bin/fdesetup`, `/usr/sbin/spctl` and `/usr/bin/defaults` is denied, and reads of `/Library/Preferences` are denied even if the spawn succeeded. All four checks fall through to `.unknown`, so the shipping build shows an eight-row "check manually" list with a permanent 100/100. The PR body states "4 checks are genuinely auto-verified via read-only `Process` calls". | High | Decide and document: Debug/direct-distribution only (state it in the file header, the PR body, and the UI), or route through the F-002 privileged helper. See B4. |
| 3 | PR description | Business requirement | Claims *"Also includes a Settings screen rework (layout fixes, wiring 8 previously-dead placeholder controls to real functionality) done as a prerequisite pass before this feature."* No `OnboardingView.swift` / `SettingsView` change is present in the 13 files. Either a commit was dropped or the description belongs to another branch. A reviewer would otherwise assume "8 previously-dead controls now work" had been reviewed. | Medium | Restore the commit or correct the description. |
| 4 | `Halo/App/AppState.swift:222` | Code quality | Two independent `SecurityPostureScanner` instances: `AppState` stores `securityScore` from a single launch-time scan; `ProtectionViewModel` owns a second scanner and computes its own `securityScore` over `securityChecks`. After the user acts on a finding and taps Refresh, the checklist goes green while `appState.securityScore` — and therefore the Dashboard health score at `AppState.swift:267` — keeps reflecting the launch value until relaunch. The two can disagree indefinitely in either direction. | Medium | Single source of truth: hold the checks on `AppState` (or a shared `@MainActor` store, as `AlertLog.shared` does), have `ProtectionViewModel` read and refresh *that*, and derive both scores from it. |
| 5 | `SecurityPostureScanner.swift:96` | Code quality | `waitUntilExit()` precedes `readDataToEndOfFile()`, and `standardError` is an undrained `Pipe()`. Harmless here (output is a line or two) — but this is the file #17 and #9 cite as their reference ("same read-only pattern as `SecurityPostureScanner`"), and in those the output *does* exceed the 64 KB pipe buffer and deadlocks. | Low | Reorder to read → wait → check `terminationStatus`; use `FileHandle.nullDevice` for stderr. Fixing it here stops the propagation (B5). |
| 6 | `Halo/Core/Models/Models.swift:222` | Code quality | `SecurityCheck.id` is a fresh `UUID()` per instance and `loadSecurityPosture()` replaces the whole array, so every Refresh looks like eight brand-new rows to `ForEach` — full teardown/rebuild rather than a diff, visible as a flicker. | Low | `var id: SecurityCheckKind { kind }` — already unique per check. See B8. |
| 7 | `SecurityPostureScanner.swift:6` | Code quality | Header says "Three of the eight checks (SIP, Secure Boot, Find My, Login Window …)" — that lists four. `scan()` returns four `manualCheck(...)` entries and the tests assert four. | Low | Fix the comment. |
| 8 | `Halo/Features/Protection/ProtectionView.swift:655` | Control flow | Both the score badge and the Refresh button are gated on `!securityChecks.isEmpty`. Unreachable today (`scan()` always returns eight), but if it ever returns empty there is no way to re-run it. | Low | Gate only the badge on non-empty; always show Refresh when `!isLoadingSecurity`. |
| 9 | `Halo.xcodeproj/project.pbxproj` | Code standards | Claims UUIDs `8031`/`8032`, which #13 (`8031`–`8034`) and #9 (`8031`/`8032`) also claim. | High | See B1 — reassign to a free block and update the `CLAUDE.md` UUID table. |

## Blocking issues

- **Business requirement alignment** — 1, 2, 3
- **Code standards** — 9 (and B1, B2, B3)

## Non-blocking suggestions

- 4 is Medium and worth doing before merge: the divergence is user-visible and will read as a bug.
- 5, 6, 7, 8 are Low. 5 and 6 are cheaper to fix as part of the batch-wide passes (B5, B8) than individually.

## Questions for the author

1. **Where did the Settings rework go?** (issue 3) Dropped commit, or wrong description?
2. **Is the sandboxed release build in scope for this feature?** (issue 2) This needs one answer for the whole batch, not six — see B4.
3. Was `AutomaticallyInstallMacOSUpdates` chosen deliberately over `CriticalUpdateInstall`, or is that just the first key that surfaced during development?

---

## Batch-level issues (affect this PR but cannot be fixed inside it)

These are tracked once for the whole `F-016 … F-030` batch. Full detail in the
[consolidated cross-PR comment](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519).

| # | Section | Issue | Risk |
|---|---------|-------|------|
| B1 | Code standards | **pbxproj UUID collision** — PRs #21, #13 and #9 all claim `8031`/`8032`. Whichever two merge second produce duplicate object IDs; Xcode may accept them while mapping a `PBXBuildFile` to the wrong `fileRef`. Free blocks: `8113`–`8116`, `8153`–`8156`. | High |
| B2 | Code standards | **All 13 sibling PRs report `MERGEABLE`** because mergeability is computed pairwise against `main`. The first merge conflicts the other twelve across 8 shared files (`project.pbxproj`, `Models.swift`, `HaloTests.swift`, `CLAUDE.md`, `FEATURE_ROADMAP.md`, `ROADMAP.md`, `MANUAL_TEST_PLAN.md`, `HALO_MOBILE_ROADMAP.md`). | High |
| B3 | Testing & rollout | **No CI exists.** `.github/workflows/` is absent and `gh pr checks` reports nothing on any branch. Every "BUILD SUCCEEDED" claim is unverifiable and is invalidated by the rebases B2 requires. | High |
| B4 | Business requirement | **`Process` + release App Sandbox** — six features (#21, #20, #17, #16, #10, #9) shell out; `posix_spawn` is denied under `Halo.entitlements`, so all six degrade to empty/unknown in the shipping build. They degrade *honestly*, which is right — but the PR bodies describe them as working. Needs one decision for the batch: Debug/direct-distribution only, or route via the F-002 privileged helper. | Medium |
| B5 | Logical lapses | **`Process` pipe ordering copied six times.** Five of six call `waitUntilExit()` before draining the pipe. #20 is the only one correct. Extract one shared `ShellReader` rather than fixing five call sites. | High |
| B6 | Blast radius | **Four `ProcessMonitor` instances, two `AlertManager` instances.** Cooldown state is per-instance, so the cooldown contract is not global. `AlertLog.shared` sits next to `AlertManager` and is already a singleton — promote both. | Medium |
| B7 | Security / privacy | **Inconsistent privacy posture between #10 and #13.** Both persist an app-usage behavioural profile; #10 is off-by-default with a Settings toggle and clear action, #13 is unconditional with neither. | Medium |
| B8 | Code quality | **Fresh `UUID()` as `Identifiable.id` on re-derived models** — `SecurityCheck` (#21), `NetworkConnectionEntry` (#17), `BackupHeatmapDay` (#16), `PhotoHashItem`/`PhotoAssetHashItem` (#19). Each is rebuilt every scan/poll, so `ForEach` rebuilds instead of diffing. A stable key already exists in every case. | Low |

---

## Risk definitions

- **Critical** — crash, data loss, security hole, or store-rejection risk; blocks merge
- **High** — breaks a user flow or another consumer of this code; should block merge
- **Medium** — bug or standards violation with limited blast radius; fix before merge or in immediate follow-up
- **Low** — style/readability/nice-to-have; non-blocking
