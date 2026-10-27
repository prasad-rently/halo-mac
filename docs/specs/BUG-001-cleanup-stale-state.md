# BUG-001 — Cleanup: no rescan, and deleted items linger in other categories

> **Status:** 📋 Queued — analysis and requirements only; System Caches scope decided 2026-10-27. **No fix is written yet.**
> **Raised:** 2026-10-27 · **Severity:** Medium (wrong numbers + a visible "ghost item" that errors when clicked; no data loss) · **Effort estimate:** ~2.5–3 d
> **Blocks:** [F-054 Build Artifact Cleaner](F-054-build-artifact-cleaner.md) — that pane must sit on the corrected state model.
> **Not a feature** (no new `F-xxx`, so the mobile-parity rule does not apply); recorded here and in `FEATURE_ROADMAP.md`'s bug queue.

---

## 0. Report, as received

> *"In Cleanup tab, need a refresh / rescan button and its functionality. Items deleted under one category
> like **User Caches** still show in **System Caches** after being deleted from User Caches. This needs a fix
> and entries should update in real time on each action."*

Two defects and one requirement:
- **D-1** There is **no way to rescan** Cleanup.
- **D-2** An item removed in one category is **still listed in another**.
- **Req** After *every* action the lists must be correct — "real time".

---

## 1. Root-cause analysis (from reading the code — **not yet reproduced in a running app**)

> Verified by reading `release/v2.5` @ `0100743`. The first task of the fix is to **reproduce D-2 on screen** and record it, so the regression test is written against observed behaviour.

| # | Finding | Evidence |
|---|---|---|
| **R1** | **Two categories scan the same folder.** `.systemCaches` lists `["~/Library/Caches", "/private/var/folders"]` and `.userCaches` lists `["~/Library/Caches"]`. Every file under `~/Library/Caches` is therefore scanned twice and appears in **both** categories. | `Halo/Core/Models/Models.swift:103-106` |
| **R2** | **Cross-category identity doesn't exist.** Each scan mints a fresh `UUID()` per `ScannedItem`, so the same file in System Caches and User Caches is two unrelated rows. | `FileSystemScanner.swift:140-141` (`ScannedItem(id: UUID(), …)`) |
| **R3** | **A delete only edits the category it was issued from.** `cleanSingleItem` removes `item.id` from `categories[idx]` only; `cleanAll` removes from, and rescans, only `kind`. Nothing reconciles the *other* category, so its row for a now-trashed file stays. Clicking that row's trash button calls `trashItem` on a path that no longer exists; **the failure is swallowed (R10), so the row is simply removed and a "freed" result is reported for bytes that were never freed** — it does not show an error. | `CleanupView.swift:82-94` (single), `:60-80` (all) |
| **R4** | **`cleanAll` drops every row when anything succeeded.** `categories[idx].items.removeAll { _ in deleted > 0 }` removes *all* items if even one was deleted, including ones that failed. (The follow-up `scanCategory` rescan masks it for that category only.) | `CleanupView.swift:69` |
| **R5** | **There is no rescan.** `scanAll()` runs only from `.task` when the view appears; nothing in the UI calls it again, and the view model never learns of external changes. | `CleanupView.swift:23`, `:43-57` |
| **R6** | **The total double-counts.** `CleanupViewModel.totalBytes` sums `allBytes` over *every* category, so the shared `~/Library/Caches` bytes are added twice — the headline "reclaimable" figure is inflated by R1. | `CleanupView.swift:40` |
| **R7** | **The Trash category goes stale after any delete.** `trashItem` *moves* the file into `~/.Trash`, which is itself a Cleanup category (`.trash`), but nothing refreshes it — so "freed" items never appear in Trash, and the user can't tell the space is not yet recovered. | Same call sites; `.trash` scanned only by `scanAll` |
| **R8** | **A scan in flight can overwrite newer state.** `scanAll` rebuilds `categories` and writes results as tasks finish; with a rescan button added naively, an older scan completing late would clobber a newer one (and a clean-then-rescan race could resurrect a deleted row). | `CleanupView.swift:43-57` |
| **R9** | Related but separate: `.systemCaches` also lists `/private/var/folders`; whether those files are *deletable* by the user (and whether they are the right thing to call "System Caches") has not been verified on this machine. `/Library/Caches` — the actual system-wide cache directory — is **not** in the list. | `Models.swift:104` |

