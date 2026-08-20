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
| 1.1 | `DriveAccessManager` actor — persist/resolve security-scoped bookmarks keyed by `volumeUUID` (JSON in Application Support) | ⬜ |
| 1.2 | Ask-first prompt UI (banner) + `AlertLog.append(...)` entry on first-ever drive sighting | ⬜ |
| 1.3 | `NSOpenPanel` grant flow scoped to the volume root; persist resulting bookmark on accept | ⬜ |
| 1.4 | Decline path: mark `KnownDrive.indexingState = .declined`, no future auto-prompt for that UUID | ⬜ |
| 1.5 | `DriveIndexCoordinator` actor — initial full walk (reuse `FileSystemScanner`-style bounded traversal) → `DriveIndexStore` | ⬜ |

## Phase 2 — Search & Drives UI

| # | Task | Status |
|---|------|--------|
| 2.1 | `AppModule.driveIndex` case in `Models.swift`/`AppState.swift` (title/icon/gradientColors switch arms) + add to `static var reorderable` — no migration code needed, `moduleOrder`'s load-time diff auto-appends new cases | ⬜ |
| 2.2 | `ContentView.DetailView`'s exhaustive `switch appState.selectedModule` — add `case .driveIndex: DriveIndexView()` (compiler enforces this, can't be skipped) | ⬜ |
| 2.3 | `DriveIndexView` tab-bar shell (Drives / Search / Duplicates / Settings), mirrors `FilesView`'s `FilesTab` enum | ⬜ |
| 2.4 | Drives tab — reuse `DriveSpeedView` row pattern; connected/disconnected badge, Index Now / Re-index / Forget actions | ⬜ |
| 2.5 | Search tab — query field, result rows (drive name + badge, path, size, last-seen), Reveal/Open actions gated on connected state | ⬜ |
| 2.6 | Accessibility identifiers wired (`driveIndex.*`, plus `sidebar.row.driveIndex` comes free from the existing `SidebarItem` pattern) per `HaloUITests/README.md` convention | ⬜ |
| 2.7 | Quick Search picker (`DriveSearchQuickPickerView` + controller) on **⌘⇧F**, registered in `HotkeyManager.start()` alongside the existing ⌘⇧A/⌘⇧V pickers | ⬜ |

## Phase 3 — Incremental re-index & rename/move handling

| # | Task | Status |
|---|------|--------|
| 3.1 | Diff-on-remount: inode-aware new / moved / modified / removed classification | 🔄 (`DriveIndexStore.applyDiff` implemented + committed in Phase 0; not yet called by a real coordinator/walk — see Phase 1) |
| 3.2 | Batched SQLite transactions for large-drive performance | ✅ (`applyDiff` already runs in one `withTransaction`) |
| 3.3 | Load-aware throttling/deferral via `SystemMonitor` (CPU pressure / Low Power Mode) | ⬜ |
| 3.4 | Interrupted-scan resilience (unplug mid-index leaves store consistent) | ⬜ |

## Phase 4 — Cross-Drive Duplicates

| # | Task | Status |
|---|------|--------|
| 4.1 | Size-threshold-gated hashing pipeline feeding existing `DuplicateDetector` | ⬜ |
| 4.2 | Duplicates tab UI — confirmed vs. awaiting-reconnect sections | ⬜ |
| 4.3 | Confirm-before-trash flow (TC-SAFE-02 pattern) for cross-drive duplicate cleanup | ⬜ |
| 4.4 | Settings tab — size threshold control, Forget Drive, pause-indexing toggle, file-type category filter (Documents/Images/Video/Audio/Archives/Code/Other), exclude-folders-by-name list (DiskCatalogMaker-inspired, seeded with `.git`/`node_modules`/`.Trashes`) | ⬜ |

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
| A.1 | Add `case drives = "Drives"` (or matching final title) to `HaloUITests/HaloSidebar.swift`'s `HaloModule` enum + `appModuleRawValue` override if the case name doesn't match `AppModule.rawValue` verbatim | ⬜ |
| A.2 | `HaloUITests/DriveIndexUITests.swift` — sidebar navigation + tab switching | ⬜ |
| A.3 | UI-test seed hook (deterministic sample `KnownDrive`/`IndexedFileEntry` rows under `-uiTesting`, since `HaloTestFixtures` only creates files on the boot volume and cannot simulate a real mounted external volume) | ⬜ |
| A.4 | Search tab: query → result rows → connected/disconnected action gating | ⬜ |
| A.5 | Settings threshold control interaction | ⬜ |
| A.6 | Cross-drive duplicate delete confirms-and-cancels-deletes-nothing (TC-SAFE-02, `HaloTestFixtures`/`HaloUITestCase+Confirmation` pattern — reusable as-is) | ⬜ |
| A.7 | Drop `DriveIndexUITests.swift` at top level of `HaloUITests/` and re-run `ruby scripts/add_uitest_target.rb` (full-glob regenerate — no arguments, no manual pbxproj edit) | ⬜ |
| A.8 | Unit tests (`HaloTests`) for inode-diff classification and size-threshold gating (pure logic, no real disk needed) | ⬜ |
| A.9 | *(Stretch — real mount/unmount coverage)* `hdiutil attach`/`detach` a small throwaway `.dmg` from a UI test's setUp/tearDown to exercise real `DriveMonitor` notifications end-to-end; not blocking v1 since it needs disk-image entitlement/signing verification first | ⏭ |

---

## Progress Log

> Append-only. One entry per meaningful checkpoint: `YYYY-MM-DD — what happened`.

- **2026-08-21** — Spec, roadmap, execution-prompt playbook, and manual test plan drafted and saved on `feat/f051-external-drive-indexer`. Research agent dispatched to confirm exact current signatures (`Models.swift`, `AppState.swift`, `ContentView.swift`, `DriveSpeedTester.swift`, `FileSystemScanner.swift`, `DuplicateDetector.swift`, `AlertLog`/`AlertManager`, `HaloSidebar`/`HaloTestFixtures` test helpers, and the `scripts/add_source_files.rb` / `add_uitest_target.rb` pbxproj-registration flow) before Phase 0 implementation begins. Mid-planning, scope grew: added Quick Search picker (⌘⇧F), file-type category filter, and exclude-folders-by-name settings (DiskCatalogMaker prior art) to the spec, roadmap, and prompts.
- **2026-08-21** — Phase 0 complete. `DriveVolume` promoted to `Models.swift` with `volumeUUID`/`driveKey`; added `IndexedFileEntry`, `KnownDrive`, `DriveIndexingState`, `IndexedFileCategory`, `CrossDriveDuplicateGroup`/`Item`. New `DriveMonitor.swift` (NSWorkspace mount/unmount observer, mirrors `IdleAppMonitor`'s token pattern) and `DriveIndexStore.swift` (SQLite actor — schema, `applyDiff` inode-aware reconciliation in one transaction, `search`, duplicate-candidate queries, `forgetDrive`). Linked `libsqlite3.tbd` via a new `scripts/add_system_library.rb` (xcodeproj-gem based, mirrors the IOKit/SystemConfiguration pattern rather than hand-editing pbxproj). Added `com.apple.security.files.bookmarks.app-scope` to `Halo.entitlements`. `xcodebuild -target Halo build` (signing disabled) succeeds with no errors/warnings on the new files. Note: this checkout has no committed shared scheme for the `Halo` target (only `HaloTests`/`HaloUITests` are shared schemes; `Halo`'s scheme is normally Xcode-autocreated into gitignored `xcuserdata`) — used `-target Halo` instead of `-scheme Halo` for CLI verification; not a regression from this work, pre-existing environment quirk.
