# Phase 2 — Per-Display Brightness Control

**Feature name:** Display Brightness Manager  
**Module ID:** `displays`  
**Status:** Planned  
**Priority:** High  
**Estimated effort:** 3–4 days  
**Target macOS:** 13.0+ (Ventura)

---

## 1. Feature Overview

Add a new **Displays** module to Halo that lets users control the brightness of every connected monitor individually — built-in Retina panel, external USB-C/HDMI/Thunderbolt displays — all from one unified interface. No third-party software required.

### User story
> *"As a multi-monitor user I want to adjust the brightness of each screen independently from Halo, without hunting through System Settings or using multiple apps."*

### Key capabilities
| Capability | Built-in display | External displays |
|---|---|---|
| Read current brightness | ✅ CoreDisplay API | ✅ DDC/CI via IOKit |
| Set brightness | ✅ CoreDisplay API | ✅ DDC/CI via IOKit |
| Display name & resolution | ✅ CGDisplay / NSScreen | ✅ CGDisplay / NSScreen |
| Night Shift schedule | ✅ CBBlueLightClient | ✅ CBBlueLightClient |
| True Tone | ✅ (read-only via CoreDisplay) | ❌ hardware-only |
| Auto-dim on idle | ✅ via IOKit display sleep | ❌ |
| **Menu bar brightness control** | ✅ **MANDATORY** — compact slider in MenuBarExtra popover | ✅ |

---

## 2. Technical Analysis

### 2.1 Display Enumeration

```swift
// CGGetActiveDisplayList — enumerates all active displays
var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
```

Cross-reference with `NSScreen.screens` to get `localizedName`, `frame`, `backingScaleFactor`, and `colorSpace`.

### 2.2 Brightness — Built-in Display

Use the **private `CoreDisplay` framework** (available on all Macs, used by System Preferences itself):

```swift
// Link via: OTHER_LDFLAGS = -framework CoreDisplay
// Header bridged via BridgingHeader or @_silgen_name

@_silgen_name("CoreDisplay_Display_GetUserBrightness")
func CoreDisplay_Display_GetUserBrightness(_ display: CGDirectDisplayID) -> Double

@_silgen_name("CoreDisplay_Display_SetUserBrightness")
func CoreDisplay_Display_SetUserBrightness(_ display: CGDirectDisplayID, _ brightness: Double)
```

`CoreDisplay` is a private Apple framework located at:
`/System/Library/PrivateFrameworks/CoreDisplay.framework`

For non-sandboxed debug builds this links directly. For App Store builds, use `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (also private, same restrictions).

**Fallback (public API path):**
```swift
import IOKit
let service = IOServiceGetMatchingService(
    kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(brightness))
IOObjectRelease(service)
```

### 2.3 Brightness — External Displays (DDC/CI)

External monitors expose brightness via the **DDC/CI** (Display Data Channel / Command Interface) protocol over I²C. On Apple Silicon Macs this is mediated by `IOAVService`; on Intel it goes through `IOFramebufferUserClient`.

**Apple Silicon path (`IOAVService`):**
```swift
// Private XPC: com.apple.ioavserviced
// Used by open-source MonitorControl project
// Requires IOKit entitlement exception in debug builds
```

**Intel path (`I2C` via IOKit):**
```swift
// Match service: "IOFramebufferUserClient"
// Send DDC VCP code 0x10 (Brightness) via I2CRequest
```

**Practical approach:**  
Bundle a lightweight DDC helper (adapted from open-source `MonitorControl`'s DDC.swift, Apache-2.0 licensed) as a single file `Core/Display/DDCHelper.swift`. This avoids a full SPM dependency and keeps the binary small.

DDC VCP codes used:
| Code | Name |
|------|------|
| `0x10` | Brightness |
| `0x12` | Contrast |
| `0xD6` | Power Mode |

### 2.4 Night Shift Integration

```swift
import CoreBluetooth
// CBBlueLightClient (private, used by System Preferences)
// Controls colour temperature shift (warm/cool)
// Can enable/disable schedule, set manual colour temp

