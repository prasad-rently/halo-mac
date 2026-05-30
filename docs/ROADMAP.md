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

## Future Ideas (F-016 → F-030)

Brainstormed during v2.0 planning. Full cards with rationale, data sources, and integration points are in `docs/FEATURE_ROADMAP.md`. Grouped by theme below.

---

### Theme A — Privacy & Security

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-016 | **Permission Auditor** | ~3 d | Full map of every app's TCC permissions (mic, camera, screen recording, full disk access). Risk-flags excessive grants. Deep-links to System Settings pane per permission. |
| F-017 | **Network Traffic Monitor** | ~5 d | Live per-app, per-domain network activity table. Flags telemetry/tracker domains from a bundled list. Read-only — no blocking. Complements existing Network section. |
| F-018 | **Privacy Data Exposure Scanner** | ~3 d | Scans Downloads/Documents/Desktop for files containing API keys, credit card numbers, SSH private keys, SSNs. Regex-based, entirely on-device. Results grouped by risk level. |
| F-019 | **Security Posture Dashboard** | ~1.5 d | Checklist of 8 macOS security settings: FileVault, Gatekeeper, SIP, Secure Boot, Find My, Firewall, auto-updates, login window. One-click deep-links. Security Score feeds into health score. |

---

### Theme B — Intelligent Insights

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-020 | **S.M.A.R.T. Disk Health Monitor** | ~3 d | IOKit-based drive health via S.M.A.R.T. attributes: health %, temperature, TBW, reallocated sectors, power-on hours. Lifespan estimate vs manufacturer TBW rating. Alerts on degradation. |
| F-021 | **App Usage & Screen Time Analytics** | ~3 d | Tracks active foreground time per app using NSWorkspace notifications. Weekly bar chart, context-switch score, "background hog" list. All local — no cloud. |
| F-022 | **Time Machine Backup Health Monitor** | ~1.5 d | Last backup time, destination free space, 30-day backup-frequency heatmap. Alert if no backup in 48 h. "Back Up Now" button via `tmutil`. |
| F-023 | **Memory Leak & App Bloat Tracker** | ~3 d | Per-app RAM sparkline (2-hour rolling window). Flags monotonically-growing apps as "Possible leak". Inline Restart button. Alert when any app exceeds configurable threshold. |

---

### Theme C — Cleanup & Storage

| ID | Feature | Effort | Summary |
|----|---------|--------|---------|
| F-024 | **Browser Cleaner** | ~2 d | Detects Safari/Chrome/Firefox/Edge/Brave/Arc. Per-browser checklist: HTTP cache, GPU shader cache, history, cookies, crash reports. Master "Clean All" + per-browser buttons. |
| F-025 | **Duplicate Photos Finder (pHash)** | ~5 d | Perceptual hash clustering for near-duplicate images — same photo at different compressions/crops/sizes. Side-by-side comparison, auto-selects best copy. PhotoKit + loose files. |
| F-026 | **Downloads Folder Organiser** | ~2 d | Categorises ~/Downloads by type + size. Cross-references .dmg/.pkg installers with installed apps — marks "safe to remove". Stale files list. Optional sort-into-subfolders. |
| F-030 | **iCloud Storage Analyser** | ~4 d | Donut chart of iCloud quota by category. Drill-down into iCloud Drive files by size. Savings opportunities: large evictable files, duplicate synced files, old device backups. |

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
- F-024 Browser Cleaner (~2 d)
- F-026 Downloads Organiser (~2 d)
- F-029 Scheduled Reports (~2 d)

**Core differentiators** (medium effort, highest strategic value):
- F-016 Permission Auditor
- F-020 S.M.A.R.T. Disk Health
- F-027 Snippet Manager
- F-030 iCloud Storage Analyser

**Ambitious long-term** (high effort, strong market positioning):
- F-017 Network Traffic Monitor
- F-023 Memory Leak Tracker
- F-025 Duplicate Photos Finder (pHash)

---

## Mobile Platform Expansion

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
