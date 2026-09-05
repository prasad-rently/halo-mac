# Session handoff — open-PR review & Phase 0

**Written:** 2026-09-05 · **Repo:** `/Volumes/SSDA/M5/Github/Halo`

Read this first if you are picking the work up cold. It records state that is not
recoverable from `git log` alone: what is unpushed, what was decided and why, what
is blocked on a human, and a few things about the toolchain that cost time to
learn.

Companion docs in this directory:

- [`00-REVIEW-INDEX.md`](00-REVIEW-INDEX.md) — verdicts for all 16 PRs, the Critical findings, batch issues B1–B8
- [`00-MERGE-ORDER.md`](00-MERGE-ORDER.md) — the five-phase order and its reasoning
- `PR-<n>-<slug>.md` — per-PR findings (also committed to each PR's own branch)

---

## 1. ⚠️ Nothing has been pushed

`git fetch` and `git push` over SSH have **no key** in this environment:

```
git@github.com: Permission denied (publickey).
```

`gh` works fine (it authenticates over HTTPS) — that is how every PR review,
reply and thread resolution was posted. But all three work branches are **local
only**. Pushing needs the user's key.

| Branch | Commits ahead of `main` | Contents |
|---|---|---|
| `review/pr-audit` | `f1ba4a5` | This directory — audit of all 16 PRs + merge order |
| `feat/f020-smart-disk-health` | `e4e8a6d`, `4975090` unpushed (on top of the 2 PR commits) | PR #20 review fixes |
| `phase0/shell-reader` | `641a6a2`, `47f63a2` | `ShellReader` + 8 call-site conversions |

Before pushing `docs/reviews/*` to the PR branches, note the trade-off: it adds a
commit to each open PR's diff, which some reviewers will want removed before
merge. Keeping the docs local and working from them is equally viable.

---

## 2. What is done

### Review of all 16 open PRs

~114 findings, 7 Critical. Every finding is posted as an inline comment on its PR.
A [consolidated cross-PR comment](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519)
on #21 covers the eight batch-level issues (B1–B8) that no single PR can fix.

Verdicts, ordered by remaining work — full detail in `00-REVIEW-INDEX.md`:

| Verdict | PRs |
|---|---|
| Approve with comments | #20, #6 |
| Request changes | #16, #14, #13, #12, #11, #10, #9, #21, #18, #15, #19, #7, #17 |
| Request changes → **recommend close** | #1 |

**#1 is superseded**, which is worth knowing before anyone spends time on it:
`main` already contains a 21-file `HaloUITests` target including `HaloSidebar.swift`,
landed via a different branch. #1 still adds it as *new* files, which is why it
shows `CONFLICTING`. Only the version-string hunk is worth salvaging.

### PR #20 fixed — Phase 1, step 1

Six findings fixed, two pushed back on with evidence, all 8 threads replied to and
resolved. Build clean, 79/79 tests. See `PR-20-f020-smart-disk-health.md`.

### Phase 0 / P0.2 done — `ShellReader`

`Halo/Core/ShellReader.swift` plus 8 call-site conversions. Build clean, 66/66
tests. Documented as `CLAUDE.md` gotcha 20.

---

## 3. Two findings worth carrying forward

Both came from checking against reality rather than reasoning about code. Both
would have been missed by review alone.

### Apple's spare threshold is 99, and #20 trusted it literally

```
$ diskutil info -plist / | plutil -extract SMARTDeviceSpecificKeysMayVaryNotGuaranteed xml1 -o - -
AVAILABLE_SPARE              100
AVAILABLE_SPARE_THRESHOLD     99
PERCENTAGE_USED               16
```

The industry norm for that threshold is ~10. #20's `classify` read `spare <= threshold`
as *Failing*, so the first time normal wear ticked spare to 99 the app would have
shown a red **Failing** badge and fired *"back up your data immediately"* **every
hour, indefinitely**, on a healthy drive.

Latent rather than live — but it would have triggered on its own, with no user
action. **This was not in the original review**; it only surfaced when the real
values were read off the machine. Recorded as `CLAUDE.md` gotcha 22 on the
`feat/f020-smart-disk-health` branch.

### The first `ShellReader` implementation deadlocked

Draining each pipe with a blocking read on `DispatchQueue.global()`, joined by a
`DispatchGroup`, is the obvious design — and it starves the pool. Each call parks
two threads on a blocking read while a third waits on them, so once enough calls
overlap there is no thread left to run a drain block and `leave()` is never reached.

A single-threaded probe passed in 1.04s. The parallel test suite hung for **nine
minutes**; `sample` pinned every stuck thread to `dispatch_group_wait`. Halo
genuinely has several of these in flight at once (the SMART timer,
`SystemControlsManager`'s poll loop, an AI tool call), so this was a production
bug, not a test artifact.

Now multiplexes both descriptors with `poll(2)` **on the calling thread**. Verified
at 40 overlapping calls moving 256 KB down both streams: 0.15s. There are explicit
concurrency regression tests so a "tidy-up" back to worker-per-pipe fails loudly.

### A correction to the review itself

#17's `lsof` deadlock was originally rated **Critical** on the claim that output
"routinely" exceeds the 64 KB pipe buffer. Measured: **10,333 bytes across 87 open
connections**, stderr empty — roughly 550 connections would be needed. The honest
rating is **High** (latent but unrecoverable), and both #17 threads have been
corrected on the PR. Measure before assigning severity.

---

## 4. What is next

### Remaining Phase 0

| Step | What | Why it comes first |
|---|---|---|
| **P0.1** | `.github/workflows/ci.yml` — build + `HaloTests` | **Recommended next.** There is no CI at all (`.github/workflows/` does not exist, `gh pr checks` reports nothing on any branch). Every "BUILD SUCCEEDED" claim in every PR body is unverifiable, and all of them are invalidated by the 12 rebases the merge order requires. `HaloTests` now has fast pure-logic suites that gate nothing. |
| **P0.3** | `AlertManager.shared` / `ProcessMonitor.shared` | #13/#16/#20 each add an `evaluate*` method reached through a *different* `AlertManager` instance, so cooldowns are per-instance rather than global. #11/#13/#14 each construct their own `ProcessMonitor` — four overlapping process enumerations. Much cheaper before all four land. |
| **P0.4** | Reassign colliding pbxproj UUIDs | #21, #13 and #9 all claim `8031`/`8032`. Suggested: #21 keeps them, #13 → `8113`–`8116`, #9 → `8153`/`8154`. (`8163`/`8164` are now taken by `ShellReader`.) |

### Then Phase 1 continues at #16

```
Phase 1   #20 ✅ → #16 → #13      AppState + AlertManager
Phase 2   #11 → #10 → #14         Dashboard + Settings   (settle B7 here)
Phase 3   #21 → #18 → #9          Protection             (#9 needs an FDA pass first)
Phase 4   #12 → #19               Files                  (#19 needs a store decision)
Phase 5   #15 , #17               isolated, most rework
Separate  #6 (retarget → main) → #7 (split); close #1
```

---

## 5. Blocked on a human decision

### B4 — the sandbox question (the big one)

Six features shell out: #21 (`fdesetup`/`spctl`/`defaults`), #20 (`diskutil`),
#17 (`lsof`/`nettop`), #16 (`tmutil`), #10 (`ps`), #9 (`sqlite3`). Under
`Halo.entitlements` (sandbox on — the App Store configuration) `posix_spawn` is
denied, so **all six are inert in a shipping build**.

To their credit they all degrade *honestly* rather than fabricating, and
`ShellReader` now reports a denied spawn as `launchFailure` so callers can tell
"we were not allowed to ask" from "the tool found nothing". But the PR bodies
describe these features as working.

Two possible answers — **Debug/direct-distribution only** (say so in the docs and
the UI), or **route through the F-002 privileged helper**. It needs one answer for
the batch. Deciding it six times is how six inconsistent answers happen.

### Smaller open questions

- **#20 — the TBW figure.** `DATA_UNITS_WRITTEN` reads 380,469,315, which by the
  NVMe formula is **194.8 TB written on a 256 GB drive showing 16% wear**. That
  implies ~1.2 PB of endurance, which no 256 GB part has. The arithmetic is
  spec-correct so nothing was changed, but the card displays this prominently. If
  Apple does not report in thousands, users are shown a figure 1,000× too large.
  Worth checking against `system_profiler SPNVMeDataType`.
- **#20 — stale verification note.** The file header records verification against
  `APPLE SSD AP0512Z`; this machine's drive is `AP0256Q`. Deliberately **not**
  edited — if the author verified on a different Mac the note is accurate, and
  rewriting it would falsify their record. Needs confirming.
- **#6 — licence/provenance.** `docs/specs/pattern-packs/india-bank-sms.v1.json`
  declares itself a port of `~/CW/Hamza`'s `SmsClassifier.kt` / `TransactionParser.kt`
  with no licence or attribution. Should be settled before it enters git history.
- **#19 — App Store decision.** Adds the Photos entitlement and
  `NSPhotoLibraryUsageDescription` to the **release** configuration for a path the
  PR itself labels experimental and never runtime-tested.

---

## 6. Toolchain notes (learned the slow way)

Not project knowledge — environment knowledge, and none of it is written down
elsewhere.

- **Build:** `xcodebuild -project Halo.xcodeproj -scheme HaloUITests -configuration Debug -derivedDataPath /tmp/HaloBuild-<name> CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`
- **Test:** same flags with `test -scheme HaloTests`. `-only-testing:HaloTests/<SuiteTypeName>`
  does filter swift-testing suites correctly (use the *type* name, e.g.
  `ShellReaderTests`, not the `@Suite` display name).
- **A cold `-derivedDataPath` costs 8+ minutes.** Two runs were mistaken for hangs
  because of this. Reuse a warm path; only the first build of a new one is slow.
- **A genuine hang looks different:** `◇ Test run started.` appears and then
  nothing. Diagnose with
  `sample $(pgrep -f "Halo.app/Contents/MacOS/Halo") 3 -file /tmp/s.txt` — it names
  the exact blocked line.
- **swift-testing runs suites in parallel.** That is what exposed the `ShellReader`
  starvation bug; a sequential probe cannot. Worth remembering when a bug only
  appears under `xcodebuild test`.
- **macOS has no `timeout(1)`.** Use `run_in_background` plus an `until ! pgrep …`
  wait loop instead.
- **Stale worktrees** under `.claude/worktrees/` were holding locks on 12 PR
  branches; `git worktree prune` cleared them.
- **The `.claude/settings.local.json` edit is the user's** — it has been kept
  unstaged throughout. Do not commit it.

---

## 7. Quick orientation for a fresh session

```bash
git branch --show-current
git log --oneline main..HEAD                 # what this branch adds
cat docs/reviews/00-MERGE-ORDER.md           # the plan
cat docs/reviews/00-REVIEW-INDEX.md          # verdicts + Critical findings
gh pr list --state open                      # 16 PRs, all still open
gh pr view 20 --comments                     # example of the review already posted
```

The per-PR findings docs are on each PR's own branch as well as here, so
`git checkout feat/f022-time-machine-monitor && cat docs/reviews/PR-16-*.md`
gives you that PR's review next to its code.
