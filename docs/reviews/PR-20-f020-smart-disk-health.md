# Code review — PR #20 · F-020 S.M.A.R.T. Disk Health Monitor

- **PR:** [prasad-rently/halo-mac#20](https://github.com/prasad-rently/halo-mac/pull/20)
- **Branch:** `feat/f020-smart-disk-health` → `main`
- **Reviewed at:** commit `1182a290` · 14 files, +1123 / −27
- **Inline comments:** [review 5113168867](https://github.com/prasad-rently/halo-mac/pull/20#pullrequestreview-5113168867)

## Verdict: **Approve with comments**

The strongest PR in the batch. The `diskutil info -plist <mount path>` finding is well-evidenced
and cross-checked against `system_profiler SPNVMeDataType`; the file header documents exactly
what is and is not readable, including the empty-`MediaName`-by-mount-path gotcha and *why* ATA
sector counters cannot exist on NVMe (a protocol difference, not a failed read). The NVMe
data-unit → bytes conversion (`× 512_000`) is correct, the Kelvin conversion is correct, and this
is the **only** PR in the batch that gets the `Process` pipe ordering right — read, then wait,
then check `terminationStatus`. The `classify` test suite covers the branches that matter.

One real bug blocks a clean approve: a volume change arriving mid-scan is dropped, so the card
can display one drive's S.M.A.R.T. data under another drive's label.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Features/Files/DriveHealthSection.swift:29` | Logical lapses | `scanIfNeeded` compares against `scannedVolumeID`, but `scan(volume:)` assigns it on line 31 — *after* the `guard !isScanning` on line 29. Sequence: scan A starts → user switches to B → `scanIfNeeded(B)` calls `scan(B)` → guard returns → **`scannedVolumeID` stays `"A"`** → A's result populates `vm.info` → nothing re-triggers. The card now renders A's model, serial, temperature and wear percentage under B's header. For a drive-health panel that is worse than showing nothing: the user could read "Failing" against the wrong disk. | High | Record the requested id *before* the guard and re-dispatch on completion; or clear `info` to `nil` on every `volume.id` change so a stale result can never be mis-attributed. |
| 2 | `Halo/Core/Scanner/SMARTDiskMonitor.swift:144` | Logical lapses | `if case .other = status { return .warning }` catches every `SMARTStatus` that isn't literally `Verified`/`Failing`. `diskutil` reports `"Not Supported"` for essentially every USB/Thunderbolt bridge enclosure — the normal, healthy state. Result: amber "Warning" badge and amber card accent on a healthy external SSD, detail line reading *"diskutil reports S.M.A.R.T. status: Not Supported"*. Same class of false positive the F-019 `.unknown` design and the v2.1 `isUnused` fix were written to avoid. | Medium | Map unsupported/unknown strings to `.unknown`; reserve `.warning` for statuses that indicate a real problem. |
| 3 | `SMARTDiskMonitor.swift:137` | Logical lapses | Any non-zero media-error count flips `healthLevel` to `.warning` permanently. A single transient NVMe *Media and Data Integrity Error* — loggable once over a drive's life, not by itself predictive — then triggers `evaluateSMART` every 5 minutes with an 86 400 s cooldown, i.e. a "back up important files soon" system notification **every day, indefinitely**, with no acknowledge or opt-out. | Medium | Separate the UI badge (fine at >0, count already shown) from the *alert* trigger: use a threshold or growth-since-last-observed, plus a Settings opt-out alongside the other alert toggles. |
| 4 | `SMARTDiskMonitor.swift:320` | Logical lapses | `serialNumber(matchingModel:)` matches `IONVMeController`'s `"Model Number"` against the model string. On a Mac with two identical NVMe drives the first match wins, so one drive can be labelled with the other's serial — silently wrong. | Medium | Match by BSD name instead: `bsdWholeDiskID` is already computed; walk from the `IOMedia` service up the `kIOServicePlane` parent chain to the controller. |
| 5 | `Halo/App/AppState.swift:234` | Code quality | `info.model ?? "your internal drive"` is interpolated into a title, giving *"Drive Health Critical — your internal drive"* — a sentence fragment used as a noun. Also near-unreachable, since `.unknown` never alerts and `model` is nil only when `diskutil` returned nothing. | Low | Drop the interpolation when `model` is nil, or use a title-cased fallback. |
| 6 | `DriveHealthSection.swift:152` | Code quality | `availableSpareThresholdPercent` decides a `.failing` verdict but is never rendered. A user seeing "Available Spare: 8%" beside a red "Failing" badge has no way to understand the relationship (thresholds are manufacturer-specific, commonly 5–10%). | Low | Render as `"8% (threshold 10%)"` — already parsed and stored. |
| 7 | `DriveHealthSection.swift:215` | Logical lapses | `temperatureSection` renders whenever `volume.isInternal`, but `SMARTTemperatureHistory.shared` is populated only from `AppState.runSMARTCheck()`, which is hardcoded to the boot volume (`scan(path: "/", id: "/")`). On a Mac with a second internal volume or a Fusion/multi-container setup, selecting that volume shows the *boot* drive's 24 h history under a header reading "(INTERNAL DRIVE)". | Low | Gate on the resolved `bsdWholeDiskID` matching the boot disk's, or label the chart with the drive it belongs to. |
| 8 | `SMARTDiskMonitor.swift:52` | Business requirement | Sandbox: `diskutil` spawn is denied in the release configuration, so every field becomes `nil`/`.unavailable` and the whole card is empty in the shipping build. It degrades honestly ("Not available on this drive"), which is the right default — but all the verified-on-this-machine evidence comes from an unsandboxed Debug run. | Medium | See B4 — one decision for the batch. |

## Blocking issues

- **Logical lapses** — 1

## Non-blocking suggestions

- 2, 3, 4 and 8 are Medium and worth an immediate follow-up: 2 and 3 both produce user-visible false alarms, which is the failure mode this codebase is otherwise careful about.
- 5, 6, 7 are Low.
- `combine64` and `stripPartitionSuffix` are `private` and untested; both have interesting edge cases (`"disk0"` contains an `s`, and `combine64` returns `nil` if either 32-bit half is missing). Worth making them internal like `nonEmpty` already is, and pinning them.

## Questions for the author

1. Does `diskutil` reliably emit both `<BASE>_0` and `<BASE>_1` halves for counters that fit in 32 bits? `combine64` returns `nil` if either is absent, so a single-half counter silently becomes "Not available".
2. Same sandbox question as the rest of the batch (issue 8 / B4).

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
