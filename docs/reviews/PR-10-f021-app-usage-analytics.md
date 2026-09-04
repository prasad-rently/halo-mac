# Code review — PR #10 · F-021 App Usage & Screen Time Analytics

- **PR:** [prasad-rently/halo-mac#10](https://github.com/prasad-rently/halo-mac/pull/10)
- **Branch:** `feat/f021-app-usage-analytics` → `main`
- **Reviewed at:** commit `fedeb596` · 15 files, +1073 / −4
- **Inline comments:** [review 5115646546](https://github.com/prasad-rently/halo-mac/pull/10#pullrequestreview-5115646546)

## Verdict: **Request changes**

The privacy posture here is the best in the batch and should be the reference for the others:
off-by-default opt-in, a Settings → Privacy toggle matching the existing `enableAnalytics`
convention, a Clear Usage History action, and honest gating (`nil` until ≥1 hour / ≥14 days rather
than extrapolating). The "Important limitation — please read" section is exactly right about
`FamilyControls` being entitlement-gated, and making a 30 s timer the source of truth rather than
elapsed-time-since-activation genuinely does avoid counting sleep as usage. Extracting the
aggregation logic as pure `static` functions over `(records, now)` so `HaloTests` can exercise it
against synthetic data is good structure.

Two correctness problems block merge, both in the attribution path.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/AppUsageTracker.swift:138` | Logical lapses | `handleActivation` returns early when the newly-activated app is in `excludedBundleIDs` — but *without touching `activeBundleID`*. So `activeBundleID` still names the previous app, and `tick()` keeps matching it against the running-apps list and calling `accrueForeground` every 30 s. The excluded set is Finder, Dock, SystemUIServer, WindowManager, Control Center, Notification Center, loginwindow and Halo — precisely the things users bounce into and linger in. Ten minutes copying files in Finder credits ten minutes of foreground time to Xcode. **Screen lock has the same effect**: `loginwindow` activates, the guard returns early, and the last app accrues foreground time for the entire locked period. That is the exact failure mode the header says the design avoids — handled for *system* sleep, but not for lock or display sleep, where the timer keeps firing. | High | Clear the active app in the excluded branch instead of returning: `activeBundleID = nil; activeAppName = nil; activePID = nil`. For lock/display sleep, observe `NSWorkspace.screensDidSleepNotification` and the `com.apple.screenIsLocked` distributed notification and null out the active app for the duration. |
| 2 | `AppUsageTracker.swift:370` | Code quality | `processRAMMB(pid:)` builds a `Process`, runs `/bin/ps -p <pid> -o rss=`, and blocks on `waitUntilExit()` — called from `tick()`, which runs on the MainActor. That is a fork/exec plus teardown (typically 10–30 ms) on the UI thread twice a minute, forever, whenever tracking is enabled. `ProcessMonitor` reads exactly this value with no subprocess at all via `proc_pidinfo(pid, PROC_PIDTASKINFO, …)` → `pti_resident_size`, and #13 in this same batch adds `runningAppRAMSamples()` on top of it for the same purpose. | Medium | Use `proc_pidinfo` directly, or call into `ProcessMonitor`. Removes the subprocess, the main-thread block and the duplication. (This helper also has the `waitUntilExit()`-before-read ordering that deadlocks elsewhere in the batch — `ps -o rss=` output is a few bytes so it won't bite here, but it is the same copied shape. See B5.) |
| 3 | `AppUsageTracker.swift:227` | Business requirement | The doc comment says "observed running **continuously** for a long stretch (default 8 h)" and the PR body says "apps observed running 8h+", but the implementation sums `observedRunningSeconds` across the whole 7-day window and compares that total to `minObservedHours`. The real threshold is *8 cumulative hours over a week* — a bit over an hour a day. Any menu-bar utility, sync client, or app left open during the workday clears it, and the `maxForegroundRatio: 0.02` filter won't exclude them because a background helper by definition has near-zero foreground time. The section will list most of the user's normal background apps as "hogs", which isn't actionable. | Medium | Either raise the bar substantially (per-day check, or a much larger cumulative figure) or track a genuine continuous run length — `AppUsageRecord` is already day-bucketed, so "≥N hours on each of ≥M days" would be cheap and much closer to the stated intent. Whichever way, make the comment and PR text match the rule. |
| 4 | `AppUsageTracker.swift:186` | Code quality | `todayIndex` is an O(records) linear scan doing `Calendar.current.isDate(_:inSameDayAs:)` per element, called once per running app per tick — plus again for `accrueForeground` and `accrueRAMSample`. With 14-day retention and ~30 apps that is roughly 12 600 calendar comparisons every 30 s on the main thread. `pruneOldRecords()` and `persistToDefaults()` also both run every tick. | Low | A `[String: Int]` index for today's bucket, rebuilt on day rollover, reduces this to a dictionary lookup. Debounce the persist to every Nth tick — a lost 30 s bucket on unclean exit is immaterial. |
| 5 | `AppUsageTracker.swift:91` | Business requirement | `com.apple.finder` is in `excludedBundleIDs`, so Finder never appears in the top-apps chart even though it is a regular Dock-visible app users genuinely spend time in. The comment justifies the set as "menu-bar agents / system UI processes", which fits the others but not Finder. Combined with issue 1, Finder time is currently both uncounted *and* misattributed. | Low | Decide explicitly: treat Finder as a real app and let it rank, or keep it excluded and say why in the comment so the next reader doesn't "fix" it. |

## Blocking issues

- **Logical lapses** — 1

## Non-blocking suggestions

- 2 and 3 are Medium. 3 is a requirement/implementation mismatch worth resolving before merge since "Background Hogs" is one of the card's four sections.
- 4, 5 are Low.
- The deliberate choice of UserDefaults+JSON over the feature card's SQLite spec is well-reasoned and consistent with `AlertLog` / custom actions / widget data. No action needed.
- `stop()` correctly removes the notification observer and invalidates the timer — lifecycle is clean.
- Every UI surface carrying "Based on time Halo has been running" is the right disclosure. Keep it.

## Questions for the author

1. Should the previously-active app stop accruing when the user switches to Finder or locks the screen (issue 1)? I read the intent as yes, given the header's stance on sleep.
2. Is "Background Hogs" meant to be cumulative or continuous (issue 3)?
3. Is Finder's exclusion deliberate (issue 5)?

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
