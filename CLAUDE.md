# Halo — AI Agent Memory

This file is the primary context source for Claude (and any AI agent) working on this codebase. Read it fully before making any change. Deeper references: `docs/ARCHITECTURE.md`, `docs/WIDGET.md`, `docs/DESIGN_SYSTEM.md`, `docs/ROADMAP.md`.

> **🔴 MANDATORY — Mobile parity rule.** Every new desktop feature (`F-xxx`) is
> **not "done"** until it has a **mobile feasibility study** (iOS + Android) and a
> row in **[`docs/HALO_MOBILE_ROADMAP.md`](docs/HALO_MOBILE_ROADMAP.md)**. Do the
> feasibility study *before* adding the feature to the mobile backlog. That doc is
> the single source of truth for Halo-mobile development. See its §0 governance.

---

## Identity

| Field | Value |
|-------|-------|
| App name | Halo |
| Tagline | Your Mac. Elevated. |
| Bundle ID | `com.halo.mac` |
| Widget bundle ID | `com.halo.mac.widget` |
| App Group | `group.com.halo.mac` |
| Min macOS | 13.0 (Ventura) |
| Language | Swift 5.9 / SwiftUI |
| Architecture | MVVM + Actors + Swift Concurrency |
| Dev Team ID | R7S39UR27F |
| Signing cert | `Apple Development: MobileApp Developers (ZWA6Q77327)` |

---

## Directory Layout

```
Halo/
├── Halo.xcodeproj/project.pbxproj  ← all targets, phases, configs
├── Halo/                            ← main app target
│   ├── App/
│   │   ├── HaloApp.swift            @main entry, MenuBarExtra, Settings, Sentry init
│   │   ├── AppState.swift           @MainActor ObservableObject — central store
│   │   └── ContentView.swift        NavigationSplitView + sidebar routing
│   ├── Core/
│   │   ├── Models/Models.swift      all value-type data models
│   │   ├── HotkeyManager.swift      global NSEvent monitor for ⌘⇧V
│   │   ├── AlertLog.swift           @MainActor singleton — 50-item persisted alert history
│   │   ├── AlertManager.swift       UNUserNotification + AlertLog bridge
│   │   ├── ReportGenerator.swift    PDFKit 4-page PDF report export
│   │   ├── ScanScheduler.swift      NSBackgroundActivityScheduler wrapper
│   │   └── Scanner/
│   │       ├── SystemMonitor.swift       CPU/RAM/disk/battery/network
│   │       ├── FileSystemScanner.swift   async actor, AsyncStream
│   │       ├── ScanCoordinator.swift     orchestrates Smart Scan
│   │       ├── DuplicateDetector.swift   SHA-256 3-phase detection
│   │       ├── ClipboardMonitor.swift    NSPasteboard polling
│   │       ├── SignatureDatabase.swift   actor; loads signatures.json + HTTPS delta updates
│   │       ├── ProtectionScanner.swift   async; uses SignatureDatabase for threat detection
│   │       ├── LoginItemScanner.swift    actor; enumerates LaunchAgent/Daemon plists
│   │       ├── AppScanner.swift          actor; enumerates apps + leftover detection
│   │       └── DriveSpeedTester.swift     actor; internal/external drive read+write benchmark (F-043)
│   ├── DesignSystem/DesignSystem.swift   colours, components, typography
│   ├── Intents/
│   │   ├── GetHealthScoreIntent.swift
│   │   ├── GetCPUUsageIntent.swift
│   │   ├── GetBatteryHealthIntent.swift
│   │   ├── GetDiskSpaceIntent.swift
│   │   ├── RunSmartScanIntent.swift
│   │   ├── RunActionIntent.swift
│   │   ├── GetClipboardHistoryIntent.swift
│   │   ├── ExportReportIntent.swift
│   │   └── HaloShortcutsProvider.swift
│   ├── Features/
│   │   ├── Dashboard/DashboardView.swift      health score, metrics, AlertHistorySection, Export Report
│   │   ├── Cleanup/CleanupView.swift
│   │   ├── Protection/ProtectionView.swift
│   │   ├── Performance/PerformanceView.swift  login items via LoginItemScanner
│   │   ├── Applications/ApplicationsView.swift AppScanner + deep uninstall
│   │   ├── Files/FilesView.swift              SpaceLens + Duplicates + LargeFiles + Downloads + Drive Speed tabs
│   │   ├── Files/DriveSpeedView.swift          drive read/write benchmark screen (F-043)
│   │   ├── Clipboard/
│   │   │   ├── ClipboardView.swift
│   │   │   ├── ClipboardMonitor.swift
│   │   │   └── ClipboardQuickPickerView.swift
│   │   ├── MenuBar/MenuBarView.swift          MenuBarDisplayStyle enum + MenuBarIconView
│   │   ├── SmartScan/SmartScanView.swift
│   │   └── Onboarding/OnboardingView.swift    scan schedule + menu bar style + login item settings
│   └── Resources/
│       ├── Info.plist                  SentryDSN placeholder, BGTaskSchedulerPermittedIdentifiers
│       ├── PrivacyInfo.xcprivacy
│       ├── signatures.json             45 malware/adware/PUP/hijacker/keylogger signatures
│       ├── Halo.entitlements           release / App Store (sandboxed)
│       └── Halo-Debug.entitlements     debug (sandbox OFF — AX monitor needs it)
├── HaloWidget/                       ← widget extension target
│   ├── HaloWidget.swift              timeline provider + 3 size views
│   ├── HaloWidgetBundle.swift        @main WidgetBundle
│   ├── Info.plist
│   └── HaloWidget.entitlements
├── Shared/
│   └── HaloSharedData.swift          HaloWidgetData: Codable — compiled into BOTH targets
├── HaloTests/HaloTests.swift
├── Package.swift                     SPM manifest (Sentry 8.x dependency)
├── README.md
├── CLAUDE.md                         ← this file
└── docs/
    ├── ARCHITECTURE.md
    ├── WIDGET.md
    ├── DESIGN_SYSTEM.md
    ├── ROADMAP.md
    └── FEATURE_ROADMAP.md
```

