# Halo Design System

All visual tokens, reusable components, and typography rules live in `DesignSystem/DesignSystem.swift`. This document is the human-readable reference.

---

## Colour Palette

### SwiftUI usage: `Color.haloAccent`, `Color.haloGreen`, etc.

| Token | `Color` property | Hex | Role |
|-------|-----------------|-----|------|
| Background | `.haloBackground` | `#080c14` | Window/widget fill — deepest layer |
| Surface | `.haloSurface` | `#0d1220` | Cards, sidebars — one step above background |
| Surface2 | `.haloSurface2` | `#131928` | Nested containers, input fields |
| Border | `.haloBorder` | `rgba(255,255,255,0.08)` | Dividers, card strokes |
| Accent | `.haloAccent` | `#4f7cff` | Primary CTA, active states, links |
| Accent2 | `.haloAccent2` | `#7b5ea7` | Gradient pair for Accent (logo, highlights) |
| Green | `.haloGreen` | `#22d97a` | Success, healthy, low-load |
| Amber | `.haloAmber` | `#f5a623` | Warning, medium-load |
| Red | `.haloRed` | `#ff4d6a` | Error, critical load, threats |
| Cyan | `.haloCyan` | `#00d4e8` | URL clipboard items |
| Purple | `.haloPurple` | `#b06cff` | Code clipboard items |
| Text | `.haloText` | white | Primary labels |
| Text2 | `.haloText2` | `rgba(255,255,255,0.6)` | Secondary / supporting labels |
| Text3 | `.haloText3` | `rgba(255,255,255,0.35)` | Tertiary / disabled / timestamps |

### Hex init helper (available in both targets)

```swift
// Works in main app via DesignSystem.swift
// Inlined in HaloWidget.swift for the widget extension
Color(hex: "#4f7cff")
```

### Semantic colour rules

- **Always use tokens** — never hardcode `Color(.sRGB, red: 0.31, …)`.
- Use `rampColor(for:)` when the colour should respond to a 0–1 metric:
  ```swift
  Color.rampColor(for: cpuUsage)  // green → amber → red
  ```

---

## Typography

```swift
HaloFont.display(22, weight: .bold)    // Dashboard header, onboarding titles
HaloFont.body(13)                      // Standard body copy
HaloFont.body(13, weight: .medium)     // Slightly emphasised body
HaloFont.mono(11)                      // Code snippets, hex values, counts
HaloFont.caption(10)                   // Labels, badges, small UI text
```

`HaloFont` wraps `Font.system(size:weight:design:)` — no custom font files required.

---

## Reusable Components

### HaloCard

A surface-coloured rounded rectangle container. Use for any grouping of related content.

```swift
HaloCard {
    VStack { ... }
}

// With custom padding or corner radius:
HaloCard(padding: 20, cornerRadius: 16) {
    Text("Custom")
}
```

- Background: `.haloSurface`
- Corner radius: 12 (default)
- Padding: 16 (default)
- Subtle border: `.haloBorder` stroke

### HaloPrimaryButton

The main call-to-action button. Supports a loading spinner.

```swift
HaloPrimaryButton("Smart Scan", icon: "play.fill", isLoading: appState.isSmartScanRunning) {
    Task { await appState.runSmartScan() }
}
```

- Background: linear gradient from `.haloAccent` to `.haloAccent2`
- When `isLoading = true`: shows a `ProgressView` and disables the button
- Icon is optional

### HaloToggle

A styled `Toggle` with the accent colour.

```swift
HaloToggle("Enable feature", isOn: $featureEnabled)
```

### HaloHealthRing

An animated circular progress indicator for the system health score (0–100).

```swift
HaloHealthRing(score: appState.systemHealthScore, size: 120)
```

- Green at 75+, amber at 50–74, red below 50
- Animates on value change

### HaloMetricCard

A stat card combining icon, value, label, and an optional mini chart.

```swift
HaloMetricCard(
    icon: "cpu",
    value: "\(Int(cpuUsage * 100))%",
    label: "CPU Usage",
    accent: .haloAccent,
    chartData: cpuHistory    // [Double], optional
)
```

### StatGauge (Widget)

Used inside widget views — a mini labelled progress bar.

```swift
StatGauge(
    label: "CPU",
    value: entry.data.cpuUsage,    // 0–1
    detail: "42%"
)
```

### MenuBarIconView

The live menu bar icon component. Respects `@AppStorage("menuBarDisplayStyle")`.

