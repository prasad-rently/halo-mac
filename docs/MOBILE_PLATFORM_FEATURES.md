# Halo — Mobile Platform Feature Analysis

> Research document mapping all current (F-001 → F-015 + v2.1) and planned (F-016 → F-030)
> Halo features to iOS and Android equivalents. Used for planning a "Halo Mobile" product line.
>
> **Date:** 2026-05-29 | **macOS baseline:** Halo v2.1

---

## 1. Platform Philosophy & Key Blockers

Halo's value on macOS comes from deep system access: IOKit hardware sensors, LaunchAgent
enumeration, full filesystem traversal, privileged XPC helper, global keyboard hooks, and
NSPasteboard polling. Mobile OSes deliberately remove these capabilities to protect users.

### Fundamental Blockers

| Blocker | iOS | Android | Impact |
|---------|-----|---------|--------|
| **App sandbox** | All apps confined to own container | Scoped storage (Android 11+) limits filesystem access | Kills Cleanup, Applications, Browser Cleaner |
| **No privileged daemon** | No XPC / launchd equivalent | No root; no Device Admin without MDM | Kills RAM purge, DNS flush, maintenance tasks |
| **No startup item access** | iOS apps cannot launch at boot (background modes only) | RECEIVE_BOOT_COMPLETED, but Doze/battery kills persistent daemons | Kills Login Item Scanner |
| **No hardware sensor API** | IOKit / SMC entirely absent | HardwarePropertiesManager (API 24+) is device-dependent | Kills SMC sensors, S.M.A.R.T. disk |
| **No clipboard history API** | UIPasteboard only exposes current item | ClipboardManager provides change events, not history | Limits Clipboard module |
| **No global keyboard hooks** | AXIsProcessTrusted + NSEvent not available | No equivalent for arbitrary global shortcuts | Kills ⌘⇧V quick-picker |
| **No traditional file system** | No /Applications, ~/Library, ~/Downloads as user-visible FS | No /Library/LaunchAgents, no Trash | Kills deep uninstall, Cleanup, Login Scanner |

---

## 2. Full Feature Portability Matrix

### Current Features (Shipped)

| Feature | macOS Status | iOS | Android | Notes |
|---------|-------------|-----|---------|-------|
| Dashboard (health score + metrics) | ✅ | 🟡 Partial | 🟡 Partial | Metrics available but less granular |
| Cleanup — caches/logs/trash | ✅ | ❌ No | ❌ No | Sandbox blocks all system-level cleanup |
| Protection — malware signature scan | ✅ | 🟡 Adapted | ✅ Full | Scan scope limited on iOS (no LaunchAgents) |
| Performance — CPU/RAM monitor | ✅ | 🟡 Partial | 🟡 Partial | APIs exist; less detail than Darwin kernel calls |
| Performance — battery health | ✅ | 🟡 Partial | 🟡 Partial | iOS hides cycle count; Android exposes coarse health |
| Performance — top processes | ✅ | ❌ No | 🟡 Limited | iOS: no public process API; Android: UsageStats only |
| Performance — login items | ✅ | ❌ No | ❌ No | No launchd / LaunchAgent concept on mobile |
| Performance — VPN detection | ✅ | ✅ Full | ✅ Full | NetworkExtension / ConnectivityManager |
| Performance — speed test | ✅ | ✅ Full | ✅ Full | Socket-based, fully portable |
| Applications — installed app list | ✅ | ❌ No | 🟡 Partial | iOS: no enumeration; Android: PackageManager |
| Applications — deep uninstall | ✅ | ❌ No | ❌ No | Sandbox prevents leftover cleanup |
| Files — SpaceLens (disk treemap) | ✅ | 🟡 App-only | 🟡 Partial | Mobile: own sandbox / accessible dirs only |
| Files — Duplicate Finder (SHA-256) | ✅ | 🟡 Photos-only | ✅ Full | iOS: PhotoKit; Android: MediaStore + SHA-256 |
| Files — Large Files | ✅ | 🟡 App-only | 🟡 Partial | Accessible directories only |
| Clipboard — history (500 items) | ✅ | 🟡 In-app only | 🟡 In-app only | No system history API on either platform |
| Clipboard — quick-picker (⌘⇧V) | ✅ | ❌ No | ❌ No | No global hotkey API |
| Menu Bar Extra | ✅ | ❌ No | ❌ No | Status bar widgets differ by platform |
| Widget (WidgetKit) | ✅ | ✅ Full | 🟡 Adapted | iOS WidgetKit identical; Android: App Widgets |
| Smart Scan scheduler | ✅ | ✅ Full | ✅ Full | BGTaskScheduler / WorkManager |
| Alert history + notifications | ✅ | ✅ Full | ✅ Full | UNUserNotification / NotificationManager |
| PDF report export | ✅ | ✅ Full | 🟡 Adapted | iOS: PDFKit identical; Android: iTextG / PDFDocument |
| Launch at Login toggle | ✅ | ❌ No | 🟡 Partial | iOS: N/A; Android: RECEIVE_BOOT_COMPLETED |
| Reorderable sidebar modules | ✅ | ✅ Full | ✅ Full | Pure UI, fully portable |
| Settings / onboarding | ✅ | ✅ Full | ✅ Full | @AppStorage / SharedPreferences |

