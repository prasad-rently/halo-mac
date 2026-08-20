# F-051 — External Drive Indexer & Cross-Drive Search

> **Status:** 📝 Drafting — under review with user before implementation
> **Platform:** Desktop only in v1 (mobile feasibility study required before "done" — see §12)
> **Depends on:** none. Reuses patterns from F-043 (`DriveSpeedTester` volume enumeration) and the existing `FileSystemScanner` / `DuplicateDetector` actors.
> **New sidebar module.** Not merged into the existing Files → Duplicates tab (per decision D3).

---

## 1. Summary

Whenever an external drive connects, Halo should build (and keep fresh) a
searchable index of every file path on it — name, size, dates, and which
volume it lives on. The index persists after the drive is unplugged, so the
user can search for a file and find out *which drive it's on* even with that
drive sitting in a drawer, and Halo can flag duplicate/oversized files that
exist across multiple drives (not just within one folder, which is all the
existing Duplicates tab does today).

This is a **new top-level sidebar module** ("Drive Index"), not a tab inside
the existing Files module, and its duplicate detection is a **separate
"Cross-Drive Duplicates" view** — independent from the existing single-root
Duplicates tab in Files.

## 2. Goals / Non-Goals

**Goals**
- Detect drive connect/disconnect events automatically.
- On a *new* (never-seen) drive, ask the user before indexing it.
- On a previously-approved drive, silently re-index on every future mount — cheaply, incrementally.
- Persist the index so search works with the drive **disconnected**.
- Search by filename/path across all known drives, connected or not; show where a match lives and its last-known state.
- When the owning drive is connected: reveal in Finder / open the file directly from a search result.
- Find duplicate and configurably-large files **across drives**, not just within one scan root.
- Keep CPU/memory overhead low — this runs unattended in the background of a utility app, not a foreground task.

**Non-Goals (v1)**
- Live file-content search (grep inside files) — path/name/metadata index only.
- Automatically deleting/moving files to resolve cross-drive duplicates without the existing confirm-before-trash flow.
- Network volumes / iCloud Drive (already covered by the separate F-030 idea) — local + external physical/removable volumes only.
- Continuous filesystem watching (FSEvents) for instant change detection — re-index happens on mount, not on every write.
- Indexing *inside* archive files (`.zip`/`.rar`/etc.) — index the archive as one file, not its contents (see prior art note in §3, D13).

## 2a. Prior Art

