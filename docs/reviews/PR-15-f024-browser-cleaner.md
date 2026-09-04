# Code review — PR #15 · F-024 Browser Cleaner

- **PR:** [prasad-rently/halo-mac#15](https://github.com/prasad-rently/halo-mac/pull/15)
- **Branch:** `feat/f024-browser-cleaner` → `main`
- **Reviewed at:** commit `3f0186fd` · 13 files, +1407 / −34
- **Inline comments:** [review 5113181176](https://github.com/prasad-rently/halo-mac/pull/15#pullrequestreview-5113181176)

## Verdict: **Request changes**

The path-provenance discipline in the file header is genuinely good practice — marking
Brave/Edge/Opera/Vivaldi/Firefox paths as "vendor-documented, unverified live" rather than
implying they were tested, and explicitly *omitting* Safari's GPU-cache and Site-Data categories
because the modern container path could not be verified, is exactly the right instinct. Dynamic
Chromium profile discovery instead of hardcoding `Default` is correct, and the per-category
review sheet before any `trashItem` satisfies the CLAUDE.md confirmation rule.

But this is a destructive feature, and two paths are wrong in ways that destroy data outside the
stated scope. The omitted-Safari-Site-Data reasoning ("guessing it would risk a silently-wrong
path, which is worse than omitting the category") is the correct standard — it just wasn't
applied to the Cookies category, where the same container problem exists.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/BrowserCleanerScanner.swift:181` | Blast radius | `~/Library/Cookies/Cookies.binarycookies` is the **shared, process-wide** `NSHTTPCookieStorage` file used by every non-sandboxed app that uses `NSURLSession`/`WKWebView` outside a container. Modern Safari is sandboxed and keeps cookies at `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/`. So this category does two wrong things at once: it fails to clear Safari's cookies (the stated intent) *and* it clears cookies belonging to other apps, signing the user out of anything sharing that store. Behind a one-click "Clean All Browsers", that is silent collateral damage to state the user never agreed to touch. | Critical | Point at the container path (documenting the FDA requirement), or drop the category — the same conclusion already reached, correctly, for Safari's Site Data. |
| 2 | `BrowserCleanerScanner.swift:220` | Blast radius | `History`, `Cookies` and `Sessions` are open WAL-mode SQLite databases while Chromium is running. `clear()` trashes only the primary file; sibling `-journal` / `-wal` / `-shm` and `Sessions/Session_*` files are left behind. On next launch Chromium finds an orphaned WAL with no matching database — at best it discards and recreates, realistically the user loses their open-tab session and can see profile errors. `Sessions` holds the *current* session, so trashing it mid-run is a direct "lost all my tabs" bug. There is no running-browser check anywhere. The PR's own test plan flags this as unverified. | High | Refuse (or warn prominently in the review sheet) when the target browser is running — `NSWorkspace.shared.runningApplications` matched on `bundleURL?.path == profile.appPath`. And include the `-journal`/`-wal`/`-shm` siblings so on-disk state stays consistent. |
| 3 | `BrowserCleanerScanner.swift:97` | Logical lapses | `recursiveSize` uses `fileExists(atPath:isDirectory:)`, which **resolves symlinks**. A symlink inside any of these trees pointing at a parent (or at `/`) causes unbounded recursion — a stack-overflow crash, not a slow scan. A symlink to `$HOME` would make "measure Chrome's cache" walk the entire home directory. No depth or count cap either, unlike `ICloudDriveScanner.directorySize` (#12) and `SpaceLensViewModel.directorySize`, which both bound at 20 000. | Medium | Switch to `FileManager.enumerator(at:)` (does not follow directory symlinks by default) with `[.fileSizeKey, .isRegularFileKey]` and an explicit 20 000-entry cap. |
| 4 | `BrowserCleanerScanner.swift:66` | Exception handling | `clear()` returns only `firstError` and discards the rest. If 10 of 12 paths fail — the likely outcome under the sandbox, see 5 — the user sees one message plus a `cleared` count with no idea the operation mostly failed. Separately, `let size = Self.size(ofPaths: [path])` on line 61 recursively re-walks each cache directory immediately before trashing it, even though `measure(_:)` already computed exactly this — on a multi-GB four-profile Chrome cache that doubles the I/O of the clear. | Medium | Return all failures (`[String]` or a `(succeeded, failed)` pair). Reuse the already-measured `item.size` instead of recomputing. |
| 5 | `BrowserCleanerScanner.swift:49` | Blast radius | Every path read and trashed lives outside the app container (`~/Library/Safari`, `~/Library/Cookies`, `~/Library/Application Support/<vendor>`, `~/Library/Caches/<vendor>`, `~/Library/Logs/DiagnosticReports`). This PR adds no entitlement exceptions, and `trashItem` on another app's data is more restricted than reading. Under the release build the likely outcome is `measure` reporting 0 bytes for most categories and `clear` failing with permission errors — which, combined with 4, surfaces as "cleaned 0 items" plus one opaque message. | Medium | Confirm which paths work sandboxed and add the exceptions, or document the feature as Debug/direct-distribution only. See B4. |
| 6 | `BrowserCleanerScanner.swift:41` | Business requirement | `detectBrowsers()` filters on `fileExists(atPath:)` with `appPath` hardcoded to `/Applications/<Name>.app`. A browser installed in `~/Applications` — common for per-user installs and side-by-side Arc/Brave builds — never appears, with no indication why. `AppScanner` already enumerates both locations. | Low | Resolve by bundle identifier via `NSWorkspace.urlForApplication(withBundleIdentifier:)`, which handles every install location, and derive profile roots from the resolved bundle. |
| 7 | `BrowserCleanerScanner.swift:297` | Logical lapses | `crashReportPaths` enumerates `DiagnosticReports` when `categories()` is *constructed*, so any crash report written between detection and the user tapping Clear is excluded — measured size and cleared set can disagree. The filter `hasPrefix("safari")` also matches `SafariBookmarksSyncAgent`, `SafariLaunchAgent`, `SafariNotificationAgent` (all Safari-related, so arguably intended). | Low | Re-enumerate at clear time; add a comment noting the prefix behaviour, since the same helper with prefix `"Arc"` would match any app beginning with those letters. |

## Blocking issues

- **Blast radius** — 1, 2

## Non-blocking suggestions

- 3, 4, 5 are Medium; 5 determines whether the feature works at all in the shipping build, so it belongs in the same decision as B4.
- 6, 7 are Low.
- `chromiumProfileDirs` correctly includes `"Guest Profile"` and falls back to `["Default"]` for a never-launched install; `firefoxProfileDirs` correctly discovers randomized `<hash>.default-release` names rather than assuming. Both good — noting so a later refactor doesn't regress them.
- `recursiveSize` sums logical file sizes; browser caches are often sparse/compressed, so "freed bytes" will read slightly high. Worth a note in the UI copy rather than a code change.

## Questions for the author

1. **Was the Safari Cookies path checked against a container-era Safari** (issue 1)? The header's reasoning for omitting Site Data applies identically here.
2. What is the intended behaviour when the browser is running (issue 2)? The test plan lists it as an open question; it needs an answer in code, not just in QA.
3. Do any of these paths actually work under the release sandbox (issue 5)?

---

## Batch-level issues (affect this PR but cannot be fixed inside it)

These are tracked once for the whole `F-016 … F-030` batch. Full detail in the
[consolidated cross-PR comment](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519).

| # | Section | Issue | Risk |
|---|---------|-------|------|
| B1 | Code standards | **pbxproj UUID collision** — PRs #21, #13 and #9 all claim `8031`/`8032`. Whichever two merge second produce duplicate object IDs; Xcode may accept them while mapping a `PBXBuildFile` to the wrong `fileRef`. Free blocks: `8113`–`8116`, `8153`–`8156`. | High |
| B2 | Code standards | **All 13 sibling PRs report `MERGEABLE`** because mergeability is computed pairwise against `main`. The first merge conflicts the other twelve across 8 shared files (`project.pbxproj`, `Models.swift`, `HaloTests.swift`, `CLAUDE.md`, `FEATURE_ROADMAP.md`, `ROADMAP.md`, `MANUAL_TEST_PLAN.md`, `HALO_MOBILE_ROADMAP.md`). | High |
| B3 | Testing & rollout | **No CI exists.** `.github/workflows/` is absent and `gh pr checks` reports nothing on any branch. Every "BUILD SUCCEEDED" claim is unverifiable and is invalidated by the rebases B2 requires. | High |
| B4 | Business requirement | **`Process` + release App Sandbox** — six features (#21, #20, #17, #16, #10, #9) shell out; `posix_spawn` is denied under `Halo.entitlements`, so all six degrade to empty/unknown in the shipping build. They degrade *honestly*, which is right — but the PR bodies describe them as working. Needs one decision for the batch: Debug/direct-distribution only, or route via the F-002 privileged helper. | Medium |
| B5 | Logical lapses | **`Process` pipe ordering copied six times.** Five of six call `waitUntilExit()` before draining the pipe. #20 is the only one correct. Extract one shared `ShellReader` rather than fixing five call sites. | High |
| B6 | Blast radius | **Four `ProcessMonitor` instances, two `AlertManager` instances.** Cooldown state is per-instance, so the cooldown contract is not global. `AlertLog.shared` sits next to `AlertManager` and is already a singleton — promote both. | Medium |
| B7 | Security / privacy | **Inconsistent privacy posture between #10 and #13.** Both persist an app-usage behavioural profile; #10 is off-by-default with a Settings toggle and clear action, #13 is unconditional with neither. | Medium |
| B8 | Code quality | **Fresh `UUID()` as `Identifiable.id` on re-derived models** — `SecurityCheck` (#21), `NetworkConnectionEntry` (#17), `BackupHeatmapDay` (#16), `PhotoHashItem`/`PhotoAssetHashItem` (#19). Each is rebuilt every scan/poll, so `ForEach` rebuilds instead of diffing. A stable key already exists in every case. | Low |

---

## Risk definitions

- **Critical** — crash, data loss, security hole, or store-rejection risk; blocks merge
- **High** — breaks a user flow or another consumer of this code; should block merge
- **Medium** — bug or standards violation with limited blast radius; fix before merge or in immediate follow-up
- **Low** — style/readability/nice-to-have; non-blocking
