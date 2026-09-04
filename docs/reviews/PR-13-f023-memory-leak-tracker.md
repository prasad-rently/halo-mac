# Code review — PR #13 · F-023 Memory Leak & App Bloat Tracker

- **PR:** [prasad-rently/halo-mac#13](https://github.com/prasad-rently/halo-mac/pull/13)
- **Branch:** `feat/f023-memory-leak-tracker` → `main`
- **Reviewed at:** commit `53271e09` · 17 files, +897 / −7
- **Inline comments:** [review 5113194499](https://github.com/prasad-rently/halo-mac/pull/13#pullrequestreview-5113194499)

## Verdict: **Request changes**

Extending `ProcessMonitor` with `runningAppRAMSamples()` keyed by bundle ID — so a "Restart App"
that changes the PID preserves the same history — is the right modelling call, and using
`proc_pidinfo`/`pti_resident_size` rather than shelling out to `ps` is the right implementation
(worth contrasting with #10, which does shell out for the same value). The sample-gap reset
(>5 min → streak resets, because the Mac was probably asleep) is a genuinely thoughtful edge case,
and the badge copy correctly says "possible" rather than "confirmed".

Blocking: `restart()` force-terminates the target app 1.5 s after a polite `terminate()`, which
discards unsaved work in exactly the apps most likely to still be running.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/MemoryTrendTracker.swift:189` | Logical lapses | `terminate()` sends a polite quit request; an app with unsaved documents responds by presenting a save sheet and *not* quitting — that is the whole point of the polite path. This code waits 1.5 s, finds it still running, and calls `forceTerminate()` (SIGKILL): the save dialog disappears along with the document. The failure mode is exactly inverted — the apps still running after 1.5 s are the ones with unsaved state. 1.5 s is also too short for heavy apps to quit cleanly even with nothing unsaved (Xcode, Photoshop, Docker Desktop). The confirmation dialog satisfies CLAUDE.md, but it cannot inform a decision the user doesn't know they're making. | High | Drop the force path: poll for actual exit (up to ~20 s) and relaunch only once the app has really gone; if it is still running, leave it alone and report *"didn't quit — it may have unsaved changes."* If force-quit is genuinely wanted it needs its own confirmation naming the risk, not a 1.5 s timeout. |
| 2 | `MemoryTrendTracker.swift:150` | Business requirement | The streak resets only on a >15% drop below the running peak, and the verdict is `streakDuration >= 3600 && latest.ramMB > streakStartRAM`. Neither requires growth to be *ongoing*. Worked example: RAM rises 1000 → 1200 MB in ten minutes, drops to 1100, then sits flat at 1100 for 110 minutes. `streakPeak` = 1200; 1100 > 1020 so no reset; `streakStartRAM` is still 1000; `latest` (1100) > 1000; duration > 1 h → **"Possible memory leak"** for an app whose memory hasn't moved in nearly two hours. That is the common shape for a browser or IDE that allocates at startup and plateaus, so it is likely the *typical* case. The header and `FEATURE_ROADMAP` both describe the rule as "grown monotonically for more than 1 hour", which is not what's implemented. | Medium | Add a slope requirement over the tail: require the last ~30 minutes to have a positive least-squares slope, or require `latest.ramMB > streakStartRAM * 1.10` so a plateau within noise of the start doesn't qualify. |
| 3 | `MemoryTrendTracker.swift:115` | Code quality | `byID` is seeded from all existing `histories` and only currently-running apps are refreshed; nothing ever removes an entry. Quit an app and its `AppMemoryHistory` persists forever, its samples aging out to leave a permanent zero-sample record. Over weeks `histories` accumulates one entry per app ever launched — and every one is JSON-encoded and written to disk on every 30-second tick, on the MainActor. | Medium | `.filter { !$0.samples.isEmpty }` when rebuilding `histories`; move `persistToDisk()` off the main actor or debounce it (a lost 30 s bucket on unclean exit is immaterial here). |
| 4 | `MemoryTrendTracker.swift:54` | Security / privacy | `memoryTrendHistory.json` persists, indefinitely and unconditionally, a timestamped list of every application the user runs — a usage log revealing working hours, which apps are open when, and which are never used. Its sibling #10 collects strictly less and is correctly gated behind an off-by-default `haloAppUsageTrackingEnabled` toggle with a "Clear Usage History" action, explicitly matching the `enableAnalytics` convention. This starts unconditionally from `AppState.init()` with neither. | Medium | Mirror #10: opt-in default, Settings toggle, clear-history button. Leak *detection* could still run in-memory when the toggle is off. See B7. |
| 5 | `Halo/Core/Scanner/ProcessMonitor.swift:87` | Code quality | `runningAppRAMSamples()` is actor-isolated, so it runs on a cooperative pool thread — and it calls `NSWorkspace.shared.runningApplications`, then `app.localizedName` / `app.bundleURL` on each result. `NSWorkspace` is main-thread-affine AppKit; `runningApplications` is tolerant in practice but not documented thread-safe, and `localizedName` reads through to bundle info AppKit caches without synchronization. Works until it intermittently doesn't. The same API is touched correctly from `@MainActor` in `restart()` on line 183. | Medium | Gather the app list on the MainActor and pass `(pid, bundleID, name, path)` tuples into the actor, which then only does the `proc_pidinfo` reads. Same note applies to `PermissionAuditor.appName(forBundleID:)` in #9. |
| 6 | `MemoryTrendTracker.swift:63` | Code standards | Constructs its own `AlertManager()` while `AppState` already has a private one. `AlertManager` keeps cooldown timestamps in instance state, so the two don't coordinate — the cooldown contract becomes per-instance rather than global. #16 and #20 each add methods reached through *different* instances again. | Low | Promote to `AlertManager.shared`, matching `AlertLog.shared` right beside it. See B6. |
| 7 | `MemoryTrendTracker.swift:211` | Code quality | `storageURL` is a computed property that calls `FileManager.createDirectory` on every read, and it is read from `persistToDisk()` every 30 seconds — a no-op syscall on the main thread twice a minute. | Low | Compute once in `init`. |
| 8 | `Halo.xcodeproj/project.pbxproj` | Code standards | Claims UUIDs `8031`–`8034`; #21 and #9 also claim `8031`/`8032`. | High | See B1. |

## Blocking issues

- **Logical lapses / data loss** — 1
- **Code standards** — 8 (and B1, B2, B3)

## Non-blocking suggestions

- 2, 3, 4, 5 are Medium. 2 is a requirement/implementation mismatch worth resolving before merge since the badge is the feature's headline output; 4 should be settled jointly with #10 (B7).
- 6, 7 are Low.
- `leakStatus`'s handling of a slow *decline* is correct — the final `latest.ramMB > streakStartRAM` comparison catches it. Noting so a refactor doesn't remove that guard.
- `start()`'s `guard !didStart` idempotence is correct and worth keeping.

## Questions for the author

1. **Is `forceTerminate()` intentional** (issue 1)? If so it needs an explicit data-loss warning in the confirmation.
2. Was the plateau case (issue 2) considered? "No >15% drop and net positive" is a materially weaker rule than "grown monotonically", and the docs claim the latter.
3. Should this be opt-in like #10 (issue 4)?

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
