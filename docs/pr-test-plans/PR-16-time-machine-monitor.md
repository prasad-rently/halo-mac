# Manual Test Plan — PR #16: F-022 Time Machine Backup Health Monitor

> **Branch:** `feat/f022-time-machine-monitor` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/16
> **Diff size:** 15 files changed, +817/-4
> **Master regression doc:** this PR's test cases also appear at [`§2.3`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Dashboard**.

## How to test this PR

```bash
git fetch origin feat/f022-time-machine-monitor
git checkout feat/f022-time-machine-monitor
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/AppState.swift`
- `Halo/Core/AlertManager.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/TimeMachineMonitor.swift`
- `Halo/Features/Dashboard/BackupHealthCard.swift`
- `Halo/Features/Dashboard/DashboardView.swift`

## Detailed test cases

**Files:** `TimeMachineMonitor.swift`, `BackupHealthCard.swift`, `AppState.startTimeMachineMonitoring()` / `refreshTimeMachineStatus()` / `startTimeMachineBackupNow()`, `AlertManager.evaluateBackup(status:)`

Read-only checks via the public `tmutil` CLI (`destinationinfo`, `status`, `listbackups`, `latestbackup`) — no entitlements, no elevation. "Back Up Now" is a normal `tmutil startbackup`, identical to the menu bar icon's own action. If Time Machine has never been configured, the card must show an explicit empty state — never a fabricated "healthy" card or heatmap.

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-DASH-09 | P0 | Not configured — honest empty state | Time Machine never set up | Open Dashboard | "Time Machine isn't set up" state; "Set Up" opens System Settings' Time Machine pane; no heatmap shown |
| TC-DASH-10 | P0 | Configured + reachable | TM set up, destination mounted | Open Dashboard | Last backup relative time, destination name, free/total space bar, and 30-day heatmap all render |
| TC-DASH-11 | P0 | Configured but unreachable | TM set up, backup drive unplugged | Open Dashboard | "Not currently reachable" state; last known backup date shown if any; no heatmap fabricated |
| TC-DASH-12 | P0 | Stale backup visual + alert | Last backup > 48h ago | View card / wait for the 15-min poll | Last-backup text in red; `AlertManager.evaluateBackup` fires "Time Machine Backup Overdue" (24h cooldown) |
| TC-DASH-13 | P1 | Recent backup is not flagged stale | Last backup < 48h ago | View card | Last-backup text in normal color; no stale alert fires |
| TC-DASH-14 | P0 | Back Up Now | Configured + reachable | Click "Back Up Now" | Button shows "Backing Up…"/disabled while running; `tmutil startbackup` invoked; status re-polled after |
| TC-DASH-15 | P1 | Backup already running | A TM backup is in progress (menu bar spinning) | View card | "Backing Up…" state shown; Back Up Now disabled, not double-triggerable |
| TC-DASH-16 | P1 | Heatmap — backed-up day | A snapshot exists for a given day | View 30-day grid | That day's cell is green ("Backed up") |
| TC-DASH-17 | P1 | Heatmap — late vs missed | 1-day gap vs 2+ day gap since the nearest prior snapshot | View grid | 1-day gap → amber ("Late"); 2+ day gap → red ("Missed") |
| TC-DASH-18 | P0 | Heatmap — no fabricated history | Days before Halo's earliest known snapshot, or no backup history at all | View grid | Those cells are neutral gray ("No data") — never red as if a backup was missed |
| TC-DASH-19 | P2 | 15-minute poll cadence | Leave Dashboard open | Wait / inspect | Status re-checked every 15 min (900s timer), not on the 2s metrics tick — `tmutil` is too heavy for that |
| **Unit** TC-DASH-U3 | P0 | `heatmap()` — no history at all | Empty backup-dates array | Every day in the window is `.noData` |
| **Unit** TC-DASH-U4 | P0 | `heatmap()` — backed-up / late / missed classification | Backup today; 1-day gap; 3-day gap | `.backedUp`, `.late`, `.missed` respectively |
| **Unit** TC-DASH-U5 | P0 | `heatmap()` — days before earliest backup are `.noData`, not `.missed` | One backup 2 days ago, 7-day window | Day 6 (before the backup) is `.noData` |
| **Unit** TC-DASH-U6 | P1 | `heatmap()` — window size and end date | 30-day window, referenceDate = today | Exactly 30 entries; last = today, first = 29 days ago |
| **Unit** TC-DASH-U7 | P0 | `TimeMachineStatus.isStale` | Not configured (any date); configured + no date; configured + 47h; configured + 49h | false, false, false, true respectively |
| **Unit** TC-DASH-U8 | P1 | `TimeMachineStatus.spaceUsedRatio` | 250/1000 bytes; missing available; missing total; zero total | 0.75; nil; nil; nil |

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
