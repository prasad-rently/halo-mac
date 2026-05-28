# Halo Widget — Implementation Guide

Everything you need to understand, extend, or debug the Halo Monitor macOS widget.

---

## Overview

The widget is a **WidgetKit extension** (`HaloWidget.appex`) embedded inside `Halo.app`. It displays live CPU, RAM, network, and clipboard data in three sizes.

```
Halo.app
└── Contents/PlugIns/
    └── HaloWidget.appex        ← com.halo.mac.widget
        └── Contents/
            ├── MacOS/HaloWidget
            ├── Info.plist
            └── _CodeSignature/
```

---

## Targets & Files

| File | Target(s) | Purpose |
|------|-----------|---------|
| `Shared/HaloSharedData.swift` | **Both** (main app + widget) | `HaloWidgetData: Codable` — the shared data contract |
| `HaloWidget/HaloWidget.swift` | Widget only | Timeline provider + all three size views |
| `HaloWidget/HaloWidgetBundle.swift` | Widget only | `@main WidgetBundle` |
| `HaloWidget/Info.plist` | Widget only | Bundle ID, extension point identifier |
| `HaloWidget/HaloWidget.entitlements` | Widget only | Sandbox on, App Group access |

---

## Data Pipeline

```
AppState.refreshMetrics()          — fires every 2 seconds
    └─► writeWidgetData()
          └─► HaloWidgetData(...).save()
                └─► UserDefaults(suiteName: "group.com.halo.mac")
                      key: "haloWidgetData"  value: JSON-encoded Data

AppState.widgetReloadTimer          — fires every 60 seconds
    └─► WidgetCenter.shared.reloadAllTimelines()
          └─► HaloProvider.getTimeline(completion:)
                └─► HaloWidgetData.load()    ← reads from shared UserDefaults
                      └─► [HaloEntry × 5]   ← 5 entries, 1 minute apart
                            └─► WidgetKit renders HaloWidgetEntryView
```

### Why 60-second reload, not 2-second?

macOS enforces a **reload budget** of approximately 40–70 `reloadAllTimelines()` calls per hour per widget. Calling it every 2 seconds (~1,800/hr) immediately exhausts the budget, causing the system to suppress all further reloads — the widget freezes.

At 60 seconds (60/hr), we stay well within budget. The shared container still holds data written 2 seconds ago, so the widget always shows near-live values.

### Verifying the data pipeline

```bash
# Check if data is being written (pipe is healthy if this shows JSON)
python3 -c "
import plistlib, json
with open('$HOME/Library/Group Containers/group.com.halo.mac/Library/Preferences/group.com.halo.mac.plist', 'rb') as f:
    d = plistlib.load(f)
print(json.dumps(json.loads(d['haloWidgetData']), indent=2))
"

# Check if widget process is running
ps aux | grep HaloWidget | grep -v grep
```

---

## HaloWidgetData (Shared Contract)

```swift
// Shared/HaloSharedData.swift
struct HaloWidgetData: Codable {
    var cpuUsage: Double        // 0.0–1.0
    var ramUsage: Double        // 0.0–1.0
    var ramUsedGB: Double
    var ramTotalGB: Double
    var networkUpMBps: Double
    var networkDownMBps: Double
    var clipboardPreviews: [String]  // up to 5 text snippets

    static let suiteName = "group.com.halo.mac"
    static let defaultsKey = "haloWidgetData"
}
```

**Both targets must compile this file.** In `project.pbxproj`, it appears in two `PBXSourcesBuildPhase` entries:
- `HaloSharedData.swift in Sources (Main)` — main app target
- `HaloSharedData.swift in Sources (Widget)` — widget extension target

---

## Timeline Provider

```swift
struct HaloProvider: TimelineProvider {
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<HaloEntry>) -> Void) {
        let data = HaloWidgetData.load()          // reads live App Group data
        var entries: [HaloEntry] = []
        for minuteOffset in 0..<5 {
            let date = Calendar.current.date(byAdding: .minute,
                                             value: minuteOffset, to: .now)!
            entries.append(HaloEntry(date: date, data: data))
        }
        // Request new timeline in 1 minute
        let refresh = Calendar.current.date(byAdding: .minute, value: 1, to: .now)!
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}
```