---

## Design Tokens (quick reference)

| Color property | Hex | Role |
|----------------|-----|------|
| `.haloBackground` / `wBackground` | `#080c14` | Deepest background layer |
| `.haloSurface` / `wSurface` | `#0d1220` | Cards, panels |
| `.haloSurface2` | `#131928` | Nested containers |
| `.haloAccent` / `wAccent` | `#4f7cff` | Primary actions |
| `.haloAccent2` / `wAccent2` | `#7b5ea7` | Accent gradient pair |
| `.haloGreen` / `wGreen` | `#22d97a` | Success / healthy |
| `.haloAmber` / `wAmber` | `#f5a623` | Warning / medium |
| `.haloRed` / `wRed` | `#ff4d6a` | Error / critical |
| `.haloCyan` | `#00d4e8` | URL clipboard items |
| `.haloPurple` | `#b06cff` | Code clipboard items |

- Main app tokens → `DesignSystem/DesignSystem.swift`
- Widget tokens → inlined in `HaloWidget/HaloWidget.swift` (must stay in sync)
- **Dark-only app.** Never use adaptive colours.

---

## Key Patterns

### ViewModels
```swift
@MainActor final class FooViewModel: ObservableObject { ... }
```
Owned by feature `View` as `@StateObject`. Never stored in `AppState`.

### Actors for concurrent work
```swift
actor FileSystemScanner { ... }
actor DuplicateDetector { ... }
actor ScanCoordinator { ... }
actor SignatureDatabase { ... }
actor LoginItemScanner { ... }
actor AppScanner { ... }
```

### File deletion — mandatory rule
```swift
// ALWAYS use trashItem — NEVER removeItem
try FileManager.default.trashItem(at: url, resultingItemURL: nil)
```

### All deletions require confirmation
Show a review sheet before any destructive action. Users must explicitly confirm.

### Updating AppState from a background actor
```swift
await MainActor.run { appState.somePublished = value }
```

### await with ?? or || — NEVER use autoclosure form
```swift
// ❌ WRONG — ?? and || use @autoclosure, await cannot appear inside
let result = await scanA(x) ?? (await scanB(x))
let bad = await checkA(x) || (await checkB(x))

// ✅ CORRECT — use explicit let bindings
let hitA = await scanA(x)
let hitB = hitA == nil ? await scanB(x) : nil
let result = hitA ?? hitB

if await checkA(x) != nil { return true }
if await checkB(x) != nil { return true }
```

### Stateless generators — use class, not actor
If a type is purely computational (no mutable state, no need for isolation), use
`final class: @unchecked Sendable` instead of `actor`. Using `actor` on a stateless
generator causes escaping closure captures to fail with "actor-isolated value cannot
be captured in a nonisolated closure."

---

## AppState — Central Store

`Halo/App/AppState.swift`

- Two timers:
  - `metricsTimer` — fires every **2 s** → `refreshMetrics()` → writes data to App Group container
  - `widgetReloadTimer` — fires every **60 s** → `WidgetCenter.shared.reloadAllTimelines()`
- `writeWidgetData()` saves `HaloWidgetData` to `UserDefaults(suiteName: "group.com.halo.mac")` — do **NOT** call `reloadAllTimelines()` here (budget will be exhausted)
- `calculateHealthScore()` — subtracts from 100 based on CPU/RAM/disk/battery thresholds
- Clipboard cap: 500 items in memory; top 5 text/code/URL snippets forwarded to widget

---

## Widget Pipeline (critical — frequently asked about)

```
AppState (every 2 s)  →  writeWidgetData()  →  UserDefaults(group.com.halo.mac)
AppState (every 60 s) →  reloadAllTimelines()
                              └─► HaloProvider.getTimeline()
                                    └─► HaloWidgetData.load()  [reads fresh container]
                                          └─► 5 entries × 1 min apart
                                                └─► WidgetKit renders view
```

**Why 60 s, not 2 s?** macOS throttles reloadAllTimelines() to ~40–70/hr. At 2 s cadence the budget is exhausted in 2 minutes and the widget freezes. 60 s (= 60/hr) stays within budget while the shared container stays ≤2 s stale.

**Validating the pipeline:**
```bash
python3 -c "
import plistlib, json
with open('$HOME/Library/Group Containers/group.com.halo.mac/Library/Preferences/group.com.halo.mac.plist','rb') as f:
    d = plistlib.load(f)
print(json.dumps(json.loads(d['haloWidgetData']), indent=2))
"
```

---

## Build & Sign (command-line, no Xcode account needed)

```bash
# 1. Build (signing disabled so xcodebuild doesn't demand a provisioning profile)
xcodebuild -project Halo.xcodeproj \
  -scheme Halo -configuration Debug \
  -derivedDataPath /tmp/HaloBuild \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  build

APP="/tmp/HaloBuild/Build/Products/Debug/Halo.app"
CERT="Apple Development: MobileApp Developers (ZWA6Q77327)"

# 2. Sign: dylibs → Sentry.framework → widget appex → outer app  (ORDER MATTERS)
find "$APP" -name "*.dylib" | while read d; do
  codesign --force --sign "$CERT" --timestamp=none "$d"
done
# Sign Sentry framework if present
if [ -d "$APP/Contents/Frameworks/Sentry.framework" ]; then
  codesign --force --sign "$CERT" --timestamp=none \
    "$APP/Contents/Frameworks/Sentry.framework"
fi
codesign --force --sign "$CERT" \
  --entitlements HaloWidget/HaloWidget.entitlements --timestamp=none \
  "$APP/Contents/PlugIns/HaloWidget.appex"
codesign --force --sign "$CERT" \
  --entitlements Halo/Halo-Debug.entitlements --timestamp=none "$APP"

# 3. Install & register widget
cp -R "$APP" ~/Applications/Halo.app
pluginkit -a ~/Applications/Halo.app/Contents/PlugIns/HaloWidget.appex

# 4. Verify
codesign --verify --deep --strict ~/Applications/Halo.app && echo "OK"
```

