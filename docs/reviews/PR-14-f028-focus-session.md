# Code review — PR #14 · F-028 Focus Session Companion

- **PR:** [prasad-rently/halo-mac#14](https://github.com/prasad-rently/halo-mac/pull/14)
- **Branch:** `feat/f028-focus-session` → `main`
- **Reviewed at:** commit `7d0d69f0` · 15 files, +1040 / −21
- **Inline comments:** [review 5113194234](https://github.com/prasad-rently/halo-mac/pull/14#pullrequestreview-5113194234)

## Verdict: **Request changes**

The notification-suppression correction is the best thing in this PR and should be the template
for the rest of the batch: the `INFocusStatusCenter` capability genuinely does not exist for
third-party apps, the PR says so plainly, the file header explains why, and the shipped
alternative is a deep link with an explicit tooltip saying Halo *can't* do it for you. Nothing
pretends otherwise.

The menu-bar override is also clean: `effectiveStyle` is computed from `focusSession.isActive`, so
no persisted style is mutated and the revert cannot get stuck — and both `MenuBarDisplayStyle.allCases`
call sites were correctly switched to `.selectable` so `.sessionCountdown` is never offered
manually. `hide()`/`unhide()` instead of `terminate()` is the right choice throughout.

One thing blocks merge: session state is in memory only and `unhide()` runs from exactly one place.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/FocusSessionManager.swift:159` | Control flow | `hiddenApps` is in-memory only and `unhide()` is called only from `finish(early:)`. Every path that skips `finish()` leaves the user's apps hidden with no recovery inside Halo: quitting Halo during a session (⌘Q or the menu-bar item), a crash (Sentry is wired up precisely because those happen), or a force-quit/power loss. On relaunch `FocusSessionManager` starts with `isActive == false` and an empty `hiddenApps`, so no state records that anything was hidden — the user is left hunting through ⌘-Tab wondering where Slack went. Recoverable manually, but the app broke something and can no longer fix it, and `hide()` is exactly the kind of reversible action whose reversal must be guaranteed. | High | (a) Persist the active session (bundle IDs + `endDate`) and on `init` either unhide those bundle IDs or resume the session if `endDate` is still ahead, then clear the key. (b) Also unhide on `NSApplication.willTerminateNotification` via an idempotent `restoreHiddenApps()` shared with `finish()`. |
| 2 | `FocusSessionManager.swift:198` | Exception handling | `UNUserNotificationCenter.current().add(request)` with no completion handler. If authorization was denied — or never granted because `AlertManager.requestPermission()` was declined at first launch — the request fails and nothing surfaces. The summary still lands in `AlertLog`, so it isn't lost, but the user gets no signal their session ended, which for a Pomodoro timer is the primary output. | Medium | Handle the error; when delivery isn't possible, make the overlay / Dashboard card show the completed state prominently instead. |
| 3 | `FocusSessionManager.swift:230` | Business requirement | `candidateRunningApps()` filters `NSWorkspace.shared.runningApplications` and is the only source for the picker in `FocusSessionSettingsTab`. So to configure Slack as "hide during focus", Slack must be running when the user opens Settings → Focus. The *storage* side is correctly bundle-ID based and survives the app not running (as the header says), so this is purely a discovery gap — but it's the gap a user hits first, and the empty-state copy documents the limitation rather than solving it. | Medium | Add an "Add from Applications…" path alongside the running list. `AppScanner.scanApps()` already enumerates `/Applications` and `~/Applications` with bundle IDs. |
| 4 | `FocusSessionManager.swift:167` | Code quality | `actualMinutes: max(1, Int((Double(actualSeconds) / 60).rounded()))` — a session ended 5 seconds in reports "1 minute" in the summary, the `AlertLog` entry, and the Focus History row. | Low | Report sub-minute durations honestly ("under a minute"), or don't log sessions below a floor. |
| 5 | `FocusSessionManager.swift:133` | Business requirement | `topProcesses(sortBy: .ram, limit: 3)` means an app sitting at #4 all session never contributes a sample, and the reported "top RAM process" is whichever of the rotating top-3 peaked highest. The "built from real samples" claim holds — nothing is fabricated — but the label deserves to say what it measured. | Low | Raise the limit (the actor already returns a sorted list; `limit: 10` costs little at 5 s), or relabel as "peak among top memory consumers". |
| 6 | `FocusSessionManager.swift:60` | Blast radius | This is the fourth independent `ProcessMonitor` instance across the batch, sampling every 5 s for the whole session. | Low | See B6. |

## Blocking issues

- **Control flow / lifecycle** — 1

## Non-blocking suggestions

- 2 and 3 are Medium; 3 is the one users will notice first.
- 4, 5, 6 are Low.
- `maxCPUPercent: maxCPUUsage * 100` is **correct** — `AppState.cpuUsage` is a 0–1 fraction throughout the codebase (`MenuBarFormatRenderer` and `calculateHealthScore` both treat it that way). Noting it because it reads like a double-scaling bug and shouldn't be "fixed".
- `start(minutes:bundleIDsToHide:)` correctly skips apps already hidden by the user (`!app.isHidden`), so they are not spuriously unhidden at session end. Good; don't regress.
- `tick()` derives `remainingSeconds` from `endDate.timeIntervalSinceNow` rather than decrementing, so the countdown self-corrects across sleep. Good design.

## Questions for the author

1. What should happen to hidden apps if Halo is quit mid-session (issue 1)? Restore on quit, restore on next launch, or resume the session?
2. Was the running-apps-only picker (issue 3) a deliberate v1 simplification?

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
