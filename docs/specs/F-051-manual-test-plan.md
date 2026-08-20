# F-051 — Manual Test Plan: External Drive Indexer & Cross-Drive Search

> **Companion to:** [`F-051-external-drive-index.md`](F-051-external-drive-index.md) (requirements), [`F-051-roadmap.md`](F-051-roadmap.md) (execution tracker)
> **Format matches** `docs/MANUAL_TEST_PLAN.md` — stable ID `TC-DRIVE-<NN>`, Priority P0–P3, Pass/Fail/Blocked/N-A per run.
> **Run against:** a real external drive (USB/Thunderbolt), Debug (sandbox OFF) and Release (sandbox ON) builds both, since the sandbox bookmark path only exercises in Release.

## Setup

1. Have at least **two** real external volumes available (a small USB stick + a larger drive), plus the internal disk. One volume should be exFAT or FAT32 (no stable volume UUID) to exercise the fallback-identity path.
2. Clean state: remove `~/Library/Application Support/Halo/drive-bookmarks.json` and clear the app's drive-index SQLite store before the first run of a fresh pass.
3. Keep Activity Monitor open on CPU/Memory tabs throughout — several cases assert on resource behavior, not just correctness.

---

## 1. Ask-first & permission flow

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-01 | P0 | Never-seen drive triggers ask-first prompt | Drive never plugged in with Halo before | Plug in the drive | Prompt appears asking to index it; drive is NOT scanned yet |
| TC-DRIVE-02 | P0 | Accepting opens a scoped grant panel | TC-DRIVE-01 prompt showing | Click "Index this drive" | `NSOpenPanel` opens pre-targeted at the drive's root |
| TC-DRIVE-03 | P0 | Granting starts the initial index | Panel from TC-DRIVE-02 open | Confirm the volume root in the panel | Indexing begins in the background; Drives tab shows progress for that drive |
| TC-DRIVE-04 | P1 | Declining leaves drive un-indexed, no nag | TC-DRIVE-01 prompt showing | Click "Not now" / dismiss | Drive appears in Drives tab as "Not indexed"; unplug and replug the same drive | No prompt reappears |
| TC-DRIVE-05 | P1 | Manual index after decline | State from TC-DRIVE-04 | Open Drives tab, click "Index Now" on the declined drive | Grant panel opens same as TC-DRIVE-02; proceeds normally on confirm |
| TC-DRIVE-06 | P0 | Second mount of approved drive is silent | Drive already approved (TC-DRIVE-03 done) | Unplug, replug the same drive | No prompt; re-index starts automatically in the background |
| TC-DRIVE-07 | P2 | Bookmark survives app relaunch | Drive approved; app fully quit and relaunched | Plug in the approved drive | No re-prompt; re-index proceeds — confirms `com.apple.security.files.bookmarks.app-scope` is correctly persisting/resolving (Release build only) |
| TC-DRIVE-08 | P2 | exFAT/FAT32 drive (no stable UUID) | Non-UUID-bearing volume | Plug in, accept, unplug, replug | Falls back to name+capacity identity; still recognized as approved (unless reformatted) |

## 2. Search — connected & disconnected

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-10 | P0 | Search finds a file on a connected drive | Drive indexed, file known to exist on it | Search tab → type filename | Result row appears with drive name, "Connected" badge, path, size |
| TC-DRIVE-11 | P0 | Reveal in Finder works when connected | Result from TC-DRIVE-10 | Click "Reveal in Finder" | Finder opens with the file selected |
| TC-DRIVE-12 | P0 | Open works when connected | Result from TC-DRIVE-10 | Click "Open" | File opens in its default app |
| TC-DRIVE-13 | P0 | Search finds a file with drive disconnected | Drive indexed, then unplugged | Search tab → type filename | Result row appears, "Disconnected" badge, last-indexed date shown |
| TC-DRIVE-14 | P0 | Reveal/Open disabled when disconnected | Result from TC-DRIVE-13 | Inspect Reveal/Open buttons | Both disabled; tooltip names the drive to reconnect |
| TC-DRIVE-15 | P1 | Reconnecting re-enables actions | State from TC-DRIVE-13 | Plug the drive back in, re-run search | Badge flips to "Connected"; Reveal/Open re-enabled |
| TC-DRIVE-16 | P1 | Search spans multiple drives at once | Two+ drives indexed | Search a term matching files on both | Results list shows rows from both drives, correctly labeled |
| TC-DRIVE-17 | P2 | Empty/no-match search state | Any state | Search a nonsense string | Clear "no results" state, no crash/spinner-hang |

