# Halo — where the project stands

**Last verified:** 2026-09-12 · against the live remote, not from memory.
**Updated 2026-09-12:** #29 and #30 merged into `release/v2.4`.

This is the single current-state page. The detailed history lives in
[`00-REVIEW-INDEX.md`](00-REVIEW-INDEX.md) and the session handoffs
[`00`](00-SESSION-HANDOFF.md) · [`01`](01-SESSION-2-HANDOFF.md) ·
[`04`](04-SESSION-3-HANDOFF.md), with the mistakes made along the way in
[`03-LAPSES.md`](03-LAPSES.md).

---

## 1. One-line summary

**v2.3 is built, tested by machine, released as a beta, and waiting on one human
step — a manual test pass that has not started.** Everything else is either
finished or blocked behind that step or behind a one-command token refresh.

---

## 2. Where the code is

| Ref | SHA | State |
|---|---|---|
| `main` | `364357a` | **Untouched.** 103 commits and ~18,900 lines behind `release/v2.3`. Deliberate — it advances only after the manual test pass. |
| `release/v2.3` | `9110443` | Tagged `v2.3.0-beta.1`, released, DMG published |
| `release/v2.4` | `43ff612` | #29 and #30 merged 2026-09-12. Clean build · **348 tests in 67 suites pass** · subprocess audit clean |
| `review/pr-audit` | `005226a` | All review documentation |
| `feat/ci-workflow` | `85d06ae` | ⚠️ **Local only — cannot be pushed.** See §5 |