| **R10** | **`trashItem` failures never reach the UI.** `FileSystemScanner.deleteItems` catches every per-item error, `print`s it (including the file path) and carries on; it returns only `(deleted, freed)`. `ScanCoordinator.deleteSingleItem` therefore **never throws** for a failed trash, so the `catch` in `cleanSingleItem` is dead code, and `executeCleanup`'s `firstError` can only ever be set by cancellation. Consequence: a failed trash (already gone, permission denied, in use) is indistinguishable from success — the row disappears and `lastCleanResult` counts it. | `FileSystemScanner.swift:236-252` (`deleteItems`), `ScanCoordinator.swift:128-151` |

**Why it presents as "User Caches → System Caches":** R1 puts the same files in both; R3 updates only one. The same mechanism would affect any other pair of overlapping roots.

---

## 2. Requirements

### FR-1 Rescan
- A **Rescan** control in the Cleanup header (also **⌘R** while the Cleanup module is frontmost) rescans **every** category *and* the Browsers pane (and, once F-054 lands, Build Artifacts).
- Shows per-category progress (the existing `isScanning` spinner), a **"Last scanned HH:MM"** line, and is **disabled while a scan or a clean is running**.
- **Auto-rescan on app activation** if the last scan is older than 60 s — cheap protection against changes made outside Halo (Finder, `rm`, another app) without a file watcher.

### FR-2 One owner per path (fixes R1, R6)
- **Every scanned path belongs to exactly one category.** Remove `~/Library/Caches` from `.systemCaches` (minimal fix). Whether `.systemCaches` should instead target `/Library/Caches` (+ `/private/var/folders/*/*/C`) is **OQ-1** and requires measuring readability/deletability first (R9) — it must not become a second overlap.
- A **static invariant test** asserts that no category's target path equals, contains, or is contained by another's. (Mutation-check: put `~/Library/Caches` back in `.systemCaches` → red.)
- `totalBytes` is computed over **de-duplicated standardized paths**, defensively, even after FR-2 — a future overlap must not silently inflate the headline number.

### FR-3 Reconcile on every action (fixes R2, R3, R7) — the "real time" requirement
- Introduce one shared state owner (`CleanupStore`) holding all categories. Items are keyed by **standardized path**, not a per-scan `UUID`.
- After **any** deletion (single, batch, or from the Browsers/Build Artifacts panes) call `reconcile(removed: [URL])`: remove from **every** category every item whose path equals **or is under** a removed path; recompute counts and totals; update sidebar badges — **synchronously, before any rescan returns**.
- After a trash operation, **refresh the Trash category** (R7) so the moved items appear there.
- Then run a **targeted background verification rescan** of the affected categories (not a full scan) so sizes are exact; the optimistic reconcile gives instant correctness, the rescan gives truth.

### FR-4 Scan supersession (fixes R8)
- Each scan carries a **generation token**; results from a superseded scan are **discarded**. Starting a rescan cancels the in-flight one. A clean performed during a scan is applied after, via the same token, so a deleted row can never reappear.

### FR-5 No ghost rows
- Before presenting a clean **confirmation sheet**, drop any item whose file no longer exists, so the sheet never lists something that will fail.
- A `trashItem` failure of the kind *"no such file"* (already gone) is treated as **already removed** — dropped from the list, not shown as an error.
- **Prerequisite (R10):** this is only implementable if `FileSystemScanner.deleteItems` (and `ScanCoordinator.executeCleanup` / `deleteSingleItem` above it) report **per-item outcomes** — e.g. `[(item, .moved(resultingURL) | .alreadyGone | .failed(Error))]` — instead of swallowing errors. Remove the path-bearing `print` there (use no path in logs).

### FR-6 Honest results (fixes R4, R10)
- `cleanAll` removes **only the items that were actually moved**; failures stay listed with the first error. The result banner reads *"Moved N items (X) to Trash — space is freed when you empty the Trash"* (not "freed X").

### Non-goals
- **No continuous file-system watching (FSEvents)** — FR-3 makes Halo's own actions instantly consistent and FR-1's rescan-on-activation covers outside changes; a watcher over `~/Library/Caches` is noisy and costly for little gain. Revisit only if the activation rescan proves insufficient.

---

## 3. Design notes (for the implementer)