---

## Sentry Crash Reporting

- Sentry SDK 8.x declared as `XCRemoteSwiftPackageReference` in `project.pbxproj` (ID 5003). Also in `Package.swift` but xcodebuild uses pbxproj exclusively.
- DSN stored in `Info.plist["SentryDSN"]` as `SENTRY_DSN_PLACEHOLDER`. **Replace with real DSN before release. NEVER commit the real DSN.**
- Initialised in `HaloApp.configureSentry()` — only activates when `UserDefaults["enableAnalytics"] == true` (user opt-in, defaults to `false`).
- `options.sendDefaultPii = false` — no PII ever sent.
- `options.sampleRate = 0.0` in DEBUG builds; `1.0` in release.
- Key: `"SentryEnabled"` in Info.plist is informational only; the real guard is `enableAnalytics`.

---

## SignatureDatabase

`Halo/Core/Scanner/SignatureDatabase.swift`

- Singleton actor: `SignatureDatabase.shared`
- Loads `signatures.json` from Bundle at launch; merges with cached update from UserDefaults if newer version found.
- `func load() async` — bundle-first, cached-update-wins (called once from `HaloApp.init`)
- `func checkForUpdate() async` — `URLSession` GET to `https://api.halo.mac/signatures/latest.json`; graceful failure on error
- `func matches(keyword: String) -> (kind: ThreatKind, risk: ThreatRisk)?` — O(1) flat dictionary lookup
- `var signatureCount: Int`
- `ProtectionScanner` delegates all threat checks to `SignatureDatabase.shared.matches(keyword:)`

`signatures.json` schema:
```json
{
  "version": 1,
  "updated": "2026-05-28",
  "signatures": [
    { "keyword": "genieo", "kind": "adware", "risk": "high" }
  ]
}
```

---

## ScanScheduler

`Halo/Core/ScanScheduler.swift`

- `@MainActor final class ScanScheduler` — singleton `ScanScheduler.shared`
- Call `ScanScheduler.shared.start(appState:)` once from `HaloApp` (via `.task` modifier on `WindowGroup` content)
- Uses `NSBackgroundActivityScheduler` (macOS equivalent of iOS `BGTaskScheduler`)
- `NSBackgroundActivityScheduler.Result` has `.finished` and `.deferred` — **not** `.success`
- Watches `UserDefaults.didChangeNotification` to re-schedule when scan preferences change
- `func nextScanDate(frequency:weekday:hour:) -> Date?` — uses `Calendar.nextDate(after:matching:)`
- `var nextFireDate: Date?` — published for UI display ("Next: Tuesday at 3:00 AM")
- UserDefaults keys:
  - `"scanFrequency"` — `"daily"` / `"weekly"` (default) / `"monthly"`
  - `"scanPreferredWeekday"` — `Int` 1=Sun…7=Sat (default `2` = Monday)
  - `"scanPreferredHour"` — `Int` 0–23 (default `3` = 3 AM)

---

## AlertLog

`Halo/Core/AlertLog.swift`

- `@MainActor final class AlertLog: ObservableObject` — singleton `AlertLog.shared`
- Persists to `UserDefaults["haloAlertLog"]` as JSON-encoded `[AlertEntry]`
- `struct AlertEntry: Identifiable, Codable` — `id`, `date`, `title`, `body`, `kindRaw`, `isRead`, `icon`, `accentColor`
- `func append(title:body:kindRaw:)` — inserts at index 0, caps at 50 entries
- `func markAllRead()`, `func markRead(_:)`, `func clearAll()`
- `AlertManager.fire()` calls `AlertLog.shared.append(...)` after posting `UNUserNotification`

---

## ReportGenerator

`Halo/Core/ReportGenerator.swift`

- `final class ReportGenerator: @unchecked Sendable` — **NOT** an actor (stateless computation; actor isolation causes escaping closure capture failures)
- Singleton: `ReportGenerator.shared`
- `struct ReportSnapshot: Sendable` — captures all `AppState` data on `@MainActor`
  - `@MainActor static func capture(from appState: AppState) -> ReportSnapshot`
- `func generate(snapshot: ReportSnapshot) -> PDFDocument` — 4-page A4 PDF
  - Page 1: Cover — health score ring, app name, date
  - Page 2: System Overview — CPU/RAM/disk/battery metrics
  - Page 3: Storage & Battery — disk breakdown, battery cycles
  - Page 4: Alert History — recent `AlertEntry` items
- `@MainActor static func presentSavePanel(document: PDFDocument)` — `NSSavePanel`
- Uses CoreText `CTFrameDraw` for text; `DrawablePDFPage: PDFPage` subclass overrides `func bounds(for box: PDFDisplayBox) -> CGRect` (**not** `var bounds`)

---

## LoginItemScanner / LaunchAtLoginManager

`Halo/Core/Scanner/LoginItemScanner.swift`

- `actor LoginItemScanner` — enumerates `~/Library/LaunchAgents` and `/Library/LaunchAgents`/`/Library/LaunchDaemons` for plists with `RunAtLoad || KeepAlive`
- Returns `[LoginItem]` sorted suspicious-first
- **No `SMAppService.loginItemServices(forBundleIdentifier:)`** — that API does not exist
- `enum LaunchAtLoginManager` — manages Halo's own login item only:
  - `static var isEnabled: Bool` — checks `SMAppService.mainApp.status == .enabled`
  - `@discardableResult static func setEnabled(_ enabled: Bool) -> Bool`
- `PerformanceView` calls `LaunchAtLoginManager.setEnabled(_:)` for `.appService` items only

---

## AppScanner

`Halo/Core/Scanner/AppScanner.swift`