```swift
MenuBarIconView(
    state: menuBarManager.pressureLevel,
    cpuUsage: appState.cpuUsage,
    ramUsage: appState.ramUsage
)
```

Four display styles, controlled by `MenuBarDisplayStyle` enum:

| Style | Appearance |
|-------|-----------|
| `.icon` | Halo SF Symbol glyph (default) |
| `.textStats` | `"CPU 42% · RAM 61%"` text label |
| `.miniBar` | Two 4 px capsule progress bars (CPU left, RAM right) |
| `.dot` | Single filled circle: green/amber/red based on system pressure |

### MiniProgressBar (internal)

Private sub-component of `.miniBar` style. A 4 px tall `Capsule` with a coloured fill overlay.

```swift
// Internal usage only — not exported from DesignSystem.swift
MiniProgressBar(value: cpuUsage, color: .rampColor(for: cpuUsage))
```

### AlertEntryRow

Used in `DashboardView.AlertHistorySection` to render a single `AlertEntry`.

```
┌─────────────────────────────────────────────┐
│  [icon circle]  Title (bold if unread)  [•] │
│                 Body text preview           │
│                 2 minutes ago               │
└─────────────────────────────────────────────┘
```

- Icon circle background: `accentColor.opacity(0.15)`, foreground: `accentColor`
- Title: `.haloText` bold when `!isRead`, `.haloText2` when read
- Body: `.haloText3`, single line, truncated
- Timestamp: relative format via `RelativeDateTimeFormatter`
- Unread dot: 6 pt filled circle in `.haloAccent` (hidden when read)

### AlertHistorySection (Dashboard)

Expandable card embedded in `DashboardView`:

```swift
AlertHistorySection()
    .environmentObject(appState)
```

- Header: "Recent Alerts" + unread count badge + expand/collapse chevron
- Shows up to 8 entries when expanded
- **Clear** button marks all read and calls `AlertLog.shared.clearAll()`
- Tapping a row calls `AlertLog.shared.markRead(entry.id)`

---

## Spacing & Layout Constants

Use these values to keep layouts consistent:

| Purpose | Value |
|---------|-------|
| Window content padding | 28 pt |
| Card internal padding | 16 pt |
| Inter-card gap | 16–24 pt |
| Sidebar width | 200 pt |
| Row height (list items) | 44 pt |

---

## Icon Usage

All icons are **SF Symbols**. Pick the filled variant (`.fill`) for active/selected states and the outlined variant for inactive states.

| Concept | Symbol |
|---------|--------|
| Dashboard | `house.fill` |
| Cleanup | `sparkles` |
| Protection | `shield.fill` |
| Performance | `bolt.fill` |
| Applications | `square.stack.3d.up.fill` |
| Files | `folder.fill` |
| Clipboard | `doc.on.clipboard.fill` |
| Menu Bar | `menubar.rectangle` |
| Health good | `checkmark.circle.fill` |
| Health warning | `exclamationmark.triangle.fill` |
| Upload | `arrow.up.circle.fill` |
| Download | `arrow.down.circle.fill` |
| Delete / Trash | `trash.fill` |
| Pin | `pin.fill` |
| Search | `magnifyingglass` |
| Settings | `gearshape.fill` |
| Alert / threat | `exclamationmark.shield.fill` |
| Report export | `doc.text.fill` |
| Schedule | `calendar.badge.clock` |
| Login item | `person.crop.circle.fill` |

---

## Alert Accent Colours

`AlertEntry.accentColor` is derived from `kindRaw`:

| Kind | Color |
|------|-------|
| `"threat"` | `.haloRed` |
| `"scan"` | `.haloAccent` |
| `"cleanup"` | `.haloGreen` |
| `"warning"` | `.haloAmber` |
| `"info"` / default | `.haloText2` |

---

## Dark-Only

Halo is a **dark-only** app. Do not use `Color.primary`, `Color.secondary`, or adaptive colours that change in light mode. All colours are absolute hex values.

If Apple adds a light-mode requirement in the future, every `Color` extension in `DesignSystem.swift` will need a companion `Color(light:dark:)` pair — this is the only file to change.

---

## Adding a New Token

1. Add the `static let` to the `Color` extension in `DesignSystem.swift`.
2. If it's needed in the widget too, add it to the inlined `Color` extension in `HaloWidget.swift`.
3. Document it in this file.

**Never** add a new colour without adding it here — undocumented tokens get duplicated and diverge.
