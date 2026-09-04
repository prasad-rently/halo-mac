# Code review — PR #18 · F-018 Privacy Data Exposure Scanner

- **PR:** [prasad-rently/halo-mac#18](https://github.com/prasad-rently/halo-mac/pull/18)
- **Branch:** `feat/f018-privacy-exposure-scanner` → `main`
- **Reviewed at:** commit `3fb5afa9` · 14 files, +1241 / −4
- **Inline comments:** [review 5113142436](https://github.com/prasad-rently/halo-mac/pull/18#pullrequestreview-5113142436)

## Verdict: **Request changes**

The detection design is the strongest part: Luhn validation instead of a bare digit-count regex,
exact-prefix matching for tokens (no loose substring), SSN scored down to Warning as
lower-confidence, a binary/size/null-byte pre-filter before any pattern runs, and a find-only
action surface with no delete/quarantine path anywhere. Explicitly declining to implement
"hardcoded passwords in config files" because no precise shape exists — and recording that as a
scope decision — is the right call. Redaction-at-the-source is the right architecture.

Three things block merge: the scan cannot actually be cancelled, the consumer loop publishes
once per file scanned, and the PR's stated redaction guarantee does not match the code.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/Scanner/PrivacyExposureScanner.swift:81` | Control flow | The `AsyncStream` producer is an unstructured `Task { }` created inside the initializer — not a child of the consumer — so the `Task.isCancelled` checks on lines 90/108/116 are never true when the consumer's task is cancelled. `continuation.onTermination` is not set either. `cancelPrivacyScan()` therefore resets the UI while the recursive walk over Downloads/Documents/Desktop (and optionally iCloud Drive) continues to completion, reading and matching every file. The test-plan item about cancelling will pass visually while the work keeps burning CPU and disk. | High | `continuation.onTermination = { _ in task.cancel() }`. Also switch to `AsyncStream(bufferingPolicy: .bufferingNewest(256))` — the default `.unbounded` means one `.progress` event per file accumulates in memory behind a slow consumer. |
| 2 | `Halo/Features/Protection/ProtectionView.swift:209` | Code quality | `runPrivacyScan()`'s `Task { }` is created in a `@MainActor` class, so the whole `for await` loop runs on the main actor. Each `.progress` event assigns two `@Published` properties, invalidating the Protection view. The scanner yields `.progress` for **every regular file it looks at** — an 80 000-file Documents tree means 80 000 main-thread `objectWillChange` emissions and 80 000 view invalidations. The UI is unusable for the duration and the path label is an unreadable blur. | High | Throttle the UI side to ~5 Hz (`guard Date().timeIntervalSince(lastPublish) > 0.2`). The running count stays honest; it just doesn't need publishing at file granularity. |
| 3 | `Halo/Core/Scanner/PrivacyPatternDatabase.swift:131` | Security | The PR body states *"`redact(_:category:)` is the only path that produces a `PrivacyPatternHit`"*. This line constructs one directly with `redactedPreview: needle`, never calling `redact`. Benign today — the only `exact` patterns are PEM headers, which are public markers — but the invariant is enforced by *the current contents of a remotely-updatable JSON file*, not by code. Add an `exact` pattern for a card or token prefix via `checkForUpdate()`, without an app release, and raw matched text flows into `@Published` UI state. | Medium | Route the `.exact` branch through `Self.redact(...)` like the other two. Related: `redact`'s `.sshPrivateKey` case does `return raw` — an unredacted return inside a function documented as "Never returns the full matched value"; return a fixed marker string instead. |
| 4 | `PrivacyPatternDatabase.swift:247` | Logical lapses | `for (k, v) in newTable { table[k] = v }` merges; `table` is never cleared. A pattern causing mass false positives can be *fixed* by id but never *retracted* — shipping a new JSON without it leaves the old entry live forever. And after a cached update at v5, `load()` skips a bundled v3 (correct) but any pattern existing only in the bundle is silently missing, with no cache-invalidation path. | Medium | Replace rather than merge: `if file.version >= loadedVersion { table = newTable; … }`. |
| 5 | `PrivacyPatternDatabase.swift:95` | Security | `checkForUpdate()` is dead code (never called; nor is `lastUpdatedDate`). As written it fetches from `https://api.halo.mac/…` — `.mac` is not a delegated TLD, so the host cannot resolve — accepts the response with no signature verification and no size limit, and compiles arbitrary attacker-supplied strings into `NSRegularExpression` to run against every file on disk. One catastrophically-backtracking pattern hangs every future scan. Inherited from `SignatureDatabase`, but replicating it doubles the surface. | Medium | Delete until there is a real signed endpoint; or add signature/pinning, a response size cap, and a per-pattern match deadline. |
| 6 | `PrivacyExposureScanner.swift:110` | Logical lapses | `maxDepth` is 8 and per-file size is capped at 10 MB, but there is no cap on the *number* of files. `~/Documents` on a developer machine routinely holds hundreds of thousands of files within 8 levels; every non-binary one under 10 MB is read into a `String` and matched against every pattern. Sibling F-025 caps enumeration at 20 000 for exactly this reason. | Medium | Add `maxFiles` to `ScanConfig` and have `.completed` report whether the cap was hit, so a truncated scan isn't presented as exhaustive. |
| 7 | `ProtectionView.swift:219` | Exception handling | `case .error:` discards the associated `String` and reports `.complete(findingsCount:)` — a scan that failed is presented as a scan that finished cleanly, the one thing a security feature can least afford. `ScanEvent.error` is also never yielded anywhere, so the case is currently dead. | Medium | Bind and surface the message; or remove the case and yield it where a requested root genuinely fails. |
| 8 | `PrivacyExposureScanner.swift:174` | Control flow | `String(data: data, encoding: .isoLatin1)` cannot fail — Latin-1 maps all 256 byte values — so the `else` branch and its comment ("undecodable as text — treat as binary, never scan raw bytes") are unreachable. Any file surviving the null-byte peek is scanned as Latin-1 regardless. | Low | Collapse to a single decode, or keep the fallback and delete the dead branch and comment. |
| 9 | `PrivacyExposureScanner.swift:126` | Code quality | `.skipsPackageDescendants` only affects deep enumeration via `FileManager.enumerator(at:)`; `contentsOfDirectory(at:includingPropertiesForKeys:options:)` ignores it. Since `traverse` recurses manually, `.app` / `.rtfd` / `.photoslibrary` bundles *are* descended into — wasted time, plus findings inside app bundles the user cannot act on. | Low | Add an explicit `.isPackageKey` check in the directory branch. (`.skipsHiddenFiles` is correctly *not* passed — that's what lets `.env` / `.npmrc` be scanned; worth a comment saying so, since it looks like an omission.) |
| 10 | `PrivacyPatternDatabase.swift:110` | Exception handling | `load()` sets `isLoaded = true` unconditionally and `evaluate` returns `[]` for an empty `table`. If the bundle resource is missing or its JSON fails to decode, every scan reports "No exposed sensitive data found" in green. | Low | Have `evaluate` (or the scanner) check `patternCount > 0` and yield `.error("Pattern database failed to load")` so the UI says "couldn't scan" rather than "you're clean". |

## Blocking issues

- **Control flow / lifecycle** — 1
- **Code quality (main-thread saturation)** — 2
- **Security** — 3 (stated guarantee vs code)

## Non-blocking suggestions

- 4, 5, 6, 7 are Medium. 5 is cheapest resolved by deletion — nothing calls it.
- 8, 9, 10 are Low.
- The privacy guarantees the PR claims otherwise hold: no `print`/`NSLog`/`os_log` touches a raw match, findings live only in `privacyFindings` for the session, no network calls during a scan, and Reveal-in-Finder is the only action. Verified by reading; no action needed.

## Questions for the author

1. Should `checkForUpdate()` exist at all yet (issue 5)? It is unreachable and the endpoint cannot resolve.
2. Is the `.exact`-bypasses-`redact` path (issue 3) intentional on the grounds that exact needles are pattern literals rather than user data? If so the PR body's wording should be narrowed — the guarantee as stated is stronger than the code.
3. Was a total file cap considered and rejected (issue 6), or just not reached?

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
