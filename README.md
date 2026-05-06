<p align="center">
  <img src="docs/images/banner.png" alt="Halo — Your Mac. Elevated." width="100%"/>
</p>

<p align="center">
  <strong>Your Mac. Elevated.</strong><br/>
  A native macOS system utility — cleanup, protection, performance, clipboard history &amp; live widget.<br/><br/>
  <img src="https://img.shields.io/badge/macOS-13.0+-000000?logo=apple&logoColor=white" alt="macOS 13+"/>
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" alt="Swift 5.9"/>
  <img src="https://img.shields.io/badge/SwiftUI-blue?logo=swift&logoColor=white" alt="SwiftUI"/>
  <img src="https://img.shields.io/badge/WidgetKit-✓-4f7cff" alt="WidgetKit"/>
  <img src="https://img.shields.io/badge/license-Proprietary-lightgrey" alt="License"/>
</p>

---

<p align="center">
  <img src="docs/images/features.png" alt="Halo features overview" width="640"/>
</p>

---

## Features at a Glance

| Module | What it does |
|--------|-------------|
| **Dashboard** | Live health score ring, CPU/RAM/disk/network/battery cards, Smart Scan trigger |
| **Cleanup** | Scans caches, logs, temp files, Xcode derived data, iOS backups, language packs, trash |
| **Protection** | Malware/adware threat detection, permission auditing per app |
| **Performance** | Login-item manager, RAM/DNS/permission maintenance tasks |
| **Applications** | Installed app inventory with deep-uninstall leftovers detection |
| **Files** | SpaceLens treemap, SHA-256 duplicate finder, large-file browser |
| **Clipboard** | Full clipboard history (text, URL, code, image, color), ⌘⇧V quick-picker overlay |
| **Menu Bar** | Persistent CPU %, system-pressure indicator, popover with live stats |
| **Widget** | macOS Notification Center widget — Small/Medium/Large, updates every 60 s |

---

## Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 13.0 Ventura or later |
| Xcode | 15.4 or later |
| Swift | 5.9 |
| Apple Developer account | Required for App Group entitlements & signing |

---

## Project Structure

```
Halo/
├── Halo.xcodeproj/
│   └── project.pbxproj           ← single source of truth for all targets
├── Halo/                         ← Main app target (com.halo.mac)
│   ├── App/
│   │   ├── HaloApp.swift         ← @main, MenuBarExtra, Settings scene
│   │   ├── AppState.swift        ← @MainActor ObservableObject, central store
│   │   └── ContentView.swift     ← NavigationSplitView + sidebar routing
│   ├── Core/
│   │   ├── Models/Models.swift   ← All data models
│   │   ├── HotkeyManager.swift   ← Global NSEvent monitor for ⌘⇧V
│   │   └── Scanner/
│   │       ├── SystemMonitor.swift      ← CPU/RAM/disk/battery/network via IOKit
│   │       ├── FileSystemScanner.swift  ← async actor, AsyncStream events
│   │       ├── ScanCoordinator.swift    ← orchestrates Smart Scan pipeline
│   │       ├── DuplicateDetector.swift  ← SHA-256 3-phase detection
│   │       └── ClipboardMonitor.swift   ← NSPasteboard polling
│   ├── DesignSystem/
│   │   └── DesignSystem.swift    ← Colors, HaloCard, buttons, typography tokens
│   ├── Features/
│   │   ├── Dashboard/DashboardView.swift
│   │   ├── Cleanup/CleanupView.swift
│   │   ├── Protection/ProtectionView.swift
│   │   ├── Performance/PerformanceView.swift
│   │   ├── Applications/ApplicationsView.swift
│   │   ├── Files/FilesView.swift
│   │   ├── Clipboard/
│   │   │   ├── ClipboardView.swift
│   │   │   ├── ClipboardMonitor.swift
│   │   │   └── ClipboardQuickPickerView.swift
│   │   ├── MenuBar/MenuBarView.swift
│   │   ├── SmartScan/SmartScanView.swift
│   │   └── Onboarding/OnboardingView.swift
│   └── Resources/
│       ├── Info.plist
│       ├── PrivacyInfo.xcprivacy
│       ├── Halo.entitlements          ← Release / App Store (sandboxed)
│       └── Halo-Debug.entitlements    ← Debug (no sandbox, AX monitor works)
├── HaloWidget/                   ← Widget extension target (com.halo.mac.widget)
│   ├── HaloWidget.swift          ← Timeline provider + all 3 size views
│   ├── HaloWidgetBundle.swift    ← @main WidgetBundle
│   ├── Info.plist
│   └── HaloWidget.entitlements
├── Shared/
│   └── HaloSharedData.swift      ← Codable struct shared by both targets via App Group
├── HaloTests/
│   └── HaloTests.swift           ← Swift Testing suite (DuplicateDetector, Clipboard)
├── Package.swift                 ← SPM (optional Sentry dependency)
├── CLAUDE.md                     ← AI agent memory / architecture decisions
└── docs/
    ├── ARCHITECTURE.md           ← Data flow, concurrency, key design decisions
    ├── WIDGET.md                 ← Widget implementation guide
    ├── DESIGN_SYSTEM.md          ← All design tokens and reusable components
    └── ROADMAP.md                ← Remaining BRD iterations
```

