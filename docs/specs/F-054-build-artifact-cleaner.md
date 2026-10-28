# F-054 — Build Artifact Cleaner (NFeat-131)

> **Status:** 🗓 Planned — requirements only; **owner decisions on scope and deletion recorded 2026-10-27**. **No code is written from this document yet.**
> **Extends:** Cleanup module (F-001 categories, F-024 Browsers pane precedent) · **Raised:** 2026-10-27 · **Effort estimate:** ~7–9 d desktop (incl. 1 d of spikes)
> **Reserved pbxproj ID block:** `8245`–`8264` (claimed in `CLAUDE.md`)
> **Depends on:** BUG-001 (the shared-state fix) — this pane must be built on the corrected Cleanup state model, not the current one. See [`BUG-001-cleanup-stale-state.md`](BUG-001-cleanup-stale-state.md).

---

## 0. The request, as received, and how it was read

> *"Scan for exclusive builds folders on any project and add those over exclusive tab under Cleanup main
> tab which consumes more disk space, and provision to easy deletion as builds can be regenerated."*

| Phrase | Reading used here | If wrong |
|---|---|---|
| "exclusive builds folders" | **Build-output folders that a project's tooling regenerates** (`build/`, `.build/`, `node_modules/`, `target/` …) — read as *"dedicated build folders"*. The word "exclusive" is not otherwise interpretable; the other plausible reading is **"Xcode"** (the existing Cleanup category is *Xcode DerivedData*), i.e. *Xcode builds of any project*. | The design is a **toolchain catalogue** (§5); an Xcode-only release is just the catalogue with one row enabled. Nothing structural changes. **Confirmed by the owner 2026-10-27: all regenerable build output.** |
| "on any project" | Any project directory under the user's chosen / default **scan roots** — not only Xcode projects and not only DerivedData. | — |
| "exclusive tab under Cleanup" | A **dedicated pane in the Cleanup module's sidebar** (the same pattern as *Browsers*), named **Build Artifacts**. | Name only. |
| "which consumes more disk space" | Results **sorted by size, largest first**, with a total, and "select the biggest / stale" shortcuts. | — |
| "easy deletion as builds can be regenerated" | One-click selection and removal **with a regeneration hint per item** — but see §3 D4: *"deletion"* is `trashItem`, which does **not free space until the Trash is emptied**. This is the most important thing in this document to decide. | §12 OQ-1. |

---

## 1. Summary

Developers' disks fill with regenerable output: Xcode `DerivedData`, a `node_modules` per project, Rust
`target/` (routinely multi-GB), Gradle `build/` and `.gradle/`, Flutter `build/`, Python caches. Halo's
Cleanup already has **Xcode DerivedData** — but only the one global folder and only Xcode. F-054 finds
build output **in every project the user has**, shows which projects it belongs to and how big it is,
tells the user how to regenerate it, and removes the chosen items through Halo's existing review-sheet +
`trashItem` path.

The hard part is not scanning — it is **never offering something that is not actually regenerable**
(a hand-written `build/` folder, a committed `Pods/`, a `.venv` with unpinned dependencies). §3 D2 and §5.3
define the safety gates; they are the substance of this feature.

---

## 2. Goals / Non-Goals

**Goals**
- G1. Find build-output directories across the user's project roots, attributed to a **project** and a **toolchain**.
- G2. Rank by size; show age (is the project still active?) and a **regeneration hint**.
- G3. Remove selected items safely: review sheet, `trashItem`, partial-failure honesty, results that update **every** Cleanup view immediately (BUG-001 contract).
- G4. Safe by construction: **marker-pair detection**, git-awareness, no symlink following, no scanning of system or app-library areas.
- G5. Fast and cancellable on a large home directory; never blocks the UI.

**Non-Goals**
- N1. **Not a project manager** — no opening, building or launching projects.
- N2. **No "delete everything older than N days" automation / scheduled auto-clean** in v1 (a destructive action should be a deliberate click; revisit with the Smart Scan integration).
- N3. **Never** touches `~/Library/Developer/Xcode/Archives` (App Store submissions and their dSYMs are *not* regenerable) or Simulator runtimes (use `simctl`).
- N4. No package-manager *global* caches (`~/.npm`, `~/.cargo/registry`, `~/.gradle/caches`) in v1 — they are shared across projects and deleting them forces re-download everywhere; they can be a later "Dev caches" group with different copy.
- N5. No content reading: the scanner reads **names, sizes, modification dates and marker-file existence** only.

