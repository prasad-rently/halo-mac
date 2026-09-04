# Manual Test Plan — PR #20: F-020 S.M.A.R.T. Disk Health Monitor

> **Branch:** `feat/f020-smart-disk-health` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/20
> **Diff size:** 14 files changed, +1123/-27
> **Master regression doc:** this PR's test cases also appear at [`§7.6`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Files**.

## How to test this PR

```bash
git fetch origin feat/f020-smart-disk-health
git checkout feat/f020-smart-disk-health
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/AppState.swift`
- `Halo/Core/AlertManager.swift`
- `Halo/Core/Scanner/SMARTDiskMonitor.swift`
- `Halo/Features/Files/DriveHealthSection.swift`
- `Halo/Features/Files/DriveSpeedView.swift`

## Detailed test cases

**Files:** `SMARTDiskMonitor.swift`, `DriveHealthSection.swift` (shown in the same Drive Speed tab, below the volume picker)

Read-only S.M.A.R.T./NVMe health reader via `diskutil info -plist` + an `IONVMeController` IOKit lookup for the serial number only. Every field diskutil/IOKit doesn't report renders "Not available on this drive" — never a guessed or zeroed value.

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-FILE-50 | P0 | On-demand only | Open Drive Speed tab | View Drive Health card before tapping anything | No scan has run yet — "Tap 'Check Drive Health'..." prompt shown, not a spinner |
| TC-FILE-51 | P0 | Run a health check | Tap "Check Drive Health" | Status settles to Good/Warning/Failing/Unknown with an icon + colored badge |
| TC-FILE-52 | P0 | Metrics grid renders | After a scan | View the 12-field grid | Each field shows a real value or "Not available on this drive" — never blank or a guess |
| TC-FILE-53 | P1 | NVMe sector fields | Internal Apple Silicon SSD | View Reallocated/Pending Sectors | Shows "N/A on NVMe" (not "Not available") since these are genuinely ATA-only concepts |
| TC-FILE-54 | P0 | Lifespan bar | Drive reports a wear percentage | View "Estimated Lifespan Remaining" | Bar + percentage = 100 − NVMe's `PERCENTAGE_USED`; color: red <10%, amber <25%, else green |
| TC-FILE-55 | P1 | Lifespan unavailable | Drive doesn't report wear % | View lifespan section | "Lifespan estimate unavailable" text, not a fabricated bar |
| TC-FILE-56 | P1 | Temperature sparkline (internal only) | Internal boot volume selected, Halo running a while | View card | 24h chart once ≥2 samples exist; external volumes never show this section |
| TC-FILE-57 | P1 | Re-check | Tap "Re-Check" after an initial scan | Re-runs the scan | Spinner shown briefly, values refresh |
| TC-FILE-58 | P1 | Switching volumes re-scans | Select a different volume in the picker | Drive Health card | Auto re-scans for the newly selected volume (`scanIfNeeded`) |
| TC-FILE-59 | P2 | Failing status alerts | Force/simulate a failing SMART status | — | `AlertManager.evaluateSMART` fires `.diskSmartFailing` (1h cooldown); `.good`/`.unknown` never fire |
| **Unit** TC-FILE-U8 | P0 | classify() — failing status overrides everything | status=.failing + healthy-looking counters | Returns `.failing` |
| **Unit** TC-FILE-U9 | P0 | classify() — available spare at/below threshold | spare=10, threshold=10; spare=5, threshold=10 | Both return `.failing` (NVMe spec: at-or-below threshold is critical) |
| **Unit** TC-FILE-U10 | P0 | classify() — 100%+ wear is failing, 90-99% is only a warning | percentageUsed=100 vs 90/99 | 100 → `.failing`; 90 and 99 → `.warning` |
| **Unit** TC-FILE-U11 | P1 | classify() — media errors and unrecognized status are warnings | mediaErrorCount=1; status=.other(...) | Both → `.warning` |
| **Unit** TC-FILE-U12 | P0 | classify() — verified with no red flags is good; unavailable with no signal is unknown, never guessed | status=.verified, all clean vs status=.unavailable, all nil | `.good` and `.unknown` respectively |
| **Unit** TC-FILE-U13 | P0 | nonEmpty() — the diskutil MediaName-by-mount-path gotcha | nil / "" / "   " / real value | nil, nil, nil, passthrough respectively |
| **Unit** TC-FILE-U14 | P1 | lifespanRemainingPercent | percentageUsed nil/30/0/110 | nil / 70 / 100 / 0 (clamped, never negative) |

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