let client = CBBlueLightClient()
client.setEnabled(true)           // toggle Night Shift
client.setBlueLightReduction(0.7) // 0.0 = off, 1.0 = full warm
```

### 2.5 Display Change Notifications

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main) { _ in
        // Rebuild display list (monitor plugged/unplugged)
    }
```

### 2.6 Entitlement Requirements

| Entitlement | Debug build | Release (App Store) |
|---|---|---|
| `com.apple.security.app-sandbox` | OFF (already) | ON |
| IOKit user-client exception | Not needed (no sandbox) | Needs `com.apple.security.temporary-exception.iokit-user-client-class` with value `IOFramebufferUserClient` |
| CoreDisplay private framework | Links directly | Apple may reject — use `DisplayServices` wrapper instead |

**App Store path note:** Apple has historically approved apps using `CoreDisplay` since it ships on every Mac. MonitorControl is on the Mac App Store and uses the same approach.

---

## 3. Architecture

```
Halo/
├── Core/
│   └── Display/
│       ├── DisplayBrightnessManager.swift   ← actor, all IOKit/CoreDisplay calls
│       └── DDCHelper.swift                  ← DDC/CI I²C helper for external displays
├── Features/
│   └── Displays/
│       └── DisplaysView.swift               ← view + DisplaysViewModel (same file, per project convention)
```

### 3.1 `DisplayBrightnessManager` (actor)

```swift
actor DisplayBrightnessManager {

    // Enumerate all connected displays
    func allDisplays() async -> [ConnectedDisplay]

    // Read current brightness (0.0 – 1.0)
    func brightness(for displayID: CGDirectDisplayID) async -> Double

    // Set brightness (0.0 – 1.0), animated over ~200ms
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) async

    // Night Shift
    func nightShiftEnabled() -> Bool
    func setNightShift(enabled: Bool)
    func nightShiftStrength() -> Double      // 0.0 – 1.0
    func setNightShiftStrength(_ value: Double)
}
```

### 3.2 `ConnectedDisplay` model

```swift
struct ConnectedDisplay: Identifiable {
    let id: CGDirectDisplayID          // unique per session
    let name: String                   // "Built-in Retina Display", "LG UltraFine 5K"
    let resolution: CGSize             // native pixels
    let refreshRate: Double            // Hz
    let isBuiltIn: Bool
    let isMain: Bool
    let physicalSizeInches: Double?    // diagonal, computed from mm
    var brightness: Double             // 0.0 – 1.0, mutable, drives slider
    var isDDCCapable: Bool             // false = brightness slider hidden for external
}
```

### 3.3 `DisplaysViewModel`

```swift
@MainActor
final class DisplaysViewModel: ObservableObject {
    @Published var displays: [ConnectedDisplay] = []
    @Published var nightShiftEnabled: Bool = false
    @Published var nightShiftStrength: Double = 0.5
    @Published var isLoading: Bool = false

    private let manager = DisplayBrightnessManager()
    private var debounceTask: Task<Void, Never>?

    func loadDisplays() async { ... }

    // Called on slider change — debounce 80ms to avoid IOKit spam
    func setBrightness(_ value: Double, for display: ConnectedDisplay) { ... }

    func toggleNightShift() { ... }
}
```

---

## 4. UI Design

### 4.1 Module entry
- Sidebar item label: **"Displays"**
- Sidebar icon: `sun.max.fill`
- Gradient colours: `[Color(hex: "#1a3050"), Color(hex: "#0e2040")]`
- Badge: number of connected displays (e.g. "2")

### 4.2 Layout (DisplaysView)