---

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D1 | A new `CleanupKind` case **`.buildArtifacts`** with its own actor + pane, exactly like `.browsers` (`targetPaths` returns `[]`; `ScanCoordinator` does not enumerate it). | Proven pattern in this codebase; keeps the flat-file scanner untouched. |
| D2 | **Detection requires a marker pair**: an artifact directory name **plus** a sibling file that proves the project type (§5.1). A folder called `build` with no `*.xcodeproj`/`build.gradle`/`pubspec.yaml` next to it is **never offered**. | A name alone is a guess; a deleted guess is lost data. |
| D3 | **Git gate:** if the project is a git work tree, the artifact directory must be **ignored** (`git check-ignore`) and `git ls-files -- <dir>` must be **empty**. Any tracked content ⇒ the item is skipped entirely, silently, with a count in the scan summary ("3 skipped: tracked by git"). Non-git projects rely on D2 alone and are marked *Unverified*. | The commonest foot-gun is a *committed* `Pods/` or `dist/`. Git is the only authority on "is this reproducible from source". Uses `ShellReader` (CLAUDE.md gotcha 20 — the only place a `Process` is spawned). |
| D4 | **Deletion = `FileManager.trashItem`, per the project's mandatory rule.** Consequence, stated up front: **a trashed folder frees no disk space until the Trash is emptied.** The review sheet and the result banner say so, and the pane offers a one-click jump to the existing **Trash** category. | CLAUDE.md: "ALWAYS use trashItem — NEVER removeItem." The user's goal is *recovering space*, so the UX must not imply it already happened. |
| D4b | **Approved by the owner 2026-10-27 (was OQ-1):** a second, explicit action **"Move to Trash and empty those items"** that permanently removes **only the exact URLs returned by `trashItem(resultingItemURL:)` in this operation** — never *Empty Trash* wholesale (which would destroy the user's unrelated Trash contents). | Gives the "easy deletion" the request wants without ever touching anything the user didn't select. It is still a `removeItem`, so it is a **sanctioned exception**, to be written into `CLAUDE.md` ("File deletion — mandatory rule") beside the Drive Speed one **when this is built**, scoped in source to the URLs `trashItem` returned. The default button stays *Move to Trash*; the permanent action is separate, labelled, and behind its own confirmation. |
| D5 | Every item carries a **regeneration class**: **Safe** (rebuilds offline from source: `target/`, `build/`, `.build/`), **Needs network** (`node_modules`, `Pods`, Gradle deps — rebuild needs a registry), **Caution** (`.venv`, `Unity Library/` — may not rebuild identically or quickly). *Caution* items are **unchecked by default** and cannot be bulk-selected by "Select all safe". | Honest labelling of "can be regenerated" — the user's own premise — instead of assuming it. |
| D6 | **Sizes are exact and uncapped.** Use `totalFileAllocatedSizeKey` enumeration with no 20,000-file cap **and without `.skipsHiddenFiles`** (`node_modules/.bin`, `.cache`, `.gradle` internals and `.git`-adjacent dot-folders are hidden and large). | `SpaceLensViewModel.directorySize` caps at 20,000 files (`FilesView.swift:251`), and the existing `FileSystemScanner.calculateSize(of:)` — the DerivedData sizer — uses logical `fileSizeKey` with `.skipsHiddenFiles`; a `node_modules` has 50–200 k files, so reusing either helper would **understate the very thing this feature ranks by** and fail AC-13's `du` cross-check. |
| D7 | The existing **`.xcodeData` category is folded into this pane** (toolchain *Xcode (global)*: DerivedData + CoreSimulator/Caches) and retired from the sidebar. | Two categories that both list `~/Library/Developer/Xcode/DerivedData` would reproduce BUG-001 — the exact "same folder in two places, one stays stale" defect. Single owner per path. |
| D8 | **Scan roots**: defaults that exist on disk (`~/Developer`, `~/Projects`, `~/Code`, `~/dev`, `~/src`, `~/Github`, `~/GitHub`, `~/Documents`, `~/Desktop`, `~/Sites`) **plus user-added roots**, plus an opt-in "Entire home folder (slower)". External volumes are opt-in. | Covers where projects usually live without crawling `~/Library` or `/`. |
| D9 | **Sandbox:** in the release (sandboxed) build, roots must be user-granted (`NSOpenPanel` → security-scoped bookmark, persisted). The debug/unsandboxed build can scan freely. A sandboxed build with no granted roots shows a *Choose project folders…* empty state — never a silent empty result. The sandbox also blocks the git subprocess the git gate depends on — see §12 R5. | Same split the project already has (Debug vs release entitlements); an empty list that *looks* like "nothing found" would be a lie. |

---

## 4. User Stories

- **US-1** As a developer with 40 projects, I want one list of the biggest regenerable folders so I can reclaim tens of GB in a minute.
- **US-2** As a cautious user, I want to see *why* each item is safe (marker, git status) and how to rebuild it before I confirm.
- **US-3** As someone mid-project, I don't want Halo to offer the build folder of the project I touched an hour ago, or anything git tracks.
- **US-4** As a user, I want to select "everything stale for 30+ days" in one click.
- **US-5** As a user, after I clean something, I want every number in Cleanup — here, in the sidebar, in Trash — to be correct without pressing anything (BUG-001).

---

## 5. Functional Requirements

### 5.1 Detection catalogue (data-driven — `build-artifact-catalog.json`, bundled)

| Toolchain | Marker (sibling of the artifact) | Artifact directory | Regenerate | Class |
|---|---|---|---|---|
| Xcode project | `*.xcodeproj` / `*.xcworkspace` | `build/` | Build in Xcode | Safe |
| Swift Package | `Package.swift` | `.build/` | `swift build` | Safe |
| Xcode (global) | — (fixed paths) | `~/Library/Developer/Xcode/DerivedData/*`, `~/Library/Developer/CoreSimulator/Caches/*` | Rebuilt by Xcode | Safe |
| Node | `package.json` | `node_modules/` | `npm/yarn/pnpm install` | Needs network |
| Next / Nuxt / Vite | `package.json` | `.next/`, `.nuxt/`, `dist/` (only if git-ignored) | `npm run build` | Safe |
| Rust | `Cargo.toml` | `target/` | `cargo build` | Safe |
| Gradle / Android | `build.gradle` / `build.gradle.kts` / `settings.gradle*` | `build/`, `.gradle/` | `./gradlew build` | Safe |
| Maven | `pom.xml` | `target/` | `mvn package` | Safe |
| Flutter / Dart | `pubspec.yaml` | `build/`, `.dart_tool/` | `flutter pub get` / build | Needs network |
| CocoaPods | `Podfile` | `Pods/` (only if not git-tracked) | `pod install` | Needs network |
| Carthage | `Cartfile` | `Carthage/Build/` | `carthage bootstrap` | Needs network |
| .NET | `*.csproj` / `*.sln` | `bin/`, `obj/` | `dotnet build` | Safe |
| CMake | `CMakeCache.txt` *inside* the dir | any dir containing it | re-run CMake | Safe |
| Python caches | `*.py` siblings | `__pycache__/`, `.pytest_cache/`, `.mypy_cache/` | Recreated on run | Safe |
| Python venv | `pyvenv.cfg` *inside* the dir | `.venv/`, `venv/` | recreate + `pip install` | **Caution** |
| Unity | `ProjectSettings/` | `Library/` | Re-import (can take hours) | **Caution** |

*First release (MVP) enables:* Xcode (project + global), Swift Package, Node, Rust, Gradle/Android, Flutter. The rest ship as catalogue entries behind the same code. **Marker names above are from general knowledge of those toolchains and must be confirmed against real projects during spike S1** — particularly `dist/` and `Pods/` handling.

### 5.2 Scan
- **FR-S1** `actor BuildArtifactScanner.scan(roots:config:) -> AsyncStream<ScanEvent>` (`.found(item)`, `.progress(...)`, `.skipped(reason)`, `.finished(summary)`) — the `FileSystemScanner` shape.
- **FR-S2** Depth-first with **pruning**: once an artifact directory is matched it is **not descended into** (no scanning inside `node_modules`); nested duplicates are not reported.
- **FR-S3** Always skipped: symlinks (never followed, never offered), `.git`, `.Trash`, `~/Library` (except the fixed Xcode-global paths), `/System`, `/Applications`, app bundles/packages, network and non-local volumes unless added.
- **FR-S4** Depth limit 8 from each root (configurable); a wall-clock **budget** with a visible "stopped early — scanned N folders" notice rather than silent truncation.
- **FR-S5** Cancellable (`Task.isCancelled` between directories); runs at `.utility` QoS; at most 4 concurrent size calculations.
- **FR-S6** **Rescan** and cancel-supersede semantics per BUG-001 FR-4: a newer scan invalidates an older one; stale results never overwrite.
- **FR-S7** Per-item fields: `projectName`, `projectPath`, `artifactURL`, `toolchain`, `regenClass`, `size` (exact), `artifactModified`, `projectLastModified` (newest mtime among marker files — cheap proxy, not a deep walk), `gitStatus` (`.ignored` / `.notRepo` / `.skippedTracked`), `regenHint`.

### 5.3 Safety gates (all must pass for an item to be offered)
1. **Marker pair** present (D2).
2. **Git gate** (D3).
3. Artifact is a **real directory**, not a symlink, on a **local** volume.
4. Path is **inside a scan root** after `standardizingPath` + `resolvingSymlinksInPath` (a symlinked root can't smuggle an outside path in).
5. **Recently-active warning, not a block:** artifact or project marker modified < 24 h ago ⇒ shown with an "Active" badge and **unchecked**; *Select stale* never includes it. (We cannot reliably know a build is *running*; recency is the honest proxy.)
6. **Xcode-global:** an item whose `info.plist` `WorkspacePath` project is currently open in a running Xcode is shown as **In use** and unchecked (spike S2 confirms Xcode's DerivedData layout).
7. **User ignore list**: "Never offer this folder" persists per path.

### 5.4 Pane UI (`BuildArtifactsPane`, in the Cleanup sidebar as **Build Artifacts**)
- **FR-U1** Header: total reclaimable, item count, scanned-roots summary, **Last scanned HH:MM**, **Rescan**, **Choose folders…**.
- **FR-U2** Grouping control: **Biggest first** (default) · **By project** · **By toolchain**; filter chips per toolchain; **Stale only** toggle (default threshold 30 days, user-adjustable).
- **FR-U3** Row: checkbox · project name + middle-truncated path · toolchain badge · size · age · class badge (*Safe* / *Needs network* / *Caution* / *Active*) · tooltip with the regeneration command. Context menu: *Reveal in Finder*, *Copy path*, *Never offer this folder*.
- **FR-U4** Smart-select: **Select stale (>30 d)**, **Select all Safe**, **Select none**. Never selects *Caution* or *Active*.
- **FR-U5** **Clean selected** → **review sheet** (mandatory, CLAUDE.md "all deletions require confirmation"): every path, size, project, regen hint; the count and total; the explicit sentence *"Moved to Trash — space is freed when you empty the Trash"* (D4); a **Cancel that deletes nothing**.
- **FR-U5b** **"Move to Trash and empty those items"** (D4b, owner-approved) — a *separate* button on the review sheet, never the default or the Return-key action, with its **own second confirmation** that states the items are **unrecoverable** (not in Trash afterwards). Mechanics, all required: (1) call `trashItem(at:resultingItemURL:)` per item and collect the returned URLs — **never reconstruct a Trash path from the name** (Trash may rename on collision); (2) permanently remove **only** URLs returned by *this* operation, and only after verifying each is inside a Trash directory (`~/.Trash` or a volume `.Trashes`) and is not a symlink; (3) an item whose `trashItem` failed, or whose `resultingItemURL` came back `nil`, is **not** removed and is reported as failed/left in Trash; (4) never enumerate the Trash and never call a bulk "empty trash" API; (5) whether *Caution*-class and *Unverified* (non-git) items may use this action is **OQ-6** (proposed: no — they get *Move to Trash* only); (6) the `removeItem` call site is confined to one function, commented in source, and the exception is added to `CLAUDE.md`'s "File deletion — mandatory rule" in the same change.
- **FR-U6** Result banner reports **moved N, failed M (with the first error)**, honestly — a partial failure never reads as success, and only the items that actually moved leave the list (the current `cleanAll` removes *all* rows once any deletion succeeds — BUG-001 R4).
- **FR-U7** Empty states: *Scanning…* (with progress), *Nothing found — N folders scanned* (not a blank pane), *No folders chosen* (sandbox, D9).

### 5.5 Integration
- **FR-I1** On removal the pane calls the Cleanup store's `reconcile(removed:)` (BUG-001 FR-3): sidebar badges, totals and the **Trash** category update at once.
- **FR-I2** Smart Scan: `.xcodeData` leaves the Smart Scan category list; whether the build total joins the Smart Scan summary is **OQ-3** (it needs a roots decision first — Smart Scan must not silently crawl `~/Documents`).
- **FR-I3** Settings → Cleanup: roots, stale threshold, ignore list, "Reset ignore list".

---

## 6. Non-Functional Requirements

- **NFR-1 Safety (primary).** No code path outside `trashItem` (+ the approved D4b action, FR-U5b, scoped to the URLs `trashItem` returned) removes a selected item; cancel and failure leave the disk untouched; the scanner opens no file *contents* and writes nothing.
- **NFR-2 Honesty.** Sizes are exact; "skipped" and "stopped early" are always surfaced; *Unverified* (non-git) is labelled; nothing is called "safe" that was not gated.
- **NFR-3 Performance.** A 500 GB home folder with ~100 projects scans in a bounded, visible time with the UI responsive; pruning means `node_modules` internals are never walked for *detection* (only for *sizing*, which is parallel and cancellable). Targets are measured in spike S1/S3, not asserted here.
- **NFR-4 Privacy.** Paths are shown on screen and kept in memory only for the session; no path, project name or size is logged, sent to Sentry, or persisted — except the user's *roots* and *ignore list* (their own choices, in `UserDefaults`; bookmarks as `Data`).
- **NFR-5 Concurrency.** Follows CLAUDE.md: `actor` scanner, `@MainActor` view model, `ShellReader` for `git`, never a hand-rolled `Process`, never `ShellReader` from the main actor.
- **NFR-6 Accessibility.** Rows labelled "<project>, <toolchain>, <size>, <class>"; keyboard selection; badges not colour-only.

---

## 7. Architecture & Data Model

| Component | Role |
|---|---|
| `BuildArtifactScanner` (`actor`) | Walk, prune, match catalogue, apply gates, size, emit events. |
| `BuildArtifactCatalog` | Loads `build-artifact-catalog.json` (bundle-first, same pattern as `signatures.json`); pure matching functions unit-tested with in-memory trees. |
| `GitGate` | `isIgnored(_:in:)`, `hasTrackedFiles(_:in:)` via `ShellReader` with a timeout; result `.ignored/.notRepo/.tracked/.unknown` (`.unknown` ⇒ not offered). |
| `BuildArtifactItem` | Value type (§5.2 FR-S7), `Identifiable` by **standardized path**, not a fresh `UUID()` (BUG-001 R2). |
| `BuildArtifactsViewModel` (`@MainActor`) | Selection, grouping, filters, scan generation token, clean flow; reports removals to the shared Cleanup store. |
| `CleanupStore` (from BUG-001) | The single owner of cross-category state and `reconcile(removed:)`. |
| `RootsStore` | Persists user roots as security-scoped bookmarks; default-root probing. |

---

## 8. Acceptance Criteria (ship gate)

| # | Criterion | How verified |
|---|---|---|
| AC-1 | A fixture tree with one project per catalogue toolchain yields exactly the expected artifacts, attributed to the right project and toolchain | `BuildArtifactCatalogTests` on a generated temp tree |
| AC-2 | **False-positive guard:** a `build/` (or `target/`, `dist/`) with **no** marker sibling is never offered | Same tests; mutation-check: loosen the marker rule → red |
| AC-3 | **Git gate:** an artifact directory with tracked files is never offered; an ignored one is; a non-repo one is offered as *Unverified* | `GitGateTests` against a real temp `git init` repo |
| AC-4 | Symlinks (as the artifact, or in the path) are never followed or offered; a symlinked root can't expose an outside path | `BuildArtifactSafetyTests` |
| AC-5 | `~/Library` (except the Xcode-global fixed paths), `.Trash`, `/System`, `/Applications` and app bundles are never scanned | Test over an injected root set |
| AC-6 | Sizes are exact for a tree larger than 20,000 files (the old cap would fail this) | Generated 25 k-file fixture |
| AC-7 | Cancelling the scan stops it promptly; a new scan supersedes an old one and a stale result never lands | Generation-token test |
| AC-8 | **Cancel on the review sheet deletes nothing**; a partial failure reports moved/failed truthfully and removes only moved rows | View-model test with a failing item |
| AC-9 | After a clean, the item is gone from this pane, the sidebar badge and totals update, and the **Trash** category shows it — with no manual refresh | Cross-category test (BUG-001 contract) |
| AC-10 | *Caution* and *Active* items are never selected by smart-select | Selection tests |
| AC-11 | The old `.xcodeData` category no longer appears; DerivedData is listed exactly once | Static invariant test (no overlapping roots, BUG-001 FR-2) |
| AC-12 | Sandboxed build with no granted roots shows the *Choose folders* state, not an empty list | Manual (release entitlements) |
| AC-13 | Scan of this developer's real home: results hand-checked against `du` for the top 10 items | Manual — recorded in §14 |
| AC-14 | **D4b safety (FR-U5b):** with a sentinel file placed in the Trash beforehand, "Move to Trash and empty" removes exactly the selected items and **the sentinel survives**; an item whose `trashItem` fails is not removed; a `resultingItemURL` outside a Trash directory (or a symlink) is refused; Cancel on either confirmation changes nothing | `BuildArtifactPermanentRemovalTests` on a temp tree + real Trash sentinel; **mutation-check:** replace the returned-URL list with a Trash enumeration → sentinel test goes red |

---

## 9. Test Plan

Unit: `BuildArtifactCatalogTests`, `GitGateTests` (real `git init` in a temp dir), `BuildArtifactSafetyTests`, `BuildArtifactSizingTests` (25 k-file fixture), `ScanSupersessionTests`, `BuildArtifactsViewModelTests` (selection rules, clean flow, partial failure, cancel), static `CleanupRootsInvariantTests`. **Mutation-check** AC-2, AC-3, AC-8 and AC-14 (loosen the rule / drop the gate and confirm the test goes red) — these guard data loss. UI/E2E: extend the `HaloUITests` fixture harness so the destructive flow acts only on dummy projects in a temp sandbox and a real sentinel path is asserted untouched (TC-SAFE-05 pattern). Manual cases added to `MANUAL_TEST_PLAN.md` when built.

---

## 10. Mobile Feasibility (governance requirement)

> Full study: [`HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 row + §9 "Feasibility — Build Artifact Cleaner (from desktop F-054)".

**Verdict: ❌ iOS · ❌ Android → Won't do.** There is no developer build tree on a phone to clean, and both mobile sandboxes forbid enumerating or deleting outside the app's own container, which is the feature's entire premise (the same blocker that made the Browser Cleaner F-024 ❌/❌). Recorded as *Won't do*, not "unassessed".

---

## 11. Relationship to existing code

- **`CleanupKind.xcodeData` / `ScanCoordinator.scanDerivedDataDirectories()`** — the directory-as-one-item approach is the right model and is reused; the category itself is retired into this pane (D7).
- **`FileSystemScanner`** — *not* reused for detection or sizing (it lists individual files, applies `minSizeBytes`/`maxDepth`, skips hidden files and sizes by logical `fileSizeKey` — all wrong for this; it has **no** 20 k cap — that cap lives in `SpaceLensViewModel.directorySize`), but its `AsyncStream` event shape is mirrored.
- **`BrowserCleanerView`** — the precedent for a dedicated pane inside Cleanup's sidebar.
- **`ShellReader`** — the only sanctioned subprocess path; used for `git`.
- **`Models.swift` `CleanupKind`** — adding a case needs the same icon/`targetPaths`/`ageThresholdDays` arms; `targetPaths == []` like `.browsers`.

---

## 12. Open Questions & Risks

| # | Item | Notes / proposed default |
|---|---|---|
| ~~OQ-1~~ | ~~Space is not freed by `trashItem`. Offer D4b?~~ | **Resolved 2026-10-27: yes** — separate, explicitly-labelled button, off the default path, limited to the exact URLs returned by this operation; never an *Empty Trash*. Second sanctioned exception to the `trashItem`-only rule. |
| ~~OQ-2~~ | ~~Confirm the reading of "exclusive builds folders" (§0).~~ | **Resolved 2026-10-27: all regenerable build output**, not Xcode-only. MVP toolchains per §5.1. |
| OQ-3 | Should the build total join **Smart Scan**? It would need default roots, and Smart Scan must not silently crawl `~/Documents`. | Proposed: not in v1; pane only. |
| OQ-4 | Default scan roots (D8) — include `~/Documents`/`~/Desktop`, which also hold non-project files? | Proposed: yes but marker-gated, so the cost is time not risk. |
| OQ-5 | **Root overlap with other Cleanup categories.** D8's roots (`~/Documents`, `~/Desktop`, "Entire home folder") can contain `~/Downloads` and other category roots, and the user may add arbitrary roots; BUG-001 FR-2 says every scanned path has exactly one owner, and AC-11's static invariant can only cover *fixed* roots. A `node_modules` under `~/Downloads` would be listed by both Downloads (as files) and Build Artifacts. | Proposed: Build Artifacts **excludes** paths owned by another Cleanup category (at least `~/Downloads`, `~/Library`) from its roots, *and* relies on BUG-001 `reconcile(removed:)` (which already handles "equal or under") as the backstop for user-added roots. State which in the implementation. |
| OQ-6 | May *Caution*-class and *Unverified* (non-git) items use the permanent "Move to Trash and empty" action (FR-U5b)? | Proposed: no — the action is irreversible and these are exactly the items whose regenerability is least certain. |
| R1 | A tool changes its output layout (e.g. a new `.build` location). | Catalogue is data (JSON), updatable without code; unknown ⇒ not offered. |
| R2 | `git check-ignore` on thousands of candidates is slow. | Batch per repo (`git check-ignore --stdin`); cache per repo for the scan; spike S1 measures. |
| R3 | An Xcode build running right now while its `build/` is trashed. | Recency badge + review sheet wording; cannot be fully ruled out — stated, not hidden. |
| R4 | `trashItem` across volumes copies instead of renaming (slow for huge folders on an external disk). | Show progress; warn when the artifact's volume ≠ the Trash's volume. |
| R5 | **The git gate cannot run in the sandboxed release build.** `ShellReader` reports a denied `posix_spawn` as `launchFailure` there (CLAUDE.md gotcha 20), so `GitGate` returns `.unknown` — and §5.3/`GitGate` say `.unknown` ⇒ not offered. Read literally, a sandboxed build offers **nothing inside any git repository**. (Today's shipped DMGs are unsandboxed — CLAUDE.md gotcha 27 — so this bites only a future App Store build.) Separately, on a Mac without the Command Line Tools `/usr/bin/git` is a shim that raises an "install developer tools" dialog — check for a real git before spawning. | Spike S3 must decide: sandboxed build = pure-Swift `.git` / `.gitignore` parsing (hard to get exactly right — do not approximate `git check-ignore`) or XPC helper, or **the pane is unsandboxed-only**. Until decided, AC-3 is verified on the unsandboxed build only and the sandbox state in D9 must say "git gate unavailable ⇒ offering nothing in repos" rather than silently omitting them. |
| R6 | Whether a sandboxed build may *remove* the URL `trashItem` returns (it points into `~/.Trash`, outside the app's granted scope) is unverified. | Spike S3 includes it; if denied, FR-U5b is unavailable in the sandboxed build and the button is hidden, not disabled-without-explanation. |

---

## 13. Execution Plan

| Phase | Work | Est. | Exit |
|---|---|---|---|
| **P0 — Spikes** | S1 catalogue accuracy + git-gate speed on real projects (`du` cross-check); S2 Xcode DerivedData `WorkspacePath`/in-use detection; S3 sandbox bookmark flow | 1 d | Marker table confirmed; AC-13 method works |
| **BUG-001 first** | `CleanupStore`, single-owner roots, `reconcile` | (own estimate) | This feature is built on it |
| **P1 — Engine** | Catalogue, scanner, git gate, sizing, safety gates — UI-free | 2.5 d | AC-1…7 |
| **P2 — Pane** | Rows, grouping, filters, smart-select, empty/progress states, roots UI | 2 d | AC-10, 12 |
| **P3 — Clean flow** | Review sheet, `trashItem` batch, partial-failure reporting, reconcile hookup, retire `.xcodeData` | 1.5 d | AC-8, 9, 11 |
| **P4 — Polish & docs** | Settings, a11y, `MANUAL_TEST_PLAN.md`, `CLAUDE.md` section, UI-test fixtures, mobile row | 1 d | AC-13 |

Add new files via `scripts/add_source_files.rb`, never by hand-editing `project.pbxproj`. The script assigns **random** 24-hex object IDs (see CLAUDE.md's v2.5 note above the reserved-block table), so the `8245`–`8264` block is **not consumed** by this route — it matters only if IDs are ever assigned by hand.

---

## 14. Implementation Record

*Not started.*
