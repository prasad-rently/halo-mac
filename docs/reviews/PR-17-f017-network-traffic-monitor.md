# Code review — PR #17 · F-017 Network Traffic Monitor

- **PR:** [prasad-rently/halo-mac#17](https://github.com/prasad-rently/halo-mac/pull/17)
- **Branch:** `feat/f017-network-traffic-monitor` → `main`
- **Reviewed at:** commit `980d6a54` · 14 files, +1059 / −4
- **Inline comments:** [review 5113121668](https://github.com/prasad-rently/halo-mac/pull/17#pullrequestreview-5113121668)

## Verdict: **Request changes**

The feasibility write-up in the file header is genuinely good — being explicit that no public API
reveals the DNS name or TLS SNI a process requested without a Network Extension entitlement, that
`lsof`/`proc_pidinfo` expose only raw IP:port, and that unresolved IPs are never guessed *and*
never flagged as suspicious, is the right framing. Joining `lsof` to `nettop` on `pid` rather than
`processName` is the correct fix and the reasoning (differing truncation of the same name) is
well-evidenced.

Two things block merge: a subprocess pipe deadlock that permanently wedges the actor on a busy
Mac, and a serial reverse-DNS loop that makes the documented 2 s cadence unachievable.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/NetworkTrafficMonitor.swift:143` | Logical lapses | `waitUntilExit()` is called *before* the pipe is drained on line 148. `lsof -i -n -P` on a machine with a browser open routinely emits well over the 64 KB pipe buffer; once full, `lsof` blocks in `write(2)` and Halo blocks in `waitUntilExit()` — neither can progress. The actor is wedged permanently, and because `startPolling()` awaits `snapshot()` on a 2 s loop, `pollTask.cancel()` cannot interrupt a thread parked in `waitUntilExit()`. The zombie `lsof` stays resident. `standardError` is also an undrained `Pipe()`, and permission-denied lines for other users' sockets are exactly what `lsof` writes there. | Critical | Read → wait → check `terminationStatus`. Use `FileHandle.nullDevice` for stderr, or drain both concurrently. |
| 2 | `NetworkTrafficMonitor.swift:252` | Logical lapses | Identical ordering bug on `nettop -P -L 1`. Output scales with the number of processes with network activity and will exceed 64 KB on a loaded machine. | Critical | Same fix. |
| 3 | `NetworkTrafficMonitor.swift:80` | Logical lapses | Every unique remote IP is resolved *serially*, each `await` blocking the next, and `performReverseDNS` has no timeout — a PTR lookup against an unresponsive resolver can sit for the system default (~5 s+). With ~150 unique IPs and a 10% non-responding rate, `snapshot()` takes minutes. The poll loop is stuck awaiting it, so the table never updates, and there is no `Task.checkCancellation()` inside `snapshot()` so leaving the tab doesn't stop the work. | High | Resolve concurrently in a bounded `withTaskGroup` with a hard per-lookup timeout (treat timeout as `nil`, which the design already handles honestly), and add a cancellation check before the resolve phase. |
| 4 | `NetworkTrafficMonitor.swift:165` | Logical lapses | The parser correctly anchors on the `TCP`/`UDP` token, but lines 165–166 still assume COMMAND is exactly one whitespace-delimited token so `parts[1]` is the PID. `lsof` truncates COMMAND to 9 characters *without* removing embedded spaces — `Google Ch`, `Microsoft`, `Adobe Des`. When COMMAND contains a space, `Int32(parts[1])` returns nil and the row is skipped with no signal, so the browsers users most want to see are the ones most likely to disappear. | Medium | Scan forward for the first all-numeric token as the PID and join everything before it as the name; or use `lsof -F` field output, which is delimiter-safe by design. |
| 5 | `NetworkTrafficMonitor.swift:189` | Code quality | `NetworkConnectionEntry` is `Identifiable` on a fresh `UUID()` and `snapshot()` rebuilds every entry each poll, so `ForEach` treats every row as new every 2 seconds — rows torn down and rebuilt, in-row and hover/selection state lost, diffing degenerate. | Medium | Use the composite `"\(pid):\(remoteIP):\(remotePort):\(protocolType)"` already used as the dedup key. See B8. |
| 6 | `Halo/Features/Performance/NetworkTrafficSection.swift:296` | Security / privacy | Expanding the section issues a PTR query to the user's configured resolver for every remote IP their machine is talking to — handing the full connection-endpoint list to that resolver (and often their ISP) as a side effect of opening a monitoring panel. The UI footnote explains hostnames are best-effort but never says a lookup is performed. | Medium | Disclose it in the footnote text, or gate resolution behind a toggle defaulting off. Relevant to the App Privacy questionnaire. |
| 7 | `NetworkTrafficMonitor.swift:222` | Code quality | Comment states "process names never contain a literal `.`" — false (`com.apple.WebKit.Networking`, `com.apple.audio.SandboxHelper`). Taking everything after the *last* dot is nonetheless correct for the PID, so the logic holds, but the stated justification doesn't and the next reader may "fix" it in the wrong direction. | Low | Reword: "the PID is the final dot-separated component; the name may itself contain dots." |
| 8 | `NetworkTrafficMonitor.swift:69` | Code quality | `async let connectionsTask` / `totalsTask` both call actor-isolated methods on `self`, so the two child tasks serialize on the actor's executor. The `async let` reads as parallel; it isn't. | Low | Make the two fetches `nonisolated static` (they touch no actor state and the parsers are already `static`), then `async let` actually overlaps them. |
| 9 | `NetworkTrafficSection.swift:258` | Code quality | `ForEach(filteredConnections.prefix(50))` and, inside the loop body, `filteredConnections.prefix(50).last?.id` — `filteredConnections` is a computed property that re-filters and re-sorts the whole array, recomputed once per row per render. | Low | Hoist to a `let` above the `ForEach`. |

## Blocking issues

- **Logical lapses** — 1, 2, 3

## Non-blocking suggestions

- 4, 5, 6 are Medium. 4 silently loses data, so it is worth pairing with the blockers.
- 7, 8, 9 are Low.
- `dnsCache` as `[String: String?]` correctly distinguishes "not cached" from "cached as unresolved", and the `?? nil` flattening in `snapshot()` is right. `matchesTrackerDomain` correctly requires an exact match or a dot-anchored suffix (`notdoubleclick.net` does not match). No action needed on either — noting them so a later refactor doesn't undo them.
- `.onAppear` / `.onDisappear` / `.onChange(of: isExpanded)` lifecycle is correct: polling only runs while expanded and is cancelled on disappear.

## Questions for the author

1. Was the `lsof` COMMAND-column truncation behaviour (issue 4) checked against a name with a space? The PR body cites `lsof` → `Google`, which suggests truncation *at* the space on your machine, but that isn't guaranteed across `lsof` versions or `+c` settings.
2. Is silent reverse DNS acceptable, or should it be opt-in (issue 6)?
3. Same sandbox question as the batch (B4) — `lsof` and `nettop` are both denied under the release entitlements.

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
