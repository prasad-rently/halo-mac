# Halo — AI Agent Memory

This file is the primary context source for Claude (and any AI agent) working on this codebase. Read it fully before making any change. Deeper references: `docs/ARCHITECTURE.md`, `docs/WIDGET.md`, `docs/DESIGN_SYSTEM.md`, `docs/ROADMAP.md`.

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
│   │       └── AppScanner.swift          actor; enumerates apps + leftover detection
│   ├── DesignSystem/DesignSystem.swift   colours, components, typography
│   ├── Features/
│   │   ├── Dashboard/DashboardView.swift      health score, metrics, AlertHistorySection, Export Report
│   │   ├── Cleanup/CleanupView.swift
│   │   ├── Protection/ProtectionView.swift
│   │   ├── Performance/PerformanceView.swift  login items via LoginItemScanner
│   │   ├── Applications/ApplicationsView.swift AppScanner + deep uninstall
│   │   ├── Files/FilesView.swift              SpaceLens + Duplicates + LargeFiles tabs
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
- `private func spotlightLastUsed(at url: URL) -> Date?` — via `getxattr` for `kMDItemLastUsedDate`
- `LeftoverKind` cases in `Models.swift`: `.preferences`, `.appSupport`, `.caches`, `.containers`, `.groupContainers`, `.logs`, `.savedState`, `.cookies`, `.webkit`, `.launchAgent`

---

## MenuBar Display Styles

`Halo/Features/MenuBar/MenuBarView.swift`

```swift
enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case icon       // Halo icon only (default)
    case textStats  // "CPU 42% · RAM 61%"
    case miniBar    // 4px capsule progress bars for CPU and RAM
    case dot        // coloured dot (green/amber/red) based on system pressure
}
```

- Persisted via `@AppStorage("menuBarDisplayStyle")` in `MenuBarIconView`
- `MiniProgressBar` — private 4px capsule progress indicator in `.miniBar` style

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
| Clipboard | ✅ | ClipboardViewModel | ClipboardMonitor | ✅ |
| Menu Bar | ✅ | MenuBarManager | SystemMonitor | — |
| Smart Scan | ✅ | ScanScheduler | ScanCoordinator | — |
| Onboarding / Settings | ✅ | @AppStorage | — | — |
| Widget | ✅ | HaloProvider | — | — |
| Alert History | ✅ | AlertLog | AlertManager | — |
| Report Export | ✅ | ReportGenerator | — | — |

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
