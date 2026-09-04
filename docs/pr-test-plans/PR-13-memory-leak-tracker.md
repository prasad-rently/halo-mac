# Manual Test Plan — PR #13: F-023 Memory Leak & App Bloat Tracker

> **Branch:** `feat/f023-memory-leak-tracker` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/13
> **Diff size:** 17 files changed, +897/-7
> **Master regression doc:** this PR's test cases also appear at [`§5.8`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Performance**.

## How to test this PR

```bash
git fetch origin feat/f023-memory-leak-tracker
git checkout feat/f023-memory-leak-tracker
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/App/AppState.swift`
- `Halo/Core/AlertLog.swift`
- `Halo/Core/AlertManager.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/MemoryTrendTracker.swift`
- `Halo/Core/Scanner/ProcessMonitor.swift`
- `Halo/Features/Performance/MemoryTrendsSection.swift`
- `Halo/Features/Performance/PerformanceView.swift`

## Detailed test cases

**Files:** `MemoryTrendTracker.swift`, `MemoryTrendsSection.swift`, `ProcessMonitor.runningAppRAMSamples()`, `AlertManager.checkAppMemory(appName:bundleID:ramMB:)`

Concrete thresholds under test (all constants on `MemoryTrendTracker`):

| Constant | Value |
|---|---|
| `sampleInterval` | 30 s |
| `windowSeconds` | 2 h rolling window |
| `leakWindowSeconds` | 3600 s (streak must survive >1 h before the badge shows) |
| `significantDropFraction` | 0.15 (a drop of >15% below the streak's local peak resets it) |
| `maxSampleGapSeconds` | 300 s (5× the sample interval; a bigger gap also resets the streak) |
| `defaultAlertThresholdGB` | 2.0 GB (user-configurable, `UserDefaults["memoryLeakAlertThresholdGB"]`) |

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-70 | P1 | Section renders | Open Performance | "Memory Trends" section appears below Top Processes with a subtitle "Rolling 2h window · sampled every 30s" (`performance.memoryTrends.tab`) |
| TC-PERF-71 | P1 | Sparklines render per app | Let Halo sample for a few minutes | Each visible app row (>50 MB) shows a live RAM sparkline (`performance.memoryTrends.sparkline.<bundleID>`); a freshly-added row shows "Collecting samples…" until it has ≥2 samples |
| TC-PERF-72 | P2 | Sub-50 MB apps filtered | Inspect visible rows | Helper processes/apps under 50 MB current RAM are not listed (noise filter) |
| TC-PERF-73 | P0 | Leak badge appears after >1h monotonic growth | Let an app's RAM grow continuously for >1 h | "Possible memory leak" badge (`.haloAmber`) appears on that row with a "+N MB since HH:mm" readout |
| TC-PERF-74 | P0 | Leak badge does NOT appear with <1h of growth | Fresh app / growth streak <1 h old | No badge, regardless of growth rate — not enough data yet |
| TC-PERF-75 | P1 | >15% drop resets the streak | RAM grows, then drops >15% below the streak's local peak, then grows again for <1h | Badge disappears (streak restarted at the drop) until the new streak itself passes 1 h |
| TC-PERF-76 | P2 | Sleep/wake gap resets the streak | Growing app, then a >5 min sampling gap (e.g. Mac sleeps), then growth resumes | Streak resets at the gap rather than treating it as continued monotonic growth |
| TC-PERF-77 | P0 / TC-SAFE-02 | Restart App requires confirmation | On a flagged app, click "Restart App" (`performance.memoryTrends.restart.<bundleID>`) | `.confirmationDialog` appears ("Restart \"<app>\"?" + data-loss warning) before anything happens |
| TC-PERF-78 | P0 / TC-SAFE-02 | Cancel takes no action | From the dialog in TC-PERF-77, click Cancel | Target app is NOT terminated or relaunched; its PID and RAM history are unchanged |
| TC-PERF-79 | P1 | Restart App only offered on flagged rows | Inspect a non-leaking row | No "Restart App" button present |
| TC-PERF-80 | P1 | 2 GB alert threshold — configurable | Change the Stepper (`performance.memoryTrends.alertThreshold.stepper`) | New value persists to `UserDefaults["memoryLeakAlertThresholdGB"]` and survives an app restart |
| TC-PERF-81 | P0 | Alert fires at/above threshold, not below | An app's RAM crosses the configured GB threshold | A notification + `AlertLog` entry ("`<App>` Using High Memory", icon `memorychip.fill`, `.haloAmber`) fires once, then is suppressed for 30 min (per-bundle-ID cooldown) — an app that stays just below threshold never fires |
| TC-PERF-82 | P1 | History persists across app restart | Quit and relaunch Halo after some sample history has accumulated | `Application Support/Halo/memoryTrendHistory.json` is read back on launch and sparklines resume without a gap (data older than the 2h window is dropped at load) |
| **Unit** TC-PERF-U5 | P0 | Monotonic growth >1h flags leak | Synthetic samples growing steadily over >1h (30s cadence) | `leakStatus(for:).isPossibleLeak == true` |
| **Unit** TC-PERF-U6 | P0 | <1h of growth never flags | Synthetic samples growing steadily for <1h | `isPossibleLeak == false` regardless of growth rate |
| **Unit** TC-PERF-U7 | P0 | >15% drop resets the streak | Growth, then a >15% drop from local peak, then <1h of renewed growth | `isPossibleLeak == false` (new streak hasn't reached 1h yet) |
| **Unit** TC-PERF-U8 | P2 | ≤15% dip does NOT reset the streak | Growth with a small (<15%) wobble, total streak >1h | `isPossibleLeak == true` (minor fluctuation tolerated) |
| **Unit** TC-PERF-U9 | P1 | Sleep/wake gap resets the streak | >1h of growth, then a >5 min gap, then <1h renewed growth | `isPossibleLeak == false` (gap breaks the streak) |
| **Unit** TC-PERF-U10 | P1 | JSON persistence round-trip | Encode a synthetic `[AppMemoryHistory]`, decode it back | Decoded value == original (bundleID, appName, bundlePath, samples all equal) |
| **Unit** TC-PERF-U11 | P0 | Alert fires exactly at configured threshold | `ramMB == thresholdGB * 1024` | Alert fires |
| **Unit** TC-PERF-U12 | P0 | Alert does not fire just below threshold | `ramMB` slightly under `thresholdGB * 1024` | Alert does not fire |

## Regression spot-check

This PR only *adds* a new section to **Performance** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Performance test cases from [`§5` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