- `actor AppScanner` — enumerates `/Applications` and `~/Applications`
- `func scanApps() async -> [InstalledApp]` — reads `Info.plist` per app bundle
- `func scanLeftovers(for app: InstalledApp) async -> [AppLeftover]` — checks 12 standard paths:
  - `~/Library/Preferences`, `~/Library/Application Support` (×2), `~/Library/Caches` (×2),
    `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Logs` (×2),
    `~/Library/Cookies`, `~/Library/Saved Application State`, `~/Library/WebKit`,
    `~/Library/LaunchAgents`
- `func uninstall(_ app: InstalledApp) async -> (Bool, String?)` — trashItem app bundle; trashItem each leftover
- `private func spotlightLastUsed(at url: URL) -> Date?` — via `NSMetadataItem(url:).value(forAttribute: "kMDItemLastUsedDate")` (NOT `getxattr` — that does not work for `.app` bundles)
- `LeftoverKind` cases in `Models.swift`: `.preferences`, `.appSupport`, `.caches`, `.containers`, `.groupContainers`, `.logs`, `.savedState`, `.cookies`, `.webkit`, `.launchAgent`

---

## DriveSpeedTester (F-043 / NFeat-121)

`Halo/Core/Scanner/DriveSpeedTester.swift` + `Halo/Features/Files/DriveSpeedView.swift`

- `actor DriveSpeedTester` — read/write throughput benchmark for internal & external drives. Surfaced as the **"Drive Speed"** tab in the Files module.
- `func availableVolumes() -> [DriveVolume]` — `FileManager.mountedVolumeURLs`, filtered to **local + browsable**, sorted internal-first.
- `func run(volume:size:progress:) async throws -> DriveSpeedResult` — 3-pass sequential write then read.
- **Accuracy techniques (do not remove):**
  - `fcntl(fd, F_NOCACHE, 1)` on the scratch fd → bypasses buffer cache (otherwise the read test just measures RAM).
  - `fcntl(fd, F_FULLFSYNC)` after writes → flushes the drive's own write-back cache to media.
  - Write buffer filled with `arc4random_buf` random bytes → defeats compressing/dedup controllers.
- **Average vs Optimal:** each 8 MB chunk is timed. `average = total ÷ total time` (sustained); `optimal = max chunk` (peak). Both reported for read and write.
- `DriveTestSize`: `.quick` (128 MB) / `.standard` (512 MB) / `.thorough` (1 GB).
- **Scratch file:** internal → `FileManager.temporaryDirectory`; external → `<volume>/.HaloSpeedTest/`. Removed via `unlink` in a `defer` — this is Halo's own temp data, the one sanctioned exception to the trashItem-only rule (commented in source).
- `DriveSpeedError.notWritable` surfaces as a friendly banner when a volume is read-only or sandbox-blocked.
- `@MainActor DriveSpeedViewModel` owns the run `Task`; the actor's `@Sendable` progress callback hops to `MainActor` to update published state.

---

## MenuBar Display Styles

`Halo/Features/MenuBar/MenuBarView.swift`

```swift
enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case icon       // Halo icon only (default)
    case textStats  // "CPU 42% · RAM 61%"
    case miniBar    // 4px capsule progress bars for CPU and RAM
    case dot        // coloured dot (green/amber/red) based on system pressure
    case custom     // User-defined format string with tokens
}
```

- Persisted via `@AppStorage("menuBarDisplayStyle")` in `MenuBarIconView`
- `MiniProgressBar` — private 4px capsule progress indicator in `.miniBar` style
- **Custom format strings** (F-036): `@AppStorage("menuBarFormatString")` — user-editable template with 11 tokens:
  - `{cpu}`, `{ram}`, `{ram_used}`, `{ram_total}`, `{disk}`, `{disk_free}`, `{battery}`, `{net_down}`, `{net_up}`, `{health}`, `{temp}`
  - 5 presets: Minimal (`{cpu}%`), Standard (`CPU {cpu}% · RAM {ram}%`), Full, Network (`↓{net_down} ↑{net_up}`), Battery Focus
  - `MenuBarFormatRenderer.render(format:values:)` — replaces tokens with live values from `MenuBarTokenValues`
  - `MenuBarStyleSelector` — in-app editor with live preview, preset buttons, clickable token grid

---

## Entitlements

| File | Sandbox | When |
|------|---------|------|
| `Halo-Debug.entitlements` | **OFF** | Debug builds — required for global NSEvent monitor |
| `Halo.entitlements` | **ON** (with `~/Library` exceptions) | App Store / release |
| `HaloWidget.entitlements` | **ON** | Widget extension always |

Both main-app entitlement files include `com.apple.security.application-groups = [group.com.halo.mac]`.

---

## Modules Status

| Module | View | ViewModel | Scanner | Tests |
|--------|------|-----------|---------|-------|
| Dashboard | ✅ | AppState | SystemMonitor | — |
| Cleanup | ✅ | CleanupViewModel | FileSystemScanner | — |
| Protection | ✅ | ProtectionViewModel | SignatureDatabase ✅ | — |
| Performance | ✅ | PerformanceViewModel | SystemMonitor + LoginItemScanner | — |
| Applications | ✅ | ApplicationsViewModel | AppScanner | — |
| Files (SpaceLens) | ✅ | SpaceLensViewModel | — | — |
| Files (Duplicates) | ✅ | DuplicateFinderViewModel | DuplicateDetector | ✅ |
| Files (Drive Speed) | ✅ | DriveSpeedViewModel | DriveSpeedTester | ✅ |
| Clipboard | ✅ | ClipboardViewModel | ClipboardMonitor | ✅ |
| Actions | ✅ | ActionsViewModel | ActionRunner + ActionLibrary | — |
| Ports | ✅ | PortManagerViewModel | PortScanner | — |
| Menu Bar | ✅ | MenuBarManager | SystemMonitor | — |
| Smart Scan | ✅ | ScanScheduler | ScanCoordinator | — |
| Onboarding / Settings | ✅ | @AppStorage | — | — |
| Widget | ✅ | HaloProvider | — | — |
| Alert History | ✅ | AlertLog | AlertManager | — |
| Report Export | ✅ | ReportGenerator | — | — |
| Siri Shortcuts | ✅ | HaloShortcutsProvider | 8 AppIntents | — |

