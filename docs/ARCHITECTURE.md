# Halo — Architecture Reference

This document describes the data flow, concurrency model, and key design decisions that every contributor (human or AI) needs to understand before touching the codebase.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                       HaloApp (@main)                    │
│  WindowGroup ── ContentView ── NavigationSplitView       │
│  MenuBarExtra ── MenuBarPopoverView                      │
│  Settings ── SettingsView                                │
└──────────────────────┬──────────────────────────────────┘
                       │ @EnvironmentObject
              ┌────────▼────────┐
              │    AppState     │  @MainActor ObservableObject
              │  (central store)│  — all @Published live metrics
              └─┬──────────┬───┘
                │          │
    ┌───────────▼──┐  ┌────▼──────────────┐
    │ SystemMonitor│  │  ClipboardMonitor  │
    │  (every 2 s) │  │  (NSPasteboard     │
    │  IOKit/Mach  │  │   polling, 1 s)   │
    └───────┬──────┘  └────────┬──────────┘
            │                  │
            └────────┬─────────┘
                     │ writeWidgetData() every 2 s
                     ▼
        UserDefaults(suiteName: "group.com.halo.mac")
                     │ reloadAllTimelines() every 60 s
                     ▼
              HaloWidget.appex
              HaloProvider.getTimeline()  →  WidgetKit
```

---

## AppState — Single Source of Truth

`Halo/App/AppState.swift`

`AppState` is the application's single store. Every feature view receives it via `@EnvironmentObject`. It owns:

| Concern | Properties | Provider |
|---------|-----------|----------|
| Navigation | `selectedModule` | — |
| Live metrics | `cpuUsage`, `ramUsage`, `ramUsedGB`, `ramTotalGB`, `diskFreeGB`, `diskTotalGB`, `networkUpMBps`, `networkDownMBps`, `batteryPercent`, `batteryHealth`, `batteryCycles` | `SystemMonitor` |
| Health score | `systemHealthScore` | `calculateHealthScore()` |
| Scan | `lastSmartScanDate`, `isSmartScanRunning`, `smartScanResult` | `ScanCoordinator` |
| Cleanup | `cleanupCategories`, `isCleanupScanning`, `totalCleanableBytes` | `FileSystemScanner` |
| Clipboard | `clipboardItems` (up to 500) | `ClipboardMonitor` |
| Activity log | `recentActivities` (up to 50) | app events |
| Pro state | `isPro` | `ProManager` (future) |
| Hotkey config | `shortcutKeyCode`, `shortcutModifiers` | `UserDefaults` |

### Metrics polling cadence

```
metricsTimer: every 2 s  →  refreshMetrics()
                                ├── SystemMonitor.cpuUsage()
                                ├── SystemMonitor.ramStats()
                                ├── SystemMonitor.diskStats()
                                ├── SystemMonitor.batteryStats()
                                ├── SystemMonitor.networkStats()
                                ├── calculateHealthScore()
                                └── writeWidgetData()  (writes to App Group, NO reloadTimelines)

widgetReloadTimer: every 60 s  →  WidgetCenter.shared.reloadAllTimelines()
```

**Why separate timers?**  macOS throttles `reloadAllTimelines()` to ~40–70 calls/hour per widget. Calling it every 2 s exhausts the budget instantly. The shared container stays fresh (2 s lag), while the widget reloads within macOS budget.

---

## Concurrency Model

| Layer | Tool | Thread |
|-------|------|--------|
| ViewModels | `@MainActor final class` | Main |
| File scanning | `actor FileSystemScanner` | Cooperative thread pool |
| Duplicate detection | `actor DuplicateDetector` | Cooperative thread pool |
| Scan orchestration | `actor ScanCoordinator` | Cooperative thread pool |
| Parallel category scans | `withTaskGroup` | Multiple concurrent tasks |
| Clipboard polling | `DispatchQueue` (background) | Background |

### AsyncStream usage (FileSystemScanner)

```swift
// Producer (actor)
func scanDirectory(_ url: URL) -> AsyncStream<ScannedItem> {
    AsyncStream { continuation in
        Task {
            // emit items as they're found
            continuation.yield(item)
            continuation.finish()
        }
    }
}

