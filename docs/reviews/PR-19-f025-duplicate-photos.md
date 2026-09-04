# Code review — PR #19 · F-025 Duplicate Photos Finder (Perceptual Hash)

- **PR:** [prasad-rently/halo-mac#19](https://github.com/prasad-rently/halo-mac/pull/19)
- **Branch:** `feat/f025-duplicate-photos` → `main`
- **Reviewed at:** commit `58243608` · 16 files, +1528 / −46
- **Inline comments:** [review 5113133568](https://github.com/prasad-rently/halo-mac/pull/19#pullrequestreview-5113133568)

## Verdict: **Request changes**

The DCT/pHash implementation is solid — standard algorithm, DC correctly excluded from the
median, union-find clustering, and a "recommended keep" heuristic (resolution → recency) that
is deterministic and separately testable. Labelling the PhotoKit path as experimental in code
comments, UI copy *and* both entitlement files is the right instinct, and catching the real
macOS-specific `NSImage` has-no-`.cgImage` difference during the build pass is a genuine find.

Four things block merge, and there is a store-compliance question about shipping the Photos
entitlement in the release configuration for a path that has never been runtime-tested.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/PerceptualDuplicateDetector.swift:174` | Code quality | `CGContext(data: &pixels, …)` — `&` on a Swift `Array` yields a pointer valid only for the duration of the call it is passed to. `CGContext` retains it and `context.draw(...)` on line 183 writes through it afterwards. Undefined behaviour; the canonical Swift/CoreGraphics trap. Usually appears to work (the buffer isn't relocated), which is what makes it dangerous — it can produce garbage hashes or crash under memory pressure, and no unit test will catch it. | Critical | Allocate with `UnsafeMutablePointer` and `defer` the deallocation, or wrap the context *and* the draw inside one `pixels.withUnsafeMutableBytes { … }` closure. |
| 2 | `PerceptualDuplicateDetector.swift:61` | Logical lapses | `for url in files { group.addTask { … } }` queues one child task per file with no concurrency window. `enumerateImageFiles` caps at 20 000, so up to 20 000 tasks are created and their captured state retained up front, each opening a `CGImageSource` and decoding a thumbnail. Memory spikes hard. This is the path the PR body calls the tested, complete v1 scope. | High | Bounded window (`min(8, activeProcessorCount)`): prime the group, then add one task per completed result. |
| 3 | `Halo/Features/Files/SimilarPhotosView.swift:212` | Control flow | `start(scanning:)` is a method on a `@MainActor` class, so the `Task { }` inherits the MainActor context. `Self.enumerateImageFiles(in: dirs)` is a synchronous recursive walk over `~/Pictures`, `~/Downloads` and `~/Desktop` (up to 20 000 files, each with a `resourceValues` stat) with no suspension point before it — so it runs entirely on the main thread. Several seconds of beachball. `chooseFolderAndScan()` has the same problem. | High | `Task.detached(priority: .userInitiated)` — `enumerateImageFiles` is already `static` and touches no instance state. |
| 4 | `SimilarPhotosView.swift:265` | Exception handling | `try?` discards every `trashItem` error, and line 267 removes the items from `groups[gi].items` unconditionally. When a trash fails (locked file, permission denied, sandbox violation) the photo vanishes from the list and the user believes it was trashed while it is still on disk. A destructive action reporting success it did not achieve is worse than one that fails loudly. | High | Collect failures, remove only the ids that succeeded, surface a message through the existing alert. |
| 5 | `Halo/Halo.entitlements`, `Halo/Resources/Info.plist` | App Store compliance | `com.apple.security.personal-information.photos-library` and `NSPhotoLibraryUsageDescription` are added to the **release / App Store** configuration for a path the PR itself labels experimental and never runtime-tested. That expands the App Privacy nutrition label and ships a permission prompt into a flow nobody has exercised. | Medium | Split the PhotoKit half into its own PR behind a flag, or restrict the entitlement to `Halo-Debug.entitlements` until the grant flow is verified. |
| 6 | `PerceptualDuplicateDetector.swift:424` | Exception handling | The comment asserts `.fastFormat` "calls its result handler exactly once". PhotoKit's contract is weaker: `requestImage` may invoke the handler more than once, and with `isNetworkAccessAllowed = true` an iCloud-backed asset can deliver a nil/error callback followed by a second result. A second `resume` on a checked continuation is a hard `fatalError`. The mirror risk is worse: if the handler is never called (asset unavailable, network drops) the continuation leaks and `detectInPhotosLibrary` hangs with no timeout and no cancel. | Medium | One-shot resume guard (`OSAllocatedUnfairLock`), and/or `isSynchronous = true` off the main actor, which PhotoKit does guarantee is single-delivery. |
| 7 | `PerceptualDuplicateDetector.swift:352` | Logical lapses | Union-find unions `A~B` and `B~C` even when A and C differ by up to `2 × threshold` bits. At the default 8, on a large screenshot library, this reliably produces one oversized cluster. It matters because `makeGroup` sets `isMarkedForDeletion = true` on **every** item except the single best one — a 200-photo chained cluster arrives with 199 deletions pre-checked. The confirmation dialog is a real backstop, but the default state is doing the wrong thing at scale. | Medium | Require each member within `threshold` of the cluster medoid before unioning; or default `isMarkedForDeletion = false` and drive pre-selection from an explicit "Select all but recommended" button. |
| 8 | `SimilarPhotosView.swift:226` | Exception handling | `scanError` is written but never rendered anywhere. The view's `.alert` binds only `photosLibraryError`. A failed loose-file scan ends with the spinner stopping, an empty list, and no explanation — indistinguishable from "no duplicates found". | Medium | Bind it into the same alert (a shared `errorMessage` for both paths is simpler), or delete the property. |
| 9 | `SimilarPhotosView.swift:204` | Logical lapses | `start(scanning:)` calls `scanTask?.cancel()` then immediately sets `isScanning = true`. The cancelled task's `catch is CancellationError` branch does `await MainActor.run { self?.isScanning = false }`, free to land *after* the new scan set it true → a running scan with no spinner and re-enabled buttons. | Medium | Generation counter: stamp each scan; completion handlers no-op unless their generation is current. |
| 10 | `PerceptualDuplicateDetector.swift:301` | Code quality | The median is computed over `lowFrequency.dropFirst()` (excluding DC, correct), but the thresholding loop iterates all 64 coefficients *including* DC. DC is an order of magnitude above every AC coefficient, so bit 63 is set for every image — a 63-bit hash described as 64-bit. Harmless for relative distances, but it means distances read one bit "closer" than a reference pHash, which undercuts the header's "comparable with other tools" claim and skews the meaning of the 1–20 slider. | Low | Drop DC from the hash (63 bits, documented) or take the median over all 64. |
| 11 | `PerceptualDuplicateDetector.swift:338` | Code quality | `0.25` is not the orthonormal scale for N=32 — that is `2/N` = `0.0625`. Output is unaffected (a uniform scale cancels against the median), but the comment claims "orthonormal scaling factors applied". | Low | Fix the constant to `2.0 / Double(n)`, or reword the comment. |
| 12 | `Halo/Core/Models/Models.swift:354` | Code quality | `PhotoHashItem.isFromPhotosLibrary` is declared and documented as "used by the 'recommended keep' heuristic" but is never read or written — the PhotoKit path has its own `PhotoAssetHashItem`. Also `megapixels` returns `pixelWidth * pixelHeight`, a raw pixel count. | Low | Remove the dead field; rename `megapixels` → `pixelCount`. |

## Blocking issues

- **Code quality / memory safety** — 1
- **Logical lapses** — 2, 3
- **Exception handling** — 4
- **App Store compliance** — 5 (Medium, but decide before merge since it touches release entitlements)

## Non-blocking suggestions

- 6, 7, 8, 9 are Medium; 6 and 7 both matter more once the PhotoKit path is exercised, so they pair naturally with resolving 5.
- 10, 11, 12 are Low.
- Confirmation dialogs are present and correct on both delete paths (`showDeleteConfirm` → `.confirmationDialog` with a `.destructive` role) — that satisfies the CLAUDE.md rule; no action needed.

## Questions for the author

1. **Why is the Photos entitlement in the release configuration** for a path labelled experimental (issue 5)? Ship it, or Debug-only until tested?
2. `isNetworkAccessAllowed = true` silently downloads iCloud originals during a scan the user may think is local — is that intended, and should it be disclosed or made opt-in?
3. Was the default `isMarkedForDeletion = true` (issue 7) a deliberate convenience, or an artefact of "everything except the keep"?

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
