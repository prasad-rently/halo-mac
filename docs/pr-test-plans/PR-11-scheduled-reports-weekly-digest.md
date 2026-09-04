# Manual Test Plan — PR #11: F-029 Scheduled Reports & Weekly Digest

> **Branch:** `feat/f029-scheduled-reports` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/11
> **Diff size:** 16 files changed, +1047/-5
> **Master regression doc:** this PR's test cases also appear at [`§15.3`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Alerts, Report & Notifications**.

## How to test this PR

```bash
git fetch origin feat/f029-scheduled-reports
git checkout feat/f029-scheduled-reports
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/AppState.swift`
- `Halo/App/HaloApp.swift`
- `Halo/Core/MetricsHistory.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Core/WeeklyDigestGenerator.swift`
- `Halo/Features/Dashboard/DashboardView.swift`
- `Halo/Features/Dashboard/HealthTrendCard.swift`
- `Halo/Features/Onboarding/OnboardingView.swift`

## Detailed test cases

**Files:** `MetricsHistory.swift`, `WeeklyDigestGenerator.swift`, `HealthTrendCard.swift`, Settings → "Weekly Digest" section in `OnboardingView.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-DIGEST-01 | P1 | Toggle exposed in Settings | Open Settings → General | "Send Weekly Digest" toggle present, off by default |
| TC-DIGEST-02 | P1 | Enabling reveals schedule pickers | Toggle on | Frequency (Weekly/Daily), Day (weekly only), Time pickers appear; "Next digest: …" label shown |
| TC-DIGEST-03 | P1 | Schedule independence from Smart Scan | Set digest schedule ≠ scan schedule | `WeeklyDigestScheduler`'s `com.halo.mac.weeklydigest` activity fires independently of `ScanScheduler` |
| TC-DIGEST-04 | P0 | Send Test Digest Now | Click button | Local notification posted immediately; `AlertLog` gains a "Weekly Digest Sent" entry |
| TC-DIGEST-05 | P1 | "View Report" notification action | Tap action on the digest notification | App activates, PDF save panel opens (same flow as Export Report) |
| TC-DIGEST-06 | P2 | Share Weekly Report Now | Click button | `NSSharingServicePicker` opens with a generated PDF |
| TC-DIGEST-07 | P2 | Honesty scope | Inspect digest body/report | No "backup status" claim; "top storage growers" reads as disk-free delta, not a file audit |
| TC-DIGEST-08 | P2 | Fresh-install graceful empty state | Send digest with <2 hourly samples | No trend delta shown (nil-safe); body still composes from live metrics |
| **Unit** TC-DIGEST-U1 | P1 | `healthScoreDelta` / `diskFreeDeltaGB` | Various start/end pairs, including nil start | Correct signed delta; nil when no starting sample |
| **Unit** TC-DIGEST-U2 | P1 | `notificationBody(for:)` composition | Up/down/steady score, freed/lost/negligible disk, scan & threat counts | Correct direction wording, singular/plural counts, sub-0.1GB disk noise omitted |
| **Unit** TC-DIGEST-U3 | P1 | `WeeklyDigestScheduler.nextDigestDate` | daily / weekly / "off" / out-of-range hour | Correct next date, matching weekday/hour; nil for "off"; hour clamped to 0–23 |

### Related rows in other sections

Two more rows land alongside this feature elsewhere in the app (already reflected in the master doc, called out here so you don't miss them while testing just this PR):

- **Dashboard** (§2): `TC-DASH-09` — the 7-Day Health Trend card, and `TC-DASH-U3` — `MetricsSample` Codable round-trip.
- **Onboarding/Settings** (§18): `TC-ONB-08` — the Weekly Digest toggle in Settings persists its four `UserDefaults` keys.


## Regression spot-check

This PR only *adds* a new section to **Alerts, Report & Notifications** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Alerts, Report & Notifications test cases from [`§15` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
