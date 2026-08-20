# F-051 — Execution Prompt Playbook

> Companion to [`F-051-roadmap.md`](F-051-roadmap.md). Each phase below has a
> self-contained prompt that could be handed to a fresh Claude Code session
> (or reused by this one) to execute that step, plus the actual outcome once
> it's run. **Update the "Result" line under each prompt as work completes** —
> this file is the execution record, not just a plan.

Ground rules baked into every prompt (don't repeat per-phase, but every
executor must follow them):
- Read `CLAUDE.md` and `docs/specs/F-051-external-drive-index.md` first.
- Never use `FileManager.default.removeItem` — always `trashItem`, per the
  project's mandatory rule.
- Every destructive UI action needs a confirmation sheet before it fires.
- New Swift files must be registered in `Halo.xcodeproj/project.pbxproj` via
  the repo's `scripts/add_source_files.rb` (or the UI-test equivalent) — never
  hand-edited UUIDs unless the script can't cover the case.
- After each phase: build (`xcodebuild build` per `CLAUDE.md` → "Build &
  Sign", signing disabled), fix any compile errors, then check the
  corresponding boxes in `F-051-roadmap.md` and append a Progress Log entry.

---

## Phase 0 — Foundations

**Prompt:**
> Implement Phase 0 of F-051 (`docs/specs/F-051-external-drive-index.md` §13).
> 1. Move the `DriveVolume` struct out of `DriveSpeedTester.swift` into
>    `Models.swift`, add `let volumeUUID: String?`, and populate it in
>    `availableVolumes()` via `URLResourceKey` for volume UUID (fetch
>    alongside the existing resource keys). Update the one caller
>    (`DriveSpeedViewModel`) if the type's module/visibility changes.
> 2. Add to `Models.swift`: `IndexedFileEntry` (id, volumeUUID, relativePath,
>    fileName, size, createdDate, modifiedDate, kind: FileKind, inode: UInt64,
>    partialHash: String?, fullHash: String?, lastSeenDate), `KnownDrive`
>    (volumeUUID, name, indexingState: enum{.notIndexed,.indexed,.declined},
>    lastIndexedDate, fileCount, totalBytes), and a volume-aware
>    `CrossDriveDuplicateGroup`/`CrossDriveDuplicateItem` pair (see spec §8).
> 3. Create `Halo/Core/Scanner/DriveMonitor.swift` — an observer (mirror the
>    add/remove-observer-token pattern in `IdleAppMonitor.swift`) on
>    `NSWorkspace.shared.notificationCenter` for `.didMountNotification` and
>    `.didUnmountNotification`, resolving each volume's UUID and emitting a
>    typed event (mounted/unmounted + `DriveVolume`) to a callback or
>    `AsyncStream`.
> 4. Create `Halo/Core/Scanner/DriveIndexStore.swift` — `actor DriveIndexStore`
>    wrapping raw `SQLite3` (no SPM dependency): open/create a database file
>    under Application Support, create `volumes` and `files` tables with an
>    index on `(volumeUUID, fileName)`, and stub `insert`/`upsert`/`query`
>    methods (bodies can be minimal in this phase — schema + open/close is the
>    goal).
> 5. Link `libsqlite3.tbd` into the `Halo` target: write a one-off Ruby
>    script using the `xcodeproj` gem (same dependency the existing
>    `scripts/*.rb` already use) that calls
>    `project.new_file('usr/lib/libsqlite3.tbd', :sdk_root)` then
>    `target.frameworks_build_phase.add_file_reference(...)` — mirror the
>    existing IOKit/SystemConfiguration `.framework` entries in
>    `project.pbxproj` (same three-part pattern: file ref + build file +
>    Frameworks-phase entry) but with
>    `lastKnownFileType = "sourcecode.text-based-dylib-definition"`. Do not
>    hand-edit pbxproj UUIDs directly. Confirm `import SQLite3` resolves.
> 6. Add `com.apple.security.files.bookmarks.app-scope = true` to
>    `Halo/Halo.entitlements` (release only — confirmed missing; without it
>    a security-scoped bookmark can't be resolved after the app relaunches,
>    which breaks the entire "ask once per drive" promise). Not needed in
>    `Halo-Debug.entitlements` (sandbox is off there).
> 7. Register all new app-target files via
>    `scripts/add_source_files.rb <repo-relative paths...>` (Sources phase
>    only, idempotent). Build (signing disabled per `CLAUDE.md`) and fix
>    errors until it compiles clean.
> Update `F-051-roadmap.md` Phase 0 checkboxes and Progress Log when done.

**Result:** Done 2026-08-21. `DriveVolume` moved to `Models.swift` (+`volumeUUID`,
`driveKey`); `IndexedFileEntry`/`KnownDrive`/`DriveIndexingState`/
`IndexedFileCategory`/`CrossDriveDuplicateGroup`/`Item` added.
`DriveMonitor.swift` and `DriveIndexStore.swift` created — the store ended up
with working `applyDiff`/`search`/duplicate-candidate queries rather than
stubs, since the schema and the diff logic were cheap to write together.
`libsqlite3.tbd` linked via new `scripts/add_system_library.rb`.
`bookmarks.app-scope` entitlement added. `xcodebuild -target Halo build`
succeeds clean. (Used `-target Halo`, not `-scheme Halo` — this checkout has
no committed shared scheme for the app target; pre-existing environment
quirk, not caused by this work.)

---

## Phase 1 — Access & first-index flow

**Prompt:**
> Implement Phase 1 of F-051. 1) `DriveAccessManager` actor: persist a
> security-scoped bookmark (`Data`) per `volumeUUID` as JSON under
> `~/Library/Application Support/Halo/drive-bookmarks.json`; methods to
> save/resolve/forget a bookmark, and start/stop
> `accessingSecurityScopedResource()` around any access. 2) An ask-first
> banner (reuse the app's existing alert-banner idiom if one exists, else a
> lightweight SwiftUI overlay) shown when `DriveMonitor` reports a mount with
> no `KnownDrive` row yet; on accept, present `NSOpenPanel` pre-targeted at
> the volume's root URL and directoryURL, explain in the message that this
> grants Halo access to index the drive; on the user's selection, create +
> persist the bookmark via `DriveAccessManager`, call
> `AlertLog.shared.append(...)` recording the event, and kick off Phase 1.5.
> On decline, write a `KnownDrive` row with `indexingState = .declined` and
> do not prompt again for that UUID. 3) `DriveIndexCoordinator` actor: given
> a granted volume, walk it (adapt `FileSystemScanner`'s bounded-concurrency
> `FileManager.enumerator` pattern — collect path/size/dates/kind/inode,
> skip nothing hidden-vs-visible-wise differently than `FileSystemScanner`
> already does) and batch-insert rows into `DriveIndexStore`. Wire
> `DriveMonitor` mount events → check `KnownDrive` → ask-first or resolve
> bookmark silently → coordinator walk, end to end.
> Update roadmap + log.

