# Manual Test Plan — PR #1: Maestro E2E flows + XCUITest suite + onboarding re-prompt fix

> **Branch:** `feat/maestro-e2e-tests` · **Base:** `main`
> **Status:** 🔶 Open, not yet merged. **Oldest open PR** (2026-05-06) — `mergeable`/`mergeStateStatus`
> currently report `UNKNOWN` on GitHub, meaning it hasn't been recomputed recently; expect it to need
> a rebase/recheck, and read the staleness notes below before investing review time.
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/1
> **Diff size:** 18 files changed, +1138/-5

## ⚠️ Read this before testing — likely superseded in part

`main` already has a much more developed `HaloUITests` target today than this PR adds: dozens of
per-module files (`SmokeUITests.swift`, `DashboardUITests.swift`, `FilesUITests.swift`, a
`HaloSidebar.swift` page object, `HaloTestFixtures.swift` safety harness, etc.), built up by later
work independent of this PR. This PR instead adds one single monolithic
`HaloUITests/HaloUITests.swift` with 27 tests, plus its own `project.pbxproj` target wiring. Two
concrete risks:

1. **Duplicate/conflicting `HaloUITests` target definition.** `main`'s target was (re)built via
   `scripts/add_uitest_target.rb`, which *fully regenerates* the target from a directory glob.
   Merging this PR's separate pbxproj edits on top risks a broken or duplicated target rather than
   a clean merge, even though Git itself may report no textual conflict.
2. **The "About version" fix is likely already fixed independently.** `main` shows no hardcoded
   `"Version 1.0.0 (Build 100)"` string anywhere today (confirmed by grep) — it already reads a
   live build label elsewhere in the app. Verify this specific fix is still needed before treating
   it as this PR's contribution.

The **onboarding re-prompt-on-relaunch bug fix**, on the other hand, looks like it may still be
relevant — verify with TC-MAESTRO-01 below before assuming otherwise.

## How to test this PR

```bash
git fetch origin feat/maestro-e2e-tests
git checkout feat/maestro-e2e-tests
```

Build & sign per `CLAUDE.md` → "Build & Sign" (XCUITests need a **signed** app — unlike a normal
Debug build, `CODE_SIGNING_ALLOWED=NO` won't let the UI test runner launch it).

## Source files this PR adds/changes

- `.maestro/config.yaml` + `.maestro/flows/*.yaml` (12 files) — YAML flow specs
- `Halo.xcodeproj/project.pbxproj`, `.../xcschemes/HaloUITests.xcscheme` — new UI-test target
- `Halo/App/AppState.swift` — `--uitesting` launch-arg bypass for onboarding
- `Halo/Features/Onboarding/OnboardingView.swift` — `UserDefaults.synchronize()` after completion write; live version string in About
- `HaloUITests/HaloUITests.swift` — 27 XCUITest cases across 11 modules

## Test cases

### 1. The onboarding re-prompt bug fix (the part most likely to still matter)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MAESTRO-01 | P0 | Onboarding doesn't reappear on relaunch | Complete onboarding fully, quit Halo (⌘Q), relaunch | Main window opens directly — onboarding does **not** reappear |
| TC-MAESTRO-02 | P1 | Fix mechanism is real, not coincidental | Inspect `OnboardingView.swift`'s completion handler | `UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")` is followed by `UserDefaults.standard.synchronize()` before the app considers onboarding done |
| TC-MAESTRO-03 | P2 | `--uitesting` bypass is read-only and production-safe | Launch normally (no launch args) vs. launch with `-uitesting YES` | Normal launch: onboarding still gates on the real completion flag. With the flag: onboarding is bypassed regardless of stored state — confirms the bypass can't accidentally fire in a real user's production launch |

### 2. About version string (verify before crediting this PR)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MAESTRO-04 | P2 | Version string is live, not hardcoded | Open Settings → About (or wherever the version is shown) on both `main` and this branch | If `main` already shows a real, non-hardcoded version (it does as of this writing — no `"Version 1.0.0 (Build 100)"` string exists in the tree), this fix is redundant; note that in review rather than re-verifying a fix that already landed elsewhere |

### 3. XCUITest target — build & run health

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MAESTRO-05 | P0 | `project.pbxproj` merges cleanly | Merge this branch onto current `main` locally (don't push) | No duplicate `HaloUITests` target, no broken file references; `xcodebuild -list` shows exactly one `HaloUITests` scheme |
| TC-MAESTRO-06 | P0 | Suite builds | `xcodebuild build-for-testing -project Halo.xcodeproj -scheme HaloUITests -destination 'platform=macOS'` | Builds clean |
| TC-MAESTRO-07 | P1 | Suite runs against a signed build | `xcodebuild test -project Halo.xcodeproj -scheme HaloUITests -destination 'platform=macOS' CODE_SIGN_IDENTITY="Apple Development: MobileApp Developers (ZWA6Q77327)" CODE_SIGN_STYLE=Manual` | All 27 tests execute (pass/fail aside, they must actually run, not error out on launch) |
| TC-MAESTRO-08 | P0 | Destructive test paths only confirm-and-cancel | Read through `Clean Selected` / `Uninstall` / `Clear All` test cases in `HaloUITests.swift` | Every one drives to its confirmation sheet and cancels — per the PR's own reviewer notes, no test should leave real files modified |

### 4. Maestro flows — documentation review, not execution

Per the PR's own description, Maestro doesn't support macOS desktop apps (iOS/Android/RN/Flutter/
web only) — these 12 YAML files are **not runnable** today. Review them as structured,
human-readable test documentation instead of trying to execute them:

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MAESTRO-09 | P2 | Flows are accurate documentation | Read each `.maestro/flows/*.yaml` against the current app | Each flow's described steps still match current UI (some may have drifted given how much the app has grown since May) |
| TC-MAESTRO-10 | P3 | Flag drift, don't "fix" silently | Any flow that's clearly stale (references removed UI, old module names) | Note it for a follow-up rather than assuming it's still authoritative |

## Regression spot-check

- Since this PR touches `AppState.swift` and `OnboardingView.swift` — both heavily modified since
  May by later work (including onboarding step removal in a separate hotkey-permission fix) —
  expect **merge conflicts**, not a clean apply. Resolve conflicts by keeping the *current* onboarding
  structure and re-applying just the `synchronize()` fix and the launch-arg bypass concept, rather
  than reverting onboarding back toward this PR's older version.
- Full existing `HaloTests` unit suite should still pass after merging: `xcodebuild test -scheme HaloTests`.

## Recommendation

Given the staleness, consider whether the *only* durable value left in this PR is the onboarding
`synchronize()` fix (if TC-MAESTRO-01 confirms the bug still reproduces on current `main`) — in
which case it may be cleaner to cherry-pick that one fix into a fresh, small PR rather than merging
this entire branch (including a UI-test target that would fight with `main`'s already-evolved one)
as-is.
