# Proposed merge order — 16 open PRs

Generated 2026-09-04 from a full review of every open PR. Per-PR findings live in
`docs/reviews/PR-*.md` (one file per PR, committed to that PR's own branch).

## Why an order is needed

All thirteen PRs in the `F-016 … F-030` batch (#9–#21) branch off `main` and every one of them
edits the same eight files:

```
Halo.xcodeproj/project.pbxproj
Halo/Core/Models/Models.swift
HaloTests/HaloTests.swift
CLAUDE.md
docs/FEATURE_ROADMAP.md
docs/ROADMAP.md
docs/MANUAL_TEST_PLAN.md
docs/HALO_MOBILE_ROADMAP.md
```

GitHub reports all thirteen as `MERGEABLE` because mergeability is computed pairwise against
`main`. The moment one merges, the other twelve conflict. Most of those conflicts are in
append-only regions (roadmap tables, the tail of `Models.swift`, pbxproj build-phase lists) so
they are mechanical — but there are twelve of them, and each rebase invalidates whatever local
`xcodebuild` verification that PR's description cites.

Beyond the universal eight, contention clusters like this:

| File | PRs that touch it |
|------|-------------------|
| `Halo/App/AppState.swift` | #20, #16, #13, #11, #21 |
| `Halo/Core/AlertManager.swift` | #20, #16, #13 |
| `Halo/Features/Dashboard/DashboardView.swift` | #16, #11, #10, #14 |
| `Halo/Features/Protection/ProtectionView.swift` | #21, #18, #9 |
| `Halo/Features/Onboarding/OnboardingView.swift` | #11, #10, #14 |
| `Halo/Features/Files/FilesView.swift` | #12, #19 |
| `Halo/App/HaloApp.swift` | #11, #10 |
| `Halo/Core/Scanner/ProcessMonitor.swift` | #13 |

The order below is built on two rules: **merge by readiness** (fewest blocking issues first), and
**cluster PRs that share a hot file** so those conflicts get resolved once, consecutively, by
someone with the context already loaded.

---

## Phase 0 — pre-work (before any feature PR)

These are new, small PRs. Four of the eight batch-level issues collapse to a single fix each if
done here rather than thirteen times afterwards.

| Step | What | Fixes | Why first |
|------|------|-------|-----------|
| **P0.1** | Add `.github/workflows/ci.yml` — `xcodebuild build` for the `HaloUITests` scheme + `xcodebuild test` for `HaloTests`, both with `CODE_SIGNING_ALLOWED=NO` | B3 | There is no CI at all today. Every PR body asserts `BUILD SUCCEEDED` from an unverifiable local run, and all thirteen claims are invalidated by the rebases this order requires. `HaloTests` already has fast, pure-logic suites from these PRs that currently gate nothing. |
| **P0.2** | Extract one `ShellReader` helper: `run(_ path:_ args:) -> (stdout: String, exitCode: Int32)`, reading the pipe **before** `waitUntilExit()` and sending stderr to `FileHandle.nullDevice` | B5 | The same `waitUntilExit()`-before-read bug appears in five PRs (#21, #17 ×2, #16, #9, #10). Three of those deadlock for real. Several cite `SecurityPostureScanner` as the reference implementation, so fixing the shape once and having the others adopt it turns five fixes into one. |
| **P0.3** | Promote `AlertManager` and `ProcessMonitor` to `.shared` singletons (matching `AlertLog.shared` beside them) | B6 | #13/#16/#20 each add an `evaluate*` method reached through a *different* `AlertManager` instance, so the cooldown contract is per-instance rather than global. #11/#13/#14 each construct their own `ProcessMonitor`, giving four overlapping process enumerations. Much cheaper before all four land. |
| **P0.4** | Reserve pbxproj UUID blocks in `CLAUDE.md` and reassign the collisions | B1 | #21, #13 and #9 all claim `8031`/`8032`. Whichever two merge second produce duplicate object IDs — Xcode may accept them while mapping a `PBXBuildFile` to the wrong `fileRef`, which fails quietly. Suggest: #21 keeps `8031`/`8032`, #13 → `8113`–`8116`, #9 → `8153`/`8154`. |
| **P0.5** | Extract `AsyncTimeout` — one wall-clock ceiling for callback work that cannot be cancelled | R3/R4 | F-017 and F-025 independently wrote the same timeout and it was wrong the same way in both: racing a `Task.sleep` sibling inside a `withTaskGroup` bounds the returned *value* and not the *time*, because the group joins every child before returning and `cancelAll()` cannot interrupt a `withCheckedContinuation`. Measured, a 1.5 s "ceiling" over 5 s of work returned nil after 5.01 s; where the work may never call back, the caller blocked forever. Both branches now merge P0.5 and use it. Off `main` rather than on P0.2, so adopting it does not also drag in `ShellReader`'s eight call-site changes. **Note P0.5 and P0.2 both number their CLAUDE.md gotcha 20** — whichever merges second renumbers to 21. |

> **⚠️ P0.3 breaks #13 and #14 without a merge conflict.** `phase0/shared-singletons` gives
> `AlertManager` and `ProcessMonitor` a `private init()`. `AppState.swift` and
> `TopProcessesSection.swift` construct them directly and are in the universal-eight hot set, so
> those call sites surface as ordinary conflicts during rebase. These two do not:
>
> ```
> feat/f023-memory-leak-tracker  MemoryTrendTracker.swift:91  ProcessMonitor()
> feat/f023-memory-leak-tracker  MemoryTrendTracker.swift:92  AlertManager()
> feat/f028-focus-session        FocusSessionManager.swift:57 ProcessMonitor()
> ```
>
> Phase 0 never touches either file, so git merges them cleanly and the result does not compile.
> Expect it when rebasing #13 and #14 — a clean merge is not a signal here.

Also worth settling in Phase 0, though it is a decision rather than a commit:

> **The `Process` + release-sandbox question (B4).** Six features (#21, #20, #17, #16, #10, #9)
> shell out, and `posix_spawn` is denied under `Halo.entitlements`. All six degrade honestly rather
> than fabricating — which is right — but it means six features whose value exists only in the
> unsandboxed Debug build, while the PR bodies describe them as working. This needs **one** answer
> for the batch (Debug/direct-distribution only and say so in the UI, or route through the F-002
> privileged helper), not six.

---

## Phase 1 — `AppState` + `AlertManager` core

Merge consecutively; all three touch both files, and #20 establishes the pattern (periodic
timer in `AppState.init()` → actor scan → `AlertManager.evaluate*`) that the other two follow.

| # | PR | Feature | Verdict | Blocking |
|---|----|---------|---------|----------|
| 1 | [#20](https://github.com/prasad-rently/halo-mac/pull/20) | F-020 S.M.A.R.T. Disk Health | Approve with comments | 1 High (stale volume attribution) |
| 2 | [#16](https://github.com/prasad-rently/halo-mac/pull/16) | F-022 Time Machine Monitor | Request changes | 1 High (`listbackups` deadlock — resolved by P0.2) |
| 3 | [#13](https://github.com/prasad-rently/halo-mac/pull/13) | F-023 Memory Leak Tracker | Request changes | 1 High (`forceTerminate` data loss) |

**#20 goes first deliberately.** It is the most ready PR in the batch (one blocking issue), and it
is the only one that already gets the `Process` pipe ordering right — so it is the reference the
P0.2 helper should be modelled on.

---

## Phase 2 — Dashboard + Settings surfaces

All three touch `DashboardView.swift` and `OnboardingView.swift`; #11 also touches `AppState.swift`
and `HaloApp.swift`, so it bridges cleanly from Phase 1.

| # | PR | Feature | Verdict | Blocking |
|---|----|---------|---------|----------|
| 4 | [#11](https://github.com/prasad-rently/halo-mac/pull/11) | F-029 Weekly Digest | Request changes | 1 High (threat count from prose) |
| 5 | [#10](https://github.com/prasad-rently/halo-mac/pull/10) | F-021 App Usage Analytics | Request changes | 1 High (foreground time misattributed) |
| 6 | [#14](https://github.com/prasad-rently/halo-mac/pull/14) | F-028 Focus Session | Request changes | 1 High (apps stay hidden on quit/crash) |

**Settle B7 across #10 and #13 while both are in flight.** Both persist an app-usage behavioural
profile; #10 is off-by-default with a Settings toggle and a clear action, #13 is unconditional with
neither. If both land as-is the app has two answers for the same class of data and the App Privacy
questionnaire has to describe the stricter one.

---

## Phase 3 — Protection module

All three add a section to `ProtectionView.swift` and extend `ProtectionViewModel`. #21 also
touches `AppState.swift`.

| # | PR | Feature | Verdict | Blocking |
|---|----|---------|---------|----------|
| 7 | [#21](https://github.com/prasad-rently/halo-mac/pull/21) | F-019 Security Posture | Request changes | 2 High + description/diff mismatch |
| 8 | [#18](https://github.com/prasad-rently/halo-mac/pull/18) | F-018 Privacy Exposure Scanner | Request changes | 2 High + 1 security Medium |
| 9 | [#9](https://github.com/prasad-rently/halo-mac/pull/9) | F-016 Permission Auditor | Request changes | 1 High (+ untested happy path) |

**#9 needs a verification pass before it can be reviewed properly.** Its entire happy path is
unexercised because `TCC.db` was unreadable during development. Granting Full Disk Access to a debug
build once would settle three of its findings at the same time. Do that before it reaches the front
of the queue.

**Resolve #21's description mismatch before merge** — it claims a Settings rework wiring "8
previously-dead placeholder controls" that is not present in the diff.

---

## Phase 4 — Files module

Both add a tab to `FilesView.swift`'s `FilesTab` enum.

| # | PR | Feature | Verdict | Blocking |
|---|----|---------|---------|----------|
| 10 | [#12](https://github.com/prasad-rently/halo-mac/pull/12) | F-030 iCloud Drive Analyzer | Request changes | 1 High (evicted files count 0 bytes) |
| 11 | [#19](https://github.com/prasad-rently/halo-mac/pull/19) | F-025 Duplicate Photos | Request changes | 1 Critical + 3 High |

**#19 also needs an App Store decision** before merge: it adds the Photos entitlement and
`NSPhotoLibraryUsageDescription` to the **release** configuration for a path the PR itself labels
experimental and never runtime-tested. Splitting the PhotoKit half into its own PR would let the
loose-file finder land on its own.

---

## Phase 5 — isolated surfaces, most rework remaining

Neither shares a hot file with anything above, so they can be worked in parallel with Phases 1–4
and merged whenever ready. They are last because they need the most work, not because they are
blocked by anything.

| # | PR | Feature | Verdict | Blocking |
|---|----|---------|---------|----------|
| 12 | [#15](https://github.com/prasad-rently/halo-mac/pull/15) | F-024 Browser Cleaner | Request changes | 1 Critical + 1 High (both data-loss) |
| 13 | [#17](https://github.com/prasad-rently/halo-mac/pull/17) | F-017 Network Traffic Monitor | Request changes | 2 Critical + 1 High |

#15's two blockers are both destructive-path bugs (shared cookie store, live SQLite corruption), so
it should not merge on schedule pressure. #17's two Criticals are the same deadlock fixed by P0.2,
so its real remaining work is the serial reverse-DNS loop.

---

## Outside the batch

| PR | Feature | Verdict | Recommendation |
|----|---------|---------|----------------|
| [#1](https://github.com/prasad-rently/halo-mac/pull/1) | Maestro + XCUITest | Request changes | **Close.** `main` already contains a 21-file `HaloUITests` target (including `HaloSidebar.swift`) landed via another branch, which is what #9–#21 all extend. This PR still adds it as new files, hence the `CONFLICTING` state. Cherry-pick only the version-string hunk if wanted. Decide this *first* — it costs nothing and removes a stale PR from the queue. |
| [#6](https://github.com/prasad-rently/halo-mac/pull/6) | docs/specs planning | Approve with comments | Retarget from the merged `feature/f-043-drive-speed-test` to `main`. Answer the `india-bank-sms.v1.json` licence/provenance question before it enters git history. Then merge — it is docs-only and unblocks #7. |
| [#7](https://github.com/prasad-rently/halo-mac/pull/7) | F-044 cloud foundation | Request changes | **Split.** The title says "Phase 0 foundation + spike" but the diff also ships a full SMS console, clipboard sync, and an expenditure tracker — 4 features, 5 306 lines, 36 files, 14 commits. Land `Core/Cloud/*` + the entitlement + package wiring + `CloudFoundationTests` on its own after #6; give F-045/F-048 their own PRs. Fix the two discarded `SecRandomCopyBytes` results and the passphrase-strength gap in the foundation PR. |

---

## Summary

```
Phase 0   P0.1 CI  →  P0.2 ShellReader  →  P0.3 shared singletons  →  P0.4 UUID blocks
          →  P0.5 AsyncTimeout
          (+ decide B4 sandbox scope, and close #1)
          P0.3 breaks #13/#14 compilation with no conflict — see the warning above

Phase 1   #20  →  #16  →  #13          AppState + AlertManager
Phase 2   #11  →  #10  →  #14          Dashboard + Settings   (settle B7 here)
Phase 3   #21  →  #18  →  #9           Protection             (#9 needs an FDA pass first)
Phase 4   #12  →  #19                  Files                  (#19 needs a store decision)
Phase 5   #15  ,   #17                 isolated, most rework

Separate #6 (retarget → main)  →  #7 (split, foundation only)
```

Nothing in Phases 1–5 is blocked by anything in another phase, so the phases exist to minimise
rebase pain rather than to express hard dependencies. If a PR in an earlier phase stalls on its
blocking issues, skip it and keep the order otherwise intact — just expect to resolve its hot-file
conflicts later rather than sooner.