### Planned Features (F-016 → F-030)

| ID | Feature | iOS | Android | Notes |
|----|---------|-----|---------|-------|
| F-016 | Permission Auditor | 🟡 Partial | 🟡 Partial | iOS/Android have permissions; no TCC.db access |
| F-017 | Network Traffic Monitor | ❌ No | 🟡 Limited | iOS sandbox; Android: NetworkStatsManager + root |
| F-018 | Privacy Data Exposure Scanner | ❌ No | ❌ No | No loose .env/SSH keys in mobile sandboxes |
| F-019 | Security Posture Dashboard | 🟡 Adapted | 🟡 Adapted | Different checks per platform |
| F-020 | S.M.A.R.T. Disk Health | ❌ No | ❌ No | No traditional rotating/SSD storage on mobile |
| F-021 | App Usage & Screen Time Analytics | 🟡 Partial | ✅ Full | iOS: limited Screen Time API; Android: UsageStats |
| F-022 | Time Machine Backup Health | ❌ No | ❌ No | Time Machine does not exist on mobile |
| F-023 | Memory Leak & App Bloat Tracker | 🟡 Limited | 🟡 Limited | iOS: MemoryWarning signals; Android: ActivityManager |
| F-024 | Browser Cleaner | ❌ No | 🟡 Partial | iOS sandbox; Android: Chrome/Firefox cache dirs |
| F-025 | Duplicate Photos (pHash) | ✅ Full | ✅ Full | PhotoKit / MediaStore + CIImage pHash |
| F-026 | Downloads Folder Organiser | ❌ No | ✅ Full | iOS: no Downloads; Android: MediaStore |
| F-027 | Snippet Manager | 🟡 Adapted | 🟡 Adapted | No global picker; in-app snippet library |
| F-028 | Focus Session Companion | ✅ Full | ✅ Full | INFocusStatusCenter / Digital Wellbeing API |
| F-029 | Scheduled Reports & Weekly Digest | ✅ Full | ✅ Full | BGTaskScheduler / WorkManager + push |
| F-030 | iCloud Storage Analyser | 🟡 Partial | ❌ No | CloudKit feasible on iOS; no iCloud on Android |

**Legend:** ✅ Fully feasible · 🟡 Partially feasible / adapted · ❌ Not feasible

---

## 3. iOS — Achievable Features (Detailed)

### 3.1 Fully Feasible on iOS

---

#### Device Stats Dashboard
**What it does on iOS:** Live metrics card: device RAM usage, battery level + charging state,
network connectivity type, storage used/free. Health score using available metrics subset.

| Item | Detail |
|------|--------|
| **iOS APIs** | `NSProcessInfo.processInfo.physicalMemory`, `os_proc_available_memory()`, `UIDevice.current.batteryLevel`, `UIDevice.current.batteryState`, `NWPathMonitor` (Network.framework), `FileManager.attributesOfFileSystem(forPath:)` |
| **Permissions** | None (all public APIs) |
| **Entitlements** | None |
| **Effort vs macOS** | 60% — fewer metrics; no Darwin kernel calls |
| **Gap** | No CPU % per-core, no process list, no thermal sensors, no cycle count |

---

