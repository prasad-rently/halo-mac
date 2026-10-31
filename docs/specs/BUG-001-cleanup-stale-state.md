# BUG-001 — Cleanup: no rescan, and deleted items linger in other categories

> **Status:** 🔧 **Fix merged in `release/v2.5` (PR #53); H-01/H-04 added there; v2.6 hardening H-02/H-03/H-05 built on PR #60 (unmerged).** OQ-1 closed by measurement (§6). **Nothing here has been clicked through in the running app** (T-1 ◆ pending). System Caches scope decided 2026-10-27.
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
| OQ-4 | Smart Scan coverage after FR-2 (see §3): add `.userCaches` to `runFullScan`'s category list so `~/Library/Caches` stays covered? | Proposed: yes — one-line change; add a test that Smart Scan's categories still cover `~/Library/Caches` exactly once.**Status 2026-11-01: NOT applied.** `runFullScan` on `release/v2.6` scans `systemCaches, logFiles, trash, xcodeData` — `~/Library/Caches` is therefore **no longer in Smart Scan** (PR #53's body calls the drop in the Smart Scan System Caches number "a correction"). Still open; v2.7 / owner decision. |

---

## 6. Implementation Record

### 6.1 PR #53 — merged into `release/v2.5`

System Caches no longer lists `~/Library/Caches` (one owner per path). `CleanupViewModel.reconcile(removed:)` removes a trashed path (and anything under it) from **every** category immediately, then rescans the affected categories + Trash for exact sizes. Scan generations + a removed-since-scan-start filter stop a stale scan resurrecting a deleted row. `executeCleanup` returns per-item results: only items that moved leave the lists; failures stay listed with the error; already-gone files drop quietly. **Rescan** button (⌘R) with "Last scanned"; rescan on app activation after 60 s; `pruneMissing` before the Clean-all confirmation; a banner saying space is freed when the Trash is emptied. `ScanCoordinator` takes injectable roots/trash. Before merge: scan-generation guards made test-provable (**H-04**: removing either guard turns a test red) and Clean All acts on the confirmed snapshot (**H-01**).
**Verified:** 16 new tests (`CleanupRootsTests`, `CleanupReconcileTests`, `CleanupViewModelTests`) plus the H-01/H-04 additions; mutation-checked (re-adding `~/Library/Caches` to System Caches; skipping the cross-category reconcile; removing the stale-scan filter). **Not checked on screen:** the Rescan button, ⌘R, banner, activation rescan (T-1 ◆). Not done: FSEvents watching (explicit non-goal).

### 6.2 v2.6 hardening on PR #60 (unmerged)

| ID | Built | Honest note |
|---|---|---|
| H-02 | `pruneMissing` / `beginCleanAll` / `cleanAll` existence checks run on a detached task, bounded by a deadline and by cancellation (cancellation made real by `withTaskCancellationHandler` in review); unchecked paths are treated as **present** — never dropped on a guess | The AC's "20 000-item prune without a > 50 ms main-thread stall" was **not measured** (no signpost); the only indicator is 20 000 `lstat`s on warm local APFS = 33 ms. No in-progress state during the up-to-5 s (+30 s in `cleanAll`) check — a double-click opens two prunes; key computation (`reconcile`, `cleanAll` filter) is still on the main actor |
| H-03 | `CleanOutcome`: one banner per operation, shown on partial failure ("Moved 2, 1 failed: bad.bin — …"), cleared on category switch and the next full rescan | model tests; GUI placement not seen |
| H-05 | `CleanupPath.key` resolves symlinked **directory** components (leaf not followed); documents a case-**sensitive** policy; `directoryKey` for roots/Trash (review fix: a symlinked root or Trash previously never covered its items) | **Partial.** The BRD AC asked for a case-insensitive temp-volume test and a per-volume policy — **neither exists**; firmlinks (`/System/Volumes/Data/…`) are not canonicalised (not reachable today: scanners use `/Users/…`). The pure `/var`↔`/private/var` tests pass even without H-05 (`standardizedFileURL` already maps it) — regression guards, not proofs; only the symlinked-directory test discriminates |

### 6.3 H-06 measurements (read-only, one Mac, macOS 27, 2026-10-28 — closes OQ-1)

- **`/Library/Caches`:** `drwxrwxrwt root:admin` (sticky + world-writable), 7 entries, **4 KB total**; children owned by `root`, `_iconservices`, `_modelmanagerd`. With the sticky bit a non-root process cannot remove another owner's entry, so nothing meaningful is deletable and there is nothing to reclaim.
- **`/private/var/folders`:** `root:wheel drwxr-xr-x` with the SIP flag `sunlnk`; two-letter hash dirs. The user's own `…/<hash>/C` (cache, **620 MB**) and `…/T` (temp, **1.4 GB**) are owned by the user, mode `0700`, but dozens of sub-entries return `Operation not permitted` (e.g. `TemporaryItems`, `*ShortcutsSandboxCache`, `com.apple.WebKit.*.Sandbox`) — protected even for the owner.
- **Decision recorded (owner may overturn):** do **not** add `/private/var/folders` as a root; if wanted later, only the user's `DARWIN_USER_CACHE_DIR` children, relying on H-03's partial-failure banner for the protected ones. `/Library/Caches` is not added (nothing to reclaim). The category stays as #53 left it — one owner per path, `/private/var/folders` kept per the 2026-10-27 decision.
- **Caveat:** a single machine and one user; not re-measured on Intel or another macOS.

### 6.4 `/var` path-key note (H-19 fold-in)

`URL.standardizedFileURL` already maps `/private/var` → `/var`, so `/var` and `/private/var` spellings of one item reconcile **without** the H-05 change. What H-05 actually fixes (and what turns its tests red) is symlinked directory components and non-existent leaves.
