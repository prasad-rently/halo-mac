# Manual Test Plan — PR #14: F-028 Focus Session Companion

> **Branch:** `feat/f028-focus-session` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/14
> **Diff size:** 15 files changed, +1040/-21
> **Master regression doc:** this PR's test cases also appear at [`§2.2`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Dashboard**.

## How to test this PR

```bash
git fetch origin feat/f028-focus-session
git checkout feat/f028-focus-session
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/FocusSessionManager.swift`
- `Halo/Core/Models/Models.swift`
- `Halo/Features/Dashboard/DashboardView.swift`
- `Halo/Features/Dashboard/FocusSessionOverlayView.swift`
- `Halo/Features/MenuBar/MenuBarView.swift`
- `Halo/Features/Onboarding/OnboardingView.swift`

## Detailed test cases

**Files:** `FocusSessionManager.swift`, `FocusSessionOverlayView.swift`, `FocusSessionCard`/`FocusHistorySection` (`DashboardView.swift`), Settings → Focus tab (`OnboardingView.swift`)

Pomodoro-style deep-work session. Hides (never quits) a user-configured list of apps via `NSRunningApplication.hide()`, always paired with `unhide()` on end — win or lose, nothing is ever terminated. **Notification suppression was deliberately not implemented** — no public API lets a third-party app toggle system Focus/DND or silence other apps' notifications (`INFocusStatusCenter` only reports the app's own state). `openSystemFocusSettings()` is the honest replacement: a one-click deep link to System Settings so the user turns on a Focus mode themselves.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-DASH-09 | P0 | Start requires confirmation | Click "Start Focus Session" | `.confirmationDialog` lists exactly which apps will be hidden (or says none are configured) before anything happens |
| TC-DASH-10 | P0 / TC-SAFE-02 | Cancel starts nothing | From the dialog in TC-DASH-09, click Cancel | No apps hidden; card stays in idle state; no timer starts |
| TC-DASH-11 | P0 | Starting hides only configured apps | Configure 2 apps in Settings → Focus, start a session | Only those apps (if running) are hidden via `.hide()`; card shows "N apps hidden" |
| TC-DASH-12 | P0 | Countdown displays MM:SS | Session running | `remainingFormatted` counts down every second, monospaced digits |
| TC-DASH-13 | P0 | Ending restores all hidden apps | Click "End Session" (or let it run out) | Every hidden app is `.unhide()`-d — never left hidden, never terminated |
| TC-DASH-14 | P1 | Overlay dismiss vs end | Close the floating overlay's own close button | Overlay hides only — countdown keeps running in the menu bar; reopens via "Show Overlay" |
| TC-DASH-15 | P1 | Menu bar shows live countdown | Session active | Menu bar auto-switches to `.sessionCountdown` style (not manually selectable); reverts to the user's stored style the instant the session ends |
| TC-DASH-16 | P1 | End-of-session summary is real, not synthetic | Session ends (early or full) | `digestText` reflects the actual sampled peak-RAM process + peak CPU from `ProcessMonitor`/`AppState`, not placeholder text |
| TC-DASH-17 | P1 | Session appended to Alert History | Session ends | New entry in `FocusHistorySection` (reads `AlertLog` where `kindRaw == "focus"`) — no separate history store |
| TC-DASH-18 | P2 | "Turn on Focus Mode…" opens System Settings | Click it during an active session | Opens the Notifications pane (`com.apple.Notifications-Settings.extension`) — does NOT itself suppress any notification |
| TC-DASH-19 | P1 | Settings → Focus app list | Add/remove an app in Settings → Focus | Persists to `UserDefaults["focusSessionAppConfigs"]` by bundle ID; survives even if the app isn't currently running |
| **Unit** TC-DASH-U3 | P0 | `digestText` — full data, matches documented example | plannedMinutes/actualMinutes/topRAMProcessName/topRAMProcessMB/maxCPUPercent set, not ended early | Exact string match against the doc's own example |
| **Unit** TC-DASH-U4 | P0 | `digestText` — ended early, no RAM data, zero CPU | endedEarly=true, no RAM sample, maxCPUPercent=0 | "(ended early)" suffix; "CPU usage stayed minimal throughout." fallback line |
| **Unit** TC-DASH-U5 | P1 | `digestText` — CPU rounds up to the nearest multiple of 5 | 40 (exact), 41, 55 (exact), 56 | 40%, 45%, 55%, 60% respectively |
| **Unit** TC-DASH-U6 | P1 | `digestText` omits the RAM line when no process was sampled | topRAMProcessName/MB both nil | Output never contains "Top RAM consumer" |
| **Unit** TC-DASH-U7 | P0 | `FocusAppConfig` — id, Equatable, Hashable, Codable round-trip | Various configs | `id == bundleIdentifier`; equal iff both fields match; usable in a `Set`; JSON round-trips |
| **Unit** TC-DASH-U8 | P2 | `FocusDurationPreset` — values and labels | — | Exactly `{25, 50}`; `label` formats as "N min" |

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
