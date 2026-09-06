# Halo — Full Manual Test Plan

> **App:** Halo — *Your Mac. Elevated.*
> **Version:** v2.1+ (post-HaloShare / Ports / CodeBeautifier / Snippets)
> **Bundle ID:** `com.halo.mac` · **Min macOS:** 13.0 (Ventura)
> **Document owner:** QA · **Last updated:** 2026-06-10
> **Scope:** Manual + unit test cases for every module, scanner, intent, and shared component in the project.

---

## How to use this document

- Each test case has a **stable ID** (`TC-<MODULE>-<NN>`), **preconditions**, **steps**, **expected result**, and a **priority** (P0 = blocker, P1 = high, P2 = medium, P3 = low).
- Run **P0** cases on every build; **P1** on every release candidate; **P2/P3** on full regression passes.
- Mark each run as **Pass / Fail / Blocked / N-A**, attach screenshots for UI defects, and link the crash report (Sentry) for any crash.
- "Unit testcase" rows describe logic that should be (or is) covered by `HaloTests` and what to assert when verifying manually.

### Test environment matrix

| Dimension | Values to cover |
|-----------|-----------------|
| macOS | 13 Ventura (min), 14 Sonoma, 15 Sequoia |
| Silicon | Apple Silicon (M-series) **and** Intel |
| Build config | Debug (sandbox OFF) + Release (sandbox ON) |
| Display | Single display + multi-display (for DDC/brightness) |
| Permissions | Fresh install (no perms) + fully granted |
| Power | On battery + on AC (for battery/idle tests) |
| Network | Wi-Fi, Ethernet, VPN active, iCloud Private Relay on |

### Global pre-test setup

1. Clean install: delete `~/Applications/Halo.app`, the App Group container, and all `UserDefaults` keys (or use a fresh user account).
2. Build & sign per `CLAUDE.md` → "Build & Sign". Verify `codesign --verify --deep --strict` returns **OK**.
3. Launch Halo; confirm the menu bar icon appears and no crash dialog shows.

---

## 0. Smoke / Build Acceptance

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SMOKE-01 | P0 | App launches | Launch Halo.app | Menu bar icon appears; no crash; main window opens via menu |
| TC-SMOKE-02 | P0 | Code signature valid | `codesign --verify --deep --strict ~/Applications/Halo.app` | Returns OK, exit 0 |
| TC-SMOKE-03 | P0 | Widget registers | `pluginkit -m -i com.halo.mac.widget` | Widget appex is listed |
| TC-SMOKE-04 | P0 | All sidebar modules load | Click each sidebar item | Each view renders without blank screen or spinner-hang |
| TC-SMOKE-05 | P1 | No console errors on idle | Leave app open 5 min, watch Console.app | No repeating exceptions, no runaway logging |
| TC-SMOKE-06 | P1 | Memory stable on idle | Observe in Activity Monitor 10 min | No continuous RAM growth (leak) |
| TC-SMOKE-07 | P1 | Clean quit | Quit via menu | Process terminates; timers invalidated; no zombie |

---

## 1. App Shell & Navigation

**Files:** `HaloApp.swift`, `AppState.swift`, `ContentView.swift`, `BuildToken.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-SHELL-01 | P0 | MenuBarExtra opens window | App running | Click menu bar icon → choose open/dashboard | Main `NavigationSplitView` window appears |
| TC-SHELL-02 | P0 | Sidebar routing | Window open | Click each module in sidebar | Detail pane switches to correct module view |
| TC-SHELL-03 | P1 | Dashboard is default route | Fresh launch open window | — | Dashboard shown first |
| TC-SHELL-04 | P1 | Settings window | App menu → Settings (⌘,) | Open | Settings/Onboarding-style window opens |
| TC-SHELL-05 | P1 | Window restore | Close window (not quit), reopen from menu | — | Reopens to last/again-valid state, no crash |
| TC-SHELL-06 | P2 | Multiple windows | Open window twice | — | No duplicate-state corruption |

### 1.1 Reorderable Sidebar

**Files:** `AppState.moduleOrder`, `ContentView.SidebarView`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SIDEBAR-01 | P1 | Enter edit mode | Tap edit toggle (`slider.horizontal.3`) | Dashboard row hides; label → "Drag to reorder"; rows show `≡` handle, dim to 80% |
| TC-SIDEBAR-02 | P1 | Reorder a module | Drag a module to new position | Order updates visually |
| TC-SIDEBAR-03 | P0 | Order persists | Reorder, quit, relaunch | New order restored from `UserDefaults["moduleOrder"]` |
| TC-SIDEBAR-04 | P1 | Navigation suppressed in edit | While editing, tap a row | No navigation occurs |
| TC-SIDEBAR-05 | P1 | Exit edit mode | Tap `checkmark.circle.fill` | Dashboard reappears; handles hidden; navigation restored |
| TC-SIDEBAR-06 | P0 | Forward-compat new module | Add a new module to enum, load old saved order | New module appended at end, still appears |
| TC-SIDEBAR-07 | P2 | Dashboard always pinned | Try to reorder Dashboard | Dashboard is not in reorderable list; stays pinned |
| **Unit** TC-SIDEBAR-U1 | P1 | `moveModules(from:to:)` | Call with indices | Array mutates correctly, `.dashboard` excluded |
| **Unit** TC-SIDEBAR-U2 | P1 | Persist/restore roundtrip | Save order → decode | Decoded `[AppModule]` equals saved, unknown rawValues skipped |

---

## 2. Dashboard

**Files:** `DashboardView.swift`, `GPUDashboardCard.swift`, `NetworkSparklineCard.swift`, `AppState.calculateHealthScore()`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-DASH-01 | P0 | Health score ring renders | Dashboard open | — | Ring shows 0–100 value, colour-coded (green/amber/red) |
| TC-DASH-02 | P0 | Live metrics update | Watch CPU/RAM/disk/battery cards | Wait ~2s | Values refresh on the 2s metrics timer |
| TC-DASH-03 | P1 | Health score logic | Spike CPU/RAM (run stress) | Observe | Score drops per CPU/RAM/disk/battery thresholds |
| TC-DASH-04 | P1 | GPU card | App on machine with GPU | — | GPU card shows utilisation; graceful if unsupported |
| TC-DASH-05 | P1 | Network sparkline | Generate traffic (download a file) | — | Sparkline shows up/down trend |
| TC-DASH-06 | P1 | Alert history section | After alerts fired | — | Recent `AlertEntry` items listed |
| TC-DASH-07 | P0 | Export Report button | Click Export Report | — | NSSavePanel; PDF generated (see §15) |
| TC-DASH-08 | P2 | Battery card on desktop Mac | Run on Mac mini/Studio | — | Battery card hidden or "No battery" gracefully |
| TC-DASH-09 | P1 | 7-Day Health Trend card (F-029) | Fresh install vs. ≥2 hourly samples | — | Shows honest "collecting samples" placeholder when <2 samples; sparkline + Δ pts once populated |
| **Unit** TC-DASH-U1 | P0 | `calculateHealthScore()` | Feed known CPU/RAM/disk/battery | Returns expected score; clamps 0–100 |
| **Unit** TC-DASH-U2 | P1 | Health thresholds boundary | Values at each threshold edge | Correct deduction at boundaries (off-by-one safe) |
| **Unit** TC-DASH-U3 | P1 | `MetricsSample` Codable roundtrip | Encode/decode with RAM samples | All fields, including nested `ProcessRAMSample`s, preserved |

### 2.1 Backup Health / Time Machine Monitor (F-022)

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

### 2.1 App Usage Insights (F-021)

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

### 2.1 Focus Session (F-028)

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

---

## 3. Cleanup

**Files:** `CleanupView.swift`, `DiskHealthSection.swift`, `FileSystemScanner.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLEAN-01 | P0 | Run cleanup scan | Open Cleanup → Scan | AsyncStream populates categories (caches, logs, etc.) with sizes |
| TC-CLEAN-02 | P0 | Selection + size total | Select categories | Running total of reclaimable space updates |
| TC-CLEAN-03 | P0 | Confirmation before delete | Click Clean | Review sheet appears; nothing deleted until confirmed |
| TC-CLEAN-04 | P0 | Deletion uses Trash | Confirm cleanup of a known file | File moved to Trash (recoverable), NOT permanently removed |
| TC-CLEAN-05 | P1 | Cancel scan | Start scan, cancel mid-way | Scan stops cleanly, partial results discarded/kept consistently |
| TC-CLEAN-06 | P1 | Disk health section | View DiskHealthSection | SMART/health status shown or graceful unavailable message |
| TC-CLEAN-07 | P1 | Empty result | Scan an already-clean system | "Nothing to clean" empty state, no crash |
| TC-CLEAN-08 | P2 | Permission-denied path | Scan a protected dir without perms | Skips gracefully, no crash, logged |
| TC-CLEAN-09 | P1 | Celebration overlay | Complete a cleanup | `CelebrationOverlay` shows success animation |
| **Unit** TC-CLEAN-U1 | P1 | Size aggregation | Sum file sizes | Total equals sum of selected items |
| **Unit** TC-CLEAN-U2 | P0 | trashItem invoked | Mock FileManager | `trashItem(at:)` called, never `removeItem` |

### 3.1 Browsers (F-024 — Browser Cleaner)

**Files:** `BrowserCleanerScanner.swift`, `BrowserCleanerView.swift`