[**DiskCatalogMaker**](https://diskcatalogmaker.com) is the closest existing
shipped analogue to this feature's core promise: it builds a searchable
catalog of every disk/drive/CD you own so you can find a file **without the
volume mounted**, and its Scan preferences expose an "exclude folders by
name" list. Two takeaways adopted below: (1) its Settings pattern of a
dedicated "Scan" preferences surface with folder/name exclusions (D14), and
(2) explicitly scoping out its archive-content cataloging (`.zip`/`.rar`/
`.7z` contents indexed as if they were folders) as a deliberate non-goal for
v1 — real value, but meaningfully more scope (decompression, nested paths,
version-specific extractors) than this feature needs to deliver its core
promise.

## 3. Decisions & Assumptions

| # | Decision | Note |
|---|----------|------|
| D1 | **Ask-first indexing, then silent re-index** | First time a drive (by volume UUID) is seen: show a prompt. Accept → one-time `NSOpenPanel` grant (see D5) + index. Every later mount of that same drive: auto re-index, no prompt. Decline → remembered, drive appears in the Drives list as "Not indexed" with a manual "Index Now" button. |
| D2 | **New top-level sidebar module**, not a Files tab | User confirmed. Own entry in `AppModule` / reorderable sidebar, icon `externaldrive.badge.checkmark`. |
| D3 | **Cross-Drive Duplicates is a separate view**, not merged into Files → Duplicates | User confirmed. Existing `DuplicateDetector` actor is reused as the hashing engine (it's already volume-agnostic — see §7), but the UI, entry point, and scan scope (all indexed drives vs. one chosen folder) are distinct. |
| D4 | **Persistent store: SQLite**, not JSON-in-UserDefaults | Resolves the open question from brainstorming. Rationale: the explicit requirement is "search works with the drive disconnected" + "don't consume more memory" — that means the full path list for every indexed drive must live outside process memory and be queried via indexed lookups, not deserialized wholesale on every search keystroke. SQLite is built into macOS (`libsqlite3`, linked via `import SQLite3` — **no new SPM dependency**), matching the project's minimal-dependency stance (today only Sentry is a real external package). Wrapped in a new `actor DriveIndexStore`, consistent with the existing actor-for-concurrent-work pattern. |
| D5 | **Sandbox access via per-drive security-scoped bookmark, not a blanket entitlement** | Research confirmed neither `Halo.entitlements` nor `Halo-Debug.entitlements` grants `com.apple.security.files.removable-volumes.*`. Rather than add that (weakens the sandbox posture the app just invested in via F-019 Security Posture), the ask-first prompt (D1) doubles as the sandbox grant: accepting opens an `NSOpenPanel` pre-targeted at the volume root: the user's click is the exact "user-selected" action the sandbox wants, and Halo persists the resulting security-scoped bookmark keyed by volume UUID so subsequent mounts need no repanel. **Confirmed gap to fix in Phase 0:** `Halo.entitlements` (release/sandboxed) is also missing `com.apple.security.files.bookmarks.app-scope = true` — without it, a security-scoped bookmark cannot be resolved on a fresh app launch (only within the same process that created it). This key must be added for D5 to actually survive relaunches. Not needed in `Halo-Debug.entitlements` (sandbox is off there). |
| D6 | **Volumes identified by `volumeUUIDStringKey`**, not mount path | `DriveVolume.id` in `DriveSpeedTester` is currently the mount path, which is not stable across unplug/replug (drive can remount at a different path, or two drives can share a name). The index needs a durable identity. `DriveVolume` gets a new `volumeUUID: String?` field; add it to `Models.swift` (currently only lives in `DriveSpeedTester.swift`) so both features share one definition. |
| D7 | **Two-tier scan: cheap metadata index for everything, selective hashing only above a threshold** | Per the original ask ("avoid duplicates... especially the high size files... configurable"): every file gets a metadata row (path, size, dates, kind) — no I/O beyond `stat`. SHA-256 hashing (reusing `DuplicateDetector`'s 3-phase approach) only runs on files ≥ a **user-configurable size threshold** (default 100 MB), and only after the free size-grouping phase already narrows candidates. This bounds CPU cost to exactly the class of file the user cares about, and keeps search-by-name unaffected by hashing cost. |
| D8 | **Rename/move detection via inode, not delete+re-add** | External-drive files get renamed/moved/re-organized per the user's own caveat. Tracking each row's inode (`st_ino`, fetched via `URLResourceValues` / raw `stat`) lets a re-index recognize "same file, new path" as an update (cheap) instead of a delete+insert that would also throw away a previously-computed hash. |
| D9 | **Re-index runs at background priority, throttled, and deferred under load** | Bounded concurrency (mirrors `FileSystemScanner.ScanConfig.maxConcurrency`), background QoS, and — new — skip/defer the pass if `SystemMonitor` reports high CPU load or Low Power Mode, consistent with "don't make the utility app itself a resource hog." |
| D10 | **Quick Search picker: a floating panel on a global hotkey**, mirroring the existing Quick Action Picker (⌘⇧A) and Clipboard Quick Picker (⌘⇧V) | Default shortcut **⌘⇧F** (both hotkeys already taken; F for "Find" is free and mnemonic). Same `NSPanel`-overlay pattern, registered in `HotkeyManager.start()` alongside the other two, second-press-dismisses toggle behavior. |
| D11 | **Fixed default hotkey, not user-remappable in v1** | Matches existing precedent — neither ⌘⇧A nor ⌘⇧V is user-customizable today. Documented as a stretch goal, not blocking v1. |
| D12 | **Indexed file-type filter is by category, not by `FileKind`** | `FileSystemScanner.FileKind` (cache/log/temp/download/...) exists to classify files for *cleanup*, a different concern. Drive-index filtering needs a search-relevant taxonomy instead — Documents / Images / Video / Audio / Archives / Code / Other — as a new lightweight enum scoped to this feature, default: all categories on. |
| D13 | **No archive-content indexing** (see §2a) | A `.zip` on an indexed drive is indexed as one opaque file (name/size/dates), not decompressed and walked. |
| D14 | **Exclude-folders-by-name list**, DiskCatalogMaker-inspired | A per-install (not per-drive) list of folder names to always skip during any walk (e.g. `.Trashes`, `node_modules`, `.git`) — reduces noise and indexing cost by default; user-editable in Settings. |

## 4. User Stories

- **US-1** As a user, I plug in an external drive I've never used with Halo before. Halo asks if I want it indexed.
- **US-2** As a user, I accept, and Halo indexes the drive in the background without me noticing any slowdown.
- **US-3** As a user, weeks later with that drive unplugged, I search "invoice_2024" and Halo tells me it's on "Backup SSD" at a given path, last seen on a given date — I don't need the drive plugged in to know it exists somewhere.
- **US-4** As a user, I plug that same drive back in, search again, and now I can click "Reveal in Finder" or "Open" directly.
- **US-5** As a user, I have the same large video file copied on two different external drives (and maybe also my internal disk) — Halo's Cross-Drive Duplicates view shows me all copies, which drive each is on, and lets me review before trashing extras.
- **US-6** As a user, I set the duplicate/large-file threshold to, say, 250 MB, so I'm only bothered about the files that actually matter for space.
- **US-7** As a user, I decline indexing the first time (maybe it's a friend's USB stick), and Halo doesn't nag me every time I plug it back in — but I can still turn it on later from the Drives list.
- **US-8** As a user, I unplug a drive mid-index; Halo doesn't crash or corrupt the index, it just resumes cleanly next time.

## 5. Functional Requirements

- **FR-1** Detect external volume mount/unmount via `NSWorkspace.didMountNotification` / `.didUnmountNotification` (no existing observer in the codebase today — new `DriveMonitor`).
- **FR-2** Resolve a stable identity per volume via `volumeUUIDStringKey`; fall back to name+capacity heuristic only if UUID is unavailable (rare, e.g. some exFAT/FAT32 media).
- **FR-3** On first-ever sight of a volume UUID: surface an ask-first prompt (banner + `AlertLog` entry, mirroring the existing alert pattern). Accept → `NSOpenPanel` scoped to the volume root → persist security-scoped bookmark → run initial index. Decline → mark volume "known, not indexed," no future auto-prompt.
- **FR-4** On every later mount of an already-approved volume: resolve the stored bookmark, `startAccessingSecurityScopedResource()`, and run an incremental re-index automatically, no prompt.
- **FR-5** Walk the volume (reusing the `FileSystemScanner` actor pattern: bounded-concurrency `FileManager.enumerator`) collecting per file: path (relative to volume root), name, size, created/modified dates, kind, inode.
- **FR-6** Diff the walk against the existing index rows for that volume UUID: new inode+path → insert; known inode, changed path → update path (rename/move, no re-hash); known path+inode, changed size/mtime → update + invalidate cached hash; row present in DB but not found in this walk → mark removed.
- **FR-7** Persist all of the above in a `DriveIndexStore` (SQLite, actor-wrapped) surviving app relaunch and drive disconnection.
- **FR-8** Global search: query the store by filename/path substring across all volumes (connected or not); results show file name, path, size, owning drive name + connected/disconnected badge, last-indexed date.
- **FR-9** Result actions: if the owning drive is currently connected → "Reveal in Finder" (`NSWorkspace.selectFile`) and "Open" (`NSWorkspace.open`); if disconnected → actions disabled with a tooltip naming which drive to reconnect.
- **FR-10** Cross-Drive Duplicates view: group indexed files across *all* volumes by exact size (free), then SHA-256 partial+full hash (reusing `DuplicateDetector`'s phases, fed URLs resolved through each volume's active security-scoped bookmark) — restricted to files ≥ the configured size threshold. Only volumes that are **currently connected** can be hashed (can't read bytes off a disconnected disk); the view clearly separates "confirmed duplicates" (both/all copies connected & hashed) from "known-possible duplicates awaiting reconnect" (same size+name, not yet hash-confirmed because one copy's drive is offline).
- **FR-11** Duplicate cleanup reuses the existing mandatory confirm-before-trash pattern (`trashItem`, review sheet) — never silent deletion, never across drives without explicit per-item confirmation.
- **FR-12** Configurable size threshold for "large file" / duplicate-hashing eligibility (default 100 MB), editable in the module's Settings sub-view.
- **FR-13** Drives list view: every known volume (indexed or declined), connected/disconnected state, file count, total indexed bytes, last-indexed date, and manual actions ("Index Now," "Re-index," "Forget This Drive" — which drops its rows and bookmark).
- **FR-14** Indexing pauses/defers automatically when `SystemMonitor` reports high CPU pressure or the Mac is on Low Power Mode; resumes when conditions clear.
- **FR-15** New sidebar module "Drive Index" with sub-tabs: **Drives**, **Search**, **Duplicates**, **Settings** — mirrors the existing `FilesView` tab-bar pattern.
- **FR-16** **Quick Search picker** (D10): global hotkey (**⌘⇧F** default) opens a floating panel over whatever app is frontmost — type a filename, get live results across all indexed drives (connected or not) with the same connected-state-aware Reveal/Open actions as the in-module Search tab. Second press of the hotkey dismisses it, matching the Quick Action/Clipboard pickers.
- **FR-17** **File-type category filter** (D12): Settings lets the user toggle which categories (Documents/Images/Video/Audio/Archives/Code/Other) get indexed at all; a file in a disabled category is skipped entirely during the walk (not stored, not searchable) — default all-on.
- **FR-18** **Exclude-folders-by-name list** (D14): Settings exposes an editable list of folder names (e.g. `node_modules`, `.git`, `.Trashes`) that any walk on any drive skips entirely, with a sensible default seed list.

## 6. Non-Functional Requirements

- **Performance:** metadata walk of a large drive (500k+ files) must not block the UI thread; bounded concurrency; incremental diff avoids re-hashing unchanged large files.
- **Memory:** search queries hit SQLite indexes (indexed on `fileName`, `volumeUUID`), never load the full path list into memory; result sets paginated/limited in the UI layer.
- **Resource courtesy:** background QoS for all indexing work; deferral under system load (D9); no continuous polling — event-driven on mount/unmount only.
- **Safety:** every destructive action (duplicate cleanup) goes through the existing trash-with-confirmation flow; "Forget This Drive" only deletes index rows/bookmarks, never files on the actual drive.
- **Sandbox compliance:** all external-volume file access happens through security-scoped bookmarks obtained via user-initiated `NSOpenPanel` grants — no new broad entitlement requested (D5).
- **Data integrity:** an interrupted index (drive yanked mid-scan) must leave the store in a consistent, resumable state — no partial/corrupt rows.

## 7. Architecture

```
NSWorkspace mount/unmount notifications
        │
        ▼
  DriveMonitor (new, @MainActor observer, mirrors IdleAppMonitor's
                addObserver/token pattern — none exists for volumes today)
        │  resolves volumeUUIDStringKey, isInternal/isRemovable
        │  (DriveVolume model, promoted from DriveSpeedTester.swift → Models.swift,
        │   gains `volumeUUID: String?`)
        ▼
  DriveAccessManager (new actor)                 known? ──no──► ask-first prompt
  - persists security-scoped bookmarks                             │ accept
    keyed by volumeUUID (JSON in Application Support,               ▼
    consistent with existing JSON-persistence patterns)      NSOpenPanel(volume root)
  - resolve() / start/stopAccessingSecurityScopedResource            │
        │                                                            ▼
        ▼                                                    bookmark persisted
  DriveIndexCoordinator (new actor)
  - walks the volume (FileSystemScanner-style bounded enumerator)
  - diffs against DriveIndexStore rows (inode-aware — D8)
  - feeds size-threshold candidates (D7) to DuplicateDetector
    (existing actor — already volume-agnostic, see F-043/F-044 research)
        │
        ▼
  DriveIndexStore (new actor, SQLite via libsqlite3 — D4)
  - tables: volumes(uuid, name, lastIndexed, ...), files(volumeUUID, path,
    name, size, dates, inode, kind, partialHash?, fullHash?, lastSeen)
  - indexed on fileName + volumeUUID for fast search
        │
        ▼
  DriveIndexView (new sidebar module — Drives / Search / Duplicates / Settings)
  - Drives tab reuses DriveSpeedView's volume-row UI pattern
  - Duplicates tab reuses DuplicateFinderView's DuplicateGroupCard pattern
```

## 8. Data Model Changes

- **`Models.swift` additions:**
  - `DriveVolume` promoted here from `DriveSpeedTester.swift` (shared by both F-043 and F-051), + new `volumeUUID: String?`.
  - `IndexedFileEntry`: `id`, `volumeUUID`, `relativePath`, `fileName`, `size`, `createdDate`, `modifiedDate`, `kind: FileKind` (reuse existing enum), `inode: UInt64`, `partialHash: String?`, `fullHash: String?`, `lastSeenDate`.
  - `CrossDriveDuplicateGroup`: derived query result — `fullHash`, `[CrossDriveDuplicateItem]` where each item carries its owning `volumeUUID`/volume name + connected state (extends the existing `DuplicateGroup`/`DuplicateItem` shape but volume-aware; `DuplicateItem.displayPath`'s `~`-substitution assumption doesn't hold for `/Volumes/...` paths — needs a volume-aware display path).
  - `KnownDrive`: `volumeUUID`, `name`, `indexingState: .notIndexed / .indexed / .declined`, `lastIndexedDate`, `fileCount`, `totalBytes`.

## 9. UI

- **Sidebar:** new `AppModule.driveIndex` case, icon `externaldrive.badge.checkmark`, added to the reorderable module list (`AppState.moduleOrder`) alongside the other 6.
- **Drives tab:** list of `KnownDrive`, connected/disconnected badge (`HaloBadge`, reusing `DriveSpeedView`'s row layout), per-row actions matching state (Index Now / Re-index / Forget).
- **Search tab:** search field + live-filtered result list; each row shows drive icon + name + connected badge, file name, path, size, last-seen date; Reveal/Open buttons enabled only when connected.
- **Duplicates tab:** size-threshold picker at top (same discrete-picker feel as `DriveTestSize`), `DuplicateGroupCard`-style groups split into "Confirmed" and "Awaiting reconnect" sections, confirm-before-trash sheet.
- **Settings tab:** size threshold (FR-12), per-drive "Forget," global "pause indexing" toggle.
- **Ask-first prompt:** confirmed there is no existing in-app banner/toast component in Halo (`AlertManager` only fires OS-level `UNNotification`s + an `AlertLog` history list — no custom SwiftUI banner exists anywhere yet). The ask-first prompt is a `.sheet`/`.alert` presented directly (first custom permission-gate UI in the app), with `AlertLog.shared.append(title:body:kindRaw:)` logging the event for history regardless of outcome.
- **Quick Search picker (FR-16):** a floating `NSPanel` overlay opened by **⌘⇧F**, following the exact existing pattern of `QuickActionPickerController`/`ClipboardQuickPickerView` (registered in `HotkeyManager.start()` alongside those two; second press dismisses).
- **Sidebar badge (optional, matches existing precedent):** `ContentView.SidebarView.badgeInfo(for:)` reads feature-owned singletons directly for badge counts (e.g. `LocalShareManager.shared`), bypassing `AppState` — if Drive Index wants an "indexing…" badge, follow that same precedent rather than adding new `@Published` surface to `AppState`.

## 10. Acceptance Criteria

- Plugging in a never-seen external drive triggers an ask-first prompt, not a silent scan.
- Accepting indexes the drive without a second permission prompt on future mounts.
- Search returns results for a disconnected drive's files, correctly labeled as disconnected, with last-seen date.
- Reveal-in-Finder/Open only succeeds (and is only enabled) when the owning drive is mounted.
- Renaming/moving a file on an external drive and re-plugging it updates its index row in place (verified via inode) rather than appearing as a duplicate delete+insert.
- Deleting a file from an external drive and re-plugging it removes it from the index after re-index.
- Cross-Drive Duplicates only flags files ≥ the configured threshold; separates confirmed (both copies connected) from awaiting-reconnect.
- No file is ever deleted without going through the existing trash-confirmation flow.
- Indexing measurably backs off under CPU load / Low Power Mode (spot-checked via Activity Monitor during a large-drive test).
- Unplugging mid-index leaves the store consistent; re-plugging resumes/completes cleanly on next mount.
- Declining the first-time prompt does not repeat the prompt on subsequent mounts of the same drive.

## 11. Open Questions & Risks

- **exFAT/FAT32 volumes without a stable UUID:** need a documented fallback identity (name + total capacity + first-index timestamp) and a UX note that such drives may occasionally be treated as "new" if reformatted.
- **Very large drives (multi-TB, millions of files):** initial index could take a long time even at low priority — needs a visible progress/ETA in the Drives tab, and confirmation that SQLite batch-insert performance holds up (batched transactions, not one INSERT per file).
- **Multiple Halo-known drives plugged in via a hub simultaneously:** need to confirm indexing queues (one at a time, or bounded parallel) rather than competing for I/O and CPU at once.
- **Bookmark staleness:** security-scoped bookmarks can become stale (e.g. drive reformatted, volume renamed at OS level) — needs a "bookmark failed to resolve, re-grant access" recovery path, not a silent failure.
- **Sandbox posture:** confirm in testing that the `NSOpenPanel`-grant approach (D5) actually works for indexing an entire drive tree, not just the single file/folder the panel returns — i.e. that the returned scope is recursive over the volume root, which sandboxed apps generally do get when the user selects a folder/volume itself.

## 12. Mobile Feasibility (CLAUDE.md-mandated, before this feature is "done")

Per `docs/HALO_MOBILE_ROADMAP.md` §0 governance, a feasibility study + row in the
§3 portability table is required before F-051 can be marked done on desktop.
Preliminary read (to be written up formally in that doc as part of execution):

- **iOS:** No public API for background detection of USB/external-drive mount events, and no unattended background filesystem walk of a `UIDocumentPicker`-granted tree without the user re-opening the picker per session in many cases. Likely **❌ Blocked / 🔵 Reimagine-only** (e.g. index only the Files-app-exposed folders the user explicitly picks, no auto-detect-on-connect).
- **Android:** USB-OTG external storage is reachable via Storage Access Framework (SAF) persisted tree URIs; no true "any drive auto-detected" background service without a broadcast receiver for `ACTION_MEDIA_MOUNTED`-equivalent + user-granted SAF permission per device. Likely **🟡 Adapt** with reduced automation (user grants access once per device via SAF, then background indexing is feasible via a foreground/background service).
- Both platforms lose the "ask-first + persisted OS-level grant on remount" ergonomics that make this smooth on macOS — mobile would need its own explicit study before any mobile backlog row moves out of "Unassessed."

## 13. Execution Plan

### Phase 0 — Foundations
- Promote `DriveVolume` into `Models.swift`, add `volumeUUID`.
- `DriveMonitor`: `NSWorkspace` mount/unmount observer (new — no prior art in repo).
- `DriveIndexStore`: SQLite schema + actor wrapper (volumes + files tables, indexes).

### Phase 1 — Access & first-index flow
- `DriveAccessManager`: bookmark persistence, resolve/start/stop scoped access.
- Ask-first prompt UI + `AlertLog` integration; `NSOpenPanel` grant flow.
- `DriveIndexCoordinator`: initial full walk → store, reusing `FileSystemScanner`-style bounded traversal.

### Phase 2 — Search & Drives UI
- New sidebar module scaffold (`AppModule.driveIndex`, `ContentView` routing, `DriveIndexView` tab bar).
- Drives tab (reuse `DriveSpeedView` row pattern) + Search tab.

### Phase 3 — Incremental re-index & rename/move handling
- Diff-on-remount logic (D6/D8): inode-aware update vs. insert vs. remove.
- Load-aware throttling/deferral (D9) via `SystemMonitor`.

### Phase 4 — Cross-Drive Duplicates
- Threshold-gated hashing pipeline feeding the existing `DuplicateDetector`.
- Duplicates tab UI (confirmed vs. awaiting-reconnect sections) + confirm-before-trash flow.
- Settings tab (threshold, forget-drive, pause-indexing).

### Phase 5 — Mobile governance + hardening
- Write the formal feasibility study + `HALO_MOBILE_ROADMAP.md` §3 row (§12 above).
- Interrupted-scan resilience testing (unplug mid-index).
- Multi-drive-simultaneous-mount queuing.
- Update `docs/ROADMAP.md` / `FEATURE_ROADMAP.md` with the shipped entry.

### Test plan
- Unit: inode-based rename/move detection, size-threshold gating, bookmark round-trip (mock), SQLite upsert/diff logic.
- Manual: ask-first prompt on true first mount; silent re-index on second mount; search while disconnected; reveal/open while connected; duplicate detection across two real external drives; decline-then-manually-index-later; unplug mid-scan.
- Load test: large drive (500k+ files) — timing, memory footprint, CPU while running.

### Rough effort
~9–12 days across the 5 phases above (mount detection + bookmarks + SQLite store is the bulk of the new-ground work; the duplicate-hashing and Files-tab-adjacent UI reuse existing actors/components).