**Result:** Done 2026-08-21. `DriveAccessManager` actor persists security-
scoped bookmarks as JSON in Application Support, self-heals stale bookmarks,
exposes start/stop-accessing. `DriveIndexCoordinator` ended up as a
`@MainActor final class: ObservableObject`, not an actor — it has to drive
`NSOpenPanel` and publish `@Published` state SwiftUI reads directly, which
actor isolation doesn't fit. It wires mount events end to end: unknown drive
→ `pendingAskDrive` → accept → grant panel → save bookmark → walk (own
bounded `FileManager.enumerator`, not literally reusing
`FileSystemScanner`, which has no inode/category collection) →
`DriveIndexStore.applyDiff`. Known+approved drives resolve their bookmark
and walk silently on every later mount. `AlertLog` entries fire on decline
and on indexing start.

---

## Phase 2 — Search & Drives UI

**Prompt:**
> Implement Phase 2 of F-051. **Correction from research: `AppModule` lives
> in `Halo/App/AppState.swift`, not `Models.swift`.** 1) Add `case
> driveIndex` to the `AppModule` enum there, with `title`/`icon`
> (`externaldrive.badge.checkmark`)/`gradientColors` switch arms matching
> the existing per-case pattern exactly; add `.driveIndex` to `static var
> reorderable` (no persistence-migration code needed — `moduleOrder`'s
> load-time diff already auto-appends any reorderable case missing from the
> saved array). 2) Add `case .driveIndex: DriveIndexView()` to
> `ContentView.DetailView`'s exhaustive switch (the compiler will refuse to
> build without it — that's your correctness check). 3)
> `Halo/Features/DriveIndex/DriveIndexView.swift` — tab bar with
> `DriveIndexTab: String, CaseIterable { case drives = "Drives", search =
> "Search", duplicates = "Duplicates", settings = "Settings" }`, mirroring
> `FilesView`'s `FilesTab` structure exactly. 4) Drives tab: list of
> `KnownDrive`, connected state (cross-reference live `DriveMonitor`/
> `availableVolumes()` against stored `volumeUUID`s), reusing
> `DriveSpeedView`'s row visual pattern (icon, name, badge, capacity), with
> Index Now / Re-index / Forget buttons per state. 5) Search tab: a search
> field bound to a debounced query into `DriveIndexStore`, result rows
> showing drive name + connected badge + path + size + last-seen date, with
> Reveal-in-Finder / Open buttons enabled only when the owning drive is
> currently mounted (else disabled with a tooltip naming the drive to
> reconnect). 6) Wire accessibility identifiers per
> `HaloUITests/README.md`'s `<module>.<element>.<role>` convention:
> `driveIndex.tab.<TabTitle>`, `driveIndex.drives.row`,
> `driveIndex.search.field`, `driveIndex.search.row`,
> `driveIndex.search.reveal.button`, `driveIndex.search.open.button`. 7)
> Quick Search picker: `DriveSearchQuickPickerView` + a
> `DriveSearchQuickPickerController` (`NSPanel`), copying the exact
> structure of `QuickActionPickerController`/`ClipboardQuickPickerView`,
> registered on **⌘⇧F** in `HotkeyManager.start()` alongside the existing
> ⌘⇧A/⌘⇧V pickers, second-press-dismisses.
> Build, fix errors, update roadmap + log.