#### Smart Scan Scheduler
**What it does on iOS:** Background scheduled scan (duplicate photos, signature check,
storage analysis of app sandbox). Fires at user-preferred frequency.

| Item | Detail |
|------|--------|
| **iOS APIs** | `BGProcessingTask` (iOS 13+) for long-running background work; `BGAppRefreshTask` for lightweight refresh |
| **Permissions** | `Background Modes` capability → `Background processing` |
| **Entitlements** | `com.apple.developer.backgroundtasks` |
| **Effort vs macOS** | 80% — `BGTaskScheduler` mirrors `NSBackgroundActivityScheduler` closely |
| **Gap** | iOS enforces strict CPU/time budgets; scan must be interruptible |

---

#### Signature-Based Threat Detection
**What it does on iOS:** Checks app's own accessible directories and user-shared files
against the bundled malware keyword database. Also scans MDM configuration profiles if available.

| Item | Detail |
|------|--------|
| **iOS APIs** | `Bundle.main.url(forResource:withExtension:)` for bundled `signatures.json`; `URLSession` for delta updates; `FileManager` for accessible directory scan |
| **Permissions** | None for bundled scan; `NSPhotoLibraryUsageDescription` if scanning Photos metadata |
| **Effort vs macOS** | 90% — `SignatureDatabase` actor is fully portable; only scan paths differ |
| **Gap** | Cannot scan LaunchAgents, /Applications, or system directories |

---

#### Duplicate Photos Finder (pHash)
**What it does on iOS:** Perceptual hash clustering of the user's Photo Library to find
near-duplicate images. Side-by-side comparison UI; recommended keep + delete.

| Item | Detail |
|------|--------|
| **iOS APIs** | `PHPhotoLibrary`, `PHAsset`, `PHImageManager.requestImage()`, `CIImage` + `CoreImage` for DCT-based pHash |
| **Permissions** | `NSPhotoLibraryUsageDescription` (read access) |
| **Entitlements** | None beyond Info.plist key |
| **Effort vs macOS** | 70% — pHash algorithm identical; PhotoKit replaces FileManager enumeration |
| **Gap** | Cannot scan loose image files outside Photos Library |

---

#### Clipboard History (In-App)
**What it does on iOS:** Captures clipboard content each time the user opens the Halo app
or taps a "Capture" button. Stores up to 200 entries locally. Provides search and paste-back.

| Item | Detail |
|------|--------|
| **iOS APIs** | `UIPasteboard.general.string`, `.url`, `.image`; local persistence via `UserDefaults` / Core Data |
| **Permissions** | iOS 16+ shows a banner when clipboard is read; no explicit permission needed |
| **Entitlements** | None |
| **Effort vs macOS** | 40% — no background monitoring; no global hotkey; manual capture only |
| **Gap** | No persistent background monitoring; no system-wide quick-picker shortcut |

---

#### Weekly Digest & Scheduled Reports
**What it does on iOS:** Weekly local notification summarising health score trend, duplicate
photo count, storage usage changes. Optional in-app PDF report via PDFKit.

| Item | Detail |
|------|--------|
| **iOS APIs** | `UNUserNotificationCenter` for delivery; `PDFKit` (available since iOS 11) for report; `BGAppRefreshTask` for weekly summary computation |
| **Permissions** | `UNAuthorizationOptionAlert + .sound` |
| **Effort vs macOS** | 85% — `PDFKit` and `UNUserNotificationCenter` identical to macOS |

---

#### Focus Session Companion
**What it does on iOS:** Timed focus sessions (25/50/custom min). Integrates with iOS Focus
Mode to suppress notifications. Shows session timer in Dynamic Island / Live Activity.

| Item | Detail |
|------|--------|
| **iOS APIs** | `INFocusStatusCenter` (iOS 15+), `UNNotificationCategory`, `ActivityKit` for Live Activities (iOS 16.1+) |
| **Permissions** | `NSFocusStatusUsageDescription` entitlement |
| **Entitlements** | `com.apple.developer.focus-status` |
| **Effort vs macOS** | 60% — concept port; cannot quit other apps on iOS |
| **Gap** | Cannot force-quit distracting apps; can only suppress notifications |

---