Per-category breakdown (HTTP cache, GPU shader cache, history, cookies, sessions, crash reports, site data, download history) for Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi, and Firefox — a more granular sibling to Protection's whole-browser Privacy Cleaner card. All clearing is `trashItem`-only, gated behind the review sheet.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLEAN-10 | P0 | Browsers tab detects installed browsers | Open Cleanup → Browsers | Only browsers actually present under `/Applications` are listed; "No supported browsers detected" if none |
| TC-CLEAN-11 | P0 | Per-category sizes measured | Browser detected | Each category (Cache, History, Cookies, …) shows a real on-disk size, not zero/guessed |
| TC-CLEAN-12 | P1 | Pre-selection matches data presence | Open review sheet | Only categories with `hasData == true` are pre-selected |
| TC-CLEAN-13 | P0 | Review & Clear confirms before deleting | Click "Review & Clear" on one browser, or "Clean All Browsers" | Review sheet lists in-scope browser(s) + categories; nothing is cleared until "Clear Selected" is clicked |
| TC-CLEAN-14 | P0 / TC-SAFE-02 | Cancel deletes nothing | From the review sheet, click Cancel | Sheet dismisses; no files trashed; sizes unchanged on next re-scan |
| TC-CLEAN-15 | P1 | Per-category toggle | In the review sheet, untoggle one category | That category excluded from "Clear Selected ($SIZE)"; total updates live |
| TC-CLEAN-16 | P0 | Clearing uses Trash, never permanent delete | Confirm "Clear Selected" on a real, disposable category (e.g. HTTP cache) | Files moved to Trash (recoverable) — never `removeItem` |
| TC-CLEAN-17 | P1 | Freed-space banner | After a successful clear | Green "Freed X" banner shows the real freed byte count |
| TC-CLEAN-18 | P1 | Error banner on partial failure | Force a clear error (e.g. permission-denied path) | Amber error banner shows the first error message; doesn't block other categories from clearing |
| TC-CLEAN-19 | P2 | Chromium multi-profile detection | A Chromium browser with 2+ real profiles (Default, Profile 1, …) | All profiles' data included in the category totals, not just Default |
| TC-CLEAN-20 | P2 | Celebration on large recovery | Clear > 1 GB total | `CelebrationManager` triggers `.spaceRecovered` |
| **Unit** TC-CLEAN-U3 | P0 | `candidates(home:)` lists all 8 browsers | — | Exactly 8 entries with correct `/Applications/<Name>.app` paths |
| **Unit** TC-CLEAN-U4 | P0 | `detectBrowsers()` only returns installed browsers | Run on real machine | Every returned profile's `appPath` actually exists |
| **Unit** TC-CLEAN-U5 | P0 | `chromiumProfileDirs` — discovery + fallback | Real profiles present; root unreadable; root readable but no matches | Correct filtered set; `["Default"]` fallback in both failure cases |
| **Unit** TC-CLEAN-U6 | P1 | `firefoxProfileDirs` — discovery + dotfile filtering | Profiles dir with real + dotfile entries | Only non-dotfile profile folders returned; `[]` when the dir doesn't exist |
| **Unit** TC-CLEAN-U7 | P0 | `size(ofPaths:)` — file, directory, multi-path, missing | Single file; nested directory; multiple paths; nonexistent path | Exact byte counts; recursive directory sum; missing paths contribute 0 |
| **Unit** TC-CLEAN-U8 | P0 | `measure(_:)` fills in real sizes | Synthetic profile with a temp-file-backed category | Category `.size` matches the real file size on disk |
| **Unit** TC-CLEAN-U9 | P0 | `clear(_:categories:)` — selective, trashItem-only | Two categories, only one selected | Only the selected category's paths are trashed; the other is untouched; `cleared`/`freed` counts match |

---

## 4. Protection

**Files:** `ProtectionView.swift`, `ProtectionScanner.swift`, `SignatureDatabase.swift`, `signatures.json`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-01 | P0 | Signature DB loads | Launch app | `signatureCount` ≥ 45 from bundle |
| TC-PROT-02 | P0 | Run protection scan | Protection → Scan | Scans complete; threats (if any) listed by kind/risk |
| TC-PROT-03 | P0 | Known signature match | Place file matching a keyword (e.g. `genieo`) | Detected as adware/high |
| TC-PROT-04 | P1 | Clean system | Scan clean machine | No false positives; "No threats" state |
| TC-PROT-05 | P1 | Delta update graceful fail | Block `api.halo.mac` | `checkForUpdate()` fails silently, bundle DB still used |
| TC-PROT-06 | P1 | Cached update wins | Provide newer cached version | Cached signatures merged, higher version used |
| TC-PROT-07 | P0 | Threat removal | Quarantine/remove a detected item | Confirmation sheet; trashItem used |
| **Unit** TC-PROT-U1 | P0 | `matches(keyword:)` hit | Lookup known keyword | Returns correct `(kind, risk)` |
| **Unit** TC-PROT-U2 | P0 | `matches(keyword:)` miss | Lookup unknown | Returns nil |
| **Unit** TC-PROT-U3 | P1 | Case/whitespace handling | Mixed-case keyword | Normalised match works |
| **Unit** TC-PROT-U4 | P1 | JSON schema parse | Load malformed signatures.json | Graceful failure, falls back to bundle |

### 4.1 Permission Auditor (F-016)

**Files:** `PermissionAuditor.swift`, `ProtectionView.swift` (`PermissionsAuditSection`, `PermissionAuditList`, `PermissionGroupRow`, `FullDiskAccessBanner`, `PermissionCard`)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | TCC.db readable — real per-app audit | Grant Halo (or the debug binary) Full Disk Access in System Settings, relaunch, open Protection | "App Permissions" shows the grouped, expandable per-app list (`PermissionAuditList`) instead of the category grid; subtitle reads "Real per-app grants read from this Mac's permission database" |
| TC-PROT-09 | P0 | Risk-flag heuristic — elevated flagged | With FDA granted, a non-browser/non-communication app holds Screen Recording or Accessibility | Its row shows the amber "excessive for this app" label and a warning-triangle icon; the group's "N elevated" badge counts it |
| TC-PROT-10 | P1 | Risk-flag heuristic — browsers/comms exempt | A known browser (e.g. Chrome/Safari) or comms app (e.g. Slack, Zoom) holds Screen Recording or Accessibility | NOT flagged elevated — green checkmark icon, no "excessive" label |
| TC-PROT-11 | P1 | Revoke deep link | Click "Revoke" on a per-app grant row | Opens the matching System Settings privacy pane for that permission kind (e.g. `Privacy_ScreenCapture` for Screen Recording) via `x-apple.systempreferences:` |
| TC-PROT-12 | P0 | Summary badge — "X of Y apps excessive" | View the section header once grants have loaded | Badge reads "N of M apps excessive" (M = unique audited bundle IDs, N = unique bundle IDs with ≥1 elevated grant); amber if N > 0, green if N == 0 |
| TC-PROT-13 | P0 | TCC.db unreadable — honest fallback | Default state: no Full Disk Access (sandboxed/release build, or FDA not granted) | `FullDiskAccessBanner` shows the honest reason text (e.g. "Halo needs Full Disk Access to show per-app grants — showing categories only"); the original 4-column category-card grid renders beneath it, unchanged |
| TC-PROT-14 | P1 | Zero readable grants treated as unavailable | TCC.db opens but every row is denied/undetermined (`auth_value` 0 or 1) | Falls back to `.unavailable("No readable permission grants found…")` — the category grid is shown, never an empty per-app list |
| TC-PROT-15 | P2 | Loading indicator | Observe the section header while `permissionAuditor.run()` is in flight | A small spinner replaces the summary badge; no flash of stale content or crash |
| TC-PROT-16 | P2 | Release/sandboxed build always falls back | Run the sandboxed release build | TCC.db is unreachable by design → category-card view + banner always shown, never the rich list |
| **Unit** TC-PROT-U5 | P0 | Risk heuristic — non-browser elevated | `TCCGrant` for Screen Recording/Accessibility, arbitrary bundle ID | `isElevatedRisk == true` |
| **Unit** TC-PROT-U6 | P0 | Risk heuristic — browser/comm exemption | `TCCGrant` for Screen Recording/Accessibility, known browser/comm bundle ID | `isElevatedRisk == false` |
| **Unit** TC-PROT-U7 | P1 | Risk heuristic — non-eligible kinds | `TCCGrant` for Camera/Microphone/etc. | Never flagged elevated regardless of bundle ID |
| **Unit** TC-PROT-U8 | P0 | Grouping by category | Mixed-kind synthetic grant list | Grants bucket correctly per `PermissionKind`; kinds with no grants have no entry |
| **Unit** TC-PROT-U9 | P0 | "X of Y" count — one excessive app, multiple grants | Same bundle ID: one elevated + one non-elevated grant | Counted once in both total and excessive (no double-count) |
| **Unit** TC-PROT-U10 | P1 | "X of Y" count — zero apps | Empty grant list | `total == 0`, `excessive == 0` |
| **Unit** TC-PROT-U11 | P1 | `.unavailable(reason:)` handled gracefully | `PermissionAuditor.run()` on a machine without Full Disk Access | Returns `.unavailable` with a non-empty reason; never throws or crashes |
### 4.1 Sensitive Data Scanner / Privacy Exposure Scanner (F-018)

**Files:** `PrivacyExposureScanner.swift`, `PrivacyPatternDatabase.swift`, `privacy-patterns.json`, `ProtectionView.swift` (`PrivacyExposureSection`).