Five entries are generated so WidgetKit has room to pace them. All five carry the same data snapshot (we can't predict future CPU). The `.after(refresh)` policy tells WidgetKit to call `getTimeline` again in 1 minute for a fresh snapshot.

---

## Widget Views

### Size switching

```swift
struct HaloWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: HaloEntry

    var body: some View {
        switch family {
        case .systemSmall:  HaloSmallView(entry: entry)
        case .systemMedium: HaloMediumView(entry: entry)
        default:            HaloLargeView(entry: entry)
        }
    }
}
```

### HaloSmallView (systemSmall)
- Halo logo + name header
- CPU progress bar with colour ramp
- RAM progress bar with GB detail

### HaloMediumView (systemMedium)
- Left panel: CPU + RAM gauges (same as small)
- Divider
- Right panel: Network label, upload arrow + value, download arrow + value

### HaloLargeView (systemLarge)
- Header with logo and live clock (`Text(entry.date, style: .time)`)
- CPU + RAM gauges
- Network row (icon + upload + download in a surface card)
- Divider
- Clipboard section: numbered list of up to 5 recent text items

### Colour ramp

```swift
static func rampColor(for value: Double) -> Color {
    value > 0.85 ? .wRed : value > 0.6 ? .wAmber : .wGreen
}
```
Green → Amber → Red as values climb above 60% and 85%.

---

## Design Tokens (Widget-inlined)

The widget extension cannot import `DesignSystem.swift` from the main target. Colours are inlined in `HaloWidget.swift` as a private `Color` extension:

| Token | Hex | Used for |
|-------|-----|---------|
| `wBackground` | `#080c14` | Widget background fill |
| `wSurface` | `#0d1220` | Cards (network row, clipboard row) |
| `wAccent` | `#4f7cff` | Upload arrow, row numbers |
| `wAccent2` | `#7b5ea7` | Logo gradient |
| `wGreen` | `#22d97a` | Download arrow, low-load state |
| `wAmber` | `#f5a623` | Medium-load state |
| `wRed` | `#ff4d6a` | High-load state |
| `wText` | white | Primary text |
| `wText2` | white 60% | Secondary labels |
| `wText3` | white 35% | Tertiary (timestamps) |
| `wBorder` | white 8% | Dividers, gauge tracks |

**Keep these in sync with `DesignSystem.swift`.** If you change a colour token in one place, update the other.

---

## macOS 14 Compatibility

`containerBackground(.clear, for: .widget)` is macOS 14.0+ API. It is guarded:

```swift
if #available(macOS 14.0, *) {
    HaloWidgetEntryView(entry: entry)
        .containerBackground(.clear, for: .widget)
} else {
    HaloWidgetEntryView(entry: entry)
}
```

Do not remove this guard — the project minimum deployment target is macOS 13.0.

---

## Entitlements

`HaloWidget/HaloWidget.entitlements`:
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.halo.mac</string>
</array>
```

The widget must be sandboxed (it's an app extension). The App Group entitlement on **both** targets is what enables shared `UserDefaults`.

---

## Registering the Widget with pluginkit

macOS only discovers widget extensions from apps in `/Applications` or `~/Applications`.

```bash
# Register (or re-register after a new build)
# NOTE: Halo.app must be in ~/Applications or /Applications for macOS to discover the widget.
pluginkit -a ~/Applications/Halo.app/Contents/PlugIns/HaloWidget.appex

# Verify registration
pluginkit -mAvvv -p com.apple.widgetkit-extension | grep -A6 "com.halo.mac.widget"

# Force-spawn (useful for debugging)
pluginkit -e use -i com.halo.mac.widget
```

---

## Adding a New Widget Size

1. Create a new `View` struct (e.g., `HaloExtraLargeView`) in `HaloWidget.swift`.
2. Add `.systemExtraLarge` to `HaloWidgetEntryView`'s switch.
3. Add `.systemExtraLarge` to `HaloSystemWidget.supportedFamilies`.
4. Test with the `#Preview(as: .systemExtraLarge)` macro (macOS 14+ only — wrap in `@available`).

---

## Adding a New Metric to the Widget

1. Add the property to `HaloWidgetData` in `Shared/HaloSharedData.swift`.
2. Populate it in `AppState.writeWidgetData()`.
3. Read it in the widget view (`entry.data.yourNewProperty`).
4. Re-build both targets (the file compiles into both).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Widget not in gallery | App not in `~/Applications` or `/Applications` | `cp -R build/Halo.app ~/Applications/` then `pluginkit -a …` |
| Widget shows placeholder data | App Group not writing | Check `Halo-Debug.entitlements` has `group.com.halo.mac`; verify plist with `python3` snippet above |
| Widget freezes / stops updating | `reloadAllTimelines()` budget exhausted | Ensure it's called at most once per minute |
| TeamIdentifier mismatch on launch | dylibs signed after outer bundle | Always sign in order: dylibs → Sentry.framework → appex → app |
| `#Preview` compile error | macOS 14 API on 13.0 target | Wrap in `@available(macOS 14.0, *)` |
