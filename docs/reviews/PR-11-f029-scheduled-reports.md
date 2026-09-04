# Code review — PR #11 · F-029 Scheduled Reports & Weekly Digest

- **PR:** [prasad-rently/halo-mac#11](https://github.com/prasad-rently/halo-mac/pull/11)
- **Branch:** `feat/f029-scheduled-reports` → `main`
- **Reviewed at:** commit `ba5c01bd` · 16 files, +1047 / −5
- **Inline comments:** [review 5115646079](https://github.com/prasad-rently/halo-mac/pull/11#pullrequestreview-5115646079)

## Verdict: **Request changes**

Composing this out of three already-built primitives (`ReportGenerator`, `ScanScheduler`'s
scheduling pattern, `AlertLog`) is the right approach, and the separate hourly timer — deliberately
not hooked into the 2 s metrics tick, with the widget-reload-budget precedent cited as the
rationale — is the right call. The "what's real vs simplified" table is the kind of disclosure this
batch does well: omitting backup status entirely rather than faking it, and being explicit that
top-RAM sampling is hourly and coarse so a brief spike between samples won't be caught.

Blocking: `threatsDetectedCount` counts security threats by substring-matching the word "threat" in
user-facing notification prose, so a clean-scan message reading "No threats found" is counted as a
threat detected. A security digest that inflates its own threat count is worse than one that omits it.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `Halo/Core/WeeklyDigestGenerator.swift:59` | Logical lapses | `alertsInPeriod.filter { $0.body.localizedCaseInsensitiveContains("threat") }.count`. `AlertEntry.body` is user-facing notification copy, so any alert mentioning the word is counted — *including the negative case*. `ProtectionScanner`'s clean result and `ScanScheduler`'s completion notification naturally read "No threats found" / "0 threats detected", so a week of clean scans produces *"N threats flagged"*. Also breaks entirely the moment this copy is localized. | High | Use `kindRaw`, exactly as `scansCompletedCount` correctly does two lines down. `AlertEntry` carries `kindRaw` precisely so consumers don't parse prose. |
| 2 | `WeeklyDigestGenerator.swift:113` | Blast radius | `setNotificationCategories([category])` is a *replace*, not an add, and it runs from `WeeklyDigestScheduler.start(appState:)` on every launch — discarding whatever categories any other feature registered. Nothing else registers today, so it works now, but it is a landmine: the next actionable notification (#14's focus summary is an obvious candidate) will either be silently stripped or strip this one, depending on registration order. | Medium | Read-modify-write: `var cats = await center.notificationCategories(); cats.insert(category); center.setNotificationCategories(cats)`. |
| 3 | `WeeklyDigestGenerator.swift:40` | Logical lapses | `ramTotals[proc.name]` accumulates `sum` and `count` only for hours where the app was in that hour's top 5, so the reported average is `sum / (hours it was in the top 5)` — not `sum / (hours in the period)`. An app that ran once at 8 GB averages 8000 MB and ranks first; an app at 4 GB every hour all week averages 4000 MB and ranks second. The section is titled "Apps with high average RAM" and will systematically promote brief spikes over sustained consumers — the opposite of what the user can act on. | Medium | Divide by the window's sample count (`max(history.count, 1)`), treating absence as zero (or as the top-5 cutoff floor). Consider surfacing `hoursObserved` so a spike reads as a spike. |
| 4 | `WeeklyDigestGenerator.swift:32` | Business requirement | `healthScoreStart: history.first?.healthScore` where `history = MetricsHistory.shared.recent(days: 7)`. On a fresh install with one seeded sample, `history.first` is the launch sample and `healthScoreEnd` is now — so the delta spans however long the app has been open, presented as a weekly change. Same for `diskFreeStartGB`. Sibling #10 handles this correctly and explicitly (`weekOverWeekChange()` returns `nil` until 14 days exist, precisely so nothing shows a fake +100%). | Medium | Return `nil` for the deltas until, say, ≥24 samples spanning ≥6 days; `notificationBody` already falls back to the absolute figure when `healthScoreDelta` is nil. Related: `MetricsHistory` samples on a main-runloop `Timer`, so sleep/quit gaps are simply absent with no markers — `recent(days: 7)` can't distinguish 7 days of hourly samples from 3 samples taken 7 days apart. |
| 5 | `WeeklyDigestGenerator.swift:163` | Exception handling | `if let window = NSApp.keyWindow, let view = window.contentView { picker.show(...) }` — no `else`. "Share Weekly Report Now…" lives in the Settings window; if the click path leaves `keyWindow` nil (Settings as a sheet, focus elsewhere after `NSApp.activate`, notification-driven invocation) the PDF is generated and written and then nothing happens on screen — no sheet, no error, no log. Two lines above, `guard doc.write(to: url) else { return }` discards a write failure the same way. The temp PDF is also never cleaned up. | Medium | Fall back to `NSApp.mainWindow` then any visible window; surface failures on the Settings pane; clean up the temp file via `NSSharingServicePickerDelegate` or on next launch. |
| 6 | `WeeklyDigestGenerator.swift:100` | Exception handling | `UNUserNotificationCenter.current().add(request)` with no completion handler, while the next line appends `"Weekly Digest Sent"` to `AlertLog`. If authorization was denied the digest silently never appears but Alert History claims it was sent. | Low | Handle the error and log "Sent" only on success — or log "Weekly digest generated", which is true either way. |
| 7 | `Halo/App/AppState.swift:106` | Code quality | `historyProcessMonitor` is the third independent `ProcessMonitor` instance across the batch (joining `TopProcessesSection`'s, #13's and #14's) — four actors each maintaining their own `previousCPUInfo` and independently enumerating processes on 3 s / 30 s / hourly / 5 s cadences. | Low | See B6. |

## Blocking issues

- **Logical lapses** — 1

## Non-blocking suggestions

- 2, 3, 4, 5 are Medium. 3 and 4 both make the digest report something other than what its labels claim, so they're worth fixing before the first real digest fires.
- 6, 7 are Low.
- `WeeklyDigestScheduler` correctly uses its own `com.halo.mac.weeklydigest` identifier so the digest schedule is independent of Smart Scan's, and correctly uses `.finished`/`.deferred` (not `.success`) per the known gotcha. Good.
- Building the PDF on `Task.detached` and hopping back to `MainActor` for the panel/picker is correct given `ReportGenerator` is `@unchecked Sendable`.

## Questions for the author

1. Which `AlertKind` raw value does the protection scanner fire for a real detection (issue 1)? That's the value `threatsDetectedCount` should filter on.
2. Should the digest refuse to send until there is enough history to be honest (issue 4), the way #10's week-over-week does?

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
