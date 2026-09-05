# Session 2 handoff — Phase 0 completed, all 11 batch PRs fixed

**Written:** 2026-09-05 · Follows [`00-SESSION-HANDOFF.md`](00-SESSION-HANDOFF.md)

Session 1 reviewed all 16 open PRs. **Session 2 did the fixing.** Every reported
finding on the eleven `F-016 … F-030` PRs is now addressed, built, tested and
pushed, and each PR carries a comment answering its review's open questions.

---

## 1. State of every branch

All pushed unless noted. Local branches sit one commit ahead of these only
because the `docs(reviews):` findings docs are still deliberately local — no code
is unpushed.

| Branch | Head | What it is |
|---|---|---|
| `phase0/ci-workflow` | `5e65fbf` | ⚠️ **NOT PUSHED** — needs `workflow` scope |
| `phase0/shell-reader` | `47f63a2` | P0.2 — `ShellReader` + 8 call sites |
| `phase0/shared-singletons` | `d0936f2` | P0.3 — `AlertManager` / `ProcessMonitor` |
| `phase0/pbxproj-uuid-blocks` | `83d17a2` | P0.4 — UUID block table |
| `fix/scanner-cancellation` | `5f3a0cb` | `main` bug found mid-session |
| `feat/f016-permission-auditor` (#9) | `c218dec` | 6/6 findings |
| `feat/f017-network-traffic-monitor` (#17) | `b638b9d` | 7/8 — both Criticals |
| `feat/f018-privacy-exposure-scanner` (#18) | `83d13db` | 10/10 |
| `feat/f019-security-posture` (#21) | `49393a8` | 7/9 |
| `feat/f020-smart-disk-health` (#20) | `e4e8a6d` | session 1 |
| `feat/f021-app-usage-analytics` (#10) | `d567a60` | 5/5 + non-compiling tests |
| `feat/f022-time-machine-monitor` (#16) | `f741ddb` | 5/6 + icon gap |
| `feat/f023-memory-leak-tracker` (#13) | `bb8cdf9` | 7/8 |
| `feat/f024-browser-cleaner` (#15) | `73fba41` | 5/7 — the Critical |
| `feat/f025-duplicate-photos` (#19) | `5524fe6` | 6/6 — the Critical |
| `feat/f028-focus-session` (#14) | `d5aaec5` | 4/6 |
| `feat/f029-scheduled-reports` (#11) | `42ef471` | 6/7 |
| `feat/f030-icloud-drive-analyzer` (#12) | `0029825` | 5/6 |

**All 4 Criticals and every High are fixed.** Remaining unfixed items are B4
(sandbox), B6 (resolved by `phase0/shared-singletons` on rebase), and three
deliberate deferrals listed in §4.

---

## 2. Four findings that were NOT in the original review

Each was found by running things rather than reading them.

### `FileSystemScanner` never cancels its producer — a bug on `main`

`scanDirectory` builds its `AsyncStream` around an unstructured `Task` and never
sets `onTermination`. `traverse` calls `Task.checkCancellation()` for every file,
so it is fully prepared to be cancelled — **nothing ever cancelled it**. Ending
the stream released the consumer while leaving a full-filesystem walk running to
completion in the background.

Found because `FileSystemScannerTests` "Cancellation stops scan" hung for 4+
minutes. Reproduced on clean `main`. The test was independently unbounded: it
scanned the real `NSHomeDirectory()` and broke after 5 `.item` events, but
`.item` events are only emitted *after* `traverse` returns — so the break could
never fire early. Runtime was "however long it takes to walk `~`", which is why
it passed most days. Fixed on `fix/scanner-cancellation`; suite went from an
indefinite hang to **0.485s**.

This mattered for CI: unfixed, it would have burned the 45-minute timeout on
every run.

### PR #10's test target had never compiled

`AppUsageTracker` is `@MainActor`, so its `static` aggregation helpers were
MainActor-isolated and every test calling them failed with *"call to main
actor-isolated static method"*. Verified against the pristine head `fedeb59`
with nothing else changed. `HaloTests` is one target, so **nothing** in it ran on
that branch — its "BUILD SUCCEEDED" covered the app only. Exactly what P0.1
exists to catch.

### The `AlertKind` icon gap

#20 and #16 add `AlertKind` cases with no matching arm in `AlertEntry.icon` /
`.accentColor`, so their alerts render as a generic bell in Alert History. #13
does add its icon. Fixed in #16; posted on #20. `phase0/shared-singletons` adds
a test that fails on exactly this omission.

### `Package.resolved` drift, demonstrated

A fresh checkout resolved Sentry **8.58.4** while the main tree has **8.58.3**.
The CI doc predicted this; it is now observed. `Package.resolved` is gitignored
and Sentry is pinned only as `upToNextMajorVersion`, so a Sentry release can turn
CI red with no change to this repo.

---

## 3. Blocked on a human — cannot be done from a session

| What | Why | Fix |
|---|---|---|
| **Push `phase0/ci-workflow`** | `gh` token has `gist, read:org, repo` — no `workflow`. GitHub refuses any OAuth push touching `.github/workflows/`. | `gh auth refresh -h github.com -s workflow` (browser), then re-push |
| **#9 Full Disk Access** | Confirmed directly that *both* TCC databases are unreadable without it, so F-016's entire happy path is still unexercised. | Grant FDA to a debug build once — settles findings 2, 3 and the untested-happy-path concern together |
| **B4 sandbox decision** | Six features shell out; `posix_spawn` is denied under `Halo.entitlements`. | One answer for the batch: unsandboxed direct distribution, or route via the F-002 helper. Note F-007 (App Store assets) is already marked skipped, which may make this easier than it looks |
| **#21 description mismatch** | Claims a Settings rework wiring "8 previously-dead placeholder controls" that is genuinely not in the diff. | Restore the commit or correct the description |
| **#6 licence/provenance** | `india-bank-sms.v1.json` declares itself a port with no licence or attribution | Settle before it enters git history |

---

## 4. Deliberate deferrals (each flagged on its PR)

Not oversights — each is a feature addition rather than a correction, and folding
them into a fix commit would have made those diffs materially harder to review.

- **#14** — "Add from Applications…" picker. Storage is already bundle-ID based, so only *discovery* is affected.
- **#15** — browsers installed in `~/Applications` are invisible. Needs bundle-ID resolution via `NSWorkspace`.
- **#17** — `async let` serializes on the actor. Correct, only serial; deserves to land away from a commit that just removed two deadlocks.

---

## 5. Mistakes made this session, and what they cost

Recorded because each one is a trap the next session can hit.

- **A stale remote-tracking ref nearly reverted the P0.4 UUID fix.** SSH fetch fails here, so tracking refs only update on an explicit HTTPS fetch. **Always `git -c credential.helper='!gh auth git-credential' fetch … '+refs/heads/*:refs/remotes/origin/*'` before checking out any PR branch.**
- **#9: changed `TCCGrant.id` off `UUID()`** — not a reported finding, and an existing test deliberately asserted the old behaviour. Reverted. Fix what was reported.
- **#15: moved a size measurement after `trashItem`** — measured a deleted path, reported 0 bytes freed. The PR's own existing test caught it.
- **The first branch sweep produced garbage** — two runs raced doing `git checkout` in one worktree, so reported errors belonged to whichever branch happened to be checked out. Redone in an isolated worktree; use `git worktree` for anything that checks out branches in the background.

---

## 6. What is actually left

### The re-review has NOT happened

This is the one substantial piece outstanding. Every fix builds and passes tests,
but a fresh-eyes pass over the full diffs has not been done — and reviewing one's
own changes in the same pass that made them is the weakest possible check. It
deserves a clean session with no memory of why each change seemed right.

Specifically worth adversarial attention:

- **#21** — `SecurityPostureStore.shared` is new shared state with an AppState observer. Check for retain cycles and redundant refreshes.
- **#17** — the bounded `withTaskGroup` for reverse DNS was written without a live network to exercise it. The `resolveHostWithTimeout` group cancellation in particular.
- **#13** — `restart()` polls for up to 20 s via chained `asyncAfter`; verify it cannot outlive the view or double-fire.
- **#14** — session recovery resumes a session on `init`, which runs during app startup. Verify ordering against `AppState`.
- **#19** — the `UnsafeMutablePointer` fix is correct but is manual memory management; re-read the lifetime.
- **Every `nonisolated` I added** (#10, #11, #13, #16) — confirm none touches actor state.

### Then the merge order itself

Nothing has been merged. `docs/reviews/00-MERGE-ORDER.md` still applies, with
Phase 0 now done except the CI push.

---

## 7. Verification commands

```bash
# Build (all four products) — HaloUITests scheme covers app + widget + helper
xcodebuild -project Halo.xcodeproj -scheme HaloUITests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/HaloBuild-pr \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build

# Tests — exclude FileSystemScannerTests unless fix/scanner-cancellation is merged
xcodebuild -project Halo.xcodeproj -scheme HaloTests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/HaloBuild-pr \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test

# pbxproj collision audit (--no-merged matters; see 00-MERGE-ORDER.md)
git show main:Halo.xcodeproj/project.pbxproj | grep -oE '\b[0-9A-F]{24}\b' | sort -u > /tmp/main-ids
for b in $(git branch --no-merged main --format='%(refname:short)'); do
  git show "$b":Halo.xcodeproj/project.pbxproj 2>/dev/null \
    | grep -oE '\b[0-9A-F]{24}\b' | sort -u | comm -13 /tmp/main-ids - | sed "s|$| $b|"
done | sort > /tmp/pbx-claims
awk '{print $1}' /tmp/pbx-claims | uniq -d
```

`zsh does not word-split unquoted parameters` — use arrays for
`-only-testing:` argument lists.