#### App Usage Analytics
**What it does on iOS:** Shows weekly screen-time breakdown per app category, context-switch
score, and top apps by foreground time. Powered by Screen Time framework.

| Item | Detail |
|------|--------|
| **iOS APIs** | `DeviceActivity` framework (iOS 15+): `DeviceActivityReport`, `DeviceActivityMonitor`; `FamilyControls` entitlement required |
| **Permissions** | `Screen Time` API requires Family Controls entitlement (App Store review required) |
| **Entitlements** | `com.apple.developer.family-controls` |
| **Effort vs macOS** | 50% — Screen Time API is sandboxed and opaque compared to `NSWorkspace` notifications |
| **Gap** | Data is aggregated by category, not individual apps (privacy model); requires Family Controls approval |

---

### 3.2 Partially Feasible on iOS

---

#### Storage Analysis (SpaceLens — App-Scoped)
**Adapted scope:** Shows Halo's own sandbox usage breakdown (Documents, Caches, Temporary).
Shows total device storage free/used. Cannot drill into other apps.

| Item | Detail |
|------|--------|
| **iOS APIs** | `FileManager.attributesOfFileSystem(forPath: NSHomeDirectory())` for total/free; `FileManager.enumerator()` within app container |
| **Gap** | No system-wide treemap; no per-app breakdown beyond own container |

---

#### Permission Auditor
**Adapted scope:** Shows a checklist of iOS privacy permission categories with their grant
status for Halo itself, plus deep-links to Settings.app per permission category.

| Item | Detail |
|------|--------|
| **iOS APIs** | `CLLocationManager.authorizationStatus`, `AVCaptureDevice.authorizationStatus(for:)`, `PHPhotoLibrary.authorizationStatus()`, `CNContactStore.authorizationStatus(for:)`, etc. — each permission type has its own status API |
| **Gap** | Can only inspect own app's permissions; cannot audit other apps |

---

#### Security Posture Dashboard
**Adapted checks for iOS:** Auto-update enabled (via Settings URL), passcode set
(`LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)`), Find My enabled (CloudKit),
Lockdown Mode status (iOS 16+).

| Item | Detail |
|------|--------|
| **iOS APIs** | `LAContext`, `CloudKit CKContainer.default().accountStatus`, `UIApplication.open(settingsURL)` |
| **Gap** | No FileVault, no Gatekeeper, no SIP equivalent on iOS |

---

#### iCloud Storage Analyser
**Adapted scope:** Shows iCloud Drive quota usage and lists files in iCloud Drive containers
accessible to the app. Identifies evicted files (offline placeholders).

| Item | Detail |
|------|--------|
| **iOS APIs** | `FileManager.url(forUbiquityContainerIdentifier:)`, `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope`, `CKContainer.default().accountStatus` |
| **Entitlements** | `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.ubiquity-kvstore-identifier` |
| **Gap** | Cannot read other apps' iCloud containers; backup size not exposed publicly |

---

### 3.3 iOS-Exclusive Mobile Features (New Ideas)

These make sense on iPhone/iPad but have no macOS equivalent:

| Feature | Description | iOS APIs |
|---------|-------------|---------|
| **Battery Charge Optimiser** | Alerts when battery reaches 80% to unplug (extends long-term health) | `UIDevice.batteryLevel` + `UIDevice.BatteryState` + `UNUserNotificationCenter` |
| **iCloud Backup Health Card** | Shows last iCloud backup date/time and backup size estimate | `UIDevice.identifierForVendor` + Settings deep-link (`App-Prefs:CASTLE`) |
| **Screen Time Weekly Summary Card** | Halo Dashboard card embedding weekly device usage summary | `DeviceActivity` framework |
| **Dynamic Island Scan Progress** | Live Activity showing Smart Scan progress in Dynamic Island | `ActivityKit` (iOS 16.1+, requires A15+ device) |
| **Shortcut Integration** | Siri Shortcuts to trigger scan, export report, clear cache | `AppIntents` framework (iOS 16+) |

---

## 4. Android — Achievable Features (Detailed)

### 4.1 Fully Feasible on Android

---

#### Device Stats Dashboard
**What it does on Android:** Live dashboard showing RAM available, battery level + health,
CPU architecture info, network type and speed, storage usage.

