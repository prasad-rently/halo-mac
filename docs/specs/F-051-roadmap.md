# F-051 — Execution Roadmap

> **Companion to:** [`F-051-external-drive-index.md`](F-051-external-drive-index.md) (requirements/design), [`F-051-execution-prompts.md`](F-051-execution-prompts.md) (prompt playbook), [`F-051-manual-test-plan.md`](F-051-manual-test-plan.md) (QA)
> **Branch:** `feat/f051-external-drive-indexer`
> **Owner:** Gokul Prasad M
> **Status legend:** ⬜ not started · 🔄 in progress · ✅ done · ⏭ skipped/deferred · ❌ blocked

This file is the live tracker for building F-051. Update the checkbox + status
cell for each row as work lands, and append a dated entry to the **Progress
Log** at the bottom every time a phase completes, is blocked, or scope changes.
Do not rewrite history in the log — append only.

---

## Phase 0 — Foundations

| # | Task | Status |
|---|------|--------|
| 0.1 | Promote `DriveVolume` from `DriveSpeedTester.swift` into `Models.swift`; add `volumeUUID: String?` + `driveKey` identity helper | ✅ |
| 0.2 | Add `IndexedFileEntry`, `KnownDrive`, `IndexedFileCategory`, `CrossDriveDuplicateGroup`/`CrossDriveDuplicateItem` models | ✅ |
| 0.3 | `DriveMonitor` — `NSWorkspace.didMountNotification` / `.didUnmountNotification` observer, resolves `volumeUUIDStringKey` | ✅ |
| 0.4 | `DriveIndexStore` actor — SQLite schema (`drives`, `files` tables + indexes), open/create on first use — implemented fuller than the Phase-0 minimum: also has working `applyDiff` (inode-aware diff), `search`, `candidateDuplicateSizes`/`filesOfSize`, `forgetDrive` (Phases 1/3/4 logic landed early since it was cheap to do alongside the schema) | ✅ |
| 0.5 | Link `libsqlite3.tbd` into the `Halo` target's Frameworks build phase via a small `xcodeproj`-gem Ruby script (`scripts/add_system_library.rb`) | ✅ |
| 0.6 | Register new app-target source files via `scripts/add_source_files.rb <paths...>` | ✅ |
| 0.7 | Add `com.apple.security.files.bookmarks.app-scope = true` to `Halo/Halo.entitlements` (release only) | ✅ |

## Phase 1 — Access & first-index flow

| # | Task | Status |
|---|------|--------|
| 1.1 | `DriveAccessManager` actor — persist/resolve security-scoped bookmarks keyed by `driveKey` (JSON in Application Support) | ✅ |
| 1.2 | Ask-first prompt UI (`.sheet`) + `AlertLog.append(...)` entry on first-ever drive sighting | ✅ |
| 1.3 | `NSOpenPanel` grant flow scoped to the volume root; persist resulting bookmark on accept | ✅ |
| 1.4 | Decline path: mark `KnownDrive.indexingState = .declined`, no future auto-prompt for that key | ✅ |
| 1.5 | `DriveIndexCoordinator` (`@MainActor` class, not an actor — it drives `NSOpenPanel` and publishes `@Published` UI state) — initial full walk via `FileManager.enumerator` (own bounded walk, not literally `FileSystemScanner` — that scanner has no hashing/inode/category hooks and is tuned for cleanup, not indexing) → `DriveIndexStore.applyDiff` | ✅ |

## Phase 2 — Search & Drives UI

| # | Task | Status |
|---|------|--------|
| 2.1 | `AppModule.driveIndex` case in `AppState.swift` (title/icon/gradientColors switch arms) + added to `static var reorderable` | ✅ |
| 2.2 | `ContentView.DetailView`'s exhaustive switch — `case .driveIndex: DriveIndexView()` | ✅ |
| 2.3 | `DriveIndexView` tab-bar shell (Drives / Search / Duplicates / Settings), mirrors `FilesView`'s `FilesTab` enum | ✅ |
| 2.4 | Drives tab — own row styling (`HaloCard`, connected/disconnected + state badges), Index Now / Re-index / Forget actions | ✅ |
| 2.5 | Search tab — query field, result rows (drive name + badge, path, size, last-seen), Reveal/Open actions gated on connected state | ✅ |
| 2.6 | Accessibility identifiers wired (`driveIndex.tab.*`, `driveIndex.drives.row`, `driveIndex.search.field/row/reveal.button/open.button`, `driveIndex.ask.accept/decline.button`, `driveIndex.settings.*`) | ✅ |
| 2.7 | Quick Search picker (`DriveSearchQuickPickerView` + controller) on **⌘⇧F**, registered in `HotkeyManager.start()` alongside the existing ⌘⇧A/⌘⇧V pickers | ✅ |