---

## Getting Started

### 1. Clone and open

```bash
git clone <repo-url>
cd Halo
open Halo.xcodeproj
```

### 2. Set your Team

In Xcode: select the **Halo** project → **Signing & Capabilities** → set your **Team** for both the `Halo` and `HaloWidget` targets. Ensure both use the same **App Group**: `group.com.halo.mac`.

### 3. Build & Run

Select the **Halo** scheme → ⌘R. The app targets **macOS 13.0+**.

### 4. Grant permissions (first launch)

Halo's onboarding flow requests:
- **Full Disk Access** — required for deep cleanup scans (System Settings → Privacy)
- **Accessibility** — required for the global ⌘⇧V clipboard hotkey

### 5. Run tests

```bash
xcodebuild test -project Halo.xcodeproj -scheme HaloTests
```

---

## Building for Distribution (command-line)

```bash
# Build without code signing
xcodebuild -project Halo.xcodeproj \
  -scheme Halo \
  -configuration Debug \
  -derivedDataPath /tmp/HaloBuild \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="/tmp/HaloBuild/Build/Products/Debug/Halo.app"
CERT="Apple Development: Your Name (XXXXXXXXXX)"

# Sign dylibs first, then the widget extension, then the outer app
find "$APP" -name "*.dylib" | while read d; do
  codesign --force --sign "$CERT" --timestamp=none "$d"
done
codesign --force --sign "$CERT" \
  --entitlements HaloWidget/HaloWidget.entitlements \
  --timestamp=none "$APP/Contents/PlugIns/HaloWidget.appex"
codesign --force --sign "$CERT" \
  --entitlements Halo/Halo-Debug.entitlements \
  --timestamp=none "$APP"

# Install and register the widget
cp -R "$APP" ~/Applications/Halo.app
pluginkit -a ~/Applications/Halo.app/Contents/PlugIns/HaloWidget.appex
```

> **Important:** Sign dylibs → widget appex → outer app in that exact order. Reversing the order causes TeamIdentifier mismatches at launch.

---

## How to Use

### Dashboard

The home screen shows a live **health score** (0–100) computed from CPU, RAM, disk fullness, and battery health. Hit **Smart Scan** to run a full system audit in the background — results appear in the Cleanup and Protection modules.

### Cleanup

Browse by category (System Caches, Logs, Xcode DerivedData, Trash, etc.). Each category is scanned concurrently. Check/uncheck individual files, then click **Clean Selected** — files are moved to Trash (never permanently deleted without review).

### Protection

Scans for known adware, PUPs, and browser hijackers using a bundled signature database. Also audits which apps hold sensitive permissions (Camera, Microphone, Full Disk Access, etc.).

