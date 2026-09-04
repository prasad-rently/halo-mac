# Code review — PR #16 · F-022 Time Machine Backup Health Monitor

- **PR:** [prasad-rently/halo-mac#16](https://github.com/prasad-rently/halo-mac/pull/16)
- **Branch:** `feat/f022-time-machine-monitor` → `main`
- **Reviewed at:** commit `de8390f6` · 15 files, +817 / −4
- **Inline comments:** [review 5113169763](https://github.com/prasad-rently/halo-mac/pull/16#pullrequestreview-5113169763)

## Verdict: **Request changes**

The heatmap logic is careful in the right way: distinguishing `.noData` from `.missed` so a day
before the earliest known snapshot is never coloured red, and returning an all-`.noData` grid
rather than an empty one when there is no history at all. `.notConfigured` with a "Set Up Time
Machine" empty state — rather than a fake healthy card — is the right response to a dev machine
with no destination. Capacity read from the mounted volume (which naturally reads as nil when the
drive is unplugged) rather than invented is also right.

Blocking: the shared `Process` helper reads the pipe after `waitUntilExit()`, and
`tmutil listbackups` is precisely the command that overflows the 64 KB buffer on a Mac with real
backup history — so the deadlock only appears on machines where the feature is supposed to work,
and never on the dev machine that has no destination configured.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/TimeMachineMonitor.swift:186` | Logical lapses | `waitUntilExit()` (186) precedes `readDataToEndOfFile()` (190), and `standardError` is an undrained `Pipe()`. `tmutil listbackups` prints one absolute snapshot path per line; a destination with a year of hourly-then-thinned backups holds well over a thousand snapshots at ~70–90 bytes each — comfortably past 64 KB. `tmutil` then blocks writing, `status()` blocks in `waitUntilExit()`, and the actor is wedged. `AppState.refreshTimeMachineStatus()` awaits it, so the 15-minute timer's tasks queue behind it forever and `isCheckingTimeMachine` stays `true` — a permanent spinner on the Dashboard. Invisible on the author's machine, since `status()` returns early at `destinationinfo` before `listbackups` is ever reached. | High | Read → wait → check `terminationStatus`; `FileHandle.nullDevice` for stderr. |
| 2 | `Halo/Core/AlertManager.swift:126` | Logical lapses | `guard status.isStale, let last = status.lastBackupDate else { return }`, and `isStale` itself already requires a non-nil `lastBackupDate`. So a Mac where Time Machine is *configured* but has never completed a backup — destination selected, drive never plugged in, or every attempt failed — produces `lastBackupDate == nil`, `isStale == false`, and **no alert ever**. That is the scenario where the user is most likely to believe they are protected and not be. | Medium | Add a distinct branch for `isConfigured && lastBackupDate == nil`: *"Time Machine is set up but has never completed a backup."* The heatmap already models this correctly as all-`.noData`, so the data is there. |
| 3 | `TimeMachineMonitor.swift:140` | Logical lapses | `parseDestinationInfo` only looks for `Name` and `Mount Point`. For a network destination (Time Capsule, NAS, any SMB/AFP share) `tmutil destinationinfo` emits a `URL` key instead — there is no local mount path until the sparsebundle is mounted. Result: `mountPoint == nil` → `isReachable = false`, no capacity. A healthy, currently-backing-up network destination shows as unreachable with no free-space bar, indefinitely. | Medium | Parse `URL` as well, and treat a network destination as a distinct reachable-but-unmeasurable case — "we can't measure its capacity" and "it's disconnected" are different facts, and this codebase is otherwise careful to keep them apart. |
| 4 | `Halo/Core/Models/Models.swift:551` | Code quality | `BackupHeatmapDay.id = UUID()` regenerates on every `heatmap()` call, and `heatmap` is a pure function called from the view so it re-runs on every render — `ForEach` sees 30 brand-new cells each time and rebuilds them all. | Low | `var id: Date { date }`. See B8. |
| 5 | `TimeMachineMonitor.swift:118` | Exception handling | `startBackupNow()` returns a bare `Bool`. On recent macOS `tmutil startbackup` requires the caller to hold Full Disk Access; without it the command exits non-zero and the user gets a silent `false` with no explanation. The doc comment is otherwise careful about accepted-vs-finished, which is good. | Low | Surface the exit status / stderr as a message rather than a Bool. |
| 6 | `TimeMachineMonitor.swift:118` | Business requirement | Under `Halo.entitlements` the `tmutil startbackup` spawn is denied outright, so "Back Up Now" is inert in the App Store build — as is the whole monitor. | Medium | See B4. |

## Blocking issues

- **Logical lapses** — 1

## Non-blocking suggestions

- 2 and 3 are Medium and both produce a wrong verdict on a real user configuration; worth fixing before merge rather than after.
- 4, 5, 6 are Low/Medium.
- `heatmap`'s `.late` (gap 1) vs `.missed` (gap ≥ 2) split is a reasonable design choice given Time Machine's hourly cadence; noting it as deliberate rather than an issue.
- `backupPathFormatter` correctly uses `en_US_POSIX` + `TimeZone.current`, which matches how `tmutil` names snapshots. No action needed.

## Questions for the author

1. Has `listbackups` been run against a destination with substantial history (issue 1)? The deadlock is size-dependent and the dev machine can't reach that code path.
2. Are network destinations in scope (issue 3)? If not, the card should say so rather than showing them as unreachable.
3. Should a configured-but-never-backed-up Mac alert (issue 2)?

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