## Phase 3 — Incremental re-index & rename/move handling

| # | Task | Status |
|---|------|--------|
| 3.1 | Diff-on-remount: inode-aware new / moved / modified / removed classification | ✅ (`DriveIndexCoordinator.beginIndexing` now walks + calls `applyDiff` for real, on both the initial grant and every silent re-mount) |
| 3.2 | Batched SQLite transactions for large-drive performance | ✅ (`applyDiff` already runs in one `withTransaction`) |
| 3.3 | Load-aware throttling/deferral | ✅ — implemented via `ProcessInfo.processInfo.isLowPowerModeEnabled`/`.thermalState` directly rather than `SystemMonitor` (the walk is single-threaded, so there's no concurrency to scale down — it's a cooperative yield every 200 files, plus a short sleep under detected pressure) |
| 3.4 | Interrupted-scan resilience (unplug mid-index leaves store consistent) | ✅ — `DriveIndexCoordinator.walk` now returns `[WalkedFileRow]?`; `nil` (root no longer exists post-walk) tells `beginIndexing` to skip the diff entirely rather than misreading every unvisited file as deleted |

## Phase 4 — Cross-Drive Duplicates

| # | Task | Status |
|---|------|--------|
| 4.1 | Size-threshold-gated hashing pipeline feeding existing `DuplicateDetector` | ✅ `DriveIndexCoordinator.duplicates(minSizeBytes:)` — free size-grouping across drives, hash-confirms whichever members are currently connected, groups with any disconnected member surface as "awaiting reconnect" rather than a false confirm |
| 4.2 | Duplicates tab UI — confirmed vs. awaiting-reconnect sections | ✅ |
| 4.3 | Confirm-before-trash flow (TC-SAFE-02 pattern) for cross-drive duplicate cleanup | ✅ `CrossDriveDuplicateGroupCard` mirrors the existing `DuplicateGroupCard` exactly (mark → confirmationDialog → `deleteDuplicates`, `trashItem` never `removeItem`); a copy on a disconnected drive can't be marked at all |
| 4.4 | Settings tab — size threshold control, pause-indexing toggle, file-type category filter (Documents/Images/Video/Audio/Archives/Code/Other), exclude-folders-by-name list (DiskCatalogMaker-inspired, seeded with `.git`/`node_modules`/`.Trashes`) | ✅ (Forget Drive lives on the Drives tab per-row instead of Settings — same capability, more discoverable there) |

## Phase 5 — Mobile governance, docs & hardening

| # | Task | Status |
|---|------|--------|
| 5.1 | Write formal feasibility study + `HALO_MOBILE_ROADMAP.md` §3 row | ⬜ |
| 5.2 | Multi-drive-simultaneous-mount queuing | ⬜ |
| 5.3 | Update `docs/ROADMAP.md` / `FEATURE_ROADMAP.md` with shipped entry | ⬜ |
| 5.4 | Final manual test pass against `F-051-manual-test-plan.md` | ⬜ |

## Automation / E2E