## 3. Quick Search picker (⌘⇧F)

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-20 | P0 | Hotkey opens the picker from any app | Halo running in background, another app frontmost | Press ⌘⇧F | Floating panel appears over the frontmost app |
| TC-DRIVE-21 | P0 | Picker search mirrors Search tab behavior | Picker open | Type a known filename | Same connected/disconnected-aware results as TC-DRIVE-10/13 |
| TC-DRIVE-22 | P1 | Second press dismisses | Picker open | Press ⌘⇧F again | Panel closes |
| TC-DRIVE-23 | P2 | Reveal/Open from the picker | Result showing in picker | Click Reveal or Open | Same behavior as TC-DRIVE-11/12; picker closes after action |
| TC-DRIVE-24 | P2 | No conflict with existing pickers | Halo running | Press ⌘⇧A, then ⌘⇧V, then ⌘⇧F in sequence | Each opens its own picker independently, no cross-triggering |

## 4. Rename, move, delete on the external drive (reindex correctness)

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-30 | P0 | Renamed file updates in place | Drive indexed, note a file's path | Unplug, rename the file on another Mac or via Finder, replug | Reindex updates the row's path; search finds it at the NEW path only; no duplicate/orphan row |
| TC-DRIVE-31 | P0 | Moved file (same volume) updates in place | Drive indexed | Move a file to a different folder on the same drive, replug | Path updates; previously computed hash (if any) is preserved, not recomputed (verify via timing/log if instrumented) |
| TC-DRIVE-32 | P0 | Deleted file is removed from index | Drive indexed | Delete a file from the drive externally, replug | Reindex removes its row; search no longer finds it |
| TC-DRIVE-33 | P1 | Modified file gets metadata updated | Drive indexed | Edit/append to a file (changes size/mtime), replug | Row's size/dates update; any cached hash is invalidated (re-hashed lazily next time it's a dup candidate, not immediately) |
| TC-DRIVE-34 | P2 | Large-scale reorganization | Drive indexed with many files | Rename/move/delete a large batch of files, replug | All changes reconciled correctly with no leftover stale rows or duplicate rows |
| TC-DRIVE-35 | P1 | Disconnected drive shows stale-but-honest state | Drive indexed, then unplugged (no changes made) | Search for content on it | Shows last-known state with last-indexed date — does NOT claim current knowledge it doesn't have |

## 5. Cross-Drive Duplicates

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-40 | P0 | Identical large file on two drives is flagged | Same file (≥ threshold) copied to two indexed, connected drives | Open Duplicates tab | Group shown under "Confirmed," listing both copies with their drive names |
| TC-DRIVE-41 | P0 | Below-threshold identical files are NOT flagged | Same small file (< threshold) on two drives | Open Duplicates tab | Not listed (threshold correctly excludes it) |
| TC-DRIVE-42 | P1 | One copy's drive disconnected → "awaiting reconnect" | Duplicate pair from TC-DRIVE-40, one drive unplugged | Open Duplicates tab | Pair moves to "Awaiting reconnect" section, not silently dropped or falsely "confirmed" |
| TC-DRIVE-43 | P0 | Delete extra copy requires confirmation | Confirmed duplicate group | Click delete on one copy | Confirmation sheet appears (TC-SAFE-02); Cancel leaves file untouched |
| TC-DRIVE-44 | P0 | Confirmed delete trashes, not permanently deletes | Confirmation sheet from TC-DRIVE-43 | Confirm | File moves to Trash (`trashItem`), recoverable; not `removeItem`-deleted |
| TC-DRIVE-45 | P1 | Changing the threshold live-updates results | Duplicates tab open with existing results | Change size threshold in Settings | Duplicates list re-filters to the new threshold without requiring a full re-index |