| Item | Detail |
|------|--------|
| **Android APIs** | `ActivityManager.MemoryInfo` + `getMemoryInfo()` for RAM; `BatteryManager` intent for battery; `NetworkStatsManager` (API 23+) for network; `StatFs` for storage; `Build.SUPPORTED_ABIS` for CPU info |
| **Permissions** | `ACCESS_NETWORK_STATE`, `READ_PHONE_STATE` (optional) |
| **Effort vs macOS** | 65% — APIs exist; semantics differ (no per-core CPU %) |

---

#### Smart Scan Scheduler
**What it does on Android:** Periodic background scan using WorkManager with constraints
(charging, idle, network available). Configurable frequency (daily/weekly/monthly).

| Item | Detail |
|------|--------|
| **Android APIs** | `WorkManager` (Jetpack) with `PeriodicWorkRequest`; `Constraints.Builder` for charging/idle |
| **Permissions** | `RECEIVE_BOOT_COMPLETED`, `SCHEDULE_EXACT_ALARM` (Android 12+) |
| **Effort vs macOS** | 80% — WorkManager abstracts JobScheduler and AlarmManager nicely |

---

#### Signature-Based Threat Detection
**What it does on Android:** Scans accessible directories for files matching known malware
keyword patterns (APK names, config entries). Checks installed packages against blocklist.

| Item | Detail |
|------|--------|
| **Android APIs** | `AssetManager.open("signatures.json")`; `OkHttp` / `HttpURLConnection` for delta updates; `PackageManager.getInstalledApplications(PackageManager.GET_META_DATA)` for package scan |
| **Permissions** | None for bundled scan; `QUERY_ALL_PACKAGES` (Android 11+) for full app list |
| **Effort vs macOS** | 85% — JSON loading and matching logic fully portable |

---

#### Duplicate Photo Finder (pHash)
**What it does on Android:** Perceptual hash clustering of the device's media library using
MediaStore. Groups near-duplicates; recommends best copy to keep.

| Item | Detail |
|------|--------|
| **Android APIs** | `MediaStore.Images.Media` content URI; `ContentResolver.query()` for image enumeration; `BitmapFactory.decodeFile()` + DCT pHash algorithm; `Files.readAllBytes()` for SHA-256 |
| **Permissions** | `READ_MEDIA_IMAGES` (Android 13+) or `READ_EXTERNAL_STORAGE` (Android ≤ 12) |
| **Effort vs macOS** | 70% — pHash algorithm identical; MediaStore replaces PhotoKit |

---

#### Duplicate File Finder
**What it does on Android:** SHA-256-based exact duplicate detection across accessible
storage paths (Downloads, Documents, DCIM, external SD).

| Item | Detail |
|------|--------|
| **Android APIs** | `MediaStore` or `Environment.getExternalStoragePublicDirectory()` for enumeration; `MessageDigest.getInstance("SHA-256")` for hashing |
| **Permissions** | `READ_EXTERNAL_STORAGE` (≤ Android 12) or `READ_MEDIA_*` (Android 13+) |
| **Effort vs macOS** | 75% — 3-phase detection algorithm is fully portable |

---

#### Downloads Folder Organiser (F-026)
**What it does on Android:** Categorises `Environment.DIRECTORY_DOWNLOADS` by file type,
shows size/count per category, flags stale files (not opened in 90+ days), identifies
APKs for apps already installed. Sort-into-subfolders action available.

| Item | Detail |
|------|--------|
| **Android APIs** | `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)`; `ContentResolver` with `MediaStore.Downloads` (Android 10+); `PackageManager` to cross-reference APK files |
| **Permissions** | `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE` (≤ Android 12); `READ_MEDIA_*` (Android 13+); `MANAGE_EXTERNAL_STORAGE` for full access (special permission, user-granted in Settings) |
| **Effort vs macOS** | 65% — concept identical; MediaStore replaces `~/Downloads` FileManager enumeration |

---

#### App Usage Analytics (F-021)
**What it does on Android:** Full-featured app usage tracking — foreground time per app
(past 7 days), background CPU hogs, context-switch score, weekly trends.