| # | Task | Status |
|---|------|--------|
| A.1 | Added `case driveIndex = "Drive Index"` to `HaloUITests/HaloSidebar.swift`'s `HaloModule` enum + `appModuleRawValue` override (`"driveIndex"`, matches `AppModule.rawValue` exactly) | ✅ |
| A.2 | `HaloUITests/DriveIndexUITests.swift` — sidebar navigation + tab switching across all 4 tabs | ✅ |
| A.3 | UI-test seed hook: `DriveIndexCoordinator.seedForUITesting()` under a new `-uiTestingSeedDriveIndex` launch flag, gated by a new `HaloUITestCase.additionalLaunchArguments` override hook (empty default, zero impact on existing suites). `DriveIndexStore.storeDirectory()` routes to a temp dir under the same flag so tests never touch a real on-disk index | ✅ |
| A.4 | Search tab: query → result rows → connected/disconnected action gating | ✅ (`test_search_finds_seeded_files_and_gates_actions_by_connection`) |
| A.5 | Settings threshold/toggle interaction | ✅ (`test_settings_controls_are_interactable`; Duplicates threshold picker covered by `test_duplicates_tab_renders_threshold_picker`) |
| A.6 | Cross-drive duplicate delete confirms-and-cancels-deletes-nothing (TC-SAFE-02) | ✅ (`test_duplicates_delete_confirms_and_cancel_deletes_nothing`) for the mark → confirm → cancel mechanics on the seeded "awaiting reconnect" group's connected item. A fully **hash-confirmed** group needs two real drives with byte-identical files to hash — same class of gap as A.9's real-mount stretch goal, not fakeable with metadata-only seed rows |
| A.7 | Drop `DriveIndexUITests.swift` at top level of `HaloUITests/` and re-run `ruby scripts/add_uitest_target.rb` | ✅ |
| A.8 | Unit tests (`HaloTests`) for inode-diff classification and size-threshold gating (pure logic, no real disk needed) | ✅ (`HaloTests/DriveIndexTests.swift` — `DriveIndexStoreDiffTests`, `IndexedFileCategoryTests`, `DriveVolumeIdentityTests`; also caught and fixed a real regression this work introduced in the pre-existing `DriveSpeedTesterTests.swift`, which constructed `DriveVolume` without the new `volumeUUID` field) |
| A.9 | *(Stretch — real mount/unmount coverage)* `hdiutil attach`/`detach` a small throwaway `.dmg` from a UI test's setUp/tearDown to exercise real `DriveMonitor` notifications end-to-end; not blocking v1 since it needs disk-image entitlement/signing verification first | ⏭ |
| A.10 | *(New)* Also added a quick-search-picker E2E test (`test_quick_search_picker_opens_searches_and_dismisses`) — not originally scoped as a separate roadmap line, folded into A.2's file | ✅ |

---

## Progress Log

> Append-only. One entry per meaningful checkpoint: `YYYY-MM-DD — what happened`.

