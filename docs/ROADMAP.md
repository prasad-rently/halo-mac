# Halo — Roadmap

Feature status and future plans. For the detailed iteration pipeline see `docs/FEATURE_ROADMAP.md`.
For the iOS & Android platform feature mapping see `docs/MOBILE_PLATFORM_FEATURES.md`.

---

## Completed Features (shipped)

- [x] Dashboard with live health score + metric cards
- [x] Cleanup module — all 10 `CleanupKind` categories
- [x] Protection module — real threat detection via `SignatureDatabase` (45 definitions, auto-updates)
- [x] Performance module — real login item enumeration via `LoginItemScanner` (LaunchAgent/Daemon plists)
- [x] Applications module — installed app list + deep uninstall (12 leftover paths via `AppScanner`)
- [x] Files module — SpaceLens + Duplicate Finder (SHA-256) + Large Files
- [x] Clipboard module — history (500 items), filter, pin, delete
- [x] Clipboard quick-picker overlay (⌘⇧V global shortcut)
- [x] Menu Bar Extra — 4 display styles (icon / text stats / mini bar / dot)
- [x] Onboarding flow (permissions + menu bar style + scan schedule + login item)
- [x] Settings (shortcut recorder, analytics opt-in, scheduled scan config)
- [x] macOS Widget — Small / Medium / Large sizes
- [x] Widget live data pipeline via App Group (60-second refresh)
- [x] HaloTests — DuplicateDetector + Clipboard unit tests
- [x] Dual entitlements (debug non-sandboxed, release sandboxed)
- [x] XPC Helper target (F-002 — privileged ops protocol)
- [x] SignatureDatabase (F-004 — bundled + HTTPS delta updates)
- [x] Sentry crash reporting (F-005 — opt-in, DSN from Info.plist)
- [x] Background Smart Scan scheduling (F-006 — NSBackgroundActivityScheduler)
- [x] Alert history log (F-011 — 50-item persistent in-app log)
- [x] PDF report export (F-012 — 4-page A4 PDF via PDFKit + CoreText)
- [x] Launch at Login toggle (F-014 — SMAppService.mainApp)
- [x] Custom scan schedule — day + hour picker (F-015)
- [x] Reorderable sidebar modules — drag-to-reorder with `UserDefaults` persistence (v2.1)
- [x] Performance module polish — battery health cycle-aware, real free RAM via `host_statistics64`, Top Processes spinner fix, VPN false-positive fix, speed test improvements, Login Items "Manage All" (v2.1)
- [x] Applications module fixes — `NSMetadataItem`-based last-used date, real uninstall with confirmation dialog and `trashItem` (v2.1)
- [x] Future feature roadmap documented — 15 ideas (F-016 → F-030) across 4 themes (v2.1)
- [x] Quick Actions module (v2.2) — `⌘⇧A` floating picker, 15 predefined actions, custom bash/script support, privilege escalation via macOS auth dialog, live execution log with output streaming
- [x] Quick Actions Phase 1 expansion (v3.0) — 24 new shell-based actions (39 total), 3 new categories (Developer, Files, Clipboard), covering system maintenance, network utils, dev tools, clipboard transforms
- [x] Quick Actions Phase 2 expansion (v3.0) — 29 new actions (70 total), 2 new categories (Creative, Media), covering creative suite cache cleanup, clipboard transforms, media/image/video utilities
- [x] Quick Actions Phase R1 expansion (v4.0) — 37 new actions (107 total), 3 new categories (Dock & Desktop, Display, Audio), covering Dock tinker (spacers, animations, orientation), display/screenshot controls, audio/mic management, system junk cleanup (resource forks, font cache, logs, symlinks, QuickLook, Launch Services), developer cache cleanup (CocoaPods, Gradle, Docker, pip, Homebrew)
- [x] Scheduled Reports & Weekly Digest (F-029) — hourly `MetricsHistory` store powering a new 7-day health-score sparkline on the Dashboard; opt-in Weekly Digest local notification (day/hour picker reusing the Scheduled Scans pattern) summarising health trend, disk-free delta, scans completed, and threats flagged from `AlertLog`; PDF report share via `NSSharingServicePicker` and a "View Report" notification action
- [x] Port Manager module (v4.0) — F-034: dedicated sidebar module with `PortScanner` actor, list/kill open TCP/UDP ports, named ports with friendly labels, configurable kill signals (ask/SIGTERM/SIGKILL), copy lsof/kill commands, 5s auto-refresh, search/sort
- [x] Downloads Manager (v4.0) — F-026: "Downloads" tab in Files module with age-based grouping (Today/Week/Month/Older/Stale), type-based grouping, installer cross-reference with installed apps ("Safe to remove"), one-click stale cleanup, organize into subfolders by type, search/filter, breakdown bar visualization
- [x] Customizable Menu Bar Format Strings (v4.0) — F-036: 5th "Custom" display style with user-editable format strings, 11 tokens ({cpu}, {ram}, {disk}, {battery}, {net_down}, {net_up}, {health}, etc.), 5 preset templates (Minimal/Standard/Full/Network/Battery), live preview, clickable token insertion grid
- [x] Celebration & Delight Moments (v4.0) — F-037: Canvas particle overlay with 4 animation types (green sparkle burst for healthy scan, blue floating particles for space recovered >1GB, expanding ring pulse for scan complete, green checkmark flash for action success), CelebrationManager singleton, toggleable via Settings, non-blocking overlay
- [x] Code Snippet Beautifier (v4.0) — F-038: native ray.so equivalent with regex-based SyntaxHighlighter (14 languages), 8 dark themes (Midnight/Noir/Aurora/Sunset/Ocean/Forest/Candy/Ice), CodeBeautifierView sheet with live preview, auto-detect language from clipboard, customizable padding/background/chrome/line numbers, PNG export at 2x/4x via NSHostingView render, copy to clipboard, "Beautify Code" action in Clipboard category
- [x] Auto-Quit Idle Apps (v4.0) — F-039: IdleAppMonitor actor tracking app idle state via NSWorkspace.didActivateApplicationNotification + AX window count check, IdleAppsSection in Performance module with enable/disable toggle, configurable timeout (15m/30m/1h/2h), suggest vs auto-quit mode, per-app exclude list, daily stats (apps quit + RAM recovered), quit confirmation dialog, "Quit All" button
- [x] Snippet Manager & Text Expansion (v4.0) — F-027: SnippetManager singleton with 20 bundled starter snippets (Symbols/Date/Dev/Email), SnippetExpander engine with 5 placeholder types ({date}, {time}, {clipboard}, {uuid}, {random:N}), SnippetEditorView sheet with live preview + token insertion buttons, SnippetListSection with search/filter/category chips, ClipboardView gains History/Snippets tab bar, JSON/CSV import/export
- [x] Shareable Action Configurations (v4.0) — F-041: `halo://` URL scheme registered in Info.plist, ActionShareManager singleton handling deep link encode/decode (base64url), ActionImportSheet with script preview + privilege warning, QR code generation via CIFilter, per-action context menu (Copy Share Link, Show QR Code), import/export menu in Actions header (JSON file), `.onOpenURL` handler in HaloApp
- [x] Siri Shortcuts / App Intents (v4.0) — F-042: 8 AppIntents (GetHealthScore, GetCPUUsage, GetBatteryHealth, GetDiskSpace, RunSmartScan, RunAction with HaloAction AppEntity + EntityQuery, GetClipboardHistory with count parameter, ExportReport returning IntentFile PDF), HaloShortcutsProvider with Siri phrases for all 8 intents, AppState.shared static reference for intent access
- [x] Siri Shortcuts / App Intents (v4.0) — F-042: 8 AppIntents (GetHealthScore, GetCPUUsage, GetBatteryHealth, GetDiskSpace, RunSmartScan, RunAction, GetClipboardHistory, ExportReport), HaloShortcutsProvider with Siri phrases, HaloAction AppEntity for action discovery in Shortcuts.app, IntentFile PDF export
- [x] Drive Read & Write Speed Test (v4.1) — F-043 / NFeat-121: "Drive Speed" tab in Files module with `DriveSpeedTester` actor; enumerates internal & external volumes; uncached (`F_NOCACHE`) sequential write+read benchmark with `F_FULLFSYNC` durability flush and incompressible random payload; 3-pass multi-sample run reporting both average (sustained) and optimal (peak) MB/s; Quick/Standard/Thorough sizes (128 MB/512 MB/1 GB); live progress, cancellation, friendly error banner for read-only/permission-denied volumes
- [x] S.M.A.R.T. Disk Health Monitor (v4.1) — F-020: `SMARTDiskMonitor` actor reads real NVMe health data via `diskutil info -plist` (SMART status, temperature, power-on hours/cycles, TBW, available spare, NVMe percentage-used wear indicator, media errors) plus an `IONVMeController` IOKit lookup for serial number; surfaces as a "Drive Health" card in the Files → Drive Speed tab with a lifespan-remaining bar and a 24h temperature sparkline for the internal drive; `AlertManager` rule fires on Warning/Failing status. On this Apple Silicon test machine, ATA-only fields (reallocated/pending sector counts) and the originally-planned manufacturer-TBW lookup table are not applicable/needed — NVMe's own wear-percentage counter replaces the TBW-table approach; every unavailable field renders "Not available on this drive" rather than a fabricated value. See `docs/FEATURE_ROADMAP.md` F-020 "As actually built" for the full breakdown.
- [x] Time Machine Backup Health Monitor (v4.2) — F-022: `TimeMachineMonitor` actor parses `tmutil destinationinfo`/`latestbackup`/`listbackups`/`status` (read-only); `BackupHealthCard` on the Dashboard shows last backup time, destination free space bar, and a 30-day GitHub-style heatmap (green/amber/red/gray-for-no-data); "Back Up Now" calls `tmutil startbackup`; honest "Time Machine isn't set up" empty state with a Settings deep link when no destination is configured (verified live on the dev machine, which has no Time Machine destination); `AlertManager.evaluateBackup` fires a recurring daily alert once a configured backup is 48h+ stale
- [x] Memory Leak & App Bloat Tracker (v4.2) — F-023: `MemoryTrendTracker` extends `ProcessMonitor` with per-app RAM sampling (every 30s, rolling 2-hour window, persisted as JSON in Application Support — not SQLite, matching this codebase's existing JSON-over-UserDefaults convention); "Memory Trends" sub-section below Top Processes in the Performance module with per-app sparklines; "Possible memory leak" badge after >1 hour of monotonic growth (15% drop-from-peak or a 5-minute observation gap resets the streak); confirmed terminate+relaunch "Restart App" button on flagged apps; per-app RAM alert (default 2 GB, user-configurable) wired into the existing `AlertManager`
- [x] App Usage & Screen Time Analytics (v4.1) — F-021: `AppUsageTracker` singleton tracks per-app foreground time via `NSWorkspace` activation notifications + a 30 s sampling timer (RAM correlation, context-switch counts); "App Usage Insights" card on the Dashboard below the health ring with a top-5-apps bar chart (`Charts`), "Background Hogs" list (8h+ running, never activated), context-switches/hour, and week-over-week trend; UserDefaults+JSON rolling 14-day store (no SQLite — matches `AlertLog`'s pattern); off-by-default opt-in toggle in Settings; explicit "time Halo has been running" honesty caption everywhere, since no third-party macOS API can read real system Screen Time history
- [x] Focus Session Companion (v4.1) — F-028: `FocusSessionCard` on the Dashboard with 25/50/custom-minute presets and a pre-session confirmation dialog; `FocusSessionManager` hides (never quits) a user-configured app list via `NSRunningApplication.hide()`/`unhide()`; floating `NSPanel` countdown overlay + automatic `MenuBarDisplayStyle.sessionCountdown` menu bar mode; end-of-session summary sampled every 5s from the real `ProcessMonitor` actor + `AppState.cpuUsage`, delivered via notification and logged to `AlertLog` (`kindRaw: "focus"`, surfaced in a new "Focus History" section); Settings → Focus tab to manage the hide list. **Scoping note:** the idea sheet's "suppress notifications" bullet was dropped as infeasible — no public macOS API lets a third-party app toggle system Focus/DND or silence other apps' banners — and replaced with an honest "Turn on Focus Mode…" deep link to System Settings instead of faking the capability
- [x] Security Posture Dashboard (v4.2) — F-019: `SecurityPostureScanner` actor in the Protection module checks FileVault, Gatekeeper, Application Firewall, and Automatic Updates via read-only `Process` calls; SIP, Secure Boot, Find My Mac, and Login Window surface as an honest "check manually" state (no reliable non-interactive read exists) rather than a guessed verdict; 0–100 score feeds into `AppState.systemHealthScore` at a quarter-weight, never penalizing unverifiable checks
- [x] Privacy Data Exposure Scanner (v4.2) — F-018: "Sensitive Data Scanner" section in the Protection module with `PrivacyExposureScanner` actor recursively scanning Downloads/Documents/Desktop (iCloud Drive opt-in, off by default) via `privacy-patterns.json`-driven `PrivacyPatternDatabase`; Luhn-validated credit card numbers, exact-prefix AWS/GitHub/Stripe keys, exact SSH private-key headers, and SSN patterns; binary/>10MB files skipped; results grouped by risk (Critical/Warning/Info) with redacted-preview-only findings — no raw secret is ever logged or persisted; "Reveal in Finder" only, no delete/quarantine path
- [x] Permission Auditor (v4.2) — F-016: `PermissionAuditor` actor in the Protection module attempts a real per-app read of `TCC.db` via `sqlite3`; when readable (non-sandboxed/Full Disk Access), replaces the category-card grid with a per-category expandable list of real app grants, a risk flag for non-browser/non-communication apps holding Screen Recording or Accessibility, per-app "Revoke" deep-links into System Settings, and an "X of Y apps excessive" summary; when unreadable (sandboxed release, no Full Disk Access), falls back honestly to the original category-card-only grid with an explanatory banner — never a fabricated per-app audit
- [x] iCloud Drive Analyzer (v4.1) — F-030, shipped scoped down from the original "iCloud Storage Analyser" card: no public API exists for third-party apps to read a user's total iCloud account quota or a category breakdown (Drive/Photos/Backups/Mail), so the donut chart, quota progress bar, and old-device-backups detector were all dropped as infeasible. What shipped instead is a real **local** analyzer: "iCloud Drive" tab in the Files module with `ICloudDriveScanner` actor enumerating `~/Library/Mobile Documents/` (iCloud Drive's on-disk sync mirror), real folder/file sizes and modified dates, real per-item sync status (on this Mac / downloading / uploading / iCloud-only) via `URLResourceKey.ubiquitousItemDownloadingStatusKey`, breadcrumb drill-down, Reveal in Finder, and confirmed Move to Trash. See `docs/FEATURE_ROADMAP.md` F-030 "As actually built" for the full feasibility writeup
- [x] Duplicate Photos Finder / Similar Photos (v4.1) — F-025: DCT-based 64-bit perceptual hash (pHash) via `PerceptualDuplicateDetector` actor; Hamming-distance union-find clustering (UI-adjustable ≤1–20 bit threshold, default 8); "Similar Photos" tab in Files module scans `~/Pictures`/`~/Downloads`/`~/Desktop` (or a chosen folder) for loose-file near-duplicates, cluster grid with "recommended keep" auto-selection and `trashItem`-only deletion behind confirmation. Also ships a real, entitlement-wired PhotoKit path (Photos Library scan + `PHAssetChangeRequest.deleteAssets`) that is **not yet runtime-tested** — needs a permission-grant pass on a real device before it's considered verified.
- [x] Browser Cleaner — F-024: "Browsers" tab in Cleanup module with `BrowserCleanerScanner` actor; per-category checklist (HTTP cache, GPU shader cache, browsing/download history, cookies, sessions, crash reports, site data) for Safari/Chrome/Arc/Brave/Edge/Opera/Vivaldi/Firefox; paths verified live for Safari/Chrome/Arc, long-stable documented paths for the rest; per-category review sheet, "Clean All Browsers" + per-browser buttons, `trashItem`-only deletion
- [x] Network Traffic Monitor (v4.2) — F-017: `NetworkTrafficMonitor` actor sub-section in the Performance module's Network card; real outbound socket table via `lsof -i -n -P` (per-app, remote IP:port, protocol, last-seen); real per-app session byte totals via `nettop -P -L 1`, joined to connections by PID (not by name — `lsof` and `nettop` truncate process names to different lengths); best-effort cached reverse-DNS hostname resolution (`getnameinfo` with `NI_NAMEREQD`, never fabricated) against a bundled 40-domain tracker list (`tracker-domains.json`) for suspicious-domain flagging; filter by app name, sort by recency/app/traffic volume; "Top talker" session summary; UI explicitly labels hostnames "best-effort" and unresolved IPs are never flagged. Read-only — no blocking, no kernel extension.

---

## Skipped (user decision)

| Item | Reason |
|------|--------|
| StoreKit 2 ProManager (F-003) | User chose to skip in-app purchases |
| App Store submission assets (F-007) | User chose to skip |
| iCloud Clipboard Sync (F-013) | Depends on F-003 (Pro tier); skipped |

---

## Future / Remaining Items

### 1. StoreKit 2 ProManager

**Why:** Monetisation. The app is free with a Pro upgrade.

**What to build:**
- `Core/ProManager.swift` — `@MainActor final class ProManager: ObservableObject`
- Product IDs: `com.halo.pro.annual` (₹999/yr), `com.halo.pro.lifetime` (₹2,499)
- `AppState.isPro: Bool` is already wired — `ProManager` just needs to set it
- Use `StoreKit.Product.products(for:)` and `Transaction.currentEntitlement(for:)` for restore

**Gating:**
- Clipboard history cap: free = 20 items, pro = 500
- Smart Scan: free = once/week, pro = unlimited
- Protection / Duplicate Finder: pro only

**Files to create:**
```
Core/ProManager.swift
Features/Paywall/PaywallView.swift
```

---

### 2. App Store Submission Assets

**Checklist:**
- [ ] Screenshots: 1440×900 for each of the 5 required App Store screenshots
  - Dashboard (health ring + metrics)
  - Cleanup (scan results)
  - Clipboard (history + quick picker)
  - Files (duplicate finder)
  - Widget (large size on desktop)
- [ ] App Preview video: 30-second MP4 showing key flows
- [ ] Privacy policy URL: `https://halo.mac/privacy`
- [ ] Support URL: `https://halo.mac/support`
- [ ] Release/production entitlements review: ensure `Halo.entitlements` (sandboxed) is used for the archive scheme
- [ ] `PrivacyInfo.xcprivacy` — declare all API usage (NSPasteboard, IOKit, FileManager, NSWorkspace)
- [ ] Notarisation: `xcrun notarytool submit Halo.pkg --apple-id … --team-id R7S39UR27F`
- [ ] Replace `SENTRY_DSN_PLACEHOLDER` in `Info.plist` with real Sentry DSN (production build pipeline only — never commit real DSN)

---

### 3. iCloud Clipboard Sync

**Why:** Power users want clipboard history across their Mac and iPhone/iPad.

**Approach:** `CloudKit` private database — each `ClipboardItem` becomes a `CKRecord`. Use `CKQuerySubscription` for push-based sync. Requires `com.apple.developer.icloud-container-identifiers` entitlement.

**Complexity:** High — out of scope until Pro tier is established.

---

### 4. Sentry DSN — Production Setup

Before any release:
1. Create a Sentry project at sentry.io
2. Copy the DSN
3. Set `Info.plist["SentryDSN"]` in the release build pipeline (CI/CD secret injection — **never** commit to source)
4. Verify `enableAnalytics` opt-in flow works end-to-end

---

### 5. Signature Database — Production Endpoint

`SignatureDatabase.checkForUpdate()` currently hits `https://api.halo.mac/signatures/latest.json`. To activate:
1. Host the JSON at that URL (or configure a CDN)
2. Implement server-side versioning (`version` field in JSON)
3. Consider certificate pinning via `URLAuthenticationChallenge` for added security
4. Schedule delta updates on a regular cadence (weekly recommended)

---

## Raycast-Inspired Features (F-031 → F-042) — v4.0 Execution Plan

> Source: Analysis of [raycast/extensions](https://github.com/raycast/extensions) (2,962 extensions, 7.5k stars) and [raycast/ray-so](https://github.com/raycast/ray-so) (8 web tools). Full analysis in `docs/RAYCAST_ANALYSIS.md`. Full execution cards in `docs/FEATURE_ROADMAP.md`.

### Execution Phases

#### Phase R1 — Quick Action Expansion (1.5 days total)

*Three batches of shell actions added to `ActionLibrary.swift`. No new views, no new models. Ship all three in one session.*

| ID | Feature | Effort | Actions Added | New Total |
|----|---------|--------|---------------|-----------|
| F-031 | **Dock & Desktop Tinker Actions** | 0.5 d | 14 (spacers, animation, orientation, auto-hide, reset) | 84 |
| F-032 | **Display & Audio Quick Actions** | 0.5 d | 11 (dark mode, screenshots, mic mute, volume, DND) | 95 |
| F-033 | **System Junk & Dev Cache Cleaner Actions** | 0.5 d | 12 (resource forks, font cache, logs, CocoaPods, Gradle, Docker, pip, brew) | 107 |

**Result:** Halo goes from 70 → 107 predefined actions across 13 categories (3 new: Dock & Desktop, Display, Audio). Immediate value with zero infrastructure changes.

#### Phase R2 — High-Value Feature Views (6.5 days total)

*Three features that add visible new capabilities. Each is a 2–2.5 day build with a new view + viewmodel.*

| ID | Feature | Effort | What It Adds |
|----|---------|--------|-------------|
| F-034 | **Port Manager** | 2.5 d | Dedicated port view: list/kill open ports, named ports ("React Dev → 3000"), configurable kill signals, copy lsof/kill commands |
| F-026 | **Downloads Folder Organiser & Manager** | 2.5 d | "Downloads" tab in Files: age + type grouping, installer cross-ref, stale cleanup, auto-organize *(merged F-035 into existing F-026)* |
| F-036 | **Customizable Menu Bar Format Strings** | 2 d | User-editable format strings with tokens (`{cpu}`, `{ram}`, `{battery}`, `{net_down}`), preset templates, live preview |

**Depends on:** F-031–F-033 shipped. No inter-dependencies within this phase.

#### Phase R3 — Differentiators (7 days total)

*Features that no other macOS utility offers. Position Halo as uniquely comprehensive.*

| ID | Feature | Effort | What It Adds |
|----|---------|--------|-------------|
| F-037 | **Celebration & Delight Moments** | 1.5 d | Canvas particle animations on significant events (healthy scan, space recovered, action complete) |
| F-038 | **Code Snippet Beautifier** | 3 d | Native ray.so: syntax-highlighted code → beautiful PNG export. 8 themes, 12 languages, 2x/4x export |
| F-039 | **Auto-Quit Idle Apps** | 2.5 d | Smart resource reclamation: detect idle apps (no windows), suggest/auto-quit, RAM recovery tracking |

**Depends on:** F-034–F-036 shipped. F-037 has no dependencies and can start anytime.

#### Phase R4 — Platform Integration (9.5 days total)

*Strategic investments that create long-term value through sharing, automation, and ecosystem integration.*

| ID | Feature | Effort | What It Adds |
|----|---------|--------|-------------|
| F-027 | **Snippet Manager & Text Expansion Engine** | 3.5 d | Keyword-triggered snippets with `{date}`, `{clipboard}`, `{uuid}` placeholders, collections, starter packs, CSV import *(merged F-040 into existing F-027)* |
| F-041 | **Shareable Action Configurations** | 2 d | `halo://action/BASE64` deep links, QR code export, JSON import/export for custom actions |
| F-042 | **Siri Shortcuts / App Intents** | 4 d | 8 intents: health score, CPU, battery, disk, scan, run action, clipboard, export report. Siri-invocable |

**Depends on:** F-037–F-039 shipped.

---

### Full Timeline

```
Phase R1 (1.5 days) ─── F-031, F-032, F-033 ───→  107 actions, 13 categories
     │
Phase R2 (7 days) ──── F-034, F-026, F-036 ───→  Port Manager + Downloads + Menu Bar format strings
     │
Phase R3 (7 days) ──── F-037, F-038, F-039 ───→  Celebrations + Code Beautifier + Auto-Quit
     │
Phase R4 (9.5 days) ── F-027, F-041, F-042 ───→  Snippets + Shareable Actions + Siri Shortcuts
```

**Total: 10 net-new features · ~25 days · 37 new actions + 4 new views + 1 new module + 8 Siri intents**

> **Note:** F-035 (Downloads Manager) was merged into F-026 (Downloads Folder Organiser). F-040 (Snippet/Text Expansion) was merged into F-027 (Snippet Manager). See duplicate analysis in this document and full cards in `FEATURE_ROADMAP.md`.

---

## Upcoming / Planned (NFeat-122 → NFeat-127)

User-requested features, briefed and awaiting detailed discussion before implementation. Full briefing cards (intent, references, privacy model, open questions) in `docs/FEATURE_ROADMAP.md`. Cross-cutting principle: **Bring Your Own Backend** — every cloud feature uses the user's own **configurable Firebase** project (no shared/default backend), keeping Halo private-by-design as an open-source app.

| ID | NFeat | Feature | Platform | Depends on | Ref |
|----|-------|---------|----------|-----------|-----|
| F-044 | 122 | Shared SMS Console — mobile syncs SMS → user's Firebase → desktop console | Desktop + Mobile | Firebase, F-049 | SMSArchiver |
| F-045 | 123 | Cross-Device Clipboard Sync via configurable Firebase | Desktop + Mobile | Firebase, Clipboard | — |
| F-046 | 124 | AI Querying — connect leading cloud AI providers (BYO key) | Desktop | none | — |
| F-047 | 125 | On-Device AI & Custom RAG — scripts/regex/quick answers, file-grounded RAG, model + GPU choice | Desktop | none | — |
| F-048 | 126 | Personal Expenditure Tracker — approx spend from bank SMS (F-044 data) | Desktop | F-044 | Hamza |
| F-049 | 122/123/127 | Halo Mobile App — device-side of SMS sync, clipboard sync, HaloShare | Mobile | F-044, F-045, F-050 | — |
| F-050 | 127 | HaloShare Mobile ↔ Desktop / Mobile ↔ Mobile (extend LocalSend v2.1) | Desktop + Mobile | HaloShare | LocalSend |

> **Status:** 🗓 Planned — briefings captured; each to be specced individually before coding. **NFeat-121 (F-043 Drive Speed Test) is already ✅ shipped.**

---

## Future Ideas (F-016 → F-030)

Brainstormed during v2.0 planning. Full cards with rationale, data sources, and integration points are in `docs/FEATURE_ROADMAP.md`. Grouped by theme below.

---

### Theme A — Privacy & Security

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-017 | **Network Traffic Monitor** | ~5 d | Live per-app, per-domain network activity table. Flags telemetry/tracker domains from a bundled list. Read-only — no blocking. Complements existing Network section. |
| F-016 | **Permission Auditor** | ~3 d | Full map of every app's TCC permissions (mic, camera, screen recording, full disk access). Risk-flags excessive grants. Deep-links to System Settings pane per permission. |
| F-018 | **Privacy Data Exposure Scanner** | ~3 d | Scans Downloads/Documents/Desktop for files containing API keys, credit card numbers, SSH private keys, SSNs. Regex-based, entirely on-device. Results grouped by risk level. |
| F-019 | **Security Posture Dashboard** | ~1.5 d | Checklist of 8 macOS security settings: FileVault, Gatekeeper, SIP, Secure Boot, Find My, Firewall, auto-updates, login window. One-click deep-links. Security Score feeds into health score. |

---

### Theme B — Intelligent Insights

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-021 | **App Usage & Screen Time Analytics** | ~3 d | Tracks active foreground time per app using NSWorkspace notifications. Weekly bar chart, context-switch score, "background hog" list. All local — no cloud. |
| F-020 | **S.M.A.R.T. Disk Health Monitor** | ~3 d | IOKit-based drive health via S.M.A.R.T. attributes: health %, temperature, TBW, reallocated sectors, power-on hours. Lifespan estimate vs manufacturer TBW rating. Alerts on degradation. |
| F-022 | **Time Machine Backup Health Monitor** | ~1.5 d | Last backup time, destination free space, 30-day backup-frequency heatmap. Alert if no backup in 48 h. "Back Up Now" button via `tmutil`. |
| F-023 | **Memory Leak & App Bloat Tracker** | ~3 d | Per-app RAM sparkline (2-hour rolling window). Flags monotonically-growing apps as "Possible leak". Inline Restart button. Alert when any app exceeds configurable threshold. |
| F-022 | **Time Machine Backup Health Monitor** | ~1.5 d | Last backup time, destination free space, 30-day backup-frequency heatmap. Alert if no backup in 48 h. "Back Up Now" button via `tmutil`. |

---

### Theme C — Cleanup & Storage

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-024 | **Browser Cleaner** | ~2 d | Detects Safari/Chrome/Firefox/Edge/Brave/Arc. Per-browser checklist: HTTP cache, GPU shader cache, history, cookies, crash reports. Master "Clean All" + per-browser buttons. |
| F-025 | **Duplicate Photos Finder (pHash)** | ~5 d | Perceptual hash clustering for near-duplicate images — same photo at different compressions/crops/sizes. Side-by-side comparison, auto-selects best copy. PhotoKit + loose files. |
| F-026 | **Downloads Folder Organiser** | ~2 d | Categorises ~/Downloads by type + size. Cross-references .dmg/.pkg installers with installed apps — marks "safe to remove". Stale files list. Optional sort-into-subfolders. |

---

### Theme D — User Productivity

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-027 | **Snippet Manager** | ~3 d | Promotes clipboard items to permanent labelled snippets with tags and collections. ⌘⇧V picker gains a Snippets tab. Persists across reboots, searchable. Evolution of existing Clipboard module. |
| F-028 | **Focus Session Companion** | ~3 d | Timed focus sessions (25/50/custom min). Auto-quits distracting apps, suppresses notifications, switches menu bar to session countdown. End-of-session efficiency summary. |
| F-029 | **Scheduled Reports & Weekly Digest** | ~2 d | Weekly macOS notification summarising health score trend, top storage growers, high-RAM apps, backup status, threats. Optional PDF attachment via existing ReportGenerator. |

---

### Recommended Sequencing

**Quick wins** (low effort, immediate value — implement first):
- F-019 Security Posture Dashboard (~1.5 d)
- F-022 Time Machine Backup Health (~1.5 d)
- F-026 Downloads Organiser (~2 d)

**Core differentiators** (medium effort, highest strategic value):
- F-016 Permission Auditor
- F-020 S.M.A.R.T. Disk Health
- F-027 Snippet Manager

**Ambitious long-term** (high effort, strong market positioning):
- F-017 Network Traffic Monitor
- F-023 Memory Leak Tracker
- F-025 Duplicate Photos Finder (pHash)
- F-023 Memory Leak Tracker

---

## Mobile Platform Expansion

> **Mobile development is driven by [`docs/HALO_MOBILE_ROADMAP.md`](HALO_MOBILE_ROADMAP.md)** — the authoritative feature backlog + governance (feasibility study required before any port; updated whenever desktop gains a feature).

Full research and platform-specific feature mapping documented in **`docs/MOBILE_PLATFORM_FEATURES.md`**.

### Summary
| Platform | Fully Feasible | Partially Feasible | Not Feasible |
|----------|---------------|-------------------|--------------|
| **iOS** | 8 features | 4 features | 11+ features |
| **Android** | 9 features | 5 features | 7+ features |

### Mobile-Only Features Identified
- **iOS:** Battery Charge Optimiser, iCloud Backup Health, Dynamic Island Scan Progress, Shortcut Integration
- **Android:** APK Cache Cleaner, Auto-Start Permission Manager, Storage Permissions Audit, Background App Restrictor

### Recommended Build Stack
- **iOS:** Swift / SwiftUI — extensive code reuse with macOS codebase; target iOS 16.0+
- **Android:** Kotlin / Jetpack Compose; target Android 8.0 (API 26)+
- **Shared logic:** Kotlin Multiplatform (KMP) for scan algorithms, signature matching, models