| Item | Detail |
|------|--------|
| **Android APIs** | `UsageStatsManager.queryAndAggregateUsageStats(startTime, endTime)` returns `UsageStats` per package; `UsageStats.getTotalTimeInForeground()` |
| **Permissions** | `android.permission.PACKAGE_USAGE_STATS` (user-grantable via Settings → Apps → Special App Access) |
| **Effort vs macOS** | 80% — richer API than iOS; similar to macOS `NSWorkspace` notification approach |

---

#### Weekly Digest & Scheduled Reports (F-029)
**What it does on Android:** Weekly `WorkManager`-triggered notification summarising health
score trend, storage changes, app usage highlights. Optional PDF export.

| Item | Detail |
|------|--------|
| **Android APIs** | `WorkManager` with `PeriodicWorkRequest` (7-day interval); `NotificationManager` + `NotificationChannel` for delivery; `PdfDocument` (Android API 19+) for PDF generation |
| **Permissions** | `POST_NOTIFICATIONS` (Android 13+), `SCHEDULE_EXACT_ALARM` |
| **Effort vs macOS** | 85% — `PdfDocument` is less capable than PDFKit; may need iTextG for richer reports |

---

#### Focus Session Companion (F-028)
**What it does on Android:** Timed focus sessions. Integrates with Android's built-in
Digital Wellbeing Focus Mode to pause distracting apps. Countdown notification.

| Item | Detail |
|------|--------|
| **Android APIs** | `android.app.usage.UsageStatsManager`; `NotificationManager.setInterruptionFilter()` for DND; Digital Wellbeing API (device-dependent on Android 9+); `CountDownTimer` for session tracking |
| **Permissions** | `ACCESS_NOTIFICATION_POLICY` for DND control |
| **Gap** | Digital Wellbeing API varies by manufacturer; Samsung/Pixel have better support |
| **Effort vs macOS** | 65% |

---

### 4.2 Partially Feasible on Android

---

#### Storage Analysis / SpaceLens
**Adapted scope:** Treemap/sunburst for accessible paths (Downloads, DCIM, Documents,
external SD card). Shows per-category size. Cannot show system or other apps' storage.

| Item | Detail |
|------|--------|
| **Android APIs** | `StatFs` for total/free; `MediaStore` for media file enumeration; `Environment.getExternalStorageDirectory()` for external |
| **Gap** | Scoped storage (Android 11+) restricts full filesystem traversal; system storage categories not accessible without Device Admin |

---

#### Permission Auditor (F-016)
**Adapted scope:** Lists all installed apps with their declared + granted permissions.
Risk-flags apps with excessive permission grants (e.g., SMS + Location + Camera).

| Item | Detail |
|------|--------|
| **Android APIs** | `PackageManager.getInstalledApplications(GET_PERMISSIONS)` returns `ApplicationInfo.requestedPermissions[]`; `PackageManager.checkPermission()` for grant status |
| **Permissions** | `QUERY_ALL_PACKAGES` (Android 11+) |
| **Effort vs macOS** | 70% — richer than iOS; closer to macOS TCC model |
| **Gap** | Cannot revoke permissions programmatically (must deep-link to Settings) |

---

#### Security Posture Dashboard (F-019)
**Android-specific checks:** Device encryption (`DevicePolicyManager.getStorageEncryptionStatus()`),
Google Play Protect status, Developer Options enabled (`Settings.Secure`), auto-updates,
unknown sources allowed.

| Item | Detail |
|------|--------|
| **Android APIs** | `DevicePolicyManager`, `Settings.Secure.getString(ANDROID_ID)`, `PackageInstaller` for auto-update check, Google Play Core API for Play Protect |
| **Permissions** | No special permissions for read-only status checks |
| **Effort vs macOS** | 60% — different checks; same concept |

---

#### Browser Cleaner (F-024)
**Adapted scope:** Detects Chrome, Firefox, Samsung Internet by package ID. Calculates
cache sizes via `StorageStatsManager` (Android 8+). Links to per-app storage clear in Settings.

| Item | Detail |
|------|--------|
| **Android APIs** | `StorageStatsManager.queryStatsForPackage()` (API 26+) for cache size; `Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)` for Settings deep-link; `PackageManager.clearApplicationCacheFiles()` (Device Admin only) |
| **Gap** | Cache deletion requires Device Admin or user action in Settings; cannot silently delete |

---