**Result:** Done 2026-08-21, all 7 items including the Quick Search picker.
`AppModule.driveIndex` added exactly as corrected above. `DriveIndexView`
tab shell + Drives/Search/Settings tabs are real; Duplicates tab is a
working UI shell awaiting Phase 4's data. All listed accessibility
identifiers wired, plus `driveIndex.ask.accept/decline.button` and
`driveIndex.settings.*` for the settings controls that landed early.
`DriveSearchQuickPickerView` + `DriveSearchQuickPickerController` copy
`QuickActionPickerController`'s exact `NSPanel` pattern (non-activating
panel, floating level, escape/resign-key dismiss, ↑/↓ selection, Enter
opens). `HotkeyManager` gained a 4th shortcut slot (`driveSearchKeyCode` =
3/"F", same local+global monitor pattern as the other three); `AppState
.setupHotkeys()` wires ⌘⇧F to show/hide it. Reuses
`DriveIndexCoordinator.search`/`openFile` — same data source and
connected-state gating as the in-module Search tab. Builds clean.

---

## Phase 3 — Incremental re-index & rename/move handling

**Prompt:**
> Implement Phase 3 of F-051. In `DriveIndexCoordinator`, replace the
> Phase-1 "always insert" walk with a real diff against existing
> `DriveIndexStore` rows for that `volumeUUID`, keyed by inode: unseen inode
> → insert; known inode with a different stored path → update path only
> (do not touch `fullHash`/`partialHash` — a move/rename must not invalidate
> a previously computed hash); known inode+path with changed size or
> modified-date → update metadata and null out both hash columns (lazy
> re-hash later, not eager); any stored row for that volume not present in
> this walk's inode set → delete. Batch all writes for one volume's re-index
> into a single SQLite transaction. Add throttling: before/during a walk,
> check `SystemMonitor`'s CPU/battery signal (or `ProcessInfo
> .processInfo.thermalState` / `.isLowPowerModeEnabled` if `SystemMonitor`
> doesn't already expose what's needed) and pause between batches if the
> system is under load. Make the walk resilient to the volume disappearing
> mid-scan (catch the resulting file errors, stop cleanly, leave whatever
> was already committed in prior batches intact — don't roll back
> successfully-committed batches just because a later batch failed).
> Update roadmap + log.

**Result:** _pending_

---

## Phase 4 — Cross-Drive Duplicates

**Prompt:**
> Implement Phase 4 of F-051. 1) A query against `DriveIndexStore` that
> groups indexed files by exact `size` across ALL volumes where `size >=`
> the configured threshold (default 100 MB, read from
> `UserDefaults["driveIndexSizeThresholdBytes"]`), producing duplicate
> candidates. 2) For candidate groups where every member's owning volume is
> currently mounted, resolve each member's URL through its volume's
> security-scoped bookmark and feed the URLs to the existing
> `DuplicateDetector.detect(in:onProgress:)` actor exactly as-is (it's
> already volume-agnostic) to get confirmed SHA-256 matches. Where a
> candidate group has a member whose volume is NOT currently mounted, surface
> it separately as "awaiting reconnect" (same size, can't hash-confirm yet).
> 3) Duplicates tab UI: threshold picker at top (persist to the same
> UserDefaults key), two sections (Confirmed / Awaiting reconnect), each
> using a card visually consistent with `DuplicateGroupCard` but showing each
> copy's owning drive name + connected badge. 4) Deleting a confirmed extra
> copy must go through a confirmation sheet before `trashItem` — mirror
> the exact TC-SAFE-02 pattern used by the existing Duplicates/Downloads/
> Large-Files flows (confirm review sheet, cancel does nothing, accept
> trashes). 5) Settings tab: size-threshold control, per-drive "Forget This
> Drive" (deletes its `DriveIndexStore` rows + bookmark, does NOT touch
> files on the actual drive), a global pause-indexing toggle that
> `DriveMonitor`'s mount handler checks before kicking off any walk, a
> file-type category filter (new lightweight enum — Documents/Images/Video/
> Audio/Archives/Code/Other, distinct from `FileSystemScanner.FileKind`
> which serves cleanup classification; default all-on; a file in a disabled
> category is skipped during the walk entirely) and an editable exclude-
> folders-by-name list (DiskCatalogMaker-inspired; seed with `.git`,
> `node_modules`, `.Trashes`).
> Update roadmap + log.

**Result:** _pending_

---

## Phase 5 — Mobile governance, docs & hardening

**Prompt:**
> Implement Phase 5 of F-051. 1) Read `docs/HALO_MOBILE_ROADMAP.md` §0 and
> §6 (feasibility study template); write a real feasibility study for F-051
> using that template (iOS mechanism/verdict, Android mechanism/verdict, OS
> blockers, permissions + cost, store-policy risk, mobile scope, effort,
> overall verdict + priority, recommendation) informed by the preliminary
> read already in `F-051-external-drive-index.md` §12, and add the
> corresponding row to the §3 master portability table plus a §8 change-log
> entry. 2) Handle multiple approved drives mounted simultaneously (e.g. via
> a hub): make `DriveIndexCoordinator` process mounts through a queue
> (one-at-a-time or a small bounded concurrency, not unbounded parallel
> full-drive walks). 3) Add a shipped-feature entry for F-051 to
> `docs/ROADMAP.md` (matching the style of the F-019/F-043 entries) and to
> `docs/FEATURE_ROADMAP.md`. 4) Do a real pass through
> `F-051-manual-test-plan.md` (plug in an actual external drive if
> available) and record Pass/Fail per case. Update roadmap + log; mark
> F-051 done only once the mobile roadmap row exists (CLAUDE.md's mandatory
> mobile-parity rule).

**Result:** _pending_

---

## Automation / E2E prompt

**Prompt:**
> First add a case to `HaloUITests/HaloSidebar.swift`'s `HaloModule` enum
> for the new module (rawValue = its visible tab title) and, if the case
> name doesn't already match the `AppModule` rawValue verbatim, an explicit
> `appModuleRawValue` override arm — this is required for
> `HaloSidebar.navigate(to:)` to find the new sidebar row at all. Then add
> `HaloUITests/DriveIndexUITests.swift` following the exact conventions
> in `HaloUITests/README.md` and `HaloUITestCase.swift`/`HaloSidebar.swift`/
> `HaloTestFixtures.swift`/`HaloUITestCase+Confirmation.swift`. Note
> `HaloTestFixtures` only creates files on the boot volume and has no
> mechanism to simulate a real mounted external volume — real mount/unmount
> coverage would need `hdiutil attach`/`detach` of a throwaway disk image,
> which is a stretch goal (`F-051-roadmap.md` A.9), not required for v1.
> Since CI cannot plug in a real USB drive, cover what's deterministically
> testable without one:
> (a) sidebar navigation to the new "Drive Index" module and tab switching
> across Drives/Search/Duplicates/Settings; (b) under a
> `-uiTestingSeedDriveIndex` launch argument, have the app seed a handful of
> fake `KnownDrive`/`IndexedFileEntry` rows (one connected, one
> disconnected, two same-size files across different volumes for the
> duplicates path) so tests don't depend on real hardware — mirror how the
> Duplicates tab already runs against "sample data" per the existing
> `FilesUITests` comments; (c) search field returns seeded rows and the
> Reveal/Open buttons are enabled only for the seeded connected drive's rows
> and disabled for the disconnected one; (d) settings threshold control
> changes persist; (e) the cross-drive duplicate delete flow follows
> `HaloTestFixtures`'s capture-baseline → drive to confirmation → cancel →
> assert-trash-unchanged pattern (TC-SAFE-02), never actually deleting
> anything. The file just needs to exist at the top level of `HaloUITests/`
> — re-run `ruby scripts/add_uitest_target.rb` (no args; it fully
> regenerates the `HaloUITests` target by globbing every top-level `.swift`
> file in that directory) to register it, then
> `xcodebuild build-for-testing -scheme HaloUITests` to confirm it compiles. Also add `HaloTests` unit tests for the pure-logic
> pieces that don't need real disk I/O: inode-based diff classification
> (new/moved/modified/removed) and size-threshold candidate gating. Update
> roadmap + log.

**Result:** _pending_