```
┌─────────────────────────────────────────────────────────────┐
│  Displays                                  2 connected       │
│  Brightness · Night Shift · Resolution                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────────────┐  ┌───────────────────────┐│
│  │ ☀  Built-in Retina Display   │  │ ☀  LG UltraFine 5K   ││
│  │     2560 × 1600 · 60 Hz      │  │    5120 × 2880 · 60Hz ││
│  │     ● Main display           │  │    External · 27"      ││
│  │                              │  │                        ││
│  │  Brightness                  │  │  Brightness            ││
│  │  ○──────────────●────── 72%  │  │  ○──────────────●ー 60%││
│  │                              │  │                        ││
│  │  [  Set to 100%  ]           │  │  [  Set to 100%  ]     ││
│  │  [  Set to  50%  ]           │  │  [  Set to  50%  ]     ││
│  └──────────────────────────────┘  └───────────────────────┘│
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  🌙  Night Shift                          [ ON ] ─────  ││
│  │  Warm colour temperature reduces eye strain after dark   ││
│  │  Strength  ○────────────────────● ─────────────── 70%   ││
│  │  Schedule  Sunset to Sunrise  [  Custom... ]             ││
│  └─────────────────────────────────────────────────────────┘│
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  📐  Display Info                                        ││
│  │  Built-in   2560×1600  ·  16:10  ·  227 ppi  ·  13.3"  ││
│  │  LG 5K      5120×2880  ·  16:9   ·  218 ppi  ·  27.0"  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### 4.3 Display Card component

```swift
struct DisplayCard: View {
    @Binding var display: ConnectedDisplay
    let onBrightnessChange: (Double) -> Void

    // HaloCard wrapping:
    // - Display icon (built-in: "laptopcomputer" / external: "display")
    // - Name + resolution subtitle
    // - "Main" badge if isMain
    // - HaloSlider for brightness (0–100, step 1)
    // - Quick-set buttons: 25% / 50% / 75% / 100%
    // - If !isDDCCapable → amber note "DDC not supported on this display"
}
```

### 4.4 Night Shift Card

```swift
struct NightShiftCard: View {
    @Binding var isEnabled: Bool
    @Binding var strength: Double
    let onToggle: () -> Void
    let onStrengthChange: (Double) -> Void

    // Row: moon icon + title + HaloToggle
    // Strength slider (only visible when enabled)
    // Schedule picker (system default or custom range)
}
```

---

## 5. Step-by-Step Execution Plan

### Step 1 — Data Model (`Models.swift`)
**File:** `Halo/Core/Models/Models.swift`  
**Action:** Append `ConnectedDisplay` struct.

```swift
// MARK: - Display Models

struct ConnectedDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let resolution: CGSize
    let scaleFactor: CGFloat
    let refreshRate: Double
    let isBuiltIn: Bool
    let isMain: Bool
    let physicalSizeInches: Double?
    var brightness: Double              // 0.0 – 1.0
    var isDDCCapable: Bool
}
```

---

### Step 2 — DDC Helper (`DDCHelper.swift`)
**File:** `Halo/Core/Display/DDCHelper.swift` *(new)*  
**Action:** Implement DDC/CI I²C read-write for external display brightness.

Key functions:
```swift
// Returns true if DDC write succeeded
func setDDCBrightness(_ brightness: UInt16, displayID: CGDirectDisplayID) -> Bool

// Returns current brightness (0–100) or nil if DDC unsupported
func getDDCBrightness(displayID: CGDirectDisplayID) -> UInt16?
```

Implementation uses:
- `IOServiceGetMatchingService` matching `"AppleBacklightDisplay"` for built-in
- `IOFramebufferUserClient` for external Intel
- `IOAVServiceCreate` for external Apple Silicon

---

### Step 3 — Brightness Manager (`DisplayBrightnessManager.swift`)
**File:** `Halo/Core/Display/DisplayBrightnessManager.swift` *(new)*  
**Action:** Actor wrapping all display I/O.

```swift
import CoreGraphics
import IOKit
import Foundation