#### Clipboard History (In-App)
**Adapted scope:** Monitors clipboard when Halo is active. Captures new content on
`ClipboardManager.onPrimaryClipChanged()`. Stores up to 200 entries locally.

| Item | Detail |
|------|--------|
| **Android APIs** | `ClipboardManager.addPrimaryClipChangedListener()` for monitoring; `ClipData` for content extraction |
| **Permissions** | `android.permission.READ_CLIPBOARD_IN_BACKGROUND` (AOSP hidden on most devices); visible monitoring works when app is in foreground |
| **Gap** | Background monitoring blocked on most Android 10+ devices for privacy |

---

### 4.3 Android-Exclusive Mobile Features (New Ideas)

| Feature | Description | Android APIs |
|---------|-------------|-------------|
| **APK Cache Cleaner** | Scans Downloads for orphaned APK files from apps already installed; flags old APKs for deletion | `PackageManager.getInstalledApplications()` + MediaStore APK enumeration |
| **Auto-Start Permission Manager** | Lists apps configured to start at boot via RECEIVE_BOOT_COMPLETED; lets user toggle (opens AutoStart settings per manufacturer) | `PackageManager.getInstalledApplications()` cross-referenced with known AutoStart settings URIs |
| **Storage Permissions Audit** | Lists which apps have MANAGE_EXTERNAL_STORAGE (broad file access), READ_MEDIA_*, or legacy WRITE_EXTERNAL_STORAGE grants | `PackageManager.getInstalledApplications(GET_PERMISSIONS)` |
| **Background App Restrictor** | Lists apps running background services; links to Battery Optimisation settings to restrict each | `ActivityManager.getRunningServices()` + `Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)` |
| **Android Widget (App Widget)** | Home screen widget showing RAM, battery, storage stats | `AppWidgetProvider`, `RemoteViews`, `AlarmManager` for refresh |

---

## 5. Not Feasible on Mobile (macOS-Exclusive Features)

The following features are **architecturally impossible** on both iOS and Android without
root/jailbreak or device manufacturer privileges:

| Feature | Why |
|---------|-----|
| **System Cleanup** (Cleanup module — all 10 kinds) | Sandbox: apps cannot write to system caches, ~/Library, or Trash |
| **Applications Deep Uninstall** | Sandbox: leftover enumeration across ~/Library paths is blocked |
| **Login Item Scanner** | No launchd / LaunchAgents on mobile; boot persistence is OS-managed |
| **S.M.A.R.T. Disk Health (F-020)** | Mobile devices use eMMC/UFS with no S.M.A.R.T. protocol |
| **Time Machine Backup Health (F-022)** | Time Machine does not exist on iOS/Android |
| **Privacy Data Exposure Scanner (F-018)** | No loose config files / SSH keys / .env files in mobile sandboxes |
| **Global Clipboard Quick-Picker (⌘⇧V)** | No global keyboard event monitoring API |
| **SMC / Hardware Sensor readings** | IOKit SMC not present; mobile sensors locked behind proprietary drivers |
| **Network Traffic Monitor per-app (F-017)** | Requires VPN service (battery-intensive) or root |
| **Memory Purge / DNS Flush / Spotlight Rebuild** | No privileged execution without root or Device Admin |
| **Menu Bar Extra** | iOS/Android do not have customisable persistent menu bars |

---

## 6. Recommended Mobile Build Priority

### Halo iOS — Phased Roadmap

#### Phase 1: MVP (v1.0) — ~6 weeks
> Core monitoring + scan engine. Proves the concept.

| Feature | Effort | Notes |
|---------|--------|-------|
| Device Stats Dashboard | M | Battery, RAM, storage, network |
| Battery Health Card | S | UIDevice + charge optimiser alert |
| Smart Scan (BGTask) | M | Scheduler + progress UI |
| Signature-Based Threat Scan | S | SignatureDatabase fully portable |
| Alert History + Notifications | S | UNUserNotification, identical to macOS |
| Weekly Digest | S | BGAppRefreshTask + PDFKit |
| Settings + Onboarding | M | Permissions flow, preferences |

#### Phase 2: Core Value (v1.1) — ~4 weeks
> Differentiated features. Users see real value.