Read-only, find-only scan of Downloads/Documents/Desktop (iCloud Drive is opt-in, off by default) for exposed credit card numbers, AWS/GitHub/Stripe keys, SSH private keys, and SSNs. All matching and redaction happen inside `PrivacyPatternDatabase` — the full matched secret never leaves the actor's local scope, and there is no delete/quarantine action, only "Reveal in Finder".

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | Run a scan | Protection → "Run Sensitive Data Scan" | Status cycles idle → scanning (running file count) → complete; findings (if any) grouped by risk |
| TC-PROT-09 | P0 | AWS key detected in a real file | Place a file containing an `AKIA...` key in Downloads | Finding appears, category "AWS Access Key", redacted preview `AKIA••••••••XXXX` |
| TC-PROT-10 | P0 | Credit card number detected | Place a file containing a real-shaped, Luhn-valid card number | Finding appears, category "Credit Card Number", redacted to last 4 only |
| TC-PROT-11 | P1 | Luhn-invalid digit run is NOT flagged | Place a file with a 16-digit non-card number (e.g. an order ID) | No credit-card finding — false-positive guard via Luhn checksum |
| TC-PROT-12 | P0 | SSH private key header detected | Place a file starting with `-----BEGIN OPENSSH PRIVATE KEY-----` | Finding appears; the PEM header itself is shown unredacted (it's a public marker, not a secret) |
| TC-PROT-13 | P1 | SSN detected | Place a file containing `123-45-6789`-shaped text | Finding appears, category SSN, risk Warning, redacted to last 4 |
| TC-PROT-14 | P0 | Clean locations | Scan folders with no sensitive data | "No exposed sensitive data found" empty state |
| TC-PROT-15 | P1 | Binary files skipped | Place a renamed binary with a `.txt` extension containing a real key | Not scanned — null-byte peek heuristic catches it; no finding |
| TC-PROT-16 | P1 | Oversized file skipped | Place a >10 MB file containing a key | Not scanned — size limit enforced |
| TC-PROT-17 | P0 | iCloud Drive off by default | Fresh install, view the toggle | "Include iCloud Drive" toggle is off; iCloud is not scanned unless enabled |
| TC-PROT-18 | P1 | iCloud Drive opt-in | Enable the toggle, run a scan | iCloud Drive's local folder is included in the scan |
| TC-PROT-19 | P0 | Reveal in Finder | Click "Reveal in Finder" on a finding | `NSWorkspace.activateFileViewerSelecting` opens Finder with the file selected — no other action available |
| TC-PROT-20 | P1 | Findings grouped and sorted | Multiple findings across risk levels | Grouped Critical → Warning → Info; within a group, sorted by modified date (newest first) |
| **Unit** TC-PROT-U5 | P0 | AWS key match + redaction | `evaluate(text:)` on AWS example key | Matches `.awsKey`/critical, redacted `AKIA••••••••MPLE` |
| **Unit** TC-PROT-U6 | P0 | GitHub token match + redaction | `evaluate(text:)` on a 36-char `ghp_` token | Matches `.githubToken`/critical, redacted `ghp_••••••••<last4>` |
| **Unit** TC-PROT-U7 | P0 | Stripe secret/publishable key match + redaction | `evaluate(text:)` on `sk_live_`/`pk_live_` keys | Correct category, prefix preserved, last 4 shown |
| **Unit** TC-PROT-U8 | P0 | SSH private key exact match, unredacted | `evaluate(text:)` on a PEM header | Matches `.sshPrivateKey`/critical; preview equals the header verbatim |
| **Unit** TC-PROT-U9 | P0 | SSN match + redaction | `evaluate(text:)` on `123-45-6789` | Matches `.ssn`/warning, redacted `•••-••-6789` |
| **Unit** TC-PROT-U10 | P0 | Luhn-valid card matched, Luhn-invalid rejected | Visa test number vs. sequential digits | First reported as `.creditCard`; second produces no credit-card hit |
| **Unit** TC-PROT-U11 | P1 | Per-pattern match cap | 25 repeated AWS-shaped keys in one text | Exactly 20 hits returned, not 25 |
| **Unit** TC-PROT-U12 | P2 | Plain/empty text produces no hits | Unremarkable text, empty string | Zero hits both times |
| **Unit** TC-PROT-U13 | P1 | Risk severity ordering | Sort `[.info, .warning, .critical]` | Returns `[.critical, .warning, .info]` |
### 4.1 Security Posture Dashboard (F-019)

**Files:** `SecurityPostureScanner.swift`, `ProtectionView.swift` (`SecurityPostureSection` / `SecurityCheckRow`), `Models.swift` (`SecurityCheck`, `SecurityCheckKind`, `SecurityCheckState`), `AppState.swift` (`calculateHealthScore()`).

8 read-only checks via public CLI tools (`fdesetup`, `spctl`, `defaults read`) — no entitlements, no writes, no privilege escalation. 4 are genuinely auto-verified (FileVault, Gatekeeper, Application Firewall, Automatic Updates); 4 have no reliable non-interactive read path on macOS and always surface as `.unknown` with manual-check guidance (SIP, Secure Boot, Find My Mac, Login Window Security) — Halo never guesses these.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | Section renders on Protection load | Open Protection | "Security Posture" section appears below the scanner cards; loading spinner while `loadSecurityPosture()` runs, then all 8 rows render |
| TC-PROT-09 | P0 | FileVault — On | Run on a FileVault-encrypted Mac | Row shows pass state (green check), detail "On — your disk is encrypted at rest." |
| TC-PROT-10 | P0 | FileVault — Off | Run on a Mac with FileVault disabled | Row shows fail state (red X), detail "Off — your disk isn't encrypted." |
| TC-PROT-11 | P1 | FileVault — unreadable | Simulate `fdesetup status` producing unexpected output | Row shows `.unknown` (grey `?`), detail "Couldn't read FileVault status." — never guessed as pass or fail |
| TC-PROT-12 | P0 | Gatekeeper — enabled | `spctl --status` reports assessments enabled | Row shows pass, "Enabled — unsigned apps are blocked by default." |
| TC-PROT-13 | P0 | Gatekeeper — disabled | `sudo spctl --master-disable` | Row shows fail, "Disabled — any app can run unchecked." |
| TC-PROT-14 | P1 | Gatekeeper — unreadable | Non-matching `spctl` output | Row shows `.unknown` |
| TC-PROT-15 | P0 | Application Firewall — on | Enable in System Settings → Network → Firewall | `globalstate` ≠ 0 → row shows pass |
| TC-PROT-16 | P0 | Application Firewall — off | Disable firewall | `globalstate` == 0 → row shows fail |
| TC-PROT-17 | P1 | Firewall — unreadable | `defaults read` returns non-integer / errors | Row shows `.unknown`, never a guessed pass/fail |
| TC-PROT-18 | P0 | Automatic Updates — on | `AutomaticallyInstallMacOSUpdates` = 1 | Row shows pass |
| TC-PROT-19 | P1 | Automatic Updates — off | Value = 0 | Row shows **warn** (amber), not fail — "Off — you'll need to install updates manually." |
| TC-PROT-20 | P1 | Automatic Updates — unreadable | Any other/missing value | Row shows `.unknown` |
| TC-PROT-21 | P0 | SIP — always manual guidance | View SIP row regardless of actual `csrutil status` | Always `.unknown` state with guidance text pointing to System Report / `csrutil status` in Terminal — never a guessed verdict |
| TC-PROT-22 | P0 | Secure Boot — always manual guidance | View Secure Boot row | Always `.unknown`, guidance: "Only viewable from Recovery Mode → Startup Security Utility." |
| TC-PROT-23 | P0 | Find My Mac — always manual guidance | View Find My row | Always `.unknown`, guidance points to System Settings → Apple ID → Find My |
| TC-PROT-24 | P0 | Login Window Security — always manual guidance | View Login Window row | Always `.unknown`, guidance points to Users & Groups → Login Options |
| TC-PROT-25 | P1 | "Fix →" link where a Settings pane exists | Click the arrow-up-right button on FileVault/Gatekeeper/Firewall/Automatic Updates/Find My/Login Window rows | `NSWorkspace.shared.open(_:)` invoked with the correct `x-apple.systempreferences:` URL; no crash |
| TC-PROT-26 | P0 | No "Fix" button for SIP/Secure Boot | Inspect SIP and Secure Boot rows | No arrow-up-right button rendered — `SecurityCheckKind.settingsURL` is `nil` for both, since no System Settings pane exists for either |
| TC-PROT-27 | P0 | Score badge — all pass | All 4 verifiable checks pass | Badge reads `100/100`, green |
| TC-PROT-28 | P1 | Score badge — degraded | One check fails, one warns | Badge reflects `100 - 15 - 7 = 78/100`, amber (50–79 range) |
| TC-PROT-29 | P0 | Score badge — unknowns never drag it down | All 4 manual checks `.unknown` + all 4 verifiable checks pass | Badge stays `100/100` — unknown states contribute zero |
| TC-PROT-30 | P1 | Manual refresh | Click the refresh (↻) button next to the score badge | `loadSecurityPosture()` re-runs; spinner shown briefly, rows update |
| TC-PROT-31 | P0 | Health Score integration — quarter weight | Force `securityScore` to 60 (40 points below full) via a failing check | `AppState.calculateHealthScore()` subtracts `(100 - 60) / 4 = 10` points, not the full 40 |
| TC-PROT-32 | P0 | Health Score integration — never double-penalizes unknowns | All 4 manual checks unknown, all verifiable checks pass | `securityScore == 100`; health score deduction for security is `0` |
| TC-PROT-33 | P2 | Launch-time optimistic default | Kill and relaunch app; check health score before the one-time async scan resolves | `AppState.securityScore` defaults to `100` (never shows a false "unhealthy" score before the check completes) |
| **Unit** TC-PROT-U5 | P0 | `score(for:)` — all pass | Synthetic all-`.pass` array | Returns `100` |
| **Unit** TC-PROT-U6 | P0 | `score(for:)` — single fail / warn | One `.fail` (rest pass); one `.warn` (rest pass) | Returns `85`; returns `93` respectively |
| **Unit** TC-PROT-U7 | P1 | `score(for:)` — multiple fails/warns sum and clamp | 2 fails + 1 warn; all 8 fail | Returns `63`; clamps to `0` (never negative) |
| **Unit** TC-PROT-U8 | P0 | `score(for:)` — all-unknown never penalizes | Synthetic all-`.unknown` array | Returns `100` — the core invariant of this feature |
| **Unit** TC-PROT-U9 | P0 | `score(for:)` — mixed fail/warn + unknown | 1 fail + 7 unknown; 1 warn + 7 unknown | Only the fail/warn counts (`85` / `93`); unknowns contribute nothing to the sum |
| **Unit** TC-PROT-U10 | P2 | `SecurityCheckKind.settingsURL` | Check each of the 8 kinds | `nil` only for `.sip` and `.secureBoot`; non-nil for the other 6 |

---

## 5. Performance

**Files:** `PerformanceView.swift`, `TopProcessesSection.swift`, `CPUCoresSection.swift`, `BatteryDetailSection.swift`, `NetworkDetailSection.swift`, `SensorsSection.swift`, `IdleAppsSection.swift`, monitors (`CPUDetailMonitor`, `ProcessMonitor`, `NetworkDetailMonitor`, `SMCReader`, `LoginItemScanner`, `IdleAppMonitor`)

### 5.1 Processes & CPU

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-01 | P0 | Top processes load | Open Performance | Spinner only on first load; list populates with %CPU/RAM |
| TC-PERF-02 | P1 | CPU/RAM picker | Toggle sort CPU↔RAM | List re-sorts; picker is on its own row, no overlap with Hide/Show |
| TC-PERF-03 | P1 | Per-core CPU | View CPUCoresSection | Each core shows utilisation bar |
| TC-PERF-04 | P1 | Empty state after load | Edge: no processes returned | Empty-state text (not infinite spinner) |
| TC-PERF-05 | P2 | Kill / inspect process | Select a process action | Acts on correct PID; confirmation for kill |

### 5.2 Battery

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-10 | P1 | Battery health label | View on laptop | Cycles <100→Excellent, <300→Good, else capacity ratio |
| TC-PERF-11 | P1 | Cycle/capacity display | — | Shows cycle count + max capacity |
| TC-PERF-12 | P2 | No-battery machine | Run on desktop | Section hidden / "no battery" |
| **Unit** TC-PERF-U1 | P0 | Battery label order | Cycles=50,cap=70% | Returns "Excellent" (cycles factored first) |
| **Unit** TC-PERF-U2 | P1 | Battery label fallback | Cycles=500 | Falls back to capacity ratio bucket |

### 5.3 Network

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-20 | P1 | Live throughput | Download file | Up/down rates update |
| TC-PERF-21 | P0 | VPN true positive | Connect a real VPN (utun + .other) | Shows "VPN active" |
| TC-PERF-22 | P0 | iCloud Private Relay not VPN | Enable Private Relay only | NOT flagged as VPN |
| TC-PERF-23 | P1 | Definitive protocols | ppp/ipsec/tap interface | Flagged as VPN |
| **Unit** TC-PERF-U3 | P0 | VPN two-rule logic | Mock utun+.other vs utun+.wifi | First=VPN, second=not |

### 5.4 Speed Test

**File:** `SpeedTestService.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-30 | P1 | Run speed test | Trigger speed test | Download (25MB), upload (5MB), ping median over 10 reported |
| TC-PERF-31 | P2 | Offline speed test | Disconnect network | Fails gracefully with error message |
| TC-PERF-32 | P2 | Warm-up request | Inspect first request | Warm-up issued before measurement |

### 5.5 Sensors

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-40 | P1 | Sensors on Apple Silicon | View SensorsSection | Either real values or full HaloCard explanation of SMC limits |
| TC-PERF-41 | P2 | Sensors on Intel | View on Intel Mac | Temp/fan values if available |

### 5.6 Login Items

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-50 | P1 | Enumerate login items | View login items | LaunchAgents/Daemons with RunAtLoad/KeepAlive, suspicious-first |
| TC-PERF-51 | P1 | Manage All opens Settings | Click "Manage All" | Opens `com.apple.LoginItems-Settings.extension` |
| TC-PERF-52 | P1 | Toggle Halo login item | Toggle launch-at-login | `SMAppService.mainApp` enabled/disabled reflects |
| **Unit** TC-PERF-U4 | P1 | Suspicious-first sort | Mixed list | Suspicious items sorted to top |

### 5.7 Idle Apps

**Files:** `IdleAppMonitor.swift`, `IdleAppsSection.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-60 | P1 | Detect idle apps | Leave apps idle | Apps consuming resources while idle are listed |
| TC-PERF-61 | P1 | Quit idle app | Action on idle app | App quits / confirmation shown |
| TC-PERF-62 | P2 | No idle apps | All active | Empty state |

### 5.8 Memory Trends (F-023 — Memory Leak & App Bloat Tracker)

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

---

## 6. Applications (Deep Uninstaller)

**Files:** `ApplicationsView.swift`, `AppScanner.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-APP-01 | P0 | Enumerate apps | Open Applications | `/Applications` + `~/Applications` listed with icons/versions |
| TC-APP-02 | P1 | Leftover detection | Select an app | 12 standard support paths scanned and shown |
| TC-APP-03 | P0 | Uninstall confirmation | Click Uninstall | Confirmation dialog before any deletion |
| TC-APP-04 | P0 | Uninstall trashes | Confirm uninstall of test app | App bundle + selected leftovers → Trash (recoverable) |
| TC-APP-05 | P1 | Error banner | Uninstall protected/SIP app | Error banner, no crash |
| TC-APP-06 | P1 | "Unused" accuracy | App used today | NOT marked unused |
| TC-APP-07 | P1 | "Unused" unknown date | App with no Spotlight date | `isUnused=false` (unknown ≠ unused) |
| TC-APP-08 | P1 | "Unused" true | App unused >90 days | Marked unused |
| **Unit** TC-APP-U1 | P0 | `isUnused` nil date | lastUsed=nil | Returns false |
| **Unit** TC-APP-U2 | P1 | `isUnused` 91 days | date 91d ago | Returns true |
| **Unit** TC-APP-U3 | P1 | `isUnused` 89 days | date 89d ago | Returns false |
| **Unit** TC-APP-U4 | P1 | Leftover path set | Mock fs | All 12 paths checked, only existing returned |

---

## 7. Files (SpaceLens / Duplicates / Large Files)

**Files:** `FilesView.swift`, `DuplicateDetector.swift`, `DownloadsView.swift`, `DownloadsViewModel.swift`

### 7.1 SpaceLens

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-01 | P1 | SpaceLens map | Open SpaceLens tab | Treemap/breakdown of disk usage renders |
| TC-FILE-02 | P1 | Drill into folder | Click a folder | Navigates into subtree, sizes correct |
| TC-FILE-03 | P2 | Reveal in Finder | Right-click item | Opens in Finder |

### 7.2 Duplicates

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-10 | P0 | Duplicate scan | Run on folder with known dupes | 3-phase SHA-256 detection finds true duplicates |
| TC-FILE-11 | P0 | No false dupes | Distinct files same size | NOT flagged (content hash differs) |
| TC-FILE-12 | P0 | Delete dupes via Trash | Select + delete | Confirmation; trashItem; keeps one original |
| **Unit** TC-FILE-U1 | P0 | SHA-256 grouping | Identical content | Grouped as duplicates |
| **Unit** TC-FILE-U2 | P0 | Size pre-filter | Different sizes | Skipped before hashing (perf) |
| **Unit** TC-FILE-U3 | P1 | Single file | One file | No duplicate group emitted |

### 7.3 Downloads Manager

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-20 | P1 | List downloads | Open Downloads view | `~/Downloads` contents listed with size/date |
| TC-FILE-21 | P1 | Sort/filter | Change sort | Re-orders by date/size/type |
| TC-FILE-22 | P1 | Delete download | Delete an item | Confirmation; trashItem |
| TC-FILE-23 | P2 | Large/old highlight | Old large file | Highlighted for cleanup |

### 7.4 Large Files

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-30 | P1 | Find large files | Run scan | Files above threshold listed, descending size |
| TC-FILE-31 | P1 | Delete large file | Delete | Confirmation; trashItem |

### 7.5 Drive Speed Test (F-043 / NFeat-121)

**Files:** `DriveSpeedTester.swift`, `DriveSpeedView.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-FILE-40 | P0 | Volume enumeration | — | Open Files → Drive Speed | Internal boot volume listed + preselected; externals show "External" badge |
| TC-FILE-41 | P0 | Run internal test | Internal selected | Pick Quick → Run | Progress animates Write→Read across 3 passes; live MB/s updates |
| TC-FILE-42 | P0 | Average + optimal results | Test completes | View result cards | Write & Read each show avg and optimal; **optimal ≥ average** |
| TC-FILE-43 | P1 | External drive test | Plug in external, select it | Run | Writes scratch to `<vol>/.HaloSpeedTest/`; results shown; scratch removed after |
| TC-FILE-44 | P1 | Size selection | — | Switch Quick/Standard/Thorough | Data amount in results reflects 128 MB / 512 MB / 1 GB |
| TC-FILE-45 | P1 | Cancel mid-run | Test running | Click Cancel | Stops cleanly; no result; **scratch file removed** (verify no leftover) |
| TC-FILE-46 | P1 | Read-only / denied volume | Read-only or sandbox-blocked volume | Run | Friendly `notWritable` error banner; no crash |
| TC-FILE-47 | P1 | Uncached accuracy | Run read test | Compare read speed | Not RAM-inflated (device-level, `F_NOCACHE` in effect) |
| TC-FILE-48 | P2 | No leftover on error | Force an I/O error | — | Scratch file `unlink`-ed even on failure (defer) |
| TC-FILE-49 | P2 | Controls disabled while running | Test running | — | Volume/size pickers + Run disabled until done |
| **Unit** TC-FILE-U4 | P1 | Size byte amounts | — | Assert `DriveTestSize.bytes` | 128e6 / 512e6 / 1000e6, strictly increasing |
| **Unit** TC-FILE-U5 | P1 | Enumerate internal | — | `availableVolumes()` | Non-empty; ≥1 internal; internals sorted first |
| **Unit** TC-FILE-U6 | P0 | Positive speeds | — | `run(.quick)` on internal | write/read avg > 0; optimal ≥ avg; sampleCount > 0 |
| **Unit** TC-FILE-U7 | P1 | Cancellation throws | — | Cancel then await | Run throws (CancellationError) |

> **Data-safety note:** the benchmark scratch file is Halo's own temp data and is
> `unlink`-ed (not trashed) immediately — the only sanctioned exception to
> `TC-SAFE-01`. Verify no `.HaloSpeedTest` residue remains on external drives
> after any run, cancel, or error.

### 7.6 Similar Photos (F-025 — Duplicate Photos Finder, perceptual hash)

**Files:** `PerceptualDuplicateDetector.swift`, `SimilarPhotosView.swift`

Unlike Exact Duplicates (bit-exact SHA-256), this tab finds *visually* similar images — the same photo re-saved at a different compression level, cropped, or resized still "looks" the same but hashes completely differently under SHA-256. Algorithm: 64px thumbnail → 32×32 grayscale → 2-D DCT → top-left 8×8 low-frequency block, thresholded against its median → 64-bit fingerprint; near-duplicates are images whose fingerprints differ by ≤ the configured Hamming-distance threshold (default 8 of 64 bits). Loose-file deletion is `trashItem`-only, behind a confirmation dialog. The Photos Library scan path is real PhotoKit code but has **not been runtime-verified** this pass (needs a live permission-grant walkthrough) — treat it as "needs a real permission-grant test pass," not "known broken."

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-60 | P0 | Scan default locations | Open Files → Similar Photos → "Scan Pictures" | Scans `~/Pictures`, `~/Downloads`, `~/Desktop`; progress bar animates; settles into clusters or the empty state |
| TC-FILE-61 | P1 | Choose a specific folder | Click "Choose Folder", pick a folder with known near-duplicates | Scans only that folder; clusters correctly group visually-similar images |
| TC-FILE-62 | P1 | Similarity threshold is adjustable | Change the Stepper (1–20) | Lower = stricter (fewer/tighter matches); higher = looser (catches more, more false-positive risk) |
| TC-FILE-63 | P0 | Recommended keep | View a cluster with mixed resolutions | Highest-resolution item is marked "recommended keep"; others marked for deletion |
| TC-FILE-64 | P0 / TC-SAFE-02 | Delete marked requires confirmation | Click "Delete marked" on a cluster | `.confirmationDialog` ("Move N marked photos to Trash?") appears before anything happens |
| TC-FILE-65 | P0 / TC-SAFE-02 | Cancel deletes nothing | From the dialog in TC-FILE-64, click Cancel | No files trashed; cluster and marks unchanged |
| TC-FILE-66 | P0 | Deletion uses Trash | Confirm "Move to Trash" on a disposable test cluster | Files moved to Trash (recoverable) — never `removeItem` |
| TC-FILE-67 | P2 | Non-image files ignored | Folder contains non-image files (docs, videos) | Only recognized image extensions (jpg/jpeg/png/heic/heif/tiff/tif/bmp/gif/webp) are hashed |
| TC-FILE-68 | P2 | Bounded scan | Folder with >20,000 files | Scan caps at 20,000 files, same policy as Exact Duplicates |
| TC-FILE-69 | P3 | Photos Library scan (experimental, unverified) | Click "Scan Photos Library" | System permission prompt appears; after granting, up to 3,000 most-recent assets are hashed; deleting moves assets to Photos' "Recently Deleted" |
| **Unit** TC-FILE-U8 | P0 | `hammingDistance` counts differing bits exactly | Identical hashes; single-bit diff; all-bits-different | 0; 1; 64 |
| **Unit** TC-FILE-U9 | P0 | `detect(in:)` — empty input, non-image files, single image | `[]`; a `.txt` file; one real image | `[]`, `[]`, `[]` respectively (never a 1-item "group") |
| **Unit** TC-FILE-U10 | P0 | `detect(in:)` — clusters identical copies, excludes a distinct image | Two byte-identical file copies + one visually distinct image | One group containing only the identical pair |
| **Unit** TC-FILE-U11 | P0 | `makeGroup` recommends the highest-resolution item | Two synthetic hash results, different pixel dimensions | Higher-resolution item `isRecommendedKeep`; the other `isMarkedForDeletion` |
| **Unit** TC-FILE-U12 | P1 | `makeGroup` breaks a same-resolution tie by most recent | Two synthetic hash results, equal resolution, different `modifiedDate` | The more recently modified item is recommended to keep |
| **Unit** TC-FILE-U13 | P1 | `PhotoSimilarGroup.wastedBytes` excludes the recommended keep | Group of 3 items, one recommended keep | Sum equals the total of the non-kept items only |
### 7.6 iCloud Drive Analyzer (F-030)

**Files:** `ICloudDriveScanner.swift`, `ICloudDriveView.swift`

> **Scope note:** this is a LOCAL analyzer of `~/Library/Mobile Documents/` (the
> on-disk sync mirror), not a full-account iCloud storage report — there is no
> public API for a third-party app's iCloud quota or a Drive/Photos/Backups/Mail
> category breakdown. See `docs/FEATURE_ROADMAP.md` F-030 "As actually built."

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-FILE-50 | P0 | Container enumeration | iCloud Drive set up | Open Files → iCloud Drive | `com~apple~CloudDocs` shown first as "iCloud Drive"; other ubiquity containers listed with derived names |
| TC-FILE-51 | P1 | iCloud Drive not set up | Fresh Mac / iCloud Drive off | Open tab | Friendly "iCloud Drive isn't set up on this Mac" state, no crash |
| TC-FILE-52 | P0 | Drill into a folder | Select a container with subfolders | Click a folder row | Breadcrumb grows; contents of subfolder shown |
| TC-FILE-53 | P1 | Breadcrumb navigation | Drilled 2+ levels deep | Click an earlier breadcrumb segment | Navigates back; deeper segments truncated |
| TC-FILE-54 | P1 | Real per-item sync status | Mix of local / evicted ("Optimise Mac Storage") files | View rows | Status label/icon matches actual state (On This Mac / iCloud Only / Downloading…/Uploading…) |
| TC-FILE-55 | P2 | Reveal in Finder | Any row | Click Reveal | Finder opens with item selected |
| TC-FILE-56 | P0 | Delete requires confirmation | Any row | Click Trash | Confirmation dialog names the file + size, mentions cross-device removal; Cancel deletes nothing (TC-SAFE-02) |
| TC-FILE-57 | P2 | Refresh | After external change (e.g. via Finder) | Click Refresh | Re-scans current container/folder |
| **Unit** TC-FILE-U8 | P1 | `scanDirectory` sizes + sort | Temp dir: 1 file + 1 subfolder | Real sizes (folder summed), sorted largest-first |
| **Unit** TC-FILE-U9 | P2 | `scanDirectory` empty/missing folder | Empty dir / nonexistent URL | Returns `[]`, no crash |
| **Unit** TC-FILE-U10 | P2 | `ICloudContainer.displayName` | `com~apple~CloudDocs`, `com~apple~Pages`, third-party `com~...` | "iCloud Drive" override; Apple/third-party prefixes stripped correctly |
| **Unit** TC-FILE-U11 | P2 | `ICloudSyncStatus` presentation | Each case | Correct label/icon/color mapping |
| **Unit** TC-FILE-U12 | P2 | `ICloudDriveItem.icon` | Various extensions + directory | Extension-based icon; directories always `folder.fill` |
### 7.6 Drive Health / S.M.A.R.T. Monitor (F-020)

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

---

## 8. Clipboard & Snippets

**Files:** `ClipboardView.swift`, `ClipboardMonitor.swift`, `ClipboardQuickPickerView.swift`, `SnippetManager.swift`, `SnippetEditorView.swift`, `SnippetListSection.swift`

### 8.1 Clipboard History

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLIP-01 | P0 | Capture copies | Copy text/URL/code | Items captured, typed (text/url/code colour) |
| TC-CLIP-02 | P0 | Quick picker hotkey | Press ⌘⇧V | Floating NSPanel picker appears |
| TC-CLIP-03 | P0 | Toggle dismiss | Press ⌘⇧V again | Panel dismisses |
| TC-CLIP-04 | P0 | Paste selection | Pick an item | Item pasted into frontmost app |
| TC-CLIP-05 | P1 | 500-item cap | Copy >500 items | Oldest evicted, cap enforced |
| TC-CLIP-06 | P1 | Search history | Type in search | Filters items |
| TC-CLIP-07 | P1 | Delete/clear | Clear history | History emptied; widget snippets cleared |
| TC-CLIP-08 | P2 | URL/code colour coding | Copy a URL then code | Cyan for URL, purple for code |
| **Unit** TC-CLIP-U1 | P1 | Type classification | Feed url/code/plain strings | Correct `ClipboardKind` |
| **Unit** TC-CLIP-U2 | P1 | Dedup consecutive | Copy same twice | Single entry |
| **Unit** TC-CLIP-U3 | P0 | Cap enforcement | Add 501 | Count stays ≤500 |

### 8.2 Snippets

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SNIP-01 | P1 | Create snippet | Add new snippet | Saved, appears in list |
| TC-SNIP-02 | P1 | Edit snippet | Open editor, change | Update persisted |
| TC-SNIP-03 | P1 | Delete snippet | Delete | Removed; confirmation |
| TC-SNIP-04 | P1 | Paste snippet | Use snippet | Content pasted |
| TC-SNIP-05 | P0 | Persistence | Quit/relaunch | Snippets restored from UserDefaults |
| **Unit** TC-SNIP-U1 | P1 | CRUD roundtrip | Create/encode/decode | Equal after roundtrip |

---

## 9. Actions Module

**Files:** `ActionModels.swift`, `ActionLibrary.swift`, `ActionRunner.swift`, `ActionsView.swift`, `QuickActionPickerView.swift`, `CustomActionEditor.swift`, `ActionSettingsStore.swift`, `ActionSettingsTab.swift`, `ActionShareManager.swift`, `VoiceSearchController.swift`

### 9.1 Library & Search

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-01 | P0 | 108 built-ins load | Open Actions | Category tile grid shows all built-in actions |
| TC-ACT-02 | P0 | Quick picker ⌘⇧A | Press ⌘⇧A | Floating picker opens; second press dismisses |
| TC-ACT-03 | P0 | Fuzzy search | Type partial query | AND-logic multi-term match, scored ordering |
| TC-ACT-04 | P1 | Search ranking | Exact vs prefix vs substring | Exact(100)>prefix(80)>substring(60)>subseq(30) |
| TC-ACT-05 | P1 | Usage count ordering | Run an action repeatedly | Sorts higher within equal score |
| **Unit** TC-ACT-U1 | P0 | Fuzzy scorer | Known inputs | Returns expected scores |
| **Unit** TC-ACT-U2 | P1 | All-terms-match | Multi-word, one missing | No match (AND logic) |

### 9.2 Execution

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-10 | P0 | Run shell action | Run "Remove .DS_Store" | Executes via /bin/zsh; stdout streams to ExecutionRow |
| TC-ACT-11 | P0 | Run built-in action | Run "Run Smart Scan" | Calls into AppState correctly |
| TC-ACT-12 | P0 | Privileged action | Run "Flush DNS Cache (sudo)" | osascript admin auth dialog; runs on approve |
| TC-ACT-13 | P1 | Cancel/auth deny | Deny admin prompt | Fails gracefully, marked `.failed` |
| TC-ACT-14 | P1 | Execution history | Run several | History list, most-recent-first, capped at 50 |
| TC-ACT-15 | P1 | Progress indicator | Run long action | Indeterminate (-1) spinner then 1.0 complete |
| TC-ACT-16 | P1 | Output collapse | Expand/collapse ExecutionRow | Output lines toggle |
| **Unit** TC-ACT-U3 | P1 | Multiline→osascript | Multi-line script | Collapsed to `; ` joined |
| **Unit** TC-ACT-U4 | P1 | History cap | Add 51 executions | Count ≤50, oldest dropped |

### 9.3 Custom Actions

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-20 | P1 | Create custom action | Open editor, fill name/icon/keywords/script/sudo | Saved to `UserDefaults["haloCustomActions"]` |
| TC-ACT-21 | P1 | Edit custom action | Modify | Update persisted |
| TC-ACT-22 | P1 | Delete custom action | Remove | Removed; confirmation |
| TC-ACT-23 | P0 | Persistence across update | Relaunch | Custom actions + usage counts (`haloActionUsage`) survive |
| TC-ACT-24 | P1 | Share action | Use ActionShareManager export | Action exported/encoded for share |
| TC-ACT-25 | P1 | Import shared action | Import a shared action file | Action added, validated |

### 9.4 Voice Search & Settings

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-30 | P2 | Voice search | Trigger VoiceSearchController | Mic permission prompt; speech → query |
| TC-ACT-31 | P2 | Voice perm denied | Deny mic | Graceful fallback to text |
| TC-ACT-32 | P1 | Action settings tab | Open ActionSettingsTab | Settings persist via ActionSettingsStore |

### 9.5 Category coverage (spot-check each category runs)

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-ACT-40 | P1 | Xcode actions (4) | Each runs, clears expected caches |
| TC-ACT-41 | P1 | Developer actions (11) | node_modules/npm/yarn/pods/gradle/docker/pip/brew run |
| TC-ACT-42 | P1 | System actions (25) | Each runs (sudo ones prompt) |
| TC-ACT-43 | P1 | Network actions (5) | Speed test/connectivity/IP/Wi-Fi password run |
| TC-ACT-44 | P2 | Files actions (2) | Largest files / eject disks run |
| TC-ACT-45 | P1 | Clipboard actions (15) | JSON/encode/hash/QR/beautify operate on clipboard |
| TC-ACT-46 | P2 | Creative actions (10) | Cache clears for FCP/Resolve/PS/etc. |
| TC-ACT-47 | P2 | Media actions (8) | HEIC→JPEG/optimise/gif/screenshot run |
| TC-ACT-48 | P1 | Halo actions (3) | Smart Scan / Export / Clear Clipboard run |
| TC-ACT-49 | P2 | Dock & Desktop (14) | Spacer/reset/autohide/position changes apply |
| TC-ACT-50 | P2 | Display actions (6) | Dark mode/screenshot/desktop icons toggle |
| TC-ACT-51 | P2 | Audio actions (5) | Mute/volume/DND apply |

---

## 10. Ports Manager

**Files:** `PortScanner.swift`, `PortManagerView.swift`, `PortManagerViewModel.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PORT-01 | P0 | Scan listening ports | Open Ports | `lsof` TCP LISTEN + UDP parsed; dedup; port-sorted |
| TC-PORT-02 | P1 | Process resolution | View entries | pid, process name/path, port, protocol, state shown |
| TC-PORT-03 | P0 | Kill SIGTERM | Kill a test process | SIGTERM sent; process gone; success message |
| TC-PORT-04 | P1 | Force kill SIGKILL | Force kill | SIGKILL sent |
| TC-PORT-05 | P1 | Kill signal preference | Set .ask/.sigterm/.sigkill | Behaviour respects `haloKillSignalPref` |
| TC-PORT-06 | P1 | Named port mapping | Assign a name to a port | Persisted to `haloNamedPorts`, shown as friendlyName |
| TC-PORT-07 | P2 | Refresh | Re-scan | List updates after process changes |
| TC-PORT-08 | P2 | Kill failure | Kill protected pid | Failure message, no crash |
| **Unit** TC-PORT-U1 | P0 | lsof parser | Sample lsof output | Correct `[PortEntry]`, deduped, sorted |
| **Unit** TC-PORT-U2 | P1 | Named port persist | Save/load | Mapping roundtrips |

---

## 11. Code Beautifier

**Files:** `CodeBeautifierView.swift`, `CodeTheme.swift`, `SyntaxHighlighter.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CODE-01 | P1 | Paste + highlight | Paste code | Syntax highlighting renders per language |
| TC-CODE-02 | P1 | Theme switch | Change CodeTheme | Colours update live |
| TC-CODE-03 | P1 | Beautify/format | Format JSON/code | Pretty-printed output |
| TC-CODE-04 | P1 | Copy result | Copy formatted | Clipboard gets formatted text |
| TC-CODE-05 | P2 | Language detect | Paste different langs | Highlighter adapts/falls back |
| TC-CODE-06 | P2 | Large input | Paste huge file | No hang; reasonable perf |
| **Unit** TC-CODE-U1 | P1 | Highlighter tokens | Known snippet | Correct token ranges/colours |
| **Unit** TC-CODE-U2 | P1 | Format invalid JSON | Bad JSON | Error surfaced, no crash |

---

## 12. HaloShare (LocalSend-compatible P2P transfer)

**Files:** `LocalShareManager.swift`, `LocalShareClient.swift`, `LocalShareServer.swift`, `MulticastDiscovery.swift`, `TLSManager.swift`, `TransferPowerAssertion.swift`, `LocalShareModels.swift`, `LocalShareView.swift`, `ReceiveConsentView.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-SHARE-01 | P0 | Device discovery | Two devices on same LAN | Open HaloShare both | Peers appear via multicast discovery |
| TC-SHARE-02 | P0 | Send file | Peer discovered | Send a file | Recipient gets consent prompt; on accept, transfer completes |
| TC-SHARE-03 | P0 | Receive consent | Incoming transfer | — | `ReceiveConsentView` prompts before accepting |
| TC-SHARE-04 | P0 | Reject transfer | Incoming transfer | Decline | Transfer aborts, no file written |
| TC-SHARE-05 | P1 | TLS/PIN security | Inspect connection | — | TLS via TLSManager; protocol v2.1 handshake |
| TC-SHARE-06 | P1 | Multi-file transfer | Send several files | — | All files received intact (checksum) |
| TC-SHARE-07 | P1 | Large file | Send >1GB | — | Progress accurate; power assertion keeps awake; completes |
| TC-SHARE-08 | P1 | Cancel mid-transfer | Cancel | — | Both ends clean up; partial file removed |
| TC-SHARE-09 | P1 | LocalSend interop | Send to/from official LocalSend app | — | Interoperable (protocol v2.1) |
| TC-SHARE-10 | P2 | Network drop | Disconnect Wi-Fi mid-send | — | Error surfaced; no hang |
| TC-SHARE-11 | P1 | Power assertion released | Complete/cancel | — | `TransferPowerAssertion` released (no battery drain after) |
| TC-SHARE-12 | P2 | Discovery off network | No peers | — | Empty state, periodic re-scan |
| **Unit** TC-SHARE-U1 | P1 | Model encode/decode | LocalShareModels JSON | Roundtrip matches protocol schema |
| **Unit** TC-SHARE-U2 | P1 | Discovery announce parse | Sample multicast payload | Correct peer model |
| **Unit** TC-SHARE-U3 | P1 | Checksum verify | Known bytes | Mismatch detected |

---

## 13. Menu Bar Display Styles

**Files:** `MenuBarView.swift` (`MenuBarDisplayStyle`, `MenuBarIconView`, `MenuBarStyleSelector`, `MenuBarFormatRenderer`)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MENU-01 | P0 | Icon style | Set style=icon | Halo icon only |
| TC-MENU-02 | P1 | Text stats | Set textStats | "CPU 42% · RAM 61%" live |
| TC-MENU-03 | P1 | Mini bar | Set miniBar | 4px capsule bars for CPU/RAM |
| TC-MENU-04 | P1 | Dot | Set dot | Green/amber/red per pressure |
| TC-MENU-05 | P0 | Custom format | Set custom + format string | Tokens render live values |
| TC-MENU-06 | P1 | All 11 tokens | Use each token | `{cpu}{ram}{ram_used}{ram_total}{disk}{disk_free}{battery}{net_down}{net_up}{health}{temp}` all resolve |
| TC-MENU-07 | P1 | 5 presets | Apply each preset | Minimal/Standard/Full/Network/Battery render correctly |
| TC-MENU-08 | P1 | Live preview | Edit format in selector | Preview updates as you type |
| TC-MENU-09 | P0 | Style persists | Change style, relaunch | `menuBarDisplayStyle`/`menuBarFormatString` restored |
| **Unit** TC-MENU-U1 | P0 | Format renderer | format + values | All tokens substituted, unknown tokens left/blank safely |
| **Unit** TC-MENU-U2 | P1 | Pressure→dot colour | CPU/RAM thresholds | Correct colour bucket |

---

## 14. Smart Scan & Scheduler

**Files:** `SmartScanView.swift`, `ScanCoordinator.swift`, `ScanScheduler.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SCAN-01 | P0 | Run Smart Scan | Trigger | ScanCoordinator orchestrates cleanup+protection+files; results aggregate |
| TC-SCAN-02 | P1 | Progress/stages | Watch | Stage-by-stage progress shown |
| TC-SCAN-03 | P1 | Schedule config | Set frequency/weekday/hour | Persists `scanFrequency`/`scanPreferredWeekday`/`scanPreferredHour` |
| TC-SCAN-04 | P0 | Next fire date | Set weekly Mon 3AM | "Next: Monday at 3:00 AM" displayed |
| TC-SCAN-05 | P1 | Reschedule on pref change | Change schedule | Re-schedules via UserDefaults.didChange |
| TC-SCAN-06 | P1 | Background result type | Trigger scheduled run | Uses `.finished`/`.deferred` (not `.success`) |
| TC-SCAN-07 | P1 | Scheduled fire | Set near-term schedule, wait | Scan runs at scheduled time |
| **Unit** TC-SCAN-U1 | P0 | `nextScanDate` daily | freq=daily,hour=3 | Next 3AM occurrence |
| **Unit** TC-SCAN-U2 | P0 | `nextScanDate` weekly | weekday=2,hour=3 | Next Monday 3AM |
| **Unit** TC-SCAN-U3 | P1 | `nextScanDate` monthly | freq=monthly | Correct next month date |
| **Unit** TC-SCAN-U4 | P1 | Default values | No prefs set | weekly/Mon(2)/3AM defaults |

---

## 15. Alerts, Report, & Notifications

**Files:** `AlertLog.swift`, `AlertManager.swift`, `ReportGenerator.swift`

### 15.1 Alerts

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ALERT-01 | P0 | Fire alert | Trigger condition | `UNUserNotification` posted + `AlertLog` entry added at index 0 |
| TC-ALERT-02 | P1 | 50-item cap | Fire >50 | Oldest dropped, cap enforced |
| TC-ALERT-03 | P1 | Mark read | markRead/markAllRead | isRead toggles, persisted |
| TC-ALERT-04 | P1 | Clear all | clearAll | Log empties; persisted |
| TC-ALERT-05 | P1 | Persistence | Relaunch | Log restored from `haloAlertLog` |
| **Unit** TC-ALERT-U1 | P0 | append at index 0 | append 3 | Newest first |
| **Unit** TC-ALERT-U2 | P0 | Cap at 50 | append 51 | Count=50 |
| **Unit** TC-ALERT-U3 | P1 | Codable roundtrip | encode/decode AlertEntry | Equal |

### 15.2 PDF Report

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-RPT-01 | P0 | Generate report | Export Report | 4-page A4 PDF created |
| TC-RPT-02 | P1 | Page content | Open PDF | P1 cover+ring, P2 system, P3 storage/battery, P4 alerts |
| TC-RPT-03 | P0 | Save panel | Choose location | NSSavePanel saves PDF to chosen path |
| TC-RPT-04 | P1 | Snapshot accuracy | Compare to dashboard | Values match captured snapshot |
| TC-RPT-05 | P2 | Empty alert history | No alerts | P4 renders empty gracefully |
| **Unit** TC-RPT-U1 | P1 | Snapshot capture | from AppState | All fields populated on MainActor |
| **Unit** TC-RPT-U2 | P1 | Page bounds | DrawablePDFPage | `bounds(for:)` returns A4 rect |

### 15.3 Weekly Digest (F-029)

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

---

## 16. Siri Shortcuts / App Intents

**Files:** `Halo/Intents/*` (8 intents + provider)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-INT-01 | P1 | Intents discoverable | Shortcuts app → Halo | All 8 intents listed |
| TC-INT-02 | P1 | GetHealthScore | Run intent | Returns Int 0–100 |
| TC-INT-03 | P1 | GetCPUUsage | Run | Returns Double % |
| TC-INT-04 | P1 | GetBatteryHealth | Run | Returns String summary |
| TC-INT-05 | P1 | GetDiskSpace | Run | Returns String summary |
| TC-INT-06 | P1 | RunSmartScan | Run | Triggers scan, returns result string |
| TC-INT-07 | P1 | RunAction (entity) | Pick HaloAction | Runs action, returns output |
| TC-INT-08 | P1 | GetClipboardHistory | count=5 | Returns up to 5 strings |
| TC-INT-09 | P1 | ExportReport | Run | Returns IntentFile (PDF) |
| TC-INT-10 | P0 | App-not-running guard | Quit app, run intent | `.appNotRunning` error (no crash) |
| TC-INT-11 | P2 | Siri phrases | Speak phrase | Voice invocation works |
| TC-INT-12 | P1 | Action entity query | Shortcuts suggests actions | `suggestedEntities()` from ActionLibrary |
| **Unit** TC-INT-U1 | P1 | count clamp 1–10 | count=0 / count=99 | Clamped to range |
| **Unit** TC-INT-U2 | P1 | actionNotFound | bad stableKey | `.actionNotFound` thrown |

---

## 16.1 AI Assistant (F-046 — cloud providers)

**Files:** `Halo/Features/AIAssistant/*` · **E2E:** `HaloUITests/AIAssistantUITests.swift`

> BYO-key contract (US-5): with **no** API key configured, the assistant must
> surface guidance and make **no** network call. Never store or log keys outside
> the Keychain.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-AI-01 | P1 | Module renders | Open AI Assistant | Composer + provider/model selector appear |
| TC-AI-02 | P1 | Provider picker | Open picker | Claude / OpenAI / Gemini selectable |
| TC-AI-03 | P0 | No key → no call | With no key set, send a prompt | "No API key set…" guidance; **no** request sent |
| TC-AI-04 | P2 | Quick-ask overlay | Press ⌘⇧I | Floating quick-ask panel toggles (manual — global hotkey) |
| TC-AI-05 | P0 | Tool safety classes | Model calls tools | `.read` tools auto-run; `.act` tools (run_smart_scan, export_health_report) confirm first |
| TC-AI-06 | P1 | Key stored in Keychain | Add a key in AI settings | Persisted to Keychain (`com.halo.mac.ai`), never plaintext on disk |
| **Unit** | — | Agent loop | — | Covered by `HaloTests/AIAssistantTests.swift` (provider parsing, loop, confirmation gate) |

---

## 17. Widget

**Files:** `HaloWidget.swift`, `HaloWidgetBundle.swift`, `HaloSharedData.swift`, `AppState.writeWidgetData()`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-WIDG-01 | P0 | Widget in gallery | App in /Applications, add widget | All 3 sizes appear in gallery |
| TC-WIDG-02 | P0 | Data pipeline | Validate plist (see CLAUDE.md cmd) | `haloWidgetData` present and fresh (≤2s stale) |
| TC-WIDG-03 | P0 | Reload cadence | Observe over an hour | reloadAllTimelines ~60/hr, never exhausts budget |
| TC-WIDG-04 | P1 | Small/medium/large | Add each size | Each renders correct layout |
| TC-WIDG-05 | P1 | Clipboard snippets | Copy items | Top 5 snippets forwarded to widget |
| TC-WIDG-06 | P1 | containerBackground guard | Run macOS 13 vs 14 | No crash; `if #available(macOS 14)` respected |
| TC-WIDG-07 | P1 | Token sync | Compare widget colours to app | Inlined widget tokens match DesignSystem |
| TC-WIDG-08 | P2 | Stale on app-quit | Quit app | Widget shows last data, no crash |
| **Unit** TC-WIDG-U1 | P0 | HaloWidgetData Codable | encode/decode | Backward-compatible roundtrip |
| **Unit** TC-WIDG-U2 | P1 | Timeline entries | getTimeline | 5 entries × 1 min apart |

---

## 18. Onboarding & Settings

**Files:** `OnboardingView.swift`, `@AppStorage`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ONB-01 | P1 | First-run onboarding | Fresh install | Onboarding flow shows |
| TC-ONB-02 | P1 | Scan schedule setup | Set schedule in onboarding | Persists to scan UserDefaults |
| TC-ONB-03 | P1 | Menu bar style setup | Choose style | Persists `menuBarDisplayStyle` |
| TC-ONB-04 | P1 | Login item setup | Toggle launch-at-login | `SMAppService.mainApp` reflects |
| TC-ONB-05 | P1 | Analytics opt-in | Toggle analytics | `enableAnalytics` set; default false |
| TC-ONB-06 | P2 | Skip onboarding | Skip | App usable with defaults |
| TC-ONB-07 | P2 | Re-run onboarding | From settings | Re-displays flow |
| TC-ONB-08 | P1 | Weekly Digest setup (F-029) | Toggle "Send Weekly Digest" in Settings | Persists `weeklyDigestEnabled`/`weeklyDigestFrequency`/`weeklyDigestWeekday`/`weeklyDigestHour`; see §15.3 for full digest coverage |

---

## 19. Hotkeys

**File:** `HotkeyManager.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-HOT-01 | P0 | ⌘⇧V clipboard | Press | Clipboard picker toggles |
| TC-HOT-02 | P0 | ⌘⇧A actions | Press | Action picker toggles |
| TC-HOT-03 | P0 | AX permission (debug) | Fresh debug build | Prompts for Accessibility; works once granted |
| TC-HOT-04 | P1 | No conflict | Both hotkeys registered | Independent, no interference |
| TC-HOT-05 | P1 | Hotkey after sleep | Wake from sleep, press | Still functional |

---

## 20. System Controls (Mic/Camera/DDC/Display)

**Files:** `SystemControlsManager.swift`, `MicCameraControlsView.swift`, `DDCHelper.swift`, `HelperClient.swift`, `GPUMonitor.swift`, `SMCReader.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SYS-01 | P1 | Mic toggle | Toggle mic | Microphone muted/unmuted |
| TC-SYS-02 | P1 | Camera privacy | Open camera settings | Opens privacy settings panel |
| TC-SYS-03 | P1 | DDC brightness | Adjust external monitor | DDCHelper sets brightness on external display |
| TC-SYS-04 | P2 | DDC unsupported display | Non-DDC monitor | Graceful no-op / message |
| TC-SYS-05 | P1 | Privileged helper | Action needing helper | HelperClient/XPC escalates correctly |
| TC-SYS-06 | P2 | GPU monitor | View GPU stats | Real utilisation or graceful fallback |
| TC-SYS-07 | P2 | Multi-display DDC | Two external monitors | Targets correct display |

---

## 21. Cross-Cutting / Non-Functional

### 21.1 Permissions

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-PERM-01 | P0 | No-permission launch | App launches; features needing perms prompt, don't crash |
| TC-PERM-02 | P1 | Full Disk Access | Cleanup/scan reach protected paths only with FDA |
| TC-PERM-03 | P1 | Notifications denied | Alerts still logged to AlertLog; no notification banner |
| TC-PERM-04 | P1 | Accessibility revoked mid-session | Hotkeys stop; graceful, re-prompt on next use |

### 21.2 Sentry

**File:** `HaloApp.configureSentry()`

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-SENTRY-01 | P0 | Disabled by default | `enableAnalytics=false` → Sentry inactive, no events |
| TC-SENTRY-02 | P1 | Opt-in activates | Enable analytics → Sentry initialises |
| TC-SENTRY-03 | P0 | DSN placeholder in source | `Info.plist["SentryDSN"]=="SENTRY_DSN_PLACEHOLDER"` (no real DSN committed) |
| TC-SENTRY-04 | P1 | No PII | `sendDefaultPii=false`; debug sampleRate 0.0 |

### 21.3 Resilience / Concurrency

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-RES-01 | P1 | Rapid module switching | No crash, no actor deadlock |
| TC-RES-02 | P1 | Concurrent scans | Two scans queued — coordinated, no data race |
| TC-RES-03 | P1 | Background→MainActor updates | UI updates from actors via MainActor.run, no purple runtime warnings |
| TC-RES-04 | P2 | Low disk space | Operations degrade gracefully |
| TC-RES-05 | P2 | System sleep/wake | Timers resume; metrics continue |

### 21.4 Accessibility & UI

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-A11Y-01 | P2 | Dark-only colours | No adaptive colours; consistent dark theme everywhere |
| TC-A11Y-02 | P2 | VoiceOver labels | Key controls have accessibility labels |
| TC-A11Y-03 | P2 | Keyboard navigation | Tab/arrow navigation works in lists |
| TC-A11Y-04 | P3 | Dynamic type | Text scales reasonably |

### 21.5 Data Safety (mandatory rules)

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-SAFE-01 | P0 | Never removeItem | Audit: every deletion path uses `trashItem` |
| TC-SAFE-02 | P0 | Confirmation everywhere | Every destructive action shows a review sheet first |
| TC-SAFE-03 | P0 | Recoverable deletes | Deleted items appear in Trash, restorable |
| TC-SAFE-04 | P0 | Cancel deletes nothing | Cancelling any confirmation leaves all files + Trash unchanged (automated via `HaloTestFixtures` canaries) |
| TC-SAFE-05 | P0 | Tests never touch real files | E2E destructive flows act only on dummy fixtures in a temp sandbox; a guarded real path (e.g. Calculator.app) is asserted byte-for-byte untouched |

> **Automation note.** `TC-SAFE-02/04/05` are enforced end-to-end by the XCUITest
> suite in [`HaloUITests/`](../HaloUITests/README.md): the `HaloTestFixtures`
> harness seeds dummy canary files, snapshots real paths + the Trash, drives each
> destructive flow to its confirmation, cancels, and asserts nothing was deleted.
> `PortsUITests` spawns its own listener process as a live kill-canary.

---

## 22. Regression Checklist (per release)

Run all **P0** plus these high-risk areas after any change:

- [ ] Widget data pipeline still fresh (TC-WIDG-02/03)
- [ ] Signing order correct, app verifies (TC-SMOKE-02)
- [ ] No `removeItem` introduced (TC-SAFE-01)
- [ ] Hotkeys ⌘⇧V / ⌘⇧A both work (TC-HOT-01/02)
- [ ] VPN vs Private Relay detection (TC-PERF-21/22)
- [ ] Battery health ordering (TC-PERF-U1)
- [ ] Smart Scan schedule next-date (TC-SCAN-U1/U2)
- [ ] HaloShare round-trip with LocalSend (TC-SHARE-09)
- [ ] Sentry DSN placeholder intact (TC-SENTRY-03)
- [ ] All deletions confirm + trash (TC-SAFE-02/03)

---

## 23. Defect reporting template

```
ID:            DEF-<n>
Test case:     TC-<MODULE>-<NN>
Severity:      Blocker / Critical / Major / Minor
Build:         <commit / version>
Environment:   <macOS, silicon, config>
Preconditions: <state>
Steps:         <numbered>
Expected:      <expected result>
Actual:        <observed>
Evidence:      <screenshot / Console log / Sentry link>
Frequency:     Always / Intermittent (<x/y>)
```

---

### Coverage summary

| Area | Modules covered |
|------|-----------------|
| Core UI | Shell, Sidebar, Dashboard, Onboarding |
| Cleanup/Files | Cleanup, SpaceLens, Duplicates, Downloads, Large Files, Disk Health, iCloud Drive Analyzer |
| Security | Protection, SignatureDatabase, Permissions, Sentry, Data Safety |
| Performance | Processes, CPU, Battery, Network, Speed Test, Sensors, Login Items, Idle Apps, GPU |
| Productivity | Clipboard, Snippets, Actions (108), Ports, Code Beautifier |
| Connectivity | HaloShare (LocalSend P2P) |
| System integration | Menu Bar, Widget, Siri Intents, Hotkeys, System Controls (Mic/Cam/DDC) |
| Automation | Smart Scan, Scheduler, Alerts, PDF Report, Weekly Digest |

> **Total numbered test cases:** 200+ across 23 sections, including dedicated unit-test (`-U`) rows for all pure-logic components (health score, fuzzy search, VPN detection, battery label, signature lookup, duplicate hashing, scheduler dates, format renderer, lsof parser, Codable roundtrips).