actor DisplayBrightnessManager {
    func allDisplays() -> [ConnectedDisplay] { ... }
    func brightness(for id: CGDirectDisplayID) -> Double { ... }
    func setBrightness(_ v: Double, for id: CGDirectDisplayID) { ... }
    func nightShiftEnabled() -> Bool { ... }
    func setNightShift(enabled: Bool) { ... }
    func nightShiftStrength() -> Double { ... }
    func setNightShiftStrength(_ v: Double) { ... }
}
```

CoreDisplay bridging (add to `Halo-Bridging-Header.h`):
```objc
// Brightness (built-in display)
extern double CoreDisplay_Display_GetUserBrightness(uint32_t display);
extern void   CoreDisplay_Display_SetUserBrightness(uint32_t display, double brightness);
// Night Shift colour temperature
extern int    DisplayServicesGetBrightness(uint32_t display, float *brightness);
extern int    DisplayServicesSetBrightness(uint32_t display, float brightness);
```

Build setting: `OTHER_LDFLAGS = -framework CoreDisplay`

---

### Step 4 — View & ViewModel (`DisplaysView.swift`)
**File:** `Halo/Features/Displays/DisplaysView.swift` *(new)*  
**Action:** Full SwiftUI view following PerformanceView pattern.

Sub-views:
- `DisplaysHeader` — title, subtitle, connected count badge
- `DisplayCard` — per-display HaloCard with brightness slider + quick-set buttons
- `NightShiftCard` — toggle + strength slider + schedule row
- `DisplayInfoTable` — compact resolution / PPI / size grid

State flow:
```
DisplaysView
  └── @StateObject DisplaysViewModel
        ├── @Published displays: [ConnectedDisplay]
        └── actor DisplayBrightnessManager (debounced 80ms)
```

---

### Step 5 — Register Module (`AppState.swift`)
**File:** `Halo/App/AppState.swift`  
**Action:** Add `.displays` case to `AppModule` enum.

```swift
// in AppModule enum:
case displays

// title:
case .displays: return "Displays"

// icon:
case .displays: return "sun.max.fill"

// gradientColors:
case .displays: return [Color(hex: "#1a3050"), Color(hex: "#0e2040")]
```

---

### Step 6 — Wire up Sidebar & Router (`ContentView.swift`)
**File:** `Halo/App/ContentView.swift`  
**Action 1:** Add sidebar item.
```swift
// In SidebarView, add under Modules section:
SidebarItem(module: .displays,
            badge: "\(appState.connectedDisplayCount)",
            badgeColor: .haloAccent)
```

**Action 2:** Add to `DetailView` router.
```swift
case .displays: DisplaysView()
```

---

### Step 7 — AppState display count (`AppState.swift`)
**File:** `Halo/App/AppState.swift`  
**Action:** Add one published property and populate in `refreshMetrics()`.

```swift
@Published var connectedDisplayCount: Int = 1

// in refreshMetrics():
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
connectedDisplayCount = max(1, Int(count))
```

---

### Step 8 — Entitlements (`Halo-Debug.entitlements`)
**File:** `Halo/Halo-Debug.entitlements`  
**Action:** Already sandbox-OFF for debug, so no changes needed.  
For release entitlements, add:
```xml
<key>com.apple.security.temporary-exception.iokit-user-client-class</key>
<array>
    <string>IOFramebufferUserClient</string>
    <string>IOAVServiceUserClient</string>
</array>
```

---

### Step 9 — CLAUDE.md update
**File:** `CLAUDE.md`  
**Action:** Add `displays` to the Modules Status table and the Directory Layout.

---

### Step 10 — Build, sign, run validation
```bash
xcodebuild -project Halo.xcodeproj -scheme Halo -configuration Debug \
  -derivedDataPath /tmp/HaloBuild \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  clean build

# Sign + install (same sequence as Phase 1)
CERT="Apple Development: MobileApp Developers (ZWA6Q77327)"
APP="/tmp/HaloBuild/Build/Products/Debug/Halo.app"
find "$APP" -name "*.dylib" | xargs -I{} codesign --force --sign "$CERT" --timestamp=none {}
codesign --force --sign "$CERT" --entitlements HaloWidget/HaloWidget.entitlements \
  --timestamp=none "$APP/Contents/PlugIns/HaloWidget.appex"
