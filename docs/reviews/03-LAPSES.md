# Lapses log — mistakes made while reviewing and merging the F-016…F-030 batch

**Opened:** 2026-09-06, during the `release/v2.3` merge train.

Every entry is a mistake **I** made, not a defect in the PRs. Each records what
went wrong, how it was caught, and what stops it recurring. Items marked
**OPEN** are to be resolved once all PRs are merged.

Session 2 kept its own version of this in `01-SESSION-2-HANDOFF.md` §5; those
entries are carried forward at the bottom so there is one list.

---

## A. Caught by a guard — the guard worked

### A1. Merged the wrong branch head for #16 · **resolved**

Merged the **local** `feat/f022-time-machine-monitor`, which was a docs-sibling
sitting *behind* `origin` — so the merge silently dropped the entire fix commit:
`backupNever` vanished from `AlertKind` and both `AlertLog` arms with it.

Caught by P0.3's `AlertKind` icon coverage test, which failed on
`entry.icon == "bell.fill"`. Without that test it would have shipped.

Root cause: the session-2 handoff warned about exactly this ("SSH fetch fails
here, so remote-tracking refs go stale") and I fetched correctly — but then
merged the *local* branch name without checking it matched `origin`.

Fix applied: audited all thirteen branches, found **six** diverged docs-siblings,
repointed every one to `origin` with `backup/*-docs-sibling` refs kept.

### A2. `Models.swift` structurally broken by block relocation — twice · **resolved**

The `append_ins` resolver moves inserted hunks to the end of the file. When a
hunk begins mid-declaration that produces `extraneous '}' at top level`. It
happened on #10, was fixed, then happened again on #18.

**Its structural checks passed both times**: declaration count matched, braces
balanced. Brace *counts* balance even when placement is wrong. The signal that
would have caught it — "18 indent/depth mismatches" — I had deliberately
downgraded from a refusal to a note one PR earlier.

Fix applied: the dispatcher now routes `Models.swift` to git's **in-place**
union, which never moves a hunk, with the relocation path removed from that
branch of the case statement entirely.

**Lesson worth keeping:** a check that passes on a broken file is worse than no
check, because it converts "unknown" into "verified".

---

## B. Not caught by any guard — found later, or by luck

### B1. Stray conflict markers committed into docs · **resolved**

The `feat/f022` and `feat/f023` merges committed **6** residual `=======` /
`>>>>>>>` lines into `docs/HALO_MOBILE_ROADMAP.md` and `docs/ROADMAP.md`.

Cause: the resolver asserted only that `<<<<<<<` was absent. The roadmap change
logs had *nested* conflicts — two marker pairs per region, because both branches
had already appended to the same table — and a state machine tracking one open
conflict mis-parses that and leaves the trailing markers.

**It survived three build-and-test cycles.** The compiler and the test suite have
nothing to say about a markdown file. Found only when a later merge tripped over
the leftovers.

Fix applied: `verify.sh` greps every text file type for residual markers *before*
it builds; `union_docs.py` rewritten to strip markers rather than parse them, so
nesting cannot defeat it.

### B2. `FilesView` duplicated switch arms and enum cases · **resolved**

Both #12 and #19 add a `FilesTab` case, and the union kept both sides' *full*
case lists — duplicating the shared ones. It compiled (Swift takes the first
matching arm) and both new tabs worked, so tests passed. Left 13 switch arms
where 7 belong, six of them dead.

Found by reading the merged file, not by any check.

Fix applied: enum merged by hand — keeping #19's `duplicates` → "Exact
Duplicates" rename, which exists precisely to disambiguate from "Similar Photos"
— and the switch deduplicated.

### B3. `CLAUDE.md` UUID quick-reference table is stale · **OPEN**

The quick-reference table still lists three files at `8031`/`8032`:

```
| `8031` / `8032` | PermissionAuditor.swift ... |
| `8031` / `8032` | SecurityPostureScanner.swift ... |
| `8031` / `8032` | MemoryTrendTracker.swift ... |
```

**The code is correct** — the merged `project.pbxproj` has `8153`/`8154`,
`8031`/`8032` and `8113`/`8114` respectively, exactly as P0.4's reserved-block
table specifies, and every object id is defined exactly once. This is a
documentation lapse only: P0.4 recorded the reassignment in the *reserved blocks*
table and never updated the *quick-reference* table above it.

My union resolver then preserved all three rows faithfully — and because it sorts
that table by id, the three identical-id rows sat together and read as a
legitimate group.

**To resolve:** correct the three rows to the real ids, and add `8163`/`8164`
(`ShellReader`) which is also missing from the quick-reference table.

### B4. Under-called the `nonisolated` audit — then lost the fix · **resolved (twice)**

The adversarial re-review cleared every added `nonisolated` as "touching no actor
state". True of *mutable* state — and it missed that six of them reference
`@MainActor` **static** constants, which is a warning today and an **error under
the Swift 6 language mode**.

Fixed during the pre-merge sweep by marking those constants `nonisolated` — but
the review should have caught it in the first place. The compiler had been
telling me: the warnings were in every build log I had already read.

**Then the fix was lost.** It was made on the *pre-merged* release branch, which
was reset to rebuild the release through the PR flow. The fix had never been
pushed to the feature branches, so it did not come back with them, and this log
went on claiming it was resolved. Found at the very end, by reading the final
build's warnings rather than by any check, and re-applied on `release/v2.3`.

**Two lessons, and the second is the bigger one:**

* When a build emits warnings, read them against the thing being reviewed rather
  than treating "BUILD SUCCEEDED" as the whole answer.
* **A fix made on a throwaway branch is not a fix.** Resetting `release/v2.3`
  discarded every correction made during the pre-merge sweep, not just the
  merges. Anything that has to survive belongs on the branch that owns the code.
  The archive tag preserved it, which is why it was recoverable — but nothing
  *pointed* at it, so only re-reading the warnings surfaced the loss.

### B5. Told the user a finding was reversed when it was not · **resolved**

Briefing #10, I reported that F-021 had **no** privacy toggle and that this was
"the reverse of what the original review recorded" — recommending the user change
it. The user asked me to add the toggle.

**The toggle existed all along**: `AppUsageTracker.enabledDefaultsKey`, off by
default, with a rendered `Toggle` in `OnboardingView.swift:440` and a caption.
My grep searched for `appUsageTrackingEnabled` / `isTrackingEnabled` *inside
`AppUsageTracker.swift`*; the key is named `enabledDefaultsKey` and the UI lives
in `OnboardingView`. Finding nothing, I asserted a conclusion instead of widening
the search.

Caught only because implementing the "fix" meant reading the surrounding code.
Had I gone straight to writing, a second redundant toggle would have shipped.

**Lesson:** a negative grep is not evidence of absence. "I could not find X" is
the honest report; "X does not exist" is a different and much stronger claim.

---

## C. Process and environment

### C1. Filled the disk mid-verification · **resolved**

Accumulated ten `derivedDataPath` directories (~24 GB) across the sweeps and ran
`/System/Volumes/Data` down to 150 MB, which failed a build with
`symlink error: No space left on device` and a `zsh: no space left on device` on
the working directory.

Fix applied: consolidated to a single reused derived-data path.

### C2. Wrote three audit checks that were wrong before they were right · **resolved**

Each initially produced false positives that could have masked a real finding:

- **pbxproj reference counts** — assumed every id appears twice; a `fileRef`
  legitimately appears **three** times (definition, group children, and the
  `PBXBuildFile`'s `fileRef =`). Corrected against a known-good pair on `main`.
- **duplicate enum raw values / switch cases** — checked file-wide, so
  `FileKind` and `LeftoverKind` both legitimately using `"Cache"` read as a
  collision, as did `AlertLog` mapping each kind in both `icon` and
  `accentColor`. Rescoped per-enum; the switch check removed.
- **brace balance** — checked absolutely, so `Models.swift`, which contains a
  brace inside a string literal and counts 91/90 in *every* version, read as
  permanently broken. Rewritten to compare against the parents' own imbalance,
  and later to ignore literals and comments outright.

**Lesson:** validate a new check against known-good input before trusting its
output, or it will be tuned into silence at the first false positive.

---

## D. Carried forward from session 2 (`01-SESSION-2-HANDOFF.md` §5)

Recorded there, repeated here so this is the single list.

- **A stale remote-tracking ref nearly reverted the P0.4 UUID fix.** SSH fetch
  fails on this machine, so tracking refs only update on an explicit HTTPS fetch.
  (Directly related to **A1** above, which is the same trap one level down.)
- **#9: changed `TCCGrant.id` off `UUID()`** — not a reported finding, and an
  existing test deliberately asserted the old behaviour. Reverted. *Fix what was
  reported.*
- **#15: moved a size measurement after `trashItem`** — measured a deleted path
  and reported 0 bytes freed. The PR's own existing test caught it. (The
  replacement introduced **R5**, the per-path over-count, found in the
  adversarial re-review.)
- **The first branch sweep produced garbage** — two runs raced doing
  `git checkout` in one worktree, so reported errors belonged to whichever branch
  happened to be checked out. Redone in an isolated worktree.

---

## Open items to resolve after the last merge

**All closed.** Recorded here with what the closing check actually found.

| | What | Outcome |
|---|---|---|
| **B3** | Stale UUID rows in `CLAUDE.md`'s quick-reference table | Closed in `6129958`. **Three** rows were stale, not two — `MemoryTrendsSection.swift` (`8033`/`8034` → `8115`/`8116`) was found only by diffing the whole table against the pbxproj programmatically. No row was missing. |
| **B4** | The `nonisolated` fix, lost in the branch reset | Re-applied in `24b9bce`. See the amended entry above. |

### Final full-tree audit on `release/v2.3`

| Check | Result |
|---|---|
| Residual conflict markers, every text type | **0** |
| Duplicate pbxproj object definitions | **0** |
| Duplicate Sources-phase entries (all 5 phases) | **0** |
| Direct `ProcessMonitor()` / `AlertManager()` constructions | **0** |
| `AlertKind` cases missing an icon or colour arm | **0 of 11** |
| Documented UUIDs disagreeing with the pbxproj | **0 of 63** |
| Clean build | `BUILD SUCCEEDED`, 52 warnings (was 58) |
| Tests | **346 in 67 suites pass** |

### Still open — a finding, not a lapse

Six Swift-6-error-in-waiting warnings live in **batch-introduced** files and are
pre-existing on their own feature branches, so no merge caused them:

```
SimilarPhotosView.swift      4x  reference to captured var 'self' in concurrently-executing code
DriveHealthSection.swift     1x  reference to property 'monitor' in closure requires explicit 'self'
WeeklyDigestGenerator.swift  1x  DigestNotificationDelegate conformance crosses into main actor-isolated code
```

The remaining 18 are in files that predate this batch (`LocalShareClient`,
`SystemControlsManager`, `ToolRegistry`, `AIModels`, `FileSystemScanner`,
`ActionRunner`). All are warnings under Swift 5.9 and errors under Swift 6 —
worth a pass before any language-mode migration, out of scope for v2.3.