### Performance

Manage Login Items — disable or remove startup agents that slow boot time. Run maintenance tasks: purge RAM, flush DNS cache, repair disk permissions.

### Applications

Lists every installed app with its size and last-used date. Select an app and click **Uninstall** to remove the `.app` bundle plus all detected leftovers (preferences, caches, containers).

### Files

Three tabs:
- **SpaceLens** — treemap of disk usage by folder
- **Duplicates** — SHA-256 based duplicate finder; keeps the newest copy, marks the rest for deletion
- **Large Files** — sorted list of oversized files for manual review

### Clipboard

Full history of everything copied (up to 500 items). Filter by type (text, URL, code, image, color). Pin frequently-used items. Press **⌘⇧V** from any app to open the floating quick-picker — click an item to paste it instantly.

> **Changing the shortcut:** Halo → Settings → Clipboard → record a new key combination.

### Menu Bar

The Halo icon in the menu bar shows live CPU %. Click to open a popover with CPU, RAM, network, and battery at a glance. The icon changes colour under high system pressure.

### Widget

Right-click the desktop → **Edit Widgets** → search **"Halo Monitor"**. Available in three sizes:

| Size | Content |
|------|---------|
| Small | CPU + RAM progress bars |
| Medium | CPU/RAM (left) + Network up/down (right) |
| Large | CPU + RAM + Network row + up to 5 recent clipboard items |

The widget reads live data from the shared App Group (`group.com.halo.mac`) and refreshes every **60 seconds**.

---

## Key Technical Decisions

### No permanent deletion
All file removal uses `FileManager.trashItem(at:resultingItemURL:)`. The user always has a Trash safety net.

### Dual entitlements
- `Halo-Debug.entitlements` — sandbox **off**, required so `NSEvent.addGlobalMonitorForEvents` (the ⌘⇧V hook) works without an XPC helper.
- `Halo.entitlements` — sandbox **on** with temporary path exceptions, used for App Store submission.

### Widget data pipeline
```
SystemMonitor (every 2 s)
  └─► AppState.writeWidgetData()
        └─► UserDefaults(suiteName: "group.com.halo.mac")  ← shared container
              └─► HaloProvider.getTimeline()  (every 60 s)
                    └─► WidgetKit renders updated view
```
`reloadAllTimelines()` is called once per minute (not every 2 s) to stay within macOS's reload budget (~40–70 reloads/hour).

### Swift Concurrency
- `FileSystemScanner` and `DuplicateDetector` are `actor` types — all file I/O is off the main thread via `AsyncStream`.
- All ViewModels are `@MainActor final class … ObservableObject`.
- `ScanCoordinator` uses `withTaskGroup` for parallel category scanning.

---

## Design Tokens (quick reference)

| Token | Hex | Usage |
|-------|-----|-------|
| Background | `#080c14` | Window / widget background |
| Surface | `#0d1220` | Cards, panels |
| Surface2 | `#131928` | Nested containers |
| Accent | `#4f7cff` | Primary actions, links |
| Accent2 | `#7b5ea7` | Gradient pair for Accent |
| Green | `#22d97a` | Success, healthy state |
| Amber | `#f5a623` | Warning, medium load |
| Red | `#ff4d6a` | Error, critical load |
| Cyan | `#00d4e8` | URL clipboard items |
| Purple | `#b06cff` | Code clipboard items |

All tokens live in `DesignSystem/DesignSystem.swift` as `Color` extensions (e.g., `.haloAccent`, `.haloGreen`).

---

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full list of planned features.

Top items:
1. **XPC Helper** — privileged ops (flush DNS, purge RAM, repair permissions) without disabling sandbox
2. **ProManager** — StoreKit 2 in-app purchase (annual + lifetime)
3. **BGTaskScheduler** — scheduled background Smart Scans
4. **Sentry** — crash reporting via SPM
5. **App Store assets** — 1440×900 screenshots, privacy policy URL

---

## License

Proprietary — all rights reserved. See `LICENSE` for details.