codesign --force --sign "$CERT" --entitlements Halo/Halo-Debug.entitlements \
  --timestamp=none "$APP"
cp -R "$APP" ~/Applications/Halo.app
open ~/Applications/Halo.app
```

Validation checklist:
- [ ] Displays module appears in sidebar with display count badge
- [ ] Built-in display brightness slider moves actual screen brightness
- [ ] External display card appears when second monitor connected
- [ ] Unplugging a monitor removes its card (NSNotification fires correctly)
- [ ] Night Shift toggle reflects and changes system Night Shift state
- [ ] Brightness debounce prevents IOKit spam (max 12 calls/sec)
- [ ] No crash when built-in panel sleeping / lid closed

---

## 6. Edge Cases & Known Constraints

| Scenario | Handling |
|---|---|
| Mac Mini / Mac Pro (no built-in display) | `isBuiltIn = false` for all; omit "Main" badge logic |
| External display with no DDC support | `isDDCCapable = false`; show amber warning, hide slider |
| Display brightness at 0% | Clamp to 2% minimum to prevent accidental blackout |
| Permission denied on IOKit call | Catch return code, surface inline error in card |
| Lid-closed clamshell mode | Filter out `CGDisplayIsAsleep()` displays |
| AirPlay / Sidecar display | Detect via `CGDisplayIsInMirrorSet()`, mark read-only |
| macOS 13 vs macOS 14+ | `CBBlueLightClient` available on both; CoreDisplay available 12+ |
| Rapid slider dragging | 80ms debounce on `setBrightness()` using `Task.sleep` cancellation |

---

## 7. File Checklist

| File | Action |
|------|--------|
| `Halo/Core/Models/Models.swift` | Append `ConnectedDisplay` struct |
| `Halo/Core/Display/DisplayBrightnessManager.swift` | **Create new** |
| `Halo/Core/Display/DDCHelper.swift` | **Create new** |
| `Halo/Features/Displays/DisplaysView.swift` | **Create new** |
| `Halo/App/AppState.swift` | Add `.displays` case + `connectedDisplayCount` |
| `Halo/App/ContentView.swift` | Sidebar item + DetailView router case |
| `Halo/Halo.entitlements` | Add IOKit user-client exceptions (release only) |
| `CLAUDE.md` | Update Modules Status table + Directory Layout |
| `docs/ROADMAP.md` | Mark Phase 2 added, move to Planned section |
| `Halo.xcodeproj/project.pbxproj` | Add new source files to main target |

---

## 8. Dependencies

| Dependency | Type | Source |
|---|---|---|
| `CoreDisplay.framework` | Apple private framework | Ships on every Mac, `/System/Library/PrivateFrameworks/` |
| `IOKit.framework` | Apple public framework | Already linked (used by SystemMonitor) |
| `CoreGraphics.framework` | Apple public framework | Already linked (SwiftUI dependency) |
| `DDC.swift` logic | Adapted from MonitorControl | Apache-2.0, adapted inline — no SPM package needed |

No new SPM packages required.

---

## 9. Acceptance Criteria

1. **Brightness control works** on built-in Retina display (verified by visible change).
2. **External display** brightness slider changes monitor brightness via DDC (tested with at least one external monitor).
3. **Display list auto-updates** when monitors are connected/disconnected without restart.
4. **Night Shift** toggle and strength slider reflect macOS system state bidirectionally.
5. **No IOKit spam** — slider drag does not exceed ~12 IOKit calls/sec.
6. **Build succeeds** with zero errors on macOS 13.0+ target.
7. **No regression** in any existing module (all existing tests pass).

---

*Document created: 2026-05-06*  
*Author: Claude (Halo AI Agent)*  
*Phase: 2*