## 6. Settings — thresholds, file types, exclusions

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-50 | P1 | Size threshold persists across relaunch | Settings tab | Change threshold, quit & relaunch Halo | Value persisted and shown correctly |
| TC-DRIVE-51 | P1 | Disabling a file-type category excludes it from indexing | A drive with files of a given category (e.g. Video) not yet indexed | Disable "Video" in Settings, then index/re-index the drive | Video files do not appear in search results at all (not just hidden — genuinely not indexed) |
| TC-DRIVE-52 | P1 | Re-enabling a category picks files up on next reindex | State from TC-DRIVE-51 | Re-enable "Video," re-index | Video files now appear in search |
| TC-DRIVE-53 | P1 | Exclude-folders-by-name list is honored | Drive with a `node_modules` (or similar) folder, not yet indexed | Confirm `node_modules` is in the exclude list (default seed), index the drive | Files inside that folder do not appear in search |
| TC-DRIVE-54 | P2 | Adding a custom excluded folder name | Settings tab | Add a custom folder name to the exclude list, re-index a drive containing that folder | Its contents disappear from search after reindex |
| TC-DRIVE-55 | P1 | Pause-indexing toggle halts background work | Any state, an approved drive available | Enable "Pause indexing," plug/replug the drive | No walk starts; Drives tab shows it as pending, not indexed |
| TC-DRIVE-56 | P2 | Forget This Drive removes index but not files | Indexed drive | Settings/Drives tab → Forget This Drive | Drive's rows/bookmark removed from Halo; actual files on the physical drive are untouched; drive would need re-approval to be indexed again |

## 7. Resource behavior & resilience

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|----------------|-------|----------|
| TC-DRIVE-60 | P0 | Large drive indexing doesn't block the UI | Drive with 100k+ files | Plug in, immediately interact with other Halo modules | UI remains responsive throughout the walk |
| TC-DRIVE-61 | P1 | CPU/RAM stay bounded during a large index | Drive with 100k+ files, Activity Monitor open | Watch during full walk | No runaway CPU pegging or continuously climbing memory (batch inserts, bounded concurrency) |
| TC-DRIVE-62 | P1 | Indexing defers under Low Power Mode | Mac on Low Power Mode, new drive plugged in and approved | Observe | Indexing visibly pauses/slows vs. normal-mode baseline |
| TC-DRIVE-63 | P0 | Unplugging mid-index leaves store consistent | Large drive indexing in progress | Yank the drive mid-walk | App doesn't crash; no corrupted rows; replugging resumes/completes cleanly |
| TC-DRIVE-64 | P1 | Multiple approved drives plugged in simultaneously (hub) | 2+ approved drives, both unplugged | Plug both in at once (or via a hub) | Both eventually index; no I/O contention crash; a queue/bounded-concurrency approach is evident (not two unbounded full-speed walks fighting each other) |
| TC-DRIVE-65 | P2 | Quit during active index | Drive indexing in progress | Quit Halo | Clean shutdown; no zombie process; next launch's index resumes sanely (not corrupted, not restarted from zero unnecessarily beyond the last committed batch) |

## 8. Regression — existing features unaffected

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-DRIVE-70 | P0 | Existing Files → Duplicates tab unaffected | Run the existing single-root Duplicates flow | Behaves exactly as before F-051 (separate feature, per D3) |
| TC-DRIVE-71 | P0 | Existing Files → Drive Speed tab unaffected | Run a Drive Speed benchmark | Unchanged behavior; confirms `DriveVolume`'s promotion to `Models.swift` didn't break the existing caller |
| TC-DRIVE-72 | P0 | Sidebar reorder still works with the new module | Enter sidebar edit mode | New "Drive Index" module can be reordered like the other 6; Dashboard still pinned/hidden correctly in edit mode |
| TC-DRIVE-73 | P1 | Existing hotkeys (⌘⇧A, ⌘⇧V) unaffected by the new ⌘⇧F | Trigger each | All three independent, no interference |