| Feature | Effort | Notes |
|---------|--------|-------|
| Duplicate Photos Finder (pHash) | L | PhotoKit + CIImage |
| Clipboard History (In-App) | M | UIPasteboard capture on open |
| App Usage Analytics | M | Screen Time / DeviceActivity framework |
| Focus Session Companion | M | INFocusStatusCenter + Live Activity |
| iCloud Storage Analyser | M | CloudKit + NSMetadataQuery |

#### Phase 3: Polish (v1.2) — ~3 weeks
> Rounding out the platform experience.

| Feature | Effort | Notes |
|---------|--------|-------|
| Storage Sandbox Analyser | S | App container only |
| Permission Auditor (own app) | S | Per-API status queries |
| Security Posture Dashboard | M | iOS-specific checks |
| Shortcut Integration | M | AppIntents for Siri/Shortcuts |
| Dynamic Island Scan Progress | M | ActivityKit |

---

### Halo Android — Phased Roadmap

#### Phase 1: MVP (v1.0) — ~7 weeks
> Core monitoring + scan engine.

| Feature | Effort | Notes |
|---------|--------|-------|
| Device Stats Dashboard | M | ActivityManager, BatteryManager, StatFs |
| Smart Scan (WorkManager) | M | PeriodicWorkRequest |
| Signature-Based Threat Scan | S | Identical logic; OkHttp for updates |
| App Usage Analytics | M | UsageStatsManager |
| Alert History + Notifications | S | NotificationManager + NotificationChannel |
| Weekly Digest + PDF | S | PdfDocument / iTextG |
| Settings + Onboarding | M | SharedPreferences, permission flows |

#### Phase 2: Core Value (v1.1) — ~5 weeks
> Storage + privacy features.

| Feature | Effort | Notes |
|---------|--------|-------|
| Duplicate File + Photo Finder | L | MediaStore + SHA-256 + pHash |
| Downloads Folder Organiser | M | MediaStore + APK cross-reference |
| Permission Auditor | M | PackageManager.getInstalledApplications |
| Storage Analysis / SpaceLens | M | StatFs + MediaStore treemap |
| Clipboard History (In-App) | M | ClipboardManager listener |

#### Phase 3: Polish (v1.2) — ~4 weeks
> Android-exclusive wins.

| Feature | Effort | Notes |
|---------|--------|-------|
| APK Cache Cleaner | S | PackageManager + MediaStore |
| Auto-Start Permission Manager | M | Package + Settings deep-links |
| Storage Permissions Audit | S | PackageManager permissions scan |
| Focus Session Companion | M | Digital Wellbeing + DND |
| Security Posture Dashboard | M | Android-specific checks |
| Background App Restrictor | S | ActivityManager + Settings links |
| Android Home Screen Widget | M | AppWidgetProvider + RemoteViews |

---

## 7. Technology Stack Recommendations

### iOS
- **Language:** Swift 5.9 / SwiftUI (same as macOS — massive code reuse for UI and models)
- **Shared code with macOS:** `SignatureDatabase`, `DuplicateDetector`, `AlertLog`, `ReportGenerator`, all model types, `AppModule` enum
- **Distribution:** App Store (`com.halo.ios`)
- **Min target:** iOS 16.0 (Live Activities, SwiftUI improvements, `UIPasteboard` changes)

### Android
- **Language:** Kotlin + Jetpack Compose (mirrors SwiftUI paradigm; fastest development)
- **Shared logic with macOS:** Duplicate detection algorithm, signature matching, report generation logic (can be extracted to KMP — Kotlin Multiplatform — if desired)
- **Distribution:** Google Play Store (`com.halo.android`)
- **Min target:** Android 8.0 (API 26) — covers `StorageStatsManager`, 90%+ of active devices

### Cross-Platform Code Sharing Strategy
| Layer | Approach |
|-------|---------|
| Business logic (scan algorithms, signature matching) | Kotlin Multiplatform (KMP) or duplicate in Swift |
| UI | Platform-native (SwiftUI on iOS, Compose on Android) — best UX |
| Data models | KMP shared module (`ClipboardItem`, `AlertEntry`, etc.) |
| Networking | KMP with Ktor (iOS + Android) |
| Local storage | SQLDelight (KMP) or platform-native |

---

*Last updated: 2026-05-29 | Halo v2.1 baseline*
