# Adversarial re-review of the session-2 fix commits

**Written:** 2026-09-05 · Follows [`01-SESSION-2-HANDOFF.md`](01-SESSION-2-HANDOFF.md)

Session 2 fixed every reported finding on the eleven batch PRs and pushed. This is the
fresh-eyes pass over those **fix commits** that §6 of the handoff said had not happened.
Scope is the delta only — `origin/<branch>` against each PR's pre-fix head — not a re-review
of the features.

Reviewed at the pushed heads tabulated in §1 of the handoff. The local branches are **not**
the right thing to read: each sits on a sibling `docs(reviews):` commit and is one behind
its own fix commit.

## Verdict

Four of the six areas §6 flagged hold up. Two do not, and both fail hard:

| §6 item | Holds? |
|---|---|
| #21 `SecurityPostureStore.shared` — retain cycles, redundant refreshes | Yes, no cycle. Three Lows. |
| #17 bounded `withTaskGroup` for reverse DNS | **No — Critical + High** |
| #13 chained `asyncAfter` in `restart()` | Yes. Cannot double-fire or outlive. One Low. |
| #14 init-time session recovery | **No — Critical** |
| #19 `UnsafeMutablePointer` lifetime | Yes, correct. (Separate High elsewhere in the same commit.) |
| every added `nonisolated` (#10, #11, #13, #16) | Yes, all clean. |

Both Criticals are **new defects introduced by the fix commits** — neither existed on the
pre-fix heads. Both are hangs, both are reachable by ordinary use, and neither is covered by
the tests those commits added.

---

## Findings

| # | PR | File:Line | Issue | Risk |
|---|----|-----------|-------|------|
| R1 | #17 | `NetworkTrafficMonitor.swift:144` | Infinite loop in the new bounded-concurrency scheduler | **Critical** |
| R2 | #14 | `FocusSessionManager.swift:88` | Session recovery deadlocks the app at launch | **Critical** |
| R3 | #19 | `PerceptualDuplicateDetector.swift:517` | PhotoKit timeout does not bound anything | High |
| R4 | #17 | `NetworkTrafficMonitor.swift:84` | Reverse-DNS timeout does not bound anything (same root cause as R3) | High |
| R5 | #15 | `BrowserCleanerScanner.swift:105` | "Freed N bytes" over-reported by up to `paths.count`× | Medium |
| R6 | — | `phase0/shared-singletons` | Silently breaks #13 and #14 compilation on merge (no git conflict) | Medium |
| R7 | #21 | `ProtectionView.swift:51` | `ProtectionViewModel` reads the shared store without observing it | Low |
| R8 | #21 | `SecurityPostureScanner.swift:218` | `refresh()` has no reentrancy guard | Low |
| R9 | #21 | `AppState.swift:226` | `.receive(on: RunLoop.main)` stalls during event tracking; ~4 redundant Dashboard invalidations per refresh | Low |
| R10 | #13 | `MemoryTrendsSection.swift:93` | No in-flight guard — the restart chain can be started twice for one app | Low |

---

### R1 — #17: infinite loop in the bounded-concurrency scheduler · **Critical**

`Halo/Core/Scanner/NetworkTrafficMonitor.swift:144`

```swift
func addNext() {
    guard index < uniqueIPs.count else { return }   // returns WITHOUT touching inFlight
    ...
    inFlight += 1
    group.addTask { ... }
}

while inFlight < Self.maxConcurrentResolves { addNext() }
```

Once `index` reaches `uniqueIPs.count`, `addNext()` is a no-op that leaves `inFlight`
unchanged, so the loop condition can never become false. Whenever
`uniqueIPs.count < maxConcurrentResolves` (8) the prime loop spins forever.

`snapshot()` is `actor`-isolated, so this pegs one core at 100% and wedges the actor
permanently. There is no suspension point in the spin, so `pollTask?.cancel()` on
`.onDisappear` cannot stop it — collapsing the section or leaving the tab does not help.
Only quitting Halo does.

**Reachability is not marginal.** Two independent triggers:

- **Fewer than 8 unique remote IPs** — an idle laptop.
- **Zero uncached IPs.** `dnsCache` is an instance property of a `@State`-held monitor that
  survives every poll, so once poll 1 has resolved and cached every IP, poll 2 computes
  `uniqueIPs == []` and hangs. This is the *steady state*, not an edge case.

Gated only on the user flipping "Resolve remote hostnames", which is a plain `Toggle` in the
section (`performance.networkTraffic.resolveHostnames`).

Reproduced by transcribing the loop verbatim with the task body stubbed out:

```
20 IPs, cap 8 -> resolved 20. OK
!! addNext called 1000001 times for 3 IPs — INFINITE LOOP
```

The 20-IP case passes, which is presumably why it went unnoticed — the bug only appears
when the work is *smaller* than the concurrency cap.

None of the five tests the commit adds exercise the scheduler; they cover `lsof` parsing and
the default-off toggle.

**Fix:** `while inFlight < Self.maxConcurrentResolves && index < uniqueIPs.count { addNext() }`,
or have `addNext()` return `Bool` and break on `false`. Add a test with `uniqueIPs.count`
of 0 and 1.

---

### R2 — #14: session recovery deadlocks the app at launch · **Critical**

`Halo/Core/FocusSessionManager.swift:88` → `:94` → `:169`, and
`Halo/Features/Dashboard/FocusSessionOverlayView.swift:72`

The recovery path added by this commit runs inside the lazy initializer of the singleton and
then reaches back into that same singleton:

```
FocusSessionManager.shared            // static let — swift_once
  └─ init()                                                       :88
      └─ recoverInterruptedSession()                              :94
          └─ start(minutes:bundleIDsToHide:)                      :105 guard remaining > 60
              └─ overlayController?.show()                        :169
                  └─ NSHostingController(rootView: FocusSessionOverlayView())
                      └─ @ObservedObject private var manager = FocusSessionManager.shared
                                                              // ^ reenters the once-block
```

`FocusSessionOverlayView()` evaluates its stored-property default, which is
`FocusSessionManager.shared` — a reentrant read of a Swift `static let` while its own
initializer is still on the stack. Swift lowers that to `swift_once` → `dispatch_once`, which
is not reentrant: the thread blocks in `_dispatch_once_wait` and never wakes.

Confirmed on this toolchain (Swift 6.3.1, effective 5.10) with a minimal transcription of the
chain. The watchdog fired at 8 s and the stack is unambiguous:

```
 4 libdispatch.dylib  _dispatch_once_wait + 60      <- reentrant read blocks here
...
15 libdispatch.dylib  _dispatch_once_callout + 32   <- the same once-block, still running
```

`init` is `private` and `shared` is the only construction path, so this is not avoidable by
the caller. The first touch is on the main actor — `HaloApp`'s `.task` calls
`FocusSessionManager.shared.observeAppTermination()`, and the Dashboard's focus card holds the
same singleton — so the app beachballs during startup with no window and no crash report.

**The trigger is precisely the scenario the commit was written for.** A clean ⌘Q clears the
persisted record via `observeAppTermination()`, so recovery only engages after a crash,
force-quit or power loss — the cases the fix exists to handle — with more than 60 s left on
the session. Recovering from that state bricks the launch until the
`haloFocusActiveSession` default is deleted by hand.

**Fix:** don't start a session from `init`. Record the pending resume and have `HaloApp`
call a `resumeIfNeeded()` after launch, alongside the existing
`observeAppTermination()` call. Unhiding in `init` is fine — it touches no singleton.
Separately, `FocusSessionOverlayView` should take the manager by injection rather than
reading `.shared` in a property default, so this class of cycle cannot recur.

---

### R3 — #19: the PhotoKit timeout does not bound anything · High

`Halo/Core/Scanner/PerceptualDuplicateDetector.swift:517`

The double-resume half of finding 6 is correctly fixed — the `OSAllocatedUnfairLock` one-shot
guard makes any extra PhotoKit callback a no-op. The "never called" half is not.

```swift
let first = await group.next() ?? nil
group.cancelAll()
return first
```

`withTaskGroup` awaits **all** remaining children before returning. The work task is parked in
`withCheckedContinuation` around a PhotoKit callback, which `cancelAll()` cannot interrupt.
So when the sleeper wins, the group takes `first = nil` and then blocks on the sibling that
will never finish.

If PhotoKit genuinely never calls back — the exact case the doc comment describes ("asset
unavailable, network drops") — `requestHash` hangs **forever**, which is the same wedge the
fix says it closes: *"a timeout resumes with nil so a missing callback cannot wedge the scan."*
It does not resume the continuation; it resumes a sibling.

**Fix:** the timeout must drive the same continuation through the existing `resumed` guard —
schedule it inside `withCheckedContinuation` and resume with `nil` there — rather than racing
a sibling task.

---

### R4 — #17: the reverse-DNS timeout does not bound anything · High

`Halo/Core/Scanner/NetworkTrafficMonitor.swift:84`

Same shape and same root cause as R3. `performReverseDNS` is a blocking `getnameinfo` on a
global dispatch queue wrapped in `withCheckedContinuation`, so `group.cancelAll()` is inert
and the group waits for it.

Measured on the actual pattern:

```
work=0.2s timeout=1.5s (fast path)  value=real-result  elapsed=0.21s
work=5.0s timeout=1.5s (SLOW path)  value=nil          elapsed=5.01s
```

The fast path is fine (`Task.sleep` *is* cancellable). The slow path returns the right value
at 1.5 s and then blocks for the remaining 3.5 s. So `resolveTimeoutSeconds` is not a
"per-lookup ceiling" — it changes what is returned, not how long it takes, which is the half
that mattered. An unresponsive resolver can hold a slot for 30 s+ (five 5 s retries), and eight
of those hold eight global-queue threads.

Lower impact than R3 only because `getnameinfo` does eventually return. The bounded
concurrency is still a real improvement over the serial loop; the timeout is not.

**Fix:** same as R3, or move the lookup onto a detached task whose result is read through a
one-shot box so the group can abandon it.

---

### R5 — #15: "Freed N bytes" over-reported · Medium

`Halo/Core/Scanner/BrowserCleanerScanner.swift:105`

The size measurement was correctly moved back *before* `trashItem`, but the optimisation
added alongside it changes units:

```swift
for path in item.paths {                                    // :93
    let size = item.size > 0 ? item.size : Self.size(ofPaths: [path])   // :105
    ...
    freed += size                                            // :111
}
```

`measure(_:)` sets `item.size = Self.size(ofPaths: item.paths)` — the total across **all** the
category's paths. Adding it once **per path** multiplies the reported figure by the number of
paths that exist. The fallback branch measures a single path, so the two branches are not
measuring the same quantity — that is the tell.

Safari's `.history` category has two paths (`History.db`, `History.plist`) → 2×. Chromium
categories are built one path per profile, so a four-profile Chrome reports up to 4×.
`freed` is surfaced directly as "Freed X" in `freedBanner`.

Not caught by the new tests, which construct `BrowserClearResult` values directly and never
call `clear()`.

**Fix:** keep the per-path measurement (`Self.size(ofPaths: [path])`), or carry a per-path
size dictionary out of `measure(_:)` if the I/O saving is worth it.

---

### R6 — Phase 0 breaks #13 and #14 without a git conflict · Medium

`phase0/shared-singletons` (`d0936f2`) gives `AlertManager` and `ProcessMonitor` a
`private init()`. Every branch still constructs them directly:

```
feat/f023-memory-leak-tracker  MemoryTrendTracker.swift:91  ProcessMonitor()
feat/f023-memory-leak-tracker  MemoryTrendTracker.swift:92  AlertManager()
feat/f028-focus-session        FocusSessionManager.swift:57 ProcessMonitor()
```

`AppState.swift` and `TopProcessesSection.swift` are in the universal-eight hot set, so those
call sites will surface as conflicts during rebase. `MemoryTrendTracker.swift` and
`FocusSessionManager.swift` are files Phase 0 never touches — git merges them cleanly and the
result does not compile. `00-MERGE-ORDER.md` describes the Phase 0 conflicts as mechanical;
these two are not conflicts at all, which is worse.

**Fix:** note both call sites in the merge order so the rebase of #13 and #14 expects them.

---

### R7 — #21: the view model reads the store without observing it · Low

`Halo/Features/Protection/ProtectionView.swift:51`

`securityChecks`, `securityScore` and `securityAutomationAvailable` became computed
properties over `SecurityPostureStore.shared`, but `ProtectionViewModel` never subscribes to
the store. It only calls `objectWillChange.send()` inside its own `loadSecurityPosture()`
(`:162`), so it repaints for refreshes it initiated and for nobody else's.

The fix's stated invariant is "one store, both readers" — and `AppState` *does* observe
(`AppState.swift:225`), so only half of it is wired. No live symptom today, because the only
other writer is `AppState`'s launch-time scan and `ProtectionView.task` re-refreshes on
appear anyway. It becomes a real bug the moment anything else refreshes the store.

**Fix:** subscribe in the view model's init the way `AppState` does, and drop the manual
`objectWillChange.send()`.

---

### R8 — #21: `refresh()` has no reentrancy guard · Low

`Halo/Core/Scanner/SecurityPostureScanner.swift:218`

`isRefreshing` is published but never *checked*. Opening Protection while the launch-time
scan is still running runs `refresh()` twice concurrently: ten `posix_spawn`s instead of five,
and whichever finishes first clears `isRefreshing` while the other is still in flight, so the
spinner stops early. End state is consistent (same data, last writer wins), so this is waste
and a UI blip rather than corruption.

**Fix:** `guard !isRefreshing else { return }` at the top.

---

### R9 — #21: `RunLoop.main` scheduling and redundant invalidations · Low

`Halo/App/AppState.swift:226`

Two small things in the observer:

- `.receive(on: RunLoop.main)` schedules in the default run-loop mode, so deliveries are held
  while the run loop is in `.eventTracking` — the Dashboard score will not move while the user
  is dragging or scrolling. `DispatchQueue.main` has no such mode gate and is the usual choice.
- The sink reads `SecurityPostureStore.shared.score` on *every* `objectWillChange`, and
  `refresh()` mutates four `@Published` properties. `@Published` does not compare, so each one
  fires, each deferred delivery re-assigns `AppState.securityScore`, and each assignment fires
  `AppState.objectWillChange` — roughly four full Dashboard invalidations per refresh, three of
  them redundant. One of them also lands during the `await` inside `refresh()` and reads the
  *old* `checks`, so the score briefly re-publishes its previous value.

Neither is wrong in its end state. Deriving from a single `@Published var score` on the store,
or comparing before assigning, removes both.

---

### R10 — #13: the restart chain has no in-flight guard · Low

`Halo/Features/Performance/MemoryTrendsSection.swift:93`

The chained `asyncAfter` itself is sound, and both §6 worries are unfounded:

- **Cannot double-fire.** `pollForExit` is a linear chain — each invocation either calls
  `completion` once and returns, or schedules exactly one successor. No fan-out.
- **Cannot outlive the view.** `MemoryTrendTracker` is a `static let shared`, so the
  `[weak self]` never nils and the chain always terminates. Writing `restartMessage` after the
  view is gone is a no-op, not a crash. (Worth noting the `[weak self]` is load-bearing in
  appearance only: if the tracker ever stopped being a singleton, a nil `self` would drop the
  completion and strand the caller.)

What is missing is a guard on re-entry. The confirmation dialog clears `appPendingRestart`
immediately while the poll runs for up to 20 s with no in-flight UI, so the user can tap
Restart again on the same app and get a second `terminate()` and a second independent chain,
two `openApplication` calls, and two alerts.

Also minor: `quitPollInterval` of 0.25 s over a 20 s timeout is up to 80 full
`NSWorkspace.runningApplications` enumerations on the main thread. A 1 s interval would be
indistinguishable to the user.

---

## Things that were checked and are correct

Recorded so a later pass does not redo them.

- **#19 `UnsafeMutablePointer` (`PerceptualDuplicateDetector.swift:210`).** The lifetime holds.
  `defer` is registered *before* `context` is created, and scope cleanups unwind LIFO, so the
  `CGContext` is released before the buffer is deallocated — the ordering that matters, given
  CoreGraphics retains the `data` pointer. The early `colorSpace` guard is above the
  allocation; the `CGContext` guard is below it and covered by the `defer`. `bytesPerRow: 32`
  for a 32-wide 8-bpp grayscale is exact, so the 1024-byte buffer cannot overflow, and all
  reads are in bounds.
- **Every added `nonisolated`.** Nine in total across #10, #11 and #13 (#16 added none). Eight
  are `static` and take all input as parameters. The ninth, `MemoryTrendTracker.leakStatus`
  (`:191`), is an instance method but reads only its `history` parameter and immutable `Self.`
  constants — it does not use `self` at all and could be `static`. Nothing touches isolated
  state, and the compiler independently guarantees no isolated *stored* property is reachable.
- **#21 retain cycle.** None. The sink captures `[weak self]`, the `AnyCancellable` lives on
  `AppState`, and the publisher is an immortal singleton, so there is no cycle in either
  direction.
- **#10 `todayIndexCache`.** Safe. The lookup validates the cached index against both
  `bundleID` and same-day before trusting it (`AppUsageTracker.swift:276`), `pruneOldRecords`
  invalidates on any removal (`:499`), and the two remaining mutations (`removeAll()`,
  `records = saved`) self-heal through the `idx < records.count` bound. Append does not shift
  existing indices.
- **#9 `runSQLite`.** Pipe ordering correct — read then wait, `stderr` to `nullDevice`. Not
  `@MainActor` (the two `@MainActor` annotations nearby belong to the name-resolution helpers,
  which correctly need it for `NSWorkspace`).
- **#18.** `continuation.onTermination = { _ in task.cancel() }` is the same pattern
  `fix/scanner-cancellation` adds to `FileSystemScanner`, and the `shouldStop` closure bounds
  the walk. Sound.
- **pbxproj UUID collisions.** Re-ran the audit from §7 across all seventeen unmerged
  branches: **zero** duplicate claims. P0.4 holds.
- **`AlertKind` icon coverage.** Matches what the handoff reported: #16 and #13 have both the
  `icon` and `accentColor` arms for their new kinds; **#20 still has neither** for
  `disk_smart_warning` / `disk_smart_failing`. Flagged on that PR, not fixed — unchanged, not
  a regression.
- **`ShellReader`** (`phase0/shell-reader`). Multiplexes both pipes with `poll(2)` on the
  calling thread, hard timeout with SIGTERM→SIGKILL escalation, and distinguishes launch
  failure from empty output. It addresses the deadlock class properly, including the
  thread-pool-starvation trap the header documents. No branch adopts it yet — each fixed its
  own call site locally — which is consistent with the plan.

## Recommendation

R1 and R2 must be fixed before #17 and #14 merge; both are launch/usage hangs shipped by the
commits that were supposed to make those PRs safer. R3 and R4 share one root cause and are
worth fixing together with a single helper, since the "race a sleeper inside `withTaskGroup`"
idiom is now in two files and reads correct.

The rest of the batch is in better shape than the two Criticals suggest — #13, #19's pointer
work, #18, #10 and the Phase 0 branches all survive an adversarial read.

---

## Build and test re-verification

All seventeen unmerged branches, at their pushed `origin/` heads, in an isolated
`git worktree` with a shared `derivedDataPath` (per §5 of the handoff — never `git checkout`
in the main tree for a sweep).

```bash
xcodebuild -project Halo.xcodeproj -scheme HaloUITests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build

xcodebuild -project Halo.xcodeproj -scheme HaloTests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  -skip-testing:HaloTests/FileSystemScannerTests test
```

**17/17 `BUILD SUCCEEDED`, 17/17 `TEST SUCCEEDED`, zero failures.**

| Branch | Tests |
|---|---|
| `fix/scanner-cancellation` | 50 in 14 suites |
| `phase0/shell-reader` | 62 in 15 suites |
| `phase0/shared-singletons` | 56 in 16 suites |
| `phase0/pbxproj-uuid-blocks` | 50 in 14 suites |
| `feat/f016-permission-auditor` | 68 in 16 suites |
| `feat/f017-network-traffic-monitor` | 75 in 16 suites |
| `feat/f018-privacy-exposure-scanner` | 67 in 17 suites |
| `feat/f019-security-posture` | 67 in 17 suites |
| `feat/f020-smart-disk-health` | 75 in 15 suites |
| `feat/f021-app-usage-analytics` | 66 in 15 suites |
| `feat/f022-time-machine-monitor` | 76 in 19 suites |
| `feat/f023-memory-leak-tracker` | 68 in 18 suites |
| `feat/f024-browser-cleaner` | 70 in 17 suites |
| `feat/f025-duplicate-photos` | 59 in 15 suites |
| `feat/f028-focus-session` | 64 in 18 suites |
| `feat/f029-scheduled-reports` | 74 in 21 suites |
| `feat/f030-icloud-drive-analyzer` | 68 in 20 suites |

`FileSystemScannerTests` was skipped throughout, per the handoff — it hangs on every branch
except `fix/scanner-cancellation`, where the same suite runs in 0.485 s.

**This green sweep is worth reading carefully rather than as reassurance.** None of R1–R5 is
covered by any of it:

- R1 and R2 are hangs, and neither has a test. A test that reproduced either would hang the
  suite rather than fail it — which is exactly the shape of the `FileSystemScannerTests`
  problem this batch already found once, and an argument for a per-suite timeout in P0.1's CI
  workflow.
- R3 and R4 need a stalled `getnameinfo` / PhotoKit callback to show up.
- R5 needs a category with more than one existing path; the new tests construct
  `BrowserClearResult` directly and never call `clear()`.

`Package.resolved` again resolved Sentry **8.58.4** against the tree's 8.58.3, reproducing the
drift the handoff recorded in §2.