- **2026-08-21** — Spec, roadmap, execution-prompt playbook, and manual test plan drafted and saved on `feat/f051-external-drive-indexer`. Research agent dispatched to confirm exact current signatures (`Models.swift`, `AppState.swift`, `ContentView.swift`, `DriveSpeedTester.swift`, `FileSystemScanner.swift`, `DuplicateDetector.swift`, `AlertLog`/`AlertManager`, `HaloSidebar`/`HaloTestFixtures` test helpers, and the `scripts/add_source_files.rb` / `add_uitest_target.rb` pbxproj-registration flow) before Phase 0 implementation begins. Mid-planning, scope grew: added Quick Search picker (⌘⇧F), file-type category filter, and exclude-folders-by-name settings (DiskCatalogMaker prior art) to the spec, roadmap, and prompts.
- **2026-08-21** — Phase 3 complete (3.1/3.2 had already landed in Phase 1; this closes 3.3/3.4). `DriveIndexCoordinator.walk` is now `async`, returning `[WalkedFileRow]?` instead of `[WalkedFileRow]` — `nil` specifically means "the volume disappeared before the walk finished" (detected by checking `root` still exists after enumeration completes), and `beginIndexing` skips `applyDiff` entirely in that case rather than diffing a partial walk against the full stored index, which would have misclassified every unvisited file as removed. Throttling uses `ProcessInfo.isLowPowerModeEnabled`/`.thermalState` directly (no `SystemMonitor` dependency needed) — a cooperative `Task.yield()` every 200 files, with a short sleep added under detected pressure; there's no concurrency knob to turn down since the walk is single-threaded. Added 4 new unit tests (`DriveIndexCoordinatorWalkTests`) covering folder exclusion, category filtering, and the vanished-root → `nil` contract — 13/13 drive-index unit tests passing.
- **2026-08-21** — Phase 4 complete. `DriveIndexCoordinator.duplicates(minSizeBytes:)` replaces the earlier stub: free size-grouping across every indexed drive (`DriveIndexStore.candidateDuplicateSizes`/`filesOfSize`), then resolves each currently-connected candidate's real URL through its bookmark and feeds those to the existing `DuplicateDetector` unmodified. A group is only `isConfirmed` when every same-size member's drive was connected and hash-matched; any disconnected member routes the whole group to "awaiting reconnect" instead of a false-positive confirm. `CrossDriveDuplicateGroupCard` mirrors `DuplicateGroupCard`'s mark → confirmationDialog → trash pattern exactly; a copy on a disconnected drive can't be marked at all (its row is disabled, not just unchecked). Added `test_duplicates_delete_confirms_and_cancel_deletes_nothing` and `test_duplicates_tab_shows_awaiting_reconnect_group` to `DriveIndexUITests.swift` — both pass against the seeded data. Full `HaloTests` suite (all suites, not just the new ones) re-run clean after these changes, confirming no regressions.
- **2026-08-21** — Automation/E2E landed (A.1–A.5, A.7, A.8, A.10; A.6 blocked on Phase 4; A.9 deferred stretch goal). Added `HaloUITestCase.additionalLaunchArguments` override hook (default `[]`, no effect on existing suites) so `DriveIndexUITests` can request `-uiTestingSeedDriveIndex`. `DriveIndexStore.storeDirectory()` and `DriveIndexCoordinator.start()` honor that flag to seed two fake drives (one connected, one not) into a temp-dir-isolated store — never the real on-disk index. `DriveIndexStore` gained `init(directoryOverride:)` for the same isolation reason in `HaloTests`. New `HaloTests/DriveIndexTests.swift` (Swift Testing) covers insert/moved/modified/removed diff classification, duplicate-candidate size grouping, category extension mapping, and `driveKey` fallback identity — 14/14 passing. New `HaloUITests/DriveIndexUITests.swift` covers sidebar nav+tabs, seeded-drive rendering, search with connected/disconnected action gating, settings interactability, the duplicates threshold picker, and the ⌘⇧F quick-search picker's open/search/dismiss cycle. **Caught and fixed a real regression**: Phase 0's new required `DriveVolume.volumeUUID` field broke the pre-existing `HaloTests/DriveSpeedTesterTests.swift` (a construction site the earlier research pass didn't have reason to flag) — full unit suite passes after the fix. `xcodebuild build-for-testing -scheme HaloUITests` succeeds clean.
- **2026-08-21** — Phase 2.7 complete: `DriveSearchQuickPickerView` + `DriveSearchQuickPickerController` (⌘⇧F) added, mirroring `QuickActionPickerController`'s exact `NSPanel`/key-monitor pattern (arrow-key nav, Enter opens + dismisses, Esc/resign-key dismisses). Wired into `HotkeyManager` (4th shortcut slot, same local+global monitor pattern as the other three) and `AppState.setupHotkeys()`. Reuses `DriveIndexCoordinator.search/openFile` — same data source as the in-module Search tab. Builds clean. Phase 2 is now fully done.
- **2026-08-21** — Phases 1 and 2 complete (built together — the coordinator and its UI are easiest to verify against each other). `DriveAccessManager` (security-scoped bookmarks, JSON in Application Support, self-healing on staleness). `DriveIndexCoordinator` (`@MainActor` class): mount → ask-first-or-silent-resolve → grant panel → walk → `applyDiff` → refresh, plus manual Index Now/Re-index/Forget, search passthrough, and sandboxed reveal/open (resolves the security-scoped root fresh per call, not the plain mount-notification URL). New sidebar module wired end to end: `AppModule.driveIndex`, `ContentView` routing, `DriveIndexView` (Drives/Search/Duplicates/Settings tabs), `AskIndexDriveSheet`. Settings tab landed early since it was cheap alongside the coordinator: size threshold, per-category file-type toggles, exclude-folder-names editor, pause toggle — all `@AppStorage`-backed. `xcodebuild -target Halo build` succeeds clean (fixed one macOS-14-only `onChange` overload down to the 13.0-compatible form along the way). `coordinator.duplicates()` is a deliberate stub returning `[]` until Phase 4 lands the real hashing pipeline — the Duplicates tab UI already renders whatever it returns.
- **2026-08-21** — Phase 0 complete. `DriveVolume` promoted to `Models.swift` with `volumeUUID`/`driveKey`; added `IndexedFileEntry`, `KnownDrive`, `DriveIndexingState`, `IndexedFileCategory`, `CrossDriveDuplicateGroup`/`Item`. New `DriveMonitor.swift` (NSWorkspace mount/unmount observer, mirrors `IdleAppMonitor`'s token pattern) and `DriveIndexStore.swift` (SQLite actor — schema, `applyDiff` inode-aware reconciliation in one transaction, `search`, duplicate-candidate queries, `forgetDrive`). Linked `libsqlite3.tbd` via a new `scripts/add_system_library.rb` (xcodeproj-gem based, mirrors the IOKit/SystemConfiguration pattern rather than hand-editing pbxproj). Added `com.apple.security.files.bookmarks.app-scope` to `Halo.entitlements`. `xcodebuild -target Halo build` (signing disabled) succeeds with no errors/warnings on the new files. Note: this checkout has no committed shared scheme for the `Halo` target (only `HaloTests`/`HaloUITests` are shared schemes; `Halo`'s scheme is normally Xcode-autocreated into gitignored `xcuserdata`) — used `-target Halo` instead of `-scheme Halo` for CLI verification; not a regression from this work, pre-existing environment quirk.