---

## project.pbxproj UUIDs (do not change)

| UUID | What it is |
|------|-----------|
| `000000000000000000002000` | HaloWidget.appex file ref |
| `000000000000000000002002` | HaloWidgetBundle.swift file ref |
| `000000000000000000002003` | HaloWidget.swift file ref |
| `000000000000000000002017` | WidgetKit.framework file ref |
| `000000000000000000002018` | WidgetKit.framework in Frameworks (main app) |
| `000000000000000000002019` | HaloSharedData.swift in Sources (Widget) |
| `000000000000000000002020` | HaloSharedData.swift file ref |
| `000000000000000000002021` | HaloSharedData.swift in Sources (Main) |
| `000000000000000000002022` | Shared group |
| `4001` / `4002` | signatures.json file ref / resource build file |
| `4003` / `4004` | SignatureDatabase.swift file ref / sources build file |
| `4005` / `4006` | ScanScheduler.swift file ref / sources build file |
| `4007` / `4008` | LoginItemScanner.swift file ref / sources build file |
| `4009` / `4010` | AppScanner.swift file ref / sources build file |
| `4011` / `4012` | AlertLog.swift file ref / sources build file |
| `4013` / `4014` | ReportGenerator.swift file ref / sources build file |
| `5001` | Sentry in Frameworks build file |
| `5002` | XCSwiftPackageProductDependency (Sentry) |
| `5003` | XCRemoteSwiftPackageReference (sentry-cocoa) |
| `6001` / `6002` | ActionModels.swift file ref / sources build file |
| `6003` / `6004` | ActionLibrary.swift file ref / sources build file |
| `6005` / `6006` | ActionRunner.swift file ref / sources build file |
| `6007` / `6008` | QuickActionPickerView.swift file ref / sources build file |
| `6009` / `6010` | ActionsView.swift file ref / sources build file |
| `6011` / `6012` | CustomActionEditor.swift file ref / sources build file |
| `8001` / `8002` | PortScanner.swift file ref / sources build file |
| `8003` / `8004` | PortManagerView.swift file ref / sources build file |
| `8005` / `8006` | PortManagerViewModel.swift file ref / sources build file |
| `8007` / `8008` | DownloadsView.swift file ref / sources build file |
| `8009` / `8010` | DownloadsViewModel.swift file ref / sources build file |
| `8011` / `8012` | CelebrationOverlay.swift file ref / sources build file |
| `8013` / `8014` | CodeBeautifierView.swift file ref / sources build file |
| `8015` / `8016` | CodeTheme.swift file ref / sources build file |
| `8017` / `8018` | SyntaxHighlighter.swift file ref / sources build file |
| `8019` / `8020` | IdleAppMonitor.swift file ref / sources build file |
| `8021` / `8022` | IdleAppsSection.swift file ref / sources build file |
| `8023` / `8024` | SnippetManager.swift file ref / sources build file |
| `8025` / `8026` | SnippetEditorView.swift file ref / sources build file |
| `8027` / `8028` | SnippetListSection.swift file ref / sources build file |
| `8029` / `8030` | ActionShareManager.swift file ref / sources build file |
| `9001` / `9002` | GetHealthScoreIntent.swift file ref / sources build file |
| `9003` / `9004` | GetCPUUsageIntent.swift file ref / sources build file |
| `9005` / `9006` | GetBatteryHealthIntent.swift file ref / sources build file |
| `9007` / `9008` | GetDiskSpaceIntent.swift file ref / sources build file |
| `9009` / `9010` | RunSmartScanIntent.swift file ref / sources build file |
| `9011` / `9012` | RunActionIntent.swift file ref / sources build file |
| `9013` / `9014` | GetClipboardHistoryIntent.swift file ref / sources build file |
| `9015` / `9016` | ExportReportIntent.swift file ref / sources build file |
| `9017` / `9018` | HaloShortcutsProvider.swift file ref / sources build file |

---

### Reserved ID blocks — claim one before adding a file

Object IDs in `project.pbxproj` are written zero-padded to 24 characters
(`000000000000000000008163`); the table above abbreviates them to the last four
digits. Every new source file needs **two** — a `PBXFileReference` and a
`PBXBuildFile` — and they must be unique across the whole project.

Duplicate IDs **fail quietly**. Xcode does not error on two objects sharing an ID;
it resolves the ID to one of them, and the other file silently drops out of its
Sources phase. The symptom arrives later as a missing symbol with nothing obvious
connecting it to the project file.

That already happened once: #21, #13 and #9 each independently picked `8031`/`8032`
for three different scanners, because each branched off `main` and took "the next
free pair" without seeing the others. **Pick from a free block below and add your row
before writing the file** — the table is the only thing that makes a claim visible to
a branch that has not merged yet.

