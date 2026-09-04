# Manual Test Plan — PR #19: F-025 Duplicate Photos Finder (Perceptual Hash)

> **Branch:** `feat/f025-duplicate-photos` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/19
> **Diff size:** 16 files changed, +1528/-46
> **Master regression doc:** this PR's test cases also appear at [`§7.7`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Files**.

## How to test this PR

```bash
git fetch origin feat/f025-duplicate-photos
git checkout feat/f025-duplicate-photos
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/PerceptualDuplicateDetector.swift`
- `Halo/Features/Files/FilesView.swift`
- `Halo/Features/Files/SimilarPhotosView.swift`
- `Halo/Halo-Debug.entitlements`
- `Halo/Halo.entitlements`
- `Halo/Resources/Info.plist`

## Detailed test cases

**Files:** `PerceptualDuplicateDetector.swift`, `SimilarPhotosView.swift`

Unlike Exact Duplicates (bit-exact SHA-256), this tab finds *visually* similar images — the same photo re-saved at a different compression level, cropped, or resized still "looks" the same but hashes completely differently under SHA-256. Algorithm: 64px thumbnail → 32×32 grayscale → 2-D DCT → top-left 8×8 low-frequency block, thresholded against its median → 64-bit fingerprint; near-duplicates are images whose fingerprints differ by ≤ the configured Hamming-distance threshold (default 8 of 64 bits). Loose-file deletion is `trashItem`-only, behind a confirmation dialog. The Photos Library scan path is real PhotoKit code but has **not been runtime-verified** this pass (needs a live permission-grant walkthrough) — treat it as "needs a real permission-grant test pass," not "known broken."

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-60 | P0 | Scan default locations | Open Files → Similar Photos → "Scan Pictures" | Scans `~/Pictures`, `~/Downloads`, `~/Desktop`; progress bar animates; settles into clusters or the empty state |
| TC-FILE-61 | P1 | Choose a specific folder | Click "Choose Folder", pick a folder with known near-duplicates | Scans only that folder; clusters correctly group visually-similar images |
| TC-FILE-62 | P1 | Similarity threshold is adjustable | Change the Stepper (1–20) | Lower = stricter (fewer/tighter matches); higher = looser (catches more, more false-positive risk) |
| TC-FILE-63 | P0 | Recommended keep | View a cluster with mixed resolutions | Highest-resolution item is marked "recommended keep"; others marked for deletion |
| TC-FILE-64 | P0 / TC-SAFE-02 | Delete marked requires confirmation | Click "Delete marked" on a cluster | `.confirmationDialog` ("Move N marked photos to Trash?") appears before anything happens |
| TC-FILE-65 | P0 / TC-SAFE-02 | Cancel deletes nothing | From the dialog in TC-FILE-64, click Cancel | No files trashed; cluster and marks unchanged |
| TC-FILE-66 | P0 | Deletion uses Trash | Confirm "Move to Trash" on a disposable test cluster | Files moved to Trash (recoverable) — never `removeItem` |
| TC-FILE-67 | P2 | Non-image files ignored | Folder contains non-image files (docs, videos) | Only recognized image extensions (jpg/jpeg/png/heic/heif/tiff/tif/bmp/gif/webp) are hashed |
| TC-FILE-68 | P2 | Bounded scan | Folder with >20,000 files | Scan caps at 20,000 files, same policy as Exact Duplicates |
| TC-FILE-69 | P3 | Photos Library scan (experimental, unverified) | Click "Scan Photos Library" | System permission prompt appears; after granting, up to 3,000 most-recent assets are hashed; deleting moves assets to Photos' "Recently Deleted" |
| **Unit** TC-FILE-U8 | P0 | `hammingDistance` counts differing bits exactly | Identical hashes; single-bit diff; all-bits-different | 0; 1; 64 |
| **Unit** TC-FILE-U9 | P0 | `detect(in:)` — empty input, non-image files, single image | `[]`; a `.txt` file; one real image | `[]`, `[]`, `[]` respectively (never a 1-item "group") |
| **Unit** TC-FILE-U10 | P0 | `detect(in:)` — clusters identical copies, excludes a distinct image | Two byte-identical file copies + one visually distinct image | One group containing only the identical pair |
| **Unit** TC-FILE-U11 | P0 | `makeGroup` recommends the highest-resolution item | Two synthetic hash results, different pixel dimensions | Higher-resolution item `isRecommendedKeep`; the other `isMarkedForDeletion` |
| **Unit** TC-FILE-U12 | P1 | `makeGroup` breaks a same-resolution tie by most recent | Two synthetic hash results, equal resolution, different `modifiedDate` | The more recently modified item is recommended to keep |
| **Unit** TC-FILE-U13 | P1 | `PhotoSimilarGroup.wastedBytes` excludes the recommended keep | Group of 3 items, one recommended keep | Sum equals the total of the non-kept items only |

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
