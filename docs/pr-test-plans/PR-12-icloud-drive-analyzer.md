# Manual Test Plan — PR #12: F-030 iCloud Drive Analyzer (scoped down from Storage Analyser)

> **Branch:** `feat/f030-icloud-drive-analyzer` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/12
> **Diff size:** 12 files changed, +926/-14
> **Master regression doc:** this PR's test cases also appear at [`§7.8`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Files**.

## How to test this PR

```bash
git fetch origin feat/f030-icloud-drive-analyzer
git checkout feat/f030-icloud-drive-analyzer
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/ICloudDriveScanner.swift`
- `Halo/Features/Files/FilesView.swift`
- `Halo/Features/Files/ICloudDriveView.swift`

## Detailed test cases

**Files:** `ICloudDriveScanner.swift`, `ICloudDriveView.swift`

> **Scope note:** this is a LOCAL analyzer of `~/Library/Mobile Documents/` (the
> on-disk sync mirror), not a full-account iCloud storage report — there is no
> public API for a third-party app's iCloud quota or a Drive/Photos/Backups/Mail
> category breakdown. See `docs/FEATURE_ROADMAP.md` F-030 "As actually built."

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-FILE-50 | P0 | Container enumeration | iCloud Drive set up | Open Files → iCloud Drive | `com~apple~CloudDocs` shown first as "iCloud Drive"; other ubiquity containers listed with derived names |
| TC-FILE-51 | P1 | iCloud Drive not set up | Fresh Mac / iCloud Drive off | Open tab | Friendly "iCloud Drive isn't set up on this Mac" state, no crash |
| TC-FILE-52 | P0 | Drill into a folder | Select a container with subfolders | Click a folder row | Breadcrumb grows; contents of subfolder shown |
| TC-FILE-53 | P1 | Breadcrumb navigation | Drilled 2+ levels deep | Click an earlier breadcrumb segment | Navigates back; deeper segments truncated |
| TC-FILE-54 | P1 | Real per-item sync status | Mix of local / evicted ("Optimise Mac Storage") files | View rows | Status label/icon matches actual state (On This Mac / iCloud Only / Downloading…/Uploading…) |
| TC-FILE-55 | P2 | Reveal in Finder | Any row | Click Reveal | Finder opens with item selected |
| TC-FILE-56 | P0 | Delete requires confirmation | Any row | Click Trash | Confirmation dialog names the file + size, mentions cross-device removal; Cancel deletes nothing (TC-SAFE-02) |
| TC-FILE-57 | P2 | Refresh | After external change (e.g. via Finder) | Click Refresh | Re-scans current container/folder |
| **Unit** TC-FILE-U8 | P1 | `scanDirectory` sizes + sort | Temp dir: 1 file + 1 subfolder | Real sizes (folder summed), sorted largest-first |
| **Unit** TC-FILE-U9 | P2 | `scanDirectory` empty/missing folder | Empty dir / nonexistent URL | Returns `[]`, no crash |
| **Unit** TC-FILE-U10 | P2 | `ICloudContainer.displayName` | `com~apple~CloudDocs`, `com~apple~Pages`, third-party `com~...` | "iCloud Drive" override; Apple/third-party prefixes stripped correctly |
| **Unit** TC-FILE-U11 | P2 | `ICloudSyncStatus` presentation | Each case | Correct label/icon/color mapping |
| **Unit** TC-FILE-U12 | P2 | `ICloudDriveItem.icon` | Various extensions + directory | Extension-based icon; directories always `folder.fill` |

| Cleanup/Files | Cleanup, SpaceLens, Duplicates, Downloads, Large Files, Disk Health, iCloud Drive Analyzer |

## Regression spot-check

This PR only *adds* a new section to **Files** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Files test cases from [`§7` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
