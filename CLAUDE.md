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
│   │   ├── HaloApp.swift            @main entry, MenuBarExtra, Settings
│   │   ├── AppState.swift           @MainActor ObservableObject — central store
│   │   └── ContentView.swift        NavigationSplitView + sidebar routing
│   ├── Core/
│   │   ├── Models/Models.swift      all value-type data models
│   │   ├── HotkeyManager.swift      global NSEvent monitor for ⌘⇧V
│   │   ├── Display/                 ← Phase 2 (planned)
│   │   │   ├── DisplayBrightnessManager.swift   actor — CoreDisplay + DDC/CI
│   │   │   └── DDCHelper.swift                  I²C DDC for external monitors
│   │   └── Scanner/
│   │       ├── SystemMonitor.swift       CPU/RAM/disk/battery/network
│   │       ├── FileSystemScanner.swift   async actor, AsyncStream
│   │       ├── ScanCoordinator.swift     orchestrates Smart Scan
│   │       ├── DuplicateDetector.swift   SHA-256 3-phase detection
│   │       └── ClipboardMonitor.swift    NSPasteboard polling
│   ├── DesignSystem/DesignSystem.swift   colours, components, typography
│   ├── Features/
│   │   ├── Dashboard/DashboardView.swift
│   │   ├── Cleanup/CleanupView.swift
│   │   ├── Protection/ProtectionView.swift
│   │   ├── Performance/PerformanceView.swift
│   │   ├── Applications/ApplicationsView.swift
│   │   ├── Files/FilesView.swift          SpaceLens + Duplicates + LargeFiles tabs
│   │   ├── Clipboard/
│   │   │   ├── ClipboardView.swift
│   │   │   ├── ClipboardMonitor.swift
│   │   │   └── ClipboardQuickPickerView.swift
│   │   ├── MenuBar/MenuBarView.swift
│   │   ├── SmartScan/SmartScanView.swift
│   │   ├── Displays/DisplaysView.swift   ← Phase 2 (planned) — brightness per display
│   │   └── Onboarding/OnboardingView.swift + SettingsView + Commands
│   └── Resources/
│       ├── Info.plist
│       ├── PrivacyInfo.xcprivacy
│       ├── Halo.entitlements              release / App Store (sandboxed)
│       └── Halo-Debug.entitlements        debug (sandbox OFF — AX monitor needs it)
├── HaloWidget/                       ← widget extension target
│   ├── HaloWidget.swift              timeline provider + 3 size views
│   ├── HaloWidgetBundle.swift        @main WidgetBundle
│   ├── Info.plist
│   └── HaloWidget.entitlements
├── Shared/
│   └── HaloSharedData.swift          HaloWidgetData: Codable — compiled into BOTH targets
├── HaloTests/HaloTests.swift
├── Package.swift
├── README.md
├── CLAUDE.md                         ← this file
└── docs/
    ├── ARCHITECTURE.md
    ├── WIDGET.md
    ├── DESIGN_SYSTEM.md
    └── ROADMAP.md
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

# 2. Sign: dylibs → widget appex → outer app  (ORDER MATTERS)
find "$APP" -name "*.dylib" | while read d; do
  codesign --force --sign "$CERT" --timestamp=none "$d"
done
codesign --force --sign "$CERT" \
  --entitlements HaloWidget/HaloWidget.entitlements --timestamp=none \
  "$APP/Contents/PlugIns/HaloWidget.appex"
codesign --force --sign "$CERT" \
  --entitlements Halo/Halo-Debug.entitlements --timestamp=none "$APP"

# 3. Install & register widget
cp -R "$APP" ~/Applications/Halo.app
pluginkit -a ~/Applications/Halo.app/Contents/PlugIns/HaloWidget.appex
```

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

| Module | View | ViewModel | Scanner / Manager | Tests |
|--------|------|-----------|---------|-------|
| Dashboard | ✅ | AppState | SystemMonitor | — |
| Cleanup | ✅ | CleanupViewModel | FileSystemScanner | — |
| Protection | ✅ | ProtectionViewModel | — (sample data) | — |
| Performance | ✅ | PerformanceViewModel | SystemMonitor | — |
| Applications | ✅ | ApplicationsViewModel | FileSystemScanner | — |
| Files (SpaceLens) | ✅ | SpaceLensViewModel | — | — |
| **Displays** 🆕 | 📋 Planned | DisplaysViewModel | DisplayBrightnessManager | — |
| Files (Duplicates) | ✅ | DuplicateFinderViewModel | DuplicateDetector | ✅ |
| Clipboard | ✅ | ClipboardViewModel | ClipboardMonitor | ✅ |
| Menu Bar | ✅ | MenuBarManager | SystemMonitor | — |
| Smart Scan | ✅ | — | ScanCoordinator | — |
| Onboarding | ✅ | — | — | — |
| Settings | ✅ | @AppStorage | — | — |
| Widget | ✅ | HaloProvider | — | — |

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

---

## Known Gotchas

1. **Widget reload budget** — never call `reloadAllTimelines()` more than once/min. Already handled by `widgetReloadTimer`.
2. **Signing order** — dylibs → appex → outer app. Wrong order = TeamIdentifier mismatch crash.
3. **Widget gallery** — macOS only discovers widgets from apps in `/Applications` or `~/Applications`.
4. **`containerBackground` availability** — must be wrapped in `if #available(macOS 14.0, *)`.
5. **Global NSEvent monitor** — requires Accessibility permission + sandbox off (debug) or XPC helper (release).
6. **`HaloSharedData.swift`** — compiled into both targets. Changes must be backward-compatible JSON or versioned.
7. **Protection module** — sample/mock data only. Real `SignatureDatabase` scanning is a roadmap item.

---

## Pending (from Roadmap)

1. XPC Helper — privileged ops (flush DNS, purge RAM)
2. StoreKit 2 ProManager
3. SignatureDatabase with HTTPS delta updates
4. BGTaskScheduler for scheduled Smart Scan
5. Sentry crash reporting
6. App Store submission assets

Full details → `docs/ROADMAP.md`