- **Test seam first.** `CleanupKind.targetPaths` is computed from `NSHomeDirectory()` and constants, so a unit test cannot point a scan at a temp directory. Introduce an injectable `CleanupRoots` provider (default = today's behaviour) used by `ScanCoordinator`, then write the failing reproduction test **before** changing the roots.
- `ScannedItem` gets a stable `id` derived from its standardized path (or the path itself as the key) — this also removes the `UUID()` churn that makes SwiftUI rebuild every row on each rescan.
- `CleanupViewModel` becomes a thin view over `CleanupStore` so the Browsers pane, F-054's pane and Smart Scan all reconcile through the same owner.
- Keep the **`trashItem`-only** rule and the review sheet untouched; this fix changes *what the lists say afterwards*, not *how deletion works*.
- Smart Scan (`ScanCoordinator.runFullScan`) scans exactly `[.systemCaches, .logFiles, .trash, .xcodeData]` — **not** `.userCaches`. `~/Library/Caches` is currently reachable by Smart Scan *only* through `.systemCaches`, so after FR-2 Smart Scan stops seeing the user's cache folder altogether (typically the largest cache source), not merely "double-counting less". Unless `.userCaches` is added to that list (**OQ-4**), the Smart Scan total drops for a reason that is a coverage loss, not a correction. Either way the release notes must say so.

---

## 4. Acceptance Criteria

| # | Criterion | How verified |
|---|---|---|
| AC-1 | **Repro first:** with the *current* code, deleting a file listed under User Caches leaves it listed under System Caches — recorded on screen and as a failing test | Manual capture + `CleanupReconcileTests` (red before fix) |
| AC-2 | No two categories scan the same or nested paths | `CleanupRootsInvariantTests` (mutation-checked) |
| AC-3 | Deleting an item in any category removes it from **every** category immediately, with no rescan | `CleanupReconcileTests` over a temp tree with two overlapping synthetic roots |
| AC-4 | Deleting a **directory** removes every listed item under it from all categories | Same |
| AC-5 | After a trash, the **Trash** category lists the moved item | Same |
| AC-6 | `totalBytes` never counts a path twice | `CleanupTotalsTests` |
| AC-7 | Rescan updates all categories; a **superseded scan never overwrites** a newer one; a clean during a scan never resurrects a deleted row | `ScanSupersessionTests` (controllable fake scanner) |
| AC-8 | `cleanAll` with one failing item removes the others and **keeps the failed one** listed with its error; `cleanSingleItem` on a failing item keeps the row and surfaces `cleanError` (today's code does neither — R10) | `CleanupCleanAllTests` (needs a failing-item seam, e.g. a read-only parent dir or an injectable trasher) |
| AC-9 | Rescan control + ⌘R present, disabled while busy; "Last scanned" updates | Manual + view-model test |
| AC-10 | Activating Halo after >60 s triggers a rescan; <60 s does not | View-model test with an injected clock |
| AC-11 | Confirmation sheet never lists a missing file | `CleanupConfirmTests` |
| AC-12 | The existing `trashItem`-only and confirm-before-delete behaviour is unchanged (`HaloUITests` canary tests still green) | Existing UI-test suite |

---

## 5. Open Questions

| # | Item | Proposed |
|---|---|---|
| ~~OQ-1~~ | ~~What should **System Caches** be once it stops listing `~/Library/Caches`?~~ | **Resolved 2026-10-27: minimal fix, then measure.** Remove the `~/Library/Caches` overlap now and keep `/private/var/folders`. Before adding `/Library/Caches` (or merging the category into *Temp Files*), check on a real Mac what is readable and deletable (SIP, root-owned files) and record the result here. |
| OQ-2 | Rescan scope: one button for everything (proposed) vs per-category rescan too. | One header button; a per-category rescan is a one-line addition if wanted. |
| OQ-3 | Keep a visible "moved to Trash, not yet freed" total in the header, so the user sees pending space? | Proposed: yes — it directly answers "I deleted it, why is my disk still full?". |
| OQ-4 | Smart Scan coverage after FR-2 (see §3): add `.userCaches` to `runFullScan`'s category list so `~/Library/Caches` stays covered? | Proposed: yes — one-line change; add a test that Smart Scan's categories still cover `~/Library/Caches` exactly once. |

---

## 6. Implementation Record

*Not started.*