**Latest release:** [`v2.3.0-beta.1`](https://github.com/prasad-rently/halo-mac/releases/tag/v2.3.0-beta.1)
· pre-release · `Halo-2.3-beta.dmg`, 23.3 MB · **0 downloads**.
v2.2.0 still holds the "Latest" badge, correctly.

---

## 3. What got done

### The F-016 – F-030 batch — 15 features, 18 PRs, six phases

Reviewed, fixed, re-reviewed adversarially, then merged one at a time through a
briefed approve-then-merge flow. 71 files, +18,425 / −395.

| Phase | Landed |
|---|---|
| 0 — foundation | scanner cancellation · `ShellReader` · shared singletons · pbxproj UUID blocks · `AsyncTimeout` |
| 1 | F-020 SMART disk health · F-022 Time Machine · F-023 memory-leak tracker |
| 2 | F-029 weekly digest · F-021 app usage · F-028 focus sessions |
| 3 | F-019 security posture · F-018 privacy exposure · F-016 permission auditor |
| 4 | F-030 iCloud Drive · F-025 duplicate photos |
| 5 | F-024 browser cleaner · F-017 network traffic |

**Verification on `release/v2.4`:** clean build · **348 tests in 67 suites pass**
(was 54 in 15 before the batch) · full-tree audit zero on every count — residual
conflict markers, duplicate pbxproj objects, duplicate Sources entries, direct
`ProcessMonitor()`/`AlertManager()` construction, `AlertKind` cases missing an
icon or colour, documented UUIDs disagreeing with the pbxproj.

### Six open decisions — four closed

| # | Decision | Outcome |
|---|---|---|
| 1 | #21's description claimed a Settings rework not in the diff | **Closed.** The commit was never lost — `3b0d717`, local-only, now pushed as `fix/settings-rework` and parked for v2.4. #21's body corrected |
| 2 | F-025's Photos entitlement | **Closed.** Gated the PhotoKit UI out of sandboxed builds (#27). Verified across all four sandbox/entitlement quadrants with a signed probe |
| 3 | F-016's happy path never exercised | **Closed as no-code.** Folded into the manual test pass — needs one Full Disk Access grant |
| 4 | Sandbox scope | **Answered for direct distribution** (unsandboxed, per precedent). App Store path still undecided |
| 5 | CI | **Blocked** — see §5 |
| 6 | Swift-6 warnings | **Work done, PR open** — see §4 |

### Released v2.3 as a beta

Debug configuration, App Sandbox off — matching every prior Halo release, and
necessary because the sandbox denies `posix_spawn`, which would ship six
features as empty panels. Signed with a personal development certificate; no
Developer ID exists on this machine, so it is not notarised and first launch
needs right-click → Open. Disclosed in the release notes, as v2.0–v2.2 did.

Verified before publishing rather than assumed: clean `SYMROOT` (no test
frameworks inside the bundle), `codesign --verify --deep --strict` passes,
`app-sandbox = false` read back from the embedded entitlements, DMG mounts with
its signature intact, and **the app launches and quits cleanly**.

### Documentation corrected where it was actively wrong

- **`CLAUDE.md`'s build recipe could not work.** `-scheme Halo` does not exist;
  it never signed `HaloHelper.xpc`; the documented certificate is not on this
  machine. All three fixed and the recipe run end to end (#28).
- **README rewritten** — it documented none of the 15 new features and had no
  install section at all. Now plain-English, with the right-click → Open step
  and *why*, a permissions table, and all twelve sections described.
- Three separate cases of a doc describing a state the code no longer had were
  caught — one of them in the same session that created it.

---

## 4. Open pull requests

| PR | Into | State | What |
|---|---|---|---|
| [#1](https://github.com/prasad-rently/halo-mac/pull/1) | `main` | **`CONFLICTING`/`DIRTY`** | Maestro E2E. Recommended **close** |
| [#6](https://github.com/prasad-rently/halo-mac/pull/6) | merged branch | Stale base | Docs-only. Retarget. Settle the `india-bank-sms.v1.json` licence question first |
| [#7](https://github.com/prasad-rently/halo-mac/pull/7) | `feature/upcoming-features` | Needs splitting | Titled "Phase 0 foundation" but ships 4 features / 5,306 lines / 36 files |

### Merged into `release/v2.4` on 2026-09-12

| PR | What landed |
|---|---|
| [#29](https://github.com/prasad-rently/halo-mac/pull/29) | **ShellReader migration.** Five scanners spawned subprocesses with no timeout; `SMARTDiskMonitor` also had an undrained stderr pipe. All bounded now, plus `scripts/audit-subprocess-spawning.sh` so it cannot regress |
| [#30](https://github.com/prasad-rently/halo-mac/pull/30) | **Six Swift-6 warnings** in batch code. One was a genuine latent data race: `DigestNotificationDelegate` was `@MainActor` while conforming to a protocol declaring no isolation |

GitHub's mergeability check was returning `UNKNOWN` when #30 was merged, so it
was verified locally against the post-#29 tip with `git merge-tree` — clean, 0
conflicts — rather than trusting a pending status. The two touch disjoint files.

**The merged result was built and tested, not inferred** from the two PRs'
separate runs: clean build, **348 tests in 67 suites pass**, audit script clean,
no residual conflict markers, and the six batch-code Swift-6 warnings confirmed
gone from `SimilarPhotosView`, `DriveHealthSection` and `WeeklyDigestGenerator`.

---

## 5. What is blocked, and on what

| Blocked | Blocked on | Unblocked by |
|---|---|---|
| **Everything downstream of the release** | **The manual test pass.** The beta has **0 downloads**, so it has not begun | Installing the DMG and working through it |
| `main` advancing to v2.3 | The manual test pass | Same |
| A non-beta v2.3 tag | The manual test pass | Same |
| **CI** (decision #5) | `gh` token has `gist, read:org, repo` — **no `workflow` scope**. GitHub rejects any push that creates `.github/workflows/*`. Re-confirmed by attempting it on 2026-09-07 | `gh auth refresh -h github.com -s workflow` — one command, opens a browser |
| App Store submission | Decision #4's remaining half | A decision, not engineering |

### Two things worth acting on sooner rather than later

1. **`feat/ci-workflow` (`85d06ae`) exists only on this machine.** A complete,
   reviewed 135-line workflow that cannot be pushed without the scope above.
   This is the same exposure `fix/settings-rework` had — one disk failure from
   gone — and the fix is one command.
2. **The two features that have never run at all** are F-016's permission list
   (needs Full Disk Access) and F-025's Photos Library scan (needs a real
   library). Everything else in the batch has executed at least once. These are
   the highest-value items in the manual pass.

---

## 5b. Found while installing the beta — the widget has no data

**Confirmed on 2026-09-12 by installing the released DMG on a real machine.**
This is a shipped bug, not a theory, and it has been shipped since May.

The app and the widget resolve the *same* App Group suite name to *different
files*:

| Process | Sandbox | `application-groups` entitlement | `UserDefaults(suiteName:)` resolves to |
|---|---|---|---|
| `Halo.app` | off | **absent** | `~/Library/Preferences/group.com.halo.mac.plist` — **verified present and updating** |
| `HaloWidget.appex` | on | present | `~/Library/Group Containers/group.com.halo.mac/…` — **verified does not exist** |

So `HaloWidgetData.load()` finds nothing and returns its zero placeholder
(`cpuUsage: 0`, `ramTotalGB: 8`, no clipboard items). That renders as a widget
stuck at plausible-looking values rather than an obviously broken one, which is
why it could ship unnoticed.

**Root cause, and it was deliberate.** `7f91bbb` (2026-05-07) removed
`com.apple.security.application-groups` from `Halo-Debug.entitlements` to stop a
per-launch TCC prompt, noting *"Release builds (`Halo.entitlements`) retain the
App Group for widget support."* That assumption stopped being true: every
shipped DMG — v2.0 through the v2.3 beta — is built from the **Debug**
configuration. The follow-through never happened.

The `?? UserDefaults.standard` fallback added in the same commit does not help:
`UserDefaults(suiteName:)` succeeds in both processes, so the fallback never
fires — they just land in different files.

**`CLAUDE.md` states the opposite** — *"Both main-app entitlement files include
`com.apple.security.application-groups`"* — and needs correcting either way.

Three options, all needing a decision rather than an obvious fix:

1. Put the entitlement back in `Halo-Debug.entitlements` and accept the TCC
   prompt, or suppress it by signing with a provisioning profile
2. Build releases from a configuration that uses `Halo.entitlements` — but that
   turns the sandbox on, which disables the six shell-out features
3. Give the widget its own read fallback to the unsandboxed path — narrowest
   change, but the widget is sandboxed and may not be able to reach it

---

## 6. Known gaps in the shipped beta

Stated in the release notes rather than left to be discovered:

- **Not notarised** — needs a paid Apple Developer ID
- **Five scanners can hang in theory** — fixed in #29, which is on
  `release/v2.4`; **the v2.3 beta does not have it**
- **Crash reporting inert** — `Info.plist` still holds `SENTRY_DSN_PLACEHOLDER`
- **No CI** — tests and audits run by hand
- **Swift 6 migration outstanding** — 15 warnings in app code plus 5 in the test
  target remain after #30. None is mechanical: `LocalShareClient` (6) holds an
  `NSLock` across `await` and needs its synchronisation redesigned;
  `FileSystemScanner` (2) calls `makeIterator` from async; `AIModels` /
  `ToolRegistry` need `Any` out of a `Sendable` struct
- **Temperature sensors** unavailable on most Apple Silicon — hardware, not Halo

---

## 7. The shortest path forward

1. `gh auth refresh -h github.com -s workflow`, then push `feat/ci-workflow` and
   open its PR — gets CI running and takes a local-only branch out of danger
2. ~~Merge #29 and #30 into `release/v2.4`~~ — **done 2026-09-12**
3. **Run the manual test pass** against the beta, prioritising F-016 with Full
   Disk Access granted and F-025's Photos path
4. Merge `release/v2.3` → `main`, tag a non-beta `v2.3`
5. Then v2.4's own scope: `fix/settings-rework`, the remaining Swift-6
   migration, and decisions on #1 / #6 / #7
