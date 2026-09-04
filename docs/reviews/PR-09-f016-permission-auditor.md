# Code review — PR #9 · F-016 Permission Auditor

- **PR:** [prasad-rently/halo-mac#9](https://github.com/prasad-rently/halo-mac/pull/9)
- **Branch:** `feat/f016-permission-auditor` → `main`
- **Reviewed at:** commit `46bdccd1` · 12 files, +685 / −17
- **Inline comments:** [review 5115653463](https://github.com/prasad-rently/halo-mac/pull/9#pullrequestreview-5115653463)

## Verdict: **Request changes**

The feasibility section is honest and useful — actually running the `sqlite3` read, showing the
real failure, and building `.unavailable(reason:)` around it rather than fabricating grants is the
right pattern. Reusing the existing 8-case `PermissionKind` instead of duplicating it is right too,
and adding the per-app view *alongside* the category grid rather than replacing it is a good
fallback design.

The difficulty is that the entire happy path is unexercised, and reading it closely there are three
problems on that path. Given the branch cannot be reached without Full Disk Access, granting FDA to
a debug build once and exercising it would be the highest-value thing to do before merge — this is
the one PR in the batch where the untested path *is* the feature.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/PermissionAuditor.swift:113` | Exception handling | `waitUntilExit()` (113) precedes `readDataToEndOfFile()` (117), and line 111 sets `process.standardError = outPipe` — both streams share one 64 KB buffer. `SELECT service, client, auth_value FROM access;` returns a row per (service, client) pair: several hundred rows at ~50–80 bytes on a normal machine, 12–48 KB typically and past 64 KB on a developer's. Once full, `sqlite3` blocks in `write(2)` and Halo blocks in `waitUntilExit()`. This matters more here than elsewhere because the call is launched from `ProtectionViewModel.loadAll()`'s task group — a wedged auditor means the **whole Protection module** stops loading. And it can only happen on machines that *have* FDA granted, i.e. never on the dev machine, always on the machines where the feature works. | High | Read → wait → check `terminationStatus`; give stderr its own handle (or `nullDevice`) rather than sharing — merging them is also what makes the `contains("error:")` check below fragile. |
| 2 | `PermissionAuditor.swift:30` | Business requirement | `run()` reads only `~/Library/Application Support/com.apple.TCC/TCC.db`. macOS splits TCC across the per-user database and a system-wide one at `/Library/Application Support/com.apple.TCC/TCC.db`; `kTCCServiceAccessibility` and `kTCCServiceSystemPolicyAllFiles` are recorded in the **system** store, and `kTCCServiceScreenCapture` has moved between the two across releases. Those are exactly the services `isElevatedRisk` keys on — so the headline capability ("X of Y apps hold Screen Recording or Accessibility they probably shouldn't") may find nothing to flag even on a machine where FDA is granted and the read succeeds. | Medium | Verify empirically with `sqlite3 -readonly` against both paths, then read both and merge. The system store needs FDA too, so the `.unavailable` fallback stays as-is. |
| 3 | `PermissionAuditor.swift:84` | Logical lapses | After a successful read and parse, an empty `grants` array returns `.unavailable(reason: "No readable permission grants found…")` — but that is a *successful* audit that legitimately found nothing (fresh Mac, or no app granted any of the eight mapped services). The UI then shows the FDA-style fallback banner, telling the user Halo couldn't read anything when in fact it read fine. The PR's own test plan includes "Sanity-check … with zero grants (fresh Mac / no TCC history)" — as written, that path is unreachable. It can also mask issue 2: if every row maps to an unmodelled service, `grants` is empty and the user is told the database was unreadable. | Medium | Return `.available(grants: [])` and let the view render an explicit empty state. "Couldn't read" and "read fine, nothing granted" are different facts. |
| 4 | `PermissionAuditor.swift:107` | Security | Two issues on one line. **Read-only:** the header says "read-only checks" but `sqlite3 <path> <query>` opens read-write by default; on a live database the OS holds open that also means lock contention, and a `database is locked` failure would be reported as "locked or inaccessible" without distinguishing it from a permissions problem. **Parsing:** `sqlite3`'s default list mode separates columns with `\|` and performs no quoting or escaping — the `client` column holds bundle identifiers *and* absolute executable paths, so a path containing `\|` silently shifts every field. | Medium | `process.arguments = ["-readonly", "-json", dbPath, query]` — `-json` (sqlite3 ≥ 3.33, shipped on macOS 12+) removes the delimiter class of problem entirely. |
| 5 | `PermissionAuditor.swift:95` | Code quality | `appName(forBundleID:)` is invoked from `run()`, which is actor-isolated and therefore runs on a cooperative pool thread — and `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` is main-thread-affine AppKit, called once per grant, several hundred times in a loop. Same issue as `ProcessMonitor.runningAppRAMSamples()` in #13. | Medium | Return bundle IDs from the actor and resolve display names on the `@MainActor` side, which also lets results be cached across refreshes rather than re-resolved every scan. |
| 6 | `PermissionAuditor.swift:18` | Security | `expectedElevatedPrefixes.contains(where: bundleID.hasPrefix)` — `com.apple.mail` matches `com.apple.mailctl`, and a malicious app can pick `com.apple.Safari.helper` and never be flagged. For an allowlist whose job is *suppressing* a risk flag, loose matching fails in the permissive direction. Also `com.duckduckgo` isn't a real bundle ID (DuckDuckGo's browser is `com.duckduckgo.macos.browser`), so that entry only works *because* of the prefix behaviour. | Low | Exact match on the identifier, with a separate, deliberately-chosen set of true prefixes where a family is genuinely intended (e.g. Chrome helpers). |
| 7 | `Halo.xcodeproj/project.pbxproj` | Code standards | Claims UUIDs `8031`/`8032`; #21 and #13 also claim them. | High | See B1. |

## Blocking issues

- **Exception handling** — 1
- **Code standards** — 7 (and B1, B2, B3)

## Non-blocking suggestions

- 2, 3, 4, 5 are Medium and all live on the same untested branch, so they are best addressed in one pass after exercising it with FDA granted.
- 6 is Low.
- The `auth_value` handling (`2` = allowed, `3` = allowed-always; anything else skipped rather than guessed) is correct and well-commented.

## Questions for the author

1. **Has the FDA path ever been executed?** Issues 1, 2 and 3 all live there and none is reachable without it.
2. Which TCC store holds Accessibility and Screen Recording on your macOS version (issue 2)? That determines whether the risk heuristic works at all.
3. Should a fresh Mac with zero grants show an empty state or the FDA banner (issue 3)?

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
