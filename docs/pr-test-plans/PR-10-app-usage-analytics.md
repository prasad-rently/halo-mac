# Manual Test Plan — PR #10: F-021 App Usage & Screen Time Analytics

> **Branch:** `feat/f021-app-usage-analytics` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/10
> **Diff size:** 15 files changed, +1073/-4
> **Master regression doc:** this PR's test cases also appear at [`§2.1`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Dashboard**.

## How to test this PR

```bash
git fetch origin feat/f021-app-usage-analytics
git checkout feat/f021-app-usage-analytics
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/HaloApp.swift`
- `Halo/Core/AppUsageTracker.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Features/Dashboard/AppUsageInsightsSection.swift`
- `Halo/Features/Dashboard/DashboardView.swift`
- `Halo/Features/Onboarding/OnboardingView.swift`

## Detailed test cases

**Files:** `AppUsageTracker.swift`, `AppUsageInsightsSection.swift` (Dashboard), Settings → General → Privacy toggle in `OnboardingView.swift`

**Honesty constraint — do not test around this:** Halo has no macOS API to read system-wide Screen Time history (`FamilyControls`/`ManagedSettings` need a parental-control entitlement Halo doesn't have). Every number here is time Halo personally observed via `NSWorkspace` activation notifications *while Halo itself was running* — a sleeping Mac or a quit Halo means that time is simply not counted, never estimated or backfilled. Every surface must say so.

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-DASH-09 | P0 | Tracking off by default | Fresh install | Open Dashboard | "Usage tracking is off" disabled state shown; no data collected |
| TC-DASH-10 | P0 | Opt-in starts tracking | Settings → General → Privacy | Enable "Track app usage & screen time insights" | `AppUsageTracker.shared.isTracking` becomes true; `NSWorkspace` observer + 30s timer start |
| TC-DASH-11 | P1 | Collecting state before any data | Tracking just enabled, no usage yet | View Dashboard | "Collecting usage data" state shown, not an empty chart |
| TC-DASH-12 | P0 | Top Apps bar chart | Tracking on, several apps used | View Dashboard | Top 5 apps by foreground time over last 7 days, bars sorted descending |
| TC-DASH-13 | P1 | Background Hogs list | An app run 8h+ with near-zero foreground time | View Dashboard | Listed under "Background Hogs"; apps with real usage are never misflagged |
| TC-DASH-14 | P1 | Context switching stat | <1h of tracked history vs ≥1h | View stat tile | "Not enough data yet" before 1h; a real switches/hr rate after |
| TC-DASH-15 | P1 | Week-over-week trend | <14 days of history vs ≥14 days | View stat tile | "Needs 14 days of history" before; a real ±% (or "New this week" if last week was zero) after |
| TC-DASH-16 | P0 | Sleep excludes time | Put Mac to sleep for a while with an app frontmost, wake it | Check that app's foreground time | No foreground seconds added for the sleep duration — the 30s timer can't fire while asleep |
| TC-DASH-17 | P1 | Halo quit excludes time | Quit Halo, use the Mac, relaunch Halo | Check usage history | No usage recorded for the time Halo wasn't running |
| TC-DASH-18 | P2 | System/menu-bar processes excluded | — | Check usage history | Finder, Dock, SystemUIServer, Control Center, Halo itself never appear as tracked "apps" |
| TC-DASH-19 | P1 | Clear Usage History | Tracking on, some history exists | Settings → "Clear Usage History" | All records removed; Dashboard reverts to the collecting/empty state |
| **Unit** TC-DASH-U3 | P0 | `recordsInWindow` — trailing-N-day boundary | Records at day 0, 6, 7 for a 7-day window | Days 0 and 6 included; day 7 excluded |
| **Unit** TC-DASH-U4 | P0 | `topApps` — sums across days, sorts descending, excludes zero-foreground apps | Multi-day records for 2+ bundle IDs, one with only background time | Correct per-app sums; sorted by foreground time desc; zero-foreground app excluded |
| **Unit** TC-DASH-U5 | P0 | `backgroundHogs` — flags low-ratio long-running apps, excludes short observation and real usage | 8h+/near-zero-fg app; <8h app; 10h/2h-fg app | Only the first is flagged |
| **Unit** TC-DASH-U6 | P0 | `contextSwitchesPerHour` — nil before 1h of history, real rate after | firstObservedDay 30min ago vs 1+ day ago | nil, then switches ÷ tracked hours |
| **Unit** TC-DASH-U7 | P0 | `weekOverWeekChange` — nil before 14 days, real comparison after | firstObservedDay 5 days ago vs 13 days ago | nil, then correct this-week/last-week totals and % change |
| **Unit** TC-DASH-U8 | P1 | `WeekOverWeek.percentChange` — nil when last week was zero | lastWeekSeconds = 0 | nil, not a fabricated +100% |

## Regression spot-check

This PR only *adds* a new section to **Dashboard** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Dashboard test cases from [`§2` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
