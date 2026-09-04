# Manual Test Plan — PR #15: F-024 Browser Cleaner

> **Branch:** `feat/f024-browser-cleaner` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/15
> **Diff size:** 13 files changed, +1407/-34
> **Master regression doc:** this PR's test cases also appear at [`§3.1`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Cleanup**.

## How to test this PR

```bash
git fetch origin feat/f024-browser-cleaner
git checkout feat/f024-browser-cleaner
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/BrowserCleanerScanner.swift`
- `Halo/Features/Cleanup/BrowserCleanerView.swift`
- `Halo/Features/Cleanup/CleanupView.swift`

## Detailed test cases

**Files:** `BrowserCleanerScanner.swift`, `BrowserCleanerView.swift`

Per-category breakdown (HTTP cache, GPU shader cache, history, cookies, sessions, crash reports, site data, download history) for Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi, and Firefox — a more granular sibling to Protection's whole-browser Privacy Cleaner card. All clearing is `trashItem`-only, gated behind the review sheet.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLEAN-10 | P0 | Browsers tab detects installed browsers | Open Cleanup → Browsers | Only browsers actually present under `/Applications` are listed; "No supported browsers detected" if none |
| TC-CLEAN-11 | P0 | Per-category sizes measured | Browser detected | Each category (Cache, History, Cookies, …) shows a real on-disk size, not zero/guessed |
| TC-CLEAN-12 | P1 | Pre-selection matches data presence | Open review sheet | Only categories with `hasData == true` are pre-selected |
| TC-CLEAN-13 | P0 | Review & Clear confirms before deleting | Click "Review & Clear" on one browser, or "Clean All Browsers" | Review sheet lists in-scope browser(s) + categories; nothing is cleared until "Clear Selected" is clicked |
| TC-CLEAN-14 | P0 / TC-SAFE-02 | Cancel deletes nothing | From the review sheet, click Cancel | Sheet dismisses; no files trashed; sizes unchanged on next re-scan |
| TC-CLEAN-15 | P1 | Per-category toggle | In the review sheet, untoggle one category | That category excluded from "Clear Selected ($SIZE)"; total updates live |
| TC-CLEAN-16 | P0 | Clearing uses Trash, never permanent delete | Confirm "Clear Selected" on a real, disposable category (e.g. HTTP cache) | Files moved to Trash (recoverable) — never `removeItem` |
| TC-CLEAN-17 | P1 | Freed-space banner | After a successful clear | Green "Freed X" banner shows the real freed byte count |
| TC-CLEAN-18 | P1 | Error banner on partial failure | Force a clear error (e.g. permission-denied path) | Amber error banner shows the first error message; doesn't block other categories from clearing |
| TC-CLEAN-19 | P2 | Chromium multi-profile detection | A Chromium browser with 2+ real profiles (Default, Profile 1, …) | All profiles' data included in the category totals, not just Default |
| TC-CLEAN-20 | P2 | Celebration on large recovery | Clear > 1 GB total | `CelebrationManager` triggers `.spaceRecovered` |
| **Unit** TC-CLEAN-U3 | P0 | `candidates(home:)` lists all 8 browsers | — | Exactly 8 entries with correct `/Applications/<Name>.app` paths |
| **Unit** TC-CLEAN-U4 | P0 | `detectBrowsers()` only returns installed browsers | Run on real machine | Every returned profile's `appPath` actually exists |
| **Unit** TC-CLEAN-U5 | P0 | `chromiumProfileDirs` — discovery + fallback | Real profiles present; root unreadable; root readable but no matches | Correct filtered set; `["Default"]` fallback in both failure cases |
| **Unit** TC-CLEAN-U6 | P1 | `firefoxProfileDirs` — discovery + dotfile filtering | Profiles dir with real + dotfile entries | Only non-dotfile profile folders returned; `[]` when the dir doesn't exist |
| **Unit** TC-CLEAN-U7 | P0 | `size(ofPaths:)` — file, directory, multi-path, missing | Single file; nested directory; multiple paths; nonexistent path | Exact byte counts; recursive directory sum; missing paths contribute 0 |
| **Unit** TC-CLEAN-U8 | P0 | `measure(_:)` fills in real sizes | Synthetic profile with a temp-file-backed category | Category `.size` matches the real file size on disk |
| **Unit** TC-CLEAN-U9 | P0 | `clear(_:categories:)` — selective, trashItem-only | Two categories, only one selected | Only the selected category's paths are trashed; the other is untouched; `cleared`/`freed` counts match |

## Regression spot-check

This PR only *adds* a new section to **Cleanup** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Cleanup test cases from [`§3` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