| Block | Owner | Status |
|-------|-------|--------|
| `8001`–`8030` | shipped features (see the table above) | taken |
| `8031`–`8032` | F-019 Security Posture (#21) | claimed |
| `8043`–`8046` | F-020 S.M.A.R.T. Disk Health (#20) | claimed |
| `8053`–`8056` | F-022 Time Machine Monitor (#16) | claimed |
| `8063`–`8066` | F-024 Browser Cleaner (#15) | claimed |
| `8073`–`8078` | F-029 Weekly Digest (#11) | claimed |
| `8083`–`8088` | F-018 Privacy Exposure Scanner (#18) | claimed |
| `8093`–`8098` | F-017 Network Traffic Monitor (#17) | claimed |
| `8103`–`8106` | F-021 App Usage Analytics (#10) | claimed |
| `8113`–`8116` | F-023 Memory Leak Tracker (#13) | claimed — moved off `8031` |
| `8123`–`8126` | F-025 Duplicate Photos (#19) | claimed |
| `8133`–`8136` | F-028 Focus Session (#14) | claimed |
| `8143`–`8146` | F-030 iCloud Drive Analyzer (#12) | claimed |
| `8153`–`8154` | F-016 Permission Auditor (#9) | claimed — moved off `8031` |
| `8163`–`8164` | `ShellReader` (Phase 0 / P0.2) | claimed |
| `8171`–`8172` | `AsyncTimeout` (Phase 0 / P0.5) | claimed |
| `8181`+ | — | **free — take the next block from here** |

Auditing the whole batch for collisions:

```bash
git show main:Halo.xcodeproj/project.pbxproj | grep -oE '\b[0-9A-F]{24}\b' | sort -u > /tmp/main-ids
for b in $(git branch --no-merged main --format='%(refname:short)'); do
  git show "$b":Halo.xcodeproj/project.pbxproj 2>/dev/null \
    | grep -oE '\b[0-9A-F]{24}\b' | sort -u \
    | comm -13 /tmp/main-ids - | sed "s|$| $b|"
done | sort > /tmp/pbx-claims
awk '{print $1}' /tmp/pbx-claims | uniq -d | while read id; do
  echo "$id  <-  $(grep "^$id " /tmp/pbx-claims | awk '{print $2}' | tr '\n' ' ')"
done
```

Silence means no collisions. Anything printed is claimed by more than one
unmerged branch, and the line names them.

`--no-merged main` is load-bearing: without it the scan also reports branches that
merely share lineage — `feature/upcoming-features` descends from the already-merged
`feature/f-043-drive-speed-test`, so they hold eight IDs in common quite legitimately.
A check that prints eight false positives every run is one people learn to ignore.

---

## PortScanner

`Halo/Core/Scanner/PortScanner.swift`

- `actor PortScanner` — parses `lsof -iTCP -sTCP:LISTEN -P -n` and `lsof -iUDP -P -n`
- `func scan() async -> [PortEntry]` — returns deduplicated, port-sorted list
- `func killProcess(pid:force:) async -> (Bool, String)` — sends SIGTERM or SIGKILL
- Process path resolution via `ps -p <pid> -o comm=`
- `PortEntry` model: `pid`, `processName`, `processPath`, `port`, `protocolType`, `state`, `friendlyName`
- `NamedPort` model: user-assigned `port → name` mapping, persisted to `UserDefaults["haloNamedPorts"]`
- `KillSignalPreference` enum: `.ask` / `.sigterm` / `.sigkill`, persisted to `UserDefaults["haloKillSignalPref"]`

---

## Siri Shortcuts / App Intents (F-042)

`Halo/Intents/`

- 8 `AppIntent` structs + 1 `AppShortcutsProvider`, compiled into the main app target
- Intents read live metrics from `AppState.shared` (set by HaloApp on launch)
- `HaloShortcutsProvider` registers all 8 intents with Siri phrases for voice invocation

### Intent catalog

| Intent | File | Input | Output |
|--------|------|-------|--------|
| GetHealthScoreIntent | `GetHealthScoreIntent.swift` | — | `Int` (0–100) |
| GetCPUUsageIntent | `GetCPUUsageIntent.swift` | — | `Double` (%) |
| GetBatteryHealthIntent | `GetBatteryHealthIntent.swift` | — | `String` (summary) |
| GetDiskSpaceIntent | `GetDiskSpaceIntent.swift` | — | `String` (summary) |
| RunSmartScanIntent | `RunSmartScanIntent.swift` | — | `String` (result) |
| RunActionIntent | `RunActionIntent.swift` | `HaloAction` entity | `String` (output) |
| GetClipboardHistoryIntent | `GetClipboardHistoryIntent.swift` | `count: Int` (1–10) | `[String]` |
| ExportReportIntent | `ExportReportIntent.swift` | — | `IntentFile` (PDF) |

### Key types

- `HaloAction: AppEntity` — wraps `ActionItem.stableKey` as ID for Shortcuts discovery
- `HaloActionQuery: EntityQuery` — provides `suggestedEntities()` from `ActionLibrary.shared.actions`
- `IntentError` — shared error enum: `.appNotRunning`, `.reportGenerationFailed`, `.actionNotFound`
- `AppState.shared: AppState?` — static reference set by HaloApp for intents to access live metrics

---

## Known Gotchas

1. **Widget reload budget** — never call `reloadAllTimelines()` more than once/min. Already handled by `widgetReloadTimer`.
2. **Signing order** — dylibs → Sentry.framework → appex → outer app. Wrong order = TeamIdentifier mismatch crash.
3. **Widget gallery** — macOS only discovers widgets from apps in `/Applications` or `~/Applications`.
4. **`containerBackground` availability** — must be wrapped in `if #available(macOS 14.0, *)`.
5. **Global NSEvent monitor** — requires Accessibility permission + sandbox off (debug) or XPC helper (release).
6. **`HaloSharedData.swift`** — compiled into both targets. Changes must be backward-compatible JSON or versioned.
7. **`await` in `??` / `||`** — both operators use `@autoclosure`; `await` cannot appear in their right-hand side. Use explicit `let` bindings.
8. **`NSBackgroundActivityScheduler.Result`** — cases are `.finished` and `.deferred`, **not** `.success`.
9. **`SMAppService.loginItemServices(forBundleIdentifier:)`** — does not exist. Use `SMAppService.mainApp` for Halo's own login item only.
10. **`PDFPage.bounds` override** — override `func bounds(for box: PDFDisplayBox) -> CGRect`, not `var bounds`.
11. **Sentry in xcodebuild** — must be declared as `XCRemoteSwiftPackageReference` in `project.pbxproj`. `Package.swift` alone is ignored by `xcodebuild -project`.
12. **Sentry DSN** — `Info.plist["SentryDSN"]` must equal `"SENTRY_DSN_PLACEHOLDER"` in source. Replace only in production build pipeline; never commit the real DSN.
13. **`options.enableUserInteractionTracing`** — does not exist in Sentry 8.x for macOS. Do not add it.
14. **`InstalledApp.isUnused`** — `nil` lastUsedDate means Spotlight returned nothing (unknown), treated as `false` (not unused). Only mark unused when date is present AND > 90 days ago.
15. **`NSMetadataItem` vs `getxattr`** — `getxattr` cannot read `kMDItemLastUsedDate` from `.app` bundles. Always use `NSMetadataItem(url:).value(forAttribute:)` for Spotlight metadata on app bundles.
16. **`EditMode` is iOS-only** — `\.editMode` environment key does not exist on macOS. `List + .onMove` is always drag-active on macOS without any `EditMode`. Do not use `.environment(\.editMode, ...)` in macOS code.
17. **VPN detection** — use two-rule strategy: (1) definitive protocol prefixes (`ppp`, `ipsec`, `tap`), then (2) `utun` with active IPv4 AND `path.usesInterfaceType(.other)`. iCloud Private Relay uses `utun` but `.cellular`/`.wifi` path type, so rule 2 correctly excludes it.
18. **Battery health label** — factor cycle count FIRST, then capacity ratio. Cycles < 100 → "Excellent"; < 300 → "Good"; only fall back to capacity ratio for older batteries with known cycles.
19. **Drive speed benchmark accuracy** — the scratch fd MUST set `fcntl(fd, F_NOCACHE, 1)` (else reads measure RAM) and `fcntl(fd, F_FULLFSYNC)` after writes (else writes measure the SSD's DRAM cache). Write buffer must be random (`arc4random_buf`), not zeros — zeros let compressing controllers report fake speeds. The scratch file is `unlink`-ed (not trashed) — the only sanctioned exception to the trashItem rule, because it's Halo's own temp data that must vanish immediately.

---

## Reorderable Sidebar Modules

`Halo/App/AppState.swift` + `Halo/App/ContentView.swift`

- `AppState.moduleOrder: [AppModule]` — persisted to `UserDefaults["moduleOrder"]` as `[String]` rawValues
- `AppModule.reorderable` — static list of the 6 user-reorderable modules (excludes `.dashboard` which is always pinned)
- `moveModules(from:to:)` + `saveModuleOrder()` on `AppState`
- **Forward-compat:** any new module not in the saved array is appended so it always appears after upgrades
- **SidebarView** — `@State private var isEditing: Bool`; toggle button (`slider.horizontal.3` / `checkmark.circle.fill`) in header
- In edit mode: Dashboard row is hidden, section label changes to "Drag to reorder", `SidebarItem` shows `≡` handle and dims to 80% opacity; navigation is suppressed
- Module list uses `List { ForEach(appState.moduleOrder).onMove }` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, `.scrollDisabled(true)`, `.frame(height: CGFloat(count) * 44)`
- No `.environment(\.editMode, ...)` — macOS does not support `EditMode`

---

## Skipped Features (user decision)

| Feature | Why skipped |
|---------|------------|
| F-003 StoreKit 2 ProManager | User chose to skip in-app purchases |
| F-007 App Store submission assets | User chose to skip |
| F-013 iCloud Clipboard Sync | Depends on F-003 (Pro tier) — skipped |

---

## Completed Features (F-001 – F-015 minus skipped)

| ID | Feature | Status |
|----|---------|--------|
| F-001 | Core app + all base modules | ✅ Done |
| F-002 | XPC Helper (privileged ops) | ✅ Done |
| F-003 | StoreKit 2 ProManager | ⏭ Skipped |
| F-004 | SignatureDatabase (real malware definitions) | ✅ Done |
| F-005 | Sentry crash reporting | ✅ Done |
| F-006 | BGTask / Scheduled Smart Scan | ✅ Done |
| F-007 | App Store submission assets | ⏭ Skipped |
| F-008 | Menu Bar display styles | ✅ Done |
| F-009 | Login Item scanner (real plist enumeration) | ✅ Done |
| F-010 | Deep Application uninstaller (AppScanner) | ✅ Done |
| F-011 | Alert history log | ✅ Done |
| F-012 | PDF report export | ✅ Done |
| F-013 | iCloud Clipboard Sync | ⏭ Skipped |
| F-014 | Launch at Login toggle | ✅ Done |
| F-015 | Custom scan schedule (day + hour picker) | ✅ Done |

---

## Bug Fixes & Polish (v2.1 — 2026-05-29)

### Performance Module
| Fix | File | Detail |
|-----|------|--------|
| Battery health label | `BatteryDetailSection.swift` | Cycle count checked first (< 100 → Excellent, < 300 → Good) before capacity ratio |
| Free RAM accuracy | `PerformanceView.swift` | Uses real `host_statistics64` / `vm_statistics64_data_t` inactive page count via `import Darwin` |
| Top Processes spinner | `TopProcessesSection.swift` | `hasLoaded` flag — spinner only shown on first load; empty-state text shown after |
| CPU/RAM picker alignment | `TopProcessesSection.swift` | Picker moved to its own `HStack` row below section header; no longer overlaps Hide/Show |
| Sensors unavailable message | `SensorsSection.swift` | Replaced bare text with `HaloCard` containing full explanation of Apple Silicon SMC limitations |
| VPN false positive | `NetworkDetailMonitor.swift` | Two-rule strategy: definitive protocols first, then `utun` + `path.usesInterfaceType(.other)` (excludes iCloud Private Relay) |
| Speed test reliability | `SpeedTestService.swift` | 25 MB download (was 5 MB), 64 KB chunk reads, 10-ping median RTT (was 5-ping mean), 5 MB upload, warm-up request |
| Login Items "Manage All" | `PerformanceView.swift` | Opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` via `NSWorkspace` |

### Applications Module
| Fix | File | Detail |
|-----|------|--------|
| "Unused" false positive | `AppScanner.swift` + `Models.swift` | `spotlightLastUsed` rewritten to use `NSMetadataItem`; `isUnused` returns `false` for `nil` date (unknown ≠ unused) |
| Uninstall non-functional | `ApplicationsView.swift` | Confirmation dialog before destructive action; real `trashItem` for app bundle + selected leftovers; error banner on failure |

### Sidebar Enhancement
| Feature | Files | Detail |
|---------|-------|--------|
| Reorderable modules | `AppState.swift`, `ContentView.swift` | Drag-to-reorder sidebar via `List + .onMove`; order persisted to `UserDefaults["moduleOrder"]`; edit mode toggle in header |

---

## Actions Module

`Halo/Core/Actions/` + `Halo/Features/Actions/`

### Architecture

| File | Role |
|------|------|
| `ActionModels.swift` | All value types: `ActionItem`, `ActionCategory`, `ActionCommand`, `ActionExecution`, `ActionExecutionState` |
| `ActionLibrary.swift` | `@MainActor` singleton — predefined action registry, custom action CRUD, fuzzy search, usage tracking |
| `ActionRunner.swift` | `@MainActor` singleton — async execution engine, stdout streaming, privilege escalation, execution history |
| `ActionsView.swift` + `ActionsViewModel` | Module view: category tile grid, execution history list, custom actions section |
| `QuickActionPickerView.swift` + `QuickActionPickerController` | Floating `NSPanel` overlay, identical pattern to `ClipboardQuickPickerView` |
| `CustomActionEditor.swift` | Sheet for create/edit custom actions: name, icon, keywords, script, sudo toggle |

### Key Patterns

**ActionCommand** — two cases:
```swift
enum ActionCommand: Codable {
    case builtIn(BuiltInAction)   // calls into AppState directly
    case shell(String)             // /bin/zsh -c script
}
```

**Privilege escalation** — commands with `requiresPrivilege = true` run via:
```
osascript -e 'do shell script "…" with administrator privileges'
```
This presents the native macOS auth dialog. Multi-line scripts are collapsed to `; ` for osascript.

**Fuzzy search** — multi-term word matching across name + subtitle + keywords:
- Exact word match → score 100
- Prefix match → score 80
- Substring match → score 60
- Character subsequence → score 30
- All terms must match (AND logic); sorted by score then by usage count

**Quick Action Picker shortcut** — `⌘⇧A` (keyCode `0`, modifiers `.command + .shift`).
Registered alongside the clipboard shortcut in `HotkeyManager.start()`. Toggle behaviour: second press dismisses the panel.

**Predefined actions** (108 built-in):
- **Xcode** (4): Clear Derived Data, Clear SPM Cache, Reset iOS Simulators, Kill Xcode
- **Developer** (11): Remove node_modules, Clear npm Cache, Clear Yarn Cache, Kill Process on Port, Show All Listening Ports, Copy SSH Public Key, Clear CocoaPods Cache, Clear Gradle Cache, Docker System Prune, Clear pip Cache, Clear Homebrew Cache
- **System** (25): Flush DNS Cache (sudo), Purge Inactive RAM (sudo), Empty Trash, Rebuild Spotlight Index (sudo), Repair Disk Permissions, Toggle Microphone, Camera Privacy Settings, Restart Finder, Restart Dock, Restart Menu Bar, Toggle Hidden Files, Remove .DS_Store Files, Show Disk Usage by Folder, Lock Screen, Set Volume to 0% (Mute), Set Volume to 50%, Generate Secure Password, Generate UUID, Remove ._ Resource Fork Files, Clear Font Caches (sudo), Clear User Logs, Remove Broken Symlinks, Flush QuickLook Cache, Rebuild Launch Services Database, Kill All Background Apps
- **Network** (5): Run Speed Test, Check Connectivity, Show Network Interfaces, Show Public IP Address, Show Wi-Fi Password
- **Files** (2): Show Largest Files, Eject All External Disks
- **Clipboard** (15): Format JSON, Minify JSON, Count Words, Sort Lines, URL Encode/Decode, Base64 Encode/Decode, UPPERCASE, lowercase, Remove Duplicates, Strip Formatting, Hash SHA-256, Generate QR Code, Beautify Code
- **Creative** (10): Clear caches for FCP, Motion, DaVinci Resolve, Premiere, After Effects, Photoshop, Lightroom, Figma, Logic Pro, Sketch
- **Media** (8): Convert HEIC→JPEG, Optimise Images, Get Video Info, Extract Audio, Create GIF, Take Screenshot, Screen Recording, Resize to 1080p
- **Halo** (3): Run Smart Scan, Export Health Report, Clear Clipboard History
- **Dock & Desktop** (14): Add Dock Spacer, Add Small Spacer, Reset Dock, Toggle Auto-Hide, Remove/Restore Auto-Hide Delay, Minimize Effect (Suck/Scale/Genie), Hide/Show Recent Apps, Dock Position (Left/Right/Bottom)
- **Display** (6): Toggle Dark Mode, Screenshot to Clipboard, Screenshot Region, Screenshot with Timer, Toggle Desktop Icons, Open Display Settings
- **Audio** (5): Mute Microphone, Unmute Microphone, Set Volume 25%, Set Volume 75%, Toggle Do Not Disturb

**Custom actions** persisted to `UserDefaults["haloCustomActions"]` as JSON-encoded `[ActionItem]`.
Usage counts persisted separately to `UserDefaults["haloActionUsage"]` so built-in counts survive app updates.

### Execution History

`ActionRunner.executions: [ActionExecution]` — ordered most-recent-first, capped at 50.
Each `ActionExecution` has:
- `state: ActionExecutionState` — `.queued / .running / .completed / .failed(String)`
- `outputLines: [String]` — streamed stdout/stderr (collapsible in `ExecutionRow`)
- `progress: Double` — `-1` = indeterminate spinner, `1.0` = complete bar
- `duration: String` — formatted elapsed time