// Consumer (ViewModel on MainActor)
for await item in scanner.scanDirectory(url) {
    items.append(item)  // UI updates incrementally
}
```

---

## Module Breakdown

### Core / Scanner

| File | Role |
|------|------|
| `SystemMonitor.swift` | CPU via `host_processor_info`, RAM via `host_statistics64`, disk via `FileManager`, battery via IOKit power sources, network via `SCNetworkInterface` delta |
| `FileSystemScanner.swift` | Async actor; walks directory trees with `FileManager.enumerator`; yields `ScannedItem` objects via `AsyncStream`; respects `ageThresholdDays` per `CleanupKind` |
| `DuplicateDetector.swift` | 3-phase: (1) group by size, (2) group by partial SHA-256 (first 64 KB), (3) full SHA-256 confirmation; returns `[DuplicateGroup]` |
| `ScanCoordinator.swift` | Coordinates a full Smart Scan: runs all `CleanupKind` categories via `withTaskGroup`, aggregates results into `SmartScanResult` |
| `ClipboardMonitor.swift` | Polls `NSPasteboard.general.changeCount` every 1 s on a background queue; emits new `ClipboardItem` via callback; `suppressNext` flag prevents re-capturing an item pasted by Halo itself |

### HotkeyManager

`Core/HotkeyManager.swift`

Uses `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` (requires Accessibility permission) to intercept the configured shortcut globally. Calls `onClipboardShortcut` closure → `ClipboardQuickPickerController.show()`.

**Sandbox note:** Global event monitors require the app to be **not sandboxed** (or use an XPC helper). The debug entitlements disable the sandbox for this reason.

### Design System

`DesignSystem/DesignSystem.swift` is the only source for:
- `Color` extensions (`.haloAccent`, `.haloGreen`, etc.)
- `HaloFont` (body, display, mono, caption)
- `HaloCard` — surface-coloured rounded container
- `HaloPrimaryButton` — gradient button with loading state
- `HaloToggle`, `HaloHealthRing`, `HaloMetricCard`

**Never hardcode colours or font sizes in feature views.** Always use design tokens.

---

## Widget Architecture

Detailed in [`docs/WIDGET.md`](WIDGET.md). Summary:

- Extension target: `com.halo.mac.widget`
- Shared data: `Shared/HaloSharedData.swift` compiled into **both** targets
- Transport: `UserDefaults(suiteName: "group.com.halo.mac")`
- Timeline: 5 entries × 1-minute apart, refreshed every minute
- Three size variants: `HaloSmallView`, `HaloMediumView`, `HaloLargeView`

---

## Entitlements Strategy

| File | When used | Sandbox |
|------|-----------|---------|
| `Halo-Debug.entitlements` | Debug builds (local development) | **Off** — enables global `NSEvent` monitor |
| `Halo.entitlements` | Release / App Store | **On** — temporary-exception paths for `~/Library/{Caches,Logs,Preferences,Application Support,.Trash,Downloads}` |
| `HaloWidget.entitlements` | Widget extension (all configs) | **On** — only needs App Group access |

**Full Disk Access** is requested at runtime via the Onboarding flow — it is **not** declared in entitlements, because the sandboxed entitlement equivalent does not cover all paths needed for cleanup scanning.

---

## Data Models (Models.swift)

All models are value types (`struct`), `Identifiable`, and `Sendable` where crossing actor boundaries.

| Model | Purpose |
|-------|---------|
| `ScannedItem` | A single file found during cleanup scanning |
| `CleanupCategory` | Groups of `ScannedItem` by `CleanupKind` |
| `SmartScanResult` | Full scan output: categories + threat/login item counts |
| `MalwareThreat` | A detected threat with kind, risk level, and file path |
| `AppPermission` | A macOS permission type + list of apps that hold it |
| `LoginItem` | A startup agent/login item with RAM usage and last-launched date |
| `InstalledApp` | An installed `.app` with size, last-used date, and leftover paths |
| `DuplicateGroup` | A set of identical files; wasted bytes = sum of non-primary copies |
| `ClipboardItem` | Content + metadata; content is `ClipboardContent` enum |
| `ActivityEvent` | An audit log entry (scan completed, cleanup done, threat found, etc.) |

---

## Feature ViewModels

Each module has a `@MainActor final class …ViewModel: ObservableObject` that lives inside its `View` as `@StateObject`. This keeps state scoped to the module and prevents AppState from growing unbounded.

| Module | ViewModel | Key responsibilities |
|--------|-----------|---------------------|
| Cleanup | `CleanupViewModel` | Scan categories concurrently, track selection, execute cleanup |
| Protection | `ProtectionViewModel` | Run signature scan, manage quarantine state |
| Performance | `PerformanceViewModel` | Enumerate login items, run maintenance tasks |
| Applications | `ApplicationsViewModel` | List installed apps, detect leftovers, deep-uninstall |
| Files | `SpaceLensViewModel`, `DuplicateFinderViewModel` | Treemap data, duplicate groups |
| Clipboard | `ClipboardViewModel` | Filter/search clipboard history |
| Menu Bar | `MenuBarManager` | System-pressure state, popover visibility |

---

## Navigation

`ContentView.swift` uses `NavigationSplitView`:

```
Sidebar (AppModule list)  ──►  Detail (feature view for selectedModule)
```

`AppModule` enum in `AppState.swift` provides `title`, `icon` (SF Symbol), and `gradientColors` for each module. Adding a new module requires:
1. Add case to `AppModule`
2. Add `View` in `Features/`
3. Wire in `ContentView`'s switch

---

## Rules Every Contributor Must Follow

1. **Never use `FileManager.removeItem`** — always `trashItem(at:resultingItemURL:)`.
2. **Never hardcode colours** — use `Color.haloAccent` etc. from `DesignSystem.swift`.
3. **All deletions require user confirmation** — show a review sheet before executing.
4. **AppState is @MainActor** — never mutate `@Published` properties from background actors without `await MainActor.run {}`.
5. **Widget reload budget** — never call `WidgetCenter.shared.reloadAllTimelines()` more than once per minute.
6. **No direct `URLSession` in feature views** — go through a coordinator or ViewModel.
7. **New shared types** go in `Shared/` if needed by both app and widget, otherwise in `Core/Models/Models.swift`.
