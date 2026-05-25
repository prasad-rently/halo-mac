# Halo — Phase 3 Roadmap

> **Design principle: lightweight first.**
> Halo must stay under **50 MB resident RAM** and **< 1% average CPU** while running in the background. Every new feature in Phase 3 is classified before implementation:
>
> | Class | When it runs | Rule |
> |---|---|---|
> | 🟢 **Always-background** | Continuously, even when app is hidden | Must be event-driven or timer-gated (≤ 30 s interval). No blocking calls, no file I/O in the hot path. |
> | 🟡 **Foreground-active** | Only while the relevant Halo view is visible on screen | Start on `onAppear`, cancel on `onDisappear`. Timer destroyed when view leaves hierarchy. |
> | 🔴 **On-demand** | Only when the user explicitly triggers the action | Zero background footprint. Result cached for the session; never auto-repeats. |

---

## Competitive Gap Analysis — Stats vs Halo

The table below maps every Stats capability against Halo and classifies the planned Phase 3 addition.

| Stats Feature | Halo Today | Phase 3 Plan | Class |
|---|---|---|---|
| CPU per-core breakdown | ❌ | P3-01 | 🟡 Foreground |
| CPU temperature | ❌ | P3-02 | 🟡 Foreground |
| GPU utilisation | ❌ | P3-03 | 🟡 Foreground |
| GPU temperature / VRAM | ❌ | P3-03 | 🟡 Foreground |
| Battery cycle count / health | Basic level only | P3-04 | 🟢 Background |
| Battery amperage / voltage | ❌ | P3-04 | 🟡 Foreground |
| Sensor readings (SMC) | ❌ | P3-02 | 🟡 Foreground |
| Fan speed (read-only) | ❌ | P3-02 | 🟡 Foreground |
| Network public IP | ❌ | P3-05 | 🟡 Foreground |
| Network local IP / WiFi SSID | ❌ | P3-05 | 🟡 Foreground |
| VPN detection | ❌ | P3-05 | 🟢 Background |
| Network latency (ping) | ❌ | P3-06 | 🔴 On-demand |
| Internet speed test | ❌ | P3-06 | 🔴 On-demand |
| Disk SMART health | ❌ | P3-07 | 🔴 On-demand |
| Disk lifetime read/write | ❌ | P3-07 | 🟡 Foreground |
| CPU / RAM / Disk threshold alerts | ❌ | P3-08 | 🟢 Background |
| Battery low / charging alerts | ❌ | P3-08 | 🟢 Background |
| Menu bar display styles | Basic text | P3-09 | 🟢 Background |
| Menu bar module order/toggle | ❌ | P3-09 | 🟢 Background |
| Network bandwidth history | ❌ | P3-10 | 🟡 Foreground |
| Processes list (top processes) | ❌ | P3-11 | 🟡 Foreground |
| Settings: thresholds + intervals | ❌ | P3-12 | — |

---

## P3-01 · Per-Core CPU Breakdown

**Class:** 🟡 Foreground-active (destroyed when Dashboard/Performance tab is closed)

### What it does
Shows a horizontal bar per logical CPU core with its individual utilisation percentage, distinguishing **Efficiency** cores (E-cores) from **Performance** cores (P-cores) on Apple Silicon. The existing 2-second `metricsTimer` in `AppState` is not affected — this runs on its own foreground timer that is created on `onAppear` and torn down on `onDisappear`.

### Why it's lightweight
`host_processor_info()` is a single Mach syscall. It returns all core data in one shot — no per-core polling, no file I/O. Cost is negligible (~0.01% CPU per call). The timer only runs while the view is visible.

### Implementation detail

**New file:** `Halo/Core/Scanner/CPUDetailMonitor.swift`
```swift
actor CPUDetailMonitor {
    struct CoreSample: Sendable {
        let index: Int
        let usage: Double          // 0.0–1.0
        let isEfficiency: Bool     // E-core vs P-core
    }

    func sample() -> [CoreSample]
    // Uses host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)
    // Diffs tick counts between two calls to derive per-core % (same technique as top/Activity Monitor)
}
```

**View change:** `Features/Performance/PerformanceView.swift`
- New `CPUCoresSection` view with `LazyVStack` of thin bar rows
- `@StateObject private var coreMonitor = CPUDetailMonitor()`
- Timer: every 2 s, alive only while section is expanded

**Dashboard change:** `Features/Dashboard/DashboardView.swift`
- CPU metric card gains an expandable mini-core grid (toggle, off by default)

**E/P-core detection:**
- Read `hw.perflevel0.physicalcpu` (P-cores) and `hw.perflevel1.physicalcpu` (E-cores) via `sysctlbyname` once at init — no ongoing cost

**Effort:** 2 days

---

## P3-02 · Thermal Sensors & Fan Speed (SMC Reader)

**Class:** 🟡 Foreground-active

### What it does
Reads Apple Silicon / Intel SMC (System Management Controller) temperature sensors and fan RPM. Surfaces:
- CPU die temperature (°C / °F, user preference)
- GPU temperature
- SSD / NVMe temperature
- Battery temperature
- Fan speed (RPM) — read-only, no control
- All shown in a new **Sensors** section in the Performance tab

### Why it's lightweight
SMC reads are synchronous IOKit calls (~0.5 ms each). We batch all sensor reads into a single 5-second foreground timer (not the background 2-second metrics timer). Zero cost when the Sensors section is closed.

### Implementation detail

**New file:** `Halo/Core/Scanner/SMCReader.swift`
```swift
actor SMCReader {
    struct SensorReading: Sendable {
        let key: String        // e.g. "CPU die temperature"
        let value: Double
        let unit: SensorUnit   // .celsius, .rpm
    }

    func readAll() -> [SensorReading]
    // Opens IOKit SMCService, reads known SMC keys:
    // TC0P = CPU proximity temp, TG0P = GPU temp,
    // Ts0S = SSD temp, TB0T = battery temp, F0Ac = fan 0 speed
}
```

**New section view:** `Features/Performance/SensorsSection.swift`
- Segmented list of temperature rows + fan row
- Temperature unit toggle (°C / °F) stored in `@AppStorage("temperatureUnit")`
- Amber highlight when any sensor exceeds a threshold (user-configurable in Settings, default: CPU > 90°C)

**Effort:** 3 days

---

## P3-03 · GPU Metrics

**Class:** 🟡 Foreground-active

### What it does
For **Apple Silicon** Macs, reads:
- GPU utilisation % (render pipeline busy time)
- GPU memory used / total (unified memory allocation to GPU)
- GPU temperature (via SMCReader, same as P3-02)

For **Intel + discrete GPU** Macs:
- GPU utilisation via IOAccelerator IOKit stats
- VRAM used / total

### Why it's lightweight
GPU stats are read via a single `IOServiceGetMatchingService(kIOAcceleratorClassName)` call per 2-second foreground tick. No continuous stream. Timer dies with the view.

### Implementation detail

**New file:** `Halo/Core/Scanner/GPUMonitor.swift`
```swift
actor GPUMonitor {
    struct GPUStats: Sendable {
        let utilisation: Double    // 0.0–1.0
        let memoryUsedMB: Int
        let memoryTotalMB: Int
        let temperature: Double?   // nil if SMC key unavailable
        let rendererUtilisation: Double
        let tilerUtilisation: Double
    }

    func sample() async -> GPUStats?
    // Matches IOAccelerator, reads PerformanceStatistics dictionary
}
```

**New GPU card:** Added to `DashboardView` metric card grid and a dedicated GPU section in Performance tab.

**Effort:** 2–3 days

---

## P3-04 · Battery Deep Intelligence

**Class:** 🟢 Always-background (cheap) + 🟡 Foreground (detail view)

### What it does

**Background (always, lightweight):**
- Battery percentage, charging state, and power source already tracked
- **Add:** low battery alert (≤ 20%, ≤ 10%), fully charged alert — threshold checks added to the existing 2-second `metricsTimer` at zero extra cost (no new timer, just an if-check on already-available IOKit data)

**Foreground (detail view, Performance tab → Battery section):**
- Cycle count (read once per session, not every 2 s — rarely changes)
- Design capacity vs current capacity (battery health %)
- Amperage (charge/discharge rate in mA)
- Voltage (mV)
- Time to empty / time to full
- Battery temperature (via SMCReader P3-02)
- Low Power Mode toggle

### Why it's lightweight
All battery data comes from `IOPSCopyPowerSourcesInfo()` and one IOKit service lookup (`AppleSmartBattery`) — already used in `SystemMonitor`. Cycle count and capacity are read once at session start and cached. The foreground view just presents cached data with a 10-second refresh.

### Implementation detail

**Modify:** `Halo/Core/Scanner/SystemMonitor.swift`
```swift
// Add to existing BatteryInfo struct:
var cycleCount: Int
var designCapacity: Int      // mAh
var currentCapacity: Int     // mAh (actual max)
var healthPercent: Double    // currentCapacity / designCapacity
var amperage: Int            // mA (negative = discharging)
var voltage: Int             // mV
var temperature: Double?     // °C, from SMC
var timeToEmpty: Int?        // minutes
var timeToFull: Int?         // minutes
```

**New section view:** `Features/Performance/BatteryDetailSection.swift`
- Health ring (green > 80%, amber 50–80%, red < 50%)
- Cycle count bar (0–1000, Apple's standard wear threshold)
- Amperage / voltage readings
- Capacity table (design vs current vs used)

**Alerts (AppState):**
```swift
// Added to existing refreshMetrics() — zero extra timer cost
if battery.percentage <= 10 && !lowBatteryAlertFired {
    sendNotification("Battery Critical", "Plug in your charger — \(battery.percentage)% remaining")
    lowBatteryAlertFired = true
}
```

**Effort:** 2 days

---

## P3-05 · Network Intelligence

**Class:** Mixed — 🟢 Background (VPN + reachability) · 🟡 Foreground (IP / WiFi detail)

### What it does

**Background — VPN detection (event-driven, not polling):**
- Observe `NWPathMonitor` (already available in Network framework) — fires callbacks only when network state changes (no continuous cost)
- Detect VPN: check `NWPath.usesInterfaceType(.other)` or interface name prefix (`utun`, `ipsec`, `ppp`)
- Show VPN badge in menu bar popover and Dashboard

**Foreground — Network detail view:**
- Local IP address (IPv4 + IPv6) per interface
- WiFi SSID and signal strength (via `CWWiFiClient`)
- Public IP address — fetched once on tab open via lightweight HTTPS call to `https://api.ipify.org` (JSON, ~100 bytes) and cached for the session
- Interface list (en0, en1, utun0 etc.) with type badges
- Active interface highlight

### Why it's lightweight
`NWPathMonitor` uses kernel-level network change notifications — it does not poll. CPU cost is zero between network changes. IP reads are one-shot syscalls. Public IP is fetched once and cached.

### Implementation detail

**New file:** `Halo/Core/Scanner/NetworkDetailMonitor.swift`
```swift
actor NetworkDetailMonitor {
    struct NetworkDetail: Sendable {
        let localIPv4: String?
        let localIPv6: String?
        let wifiSSID: String?
        let wifiSignalDBm: Int?
        let publicIP: String?         // nil until fetched
        let isVPN: Bool
        let activeInterface: String?  // "en0", "utun0", etc.
        let interfaces: [InterfaceInfo]
    }

    func startVPNMonitoring(onChange: @Sendable @escaping (Bool) -> Void)
    func fetchDetail() async -> NetworkDetail
    func fetchPublicIP() async -> String?    // one-shot, cached
}
```

**Modify:** `Halo/App/AppState.swift`
- Add `isVPNActive: Bool` to published properties
- Start `NetworkDetailMonitor.startVPNMonitoring` in `init()` — fires only on changes

**New section view:** `Features/Performance/NetworkDetailSection.swift`
- Card rows: Local IP, Public IP (with copy button), WiFi SSID + signal bars, VPN status badge
- Refresh button (re-fetches public IP)

**Effort:** 2–3 days

---

## P3-06 · Internet Speed Test & Network Latency

**Class:** 🔴 On-demand only — never runs in background

### What it does
A user-triggered speed test (both download and upload) and a latency ping test. Shown in the Network Intelligence section (P3-05) behind a "Run Test" button.

**Speed test approach:**
- Download: stream a known-size payload (~10 MB) from a reliable CDN endpoint using `URLSession.bytes(from:)` and measure throughput in real time
- Upload: POST a generated byte buffer of known size and measure round-trip
- Display: live animated speed gauge updating every 250 ms as bytes arrive

**Latency (ping):**
- Send 5 ICMP echo requests using `Network.framework`'s `NWConnection` (no root required for UDP echo)
- Report: min / avg / max ms

### Why it's lightweight
Strictly on-demand. No background polling whatsoever. The test cancels immediately if the user navigates away (`task` modifier with cancellation support).

### Implementation detail

**New file:** `Halo/Core/Scanner/SpeedTestService.swift`
```swift
actor SpeedTestService {
    struct SpeedResult: Sendable {
        let downloadMbps: Double
        let uploadMbps: Double
        let latencyMs: Double      // average of 5 pings
        let testedAt: Date
    }

    func runTest(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> SpeedResult
    // SpeedTestProgress: enum { .pinging, .downloading(percent: Double, mbps: Double), .uploading(...), .done }
}
```

**View:** Added to `NetworkDetailSection` as a collapsible card:
- "Run Speed Test" primary button (red while running → green on completion)
- Animated arc gauge during test
- Results: Download ↓ / Upload ↑ / Latency in styled metric chips
- Results cached for the session (re-run requires another button tap)

**Effort:** 2 days

---

## P3-07 · Disk Health & SMART Status

**Class:** 🔴 On-demand (SMART) · 🟡 Foreground (read/write totals)

### What it does

**On-demand — SMART health check:**
- Query IOKit for the `IONVMeFamily` or `IOAHCIBlockDevice` service matching each disk
- Read `SMART_SELF_TEST_RESULT`, `reallocatedSectorCount`, `powerOnHours` where available
- Report: **Verified** (green) / **Warning** (amber — failing attributes) / **Failed** (red)
- Triggered by "Check Disk Health" button in the Cleanup or Performance tab

**Foreground — Lifetime read/write:**
- Total bytes read / written since disk manufacture (from IOKit `Statistics` dictionary)
- Refreshed once per session (rarely changes meaningfully in one session)
- Displayed per-volume in a disk info card

**Disk usage per volume:**
- `FileManager.default.attributesOfFileSystem(forPath:)` — already lightweight
- Show per-volume free / used bar and formatted sizes

### Why it's lightweight
SMART reads are one blocking IOKit call per disk (< 5 ms). Never runs in background. Foreground lifetime stats read once per session open.

### Implementation detail

**New file:** `Halo/Core/Scanner/DiskHealthMonitor.swift`
```swift
actor DiskHealthMonitor {
    enum SMARTStatus: Sendable { case verified, warning(String), failed(String), unavailable }

    struct DiskInfo: Identifiable, Sendable {
        let id: UUID
        let bsdName: String          // "disk0"
        let model: String
        let totalGB: Double
        let lifetimeReadGB: Double
        let lifetimeWrittenGB: Double
        let smartStatus: SMARTStatus
        let powerOnHours: Int?
    }

    func scanAllDisks() async -> [DiskInfo]   // on-demand
    func volumeUsage() -> [VolumeInfo]        // cheap, runs on foreground
}
```

**New section view:** `Features/Cleanup/DiskHealthSection.swift` (added to Cleanup tab)
- Volume list with used/free bars
- "Run SMART Check" button → progress indicator → per-disk result cards
- Lifetime read/write shown as text (e.g., "Written: 4.2 TB")

**Effort:** 3 days

---

## P3-08 · Threshold Alerts & Notifications

**Class:** 🟢 Always-background — zero extra overhead (piggybacks on existing 2-second timer)

### What it does
Sends macOS `UNUserNotification` alerts when system metrics cross user-configured thresholds. All checks are added as simple `if` statements inside the **existing** `refreshMetrics()` function — no new timers, no new threads.

### Alert types

| Alert | Default Threshold | Debounce |
|---|---|---|
| CPU sustained high | > 85% for 10+ seconds | 5 min cool-down |
| RAM pressure | > 85% used | 5 min cool-down |
| Disk space low | < 5 GB free | Once per day |
| Battery critical | ≤ 10% | Once per charge cycle |
| Battery low | ≤ 20% | Once per charge cycle |
| Charging complete | 100% while plugged in | Once per charge cycle |
| Temperature critical | > 90°C CPU (when SMC available) | 2 min cool-down |

### Why it's lightweight
Each alert is an `if` check on a `Double` comparison — nanoseconds of CPU per 2-second tick. Debouncing uses `Date` comparison stored in a `[AlertKind: Date]` dictionary. The `UNUserNotificationCenter` call only fires when the condition is met (rare).

### Implementation detail

**New file:** `Halo/Core/AlertManager.swift`
```swift
@MainActor
final class AlertManager: ObservableObject {
    private var lastFired: [AlertKind: Date] = [:]

    func evaluate(metrics: SystemMetrics, battery: BatteryInfo) {
        checkCPU(metrics.cpuUsage)
        checkRAM(metrics.ramUsage)
        checkDisk(metrics.diskFreeGB)
        checkBattery(battery)
    }

    private func fire(_ kind: AlertKind, title: String, body: String) {
        guard canFire(kind) else { return }
        // UNUserNotificationCenter.current().add(...)
        lastFired[kind] = Date()
    }
}
```

**Settings page:** `Features/Onboarding/SettingsView.swift`
- New "Alerts" section with per-threshold sliders + enable toggles
- All values in `@AppStorage` — no model changes needed

**Effort:** 1.5 days

---

## P3-09 · Enhanced Menu Bar

**Class:** 🟢 Always-background (configuration only changes what's already running)

### What it does
Gives the user full control over the menu bar display without adding any CPU/RAM overhead. The underlying metrics are already collected by the existing 2-second timer.

### Features

**Module toggle:** Enable or disable each metric (CPU, RAM, Network ↑↓, Disk I/O, Battery %) independently. Hidden modules simply don't render their label — zero data collection change.

**Display styles per module:**
- `text` — percentage or value (current default)
- `bar` — thin vertical fill bar (like Stats' mini widget)
- `dot` — colour-coded dot (green/amber/red based on threshold)
- `hidden` — metric collected but not shown in menu bar (still in popover)

**Order:** Drag-to-reorder via a simple ordered array in `@AppStorage("menuBarOrder")`.

**Font size:** Small / Medium toggle (`@AppStorage`).

### Implementation detail

**New model:**
```swift
struct MenuBarModuleConfig: Codable {
    var isEnabled: Bool
    var displayStyle: MenuBarDisplayStyle   // .text, .bar, .dot, .hidden
    var order: Int
}

enum MenuBarDisplayStyle: String, Codable { case text, bar, dot, hidden }
```

**Modify:** `Features/MenuBar/MenuBarView.swift`
- Read `MenuBarModuleConfig` array from `@AppStorage`
- Render each enabled module in its configured style
- Bar style: a `Capsule().frame(width: 3, height: 12)` filled proportionally — adds ~2 points layout work per tick, negligible

**New settings section:** "Menu Bar" in `SettingsView`
- Toggle list with drag handles
- Style picker per module

**Effort:** 2 days

---

## P3-10 · Network Bandwidth History

**Class:** 🟡 Foreground-active

### What it does
A rolling 60-second sparkline chart of upload and download bandwidth, shown in the Network section of the Dashboard or a new Network tab. Gives the user a visual history of traffic spikes — useful for spotting unexpected background uploads.

The data is **already collected** by the existing 2-second `metricsTimer` (upload/download bytes per second). Phase 3 just stores a rolling 30-sample buffer and renders a chart.

### Why it's lightweight
The sparkline buffer is 30 × 2 `Double` values = 480 bytes. Rendering a `Chart` in SwiftUI is GPU-accelerated. No new data collection — purely a presentation addition.

### Implementation detail

**Modify:** `Halo/App/AppState.swift`
```swift
// Rolling 30-sample (60 s) history — append in refreshMetrics()
private(set) var uploadHistory: [Double] = []    // max 30 entries
private(set) var downloadHistory: [Double] = []
```

**New view:** `Features/Dashboard/NetworkSparklineCard.swift`
- Uses Swift Charts `AreaMark` with gradient fill
- Two series: upload (amber) + download (accent blue)
- X-axis: last 60 seconds, Y-axis: auto-scaled to peak
- Only rendered when the Dashboard card is visible

**Effort:** 1 day

---

## P3-11 · Top Processes Monitor

**Class:** 🟡 Foreground-active

### What it does
A live list of the top 10 processes consuming the most CPU or RAM, sortable by either metric. Similar to a lightweight Activity Monitor pane within Halo. Helps users identify what's causing a CPU spike without switching apps.

### Why it's lightweight
Process enumeration uses `proc_listallpids()` + `proc_pidinfo()` — the same APIs used by Activity Monitor and `top`. Runs only on a 3-second foreground timer (slower than the 2-second global timer to save cost). Timer is destroyed when the view closes.

### Implementation detail

**New file:** `Halo/Core/Scanner/ProcessMonitor.swift`
```swift
actor ProcessMonitor {
    struct ProcessInfo: Identifiable, Sendable {
        let id: Int32           // PID
        let name: String
        let cpuPercent: Double
        let ramMB: Double
        let icon: NSImage?      // loaded lazily, nil for daemons
    }

    func topProcesses(sortBy: SortKey, limit: Int = 10) -> [ProcessInfo]
    enum SortKey { case cpu, ram }
}
```

**New section:** `Features/Performance/TopProcessesSection.swift`
- Segmented control: CPU / RAM sort
- `LazyVStack` of process rows with app icon, name, and metric bar
- "Force Quit" button (with confirmation) for user-visible processes
- Refresh on 3-second timer, alive only while section is expanded

**Effort:** 2 days

---

## P3-12 · Settings & Customisation Expansion

**Class:** — (configuration UI only)

### What it adds to existing SettingsView

| Setting | Type | Default |
|---|---|---|
| Temperature unit | Toggle °C / °F | °C |
| Menu bar refresh interval | Picker: 1s / 2s / 5s | 2s |
| CPU alert threshold | Slider 50–100% | 85% |
| RAM alert threshold | Slider 50–100% | 85% |
| Disk free alert | Picker: 1/2/5/10 GB | 5 GB |
| Battery low threshold | Slider 5–30% | 20% |
| Battery critical threshold | Slider 5–20% | 10% |
| Dashboard cards visibility | Toggle per card | All on |
| Per-core CPU on Dashboard | Toggle | Off |
| GPU card on Dashboard | Toggle | On |
| Sensor section in Performance | Toggle | On |

All values stored via `@AppStorage` — no new model files, no database.

**Effort:** 1 day

---

## Architecture: Lightweight Guarantees

### Timer Budget (Phase 3 final state)

| Timer | Interval | Always-on? | Owner |
|---|---|---|---|
| `metricsTimer` (CPU/RAM/Net/Disk/Battery) | 2 s | ✅ Yes | `AppState` |
| `widgetReloadTimer` | 60 s | ✅ Yes | `AppState` |
| `NWPathMonitor` (VPN / reachability) | Event-driven | ✅ Yes | `NetworkDetailMonitor` |
| `AlertManager.evaluate()` | Piggybacks metricsTimer | ✅ Yes (no-cost) | `AppState` |
| Per-core CPU timer | 2 s | ❌ Foreground only | `CPUDetailMonitor` |
| Sensor / fan timer | 5 s | ❌ Foreground only | `SMCReader` |
| GPU stats timer | 2 s | ❌ Foreground only | `GPUMonitor` |
| Network detail refresh | 10 s | ❌ Foreground only | `NetworkDetailMonitor` |
| Network bandwidth chart | 2 s (same as metrics) | ❌ Foreground only | `AppState` buffer |
| Top processes timer | 3 s | ❌ Foreground only | `ProcessMonitor` |
| SMART check | One-shot | ❌ On-demand | `DiskHealthMonitor` |
| Speed test | One-shot | ❌ On-demand | `SpeedTestService` |
| Public IP fetch | One-shot per session | ❌ On-demand | `NetworkDetailMonitor` |

### Memory Budget

| Component | Estimated RAM |
|---|---|
| Existing Halo (v1.2) | ~28 MB |
| P3-01 core buffer (30 cores × 2 Double) | < 1 KB |
| P3-04 battery history | < 1 KB |
| P3-10 bandwidth buffer (30 × 2 Double) | < 1 KB |
| New actor instances (idle) | < 500 KB total |
| **Phase 3 total (background)** | **~30 MB** |
| All foreground monitors active simultaneously | ~35–40 MB |

### Actor Isolation Rules (Phase 3)
- All new monitors are `actor` types — no shared mutable state
- Foreground monitors are `@StateObject` owned by their view — automatically deallocated when view disappears
- `AppState` remains the only `@MainActor` singleton
- No new global singletons

---

## Execution Schedule

| Item | Feature | Effort | Priority |
|---|---|---|---|
| P3-08 | Threshold Alerts | 1.5 days | 🔴 High — user-visible value, near-zero cost |
| P3-04 | Battery Deep Intelligence | 2 days | 🔴 High — fills biggest Stats gap |
| P3-09 | Enhanced Menu Bar | 2 days | 🔴 High — highly visible UX improvement |
| P3-01 | Per-Core CPU | 2 days | 🟠 Medium |
| P3-05 | Network Intelligence | 2–3 days | 🟠 Medium |
| P3-10 | Bandwidth History | 1 day | 🟠 Medium |
| P3-11 | Top Processes | 2 days | 🟠 Medium |
| P3-02 | Thermal Sensors + Fan | 3 days | 🟡 Lower — requires SMC key research per model |
| P3-03 | GPU Metrics | 2–3 days | 🟡 Lower — IOAccelerator API unstable across macOS versions |
| P3-06 | Speed Test | 2 days | 🟡 Lower — nice to have |
| P3-07 | Disk SMART | 3 days | 🟡 Lower — limited data available on Apple Silicon |
| P3-12 | Settings Expansion | 1 day | 🟡 Lower — depends on P3-02, P3-08 |

**Total estimated effort: ~25–28 days**

---

## What Phase 3 Does NOT Include (intentional)

| Capability | Why excluded |
|---|---|
| Fan **control** (write RPM) | Requires kernel extension or SMC write access — not available to sandboxed apps; macOS 12+ blocks SMC writes from user space |
| Continuous public IP polling | Unnecessary overhead; IP rarely changes; fetched once on tab open |
| Bluetooth device monitor | Low value for Halo's optimisation focus; niche audience |
| Multi-timezone clock | Out of scope for a system optimiser |
| Per-app network usage | Requires `NEFilterDataProvider` (VPN entitlement) — invasive, App Store review risk |
| Always-on temperature monitoring | SMC reads are cheap but sensor data changes 4–5× per second; storing/displaying at that rate adds UI render cost for marginal benefit |

---

## Files to Create / Modify (Summary)

```
Halo/Core/Scanner/
├── CPUDetailMonitor.swift         ← new (P3-01)
├── SMCReader.swift                ← new (P3-02)
├── GPUMonitor.swift               ← new (P3-03)
├── NetworkDetailMonitor.swift     ← new (P3-05)
├── SpeedTestService.swift         ← new (P3-06)
├── DiskHealthMonitor.swift        ← new (P3-07)
└── ProcessMonitor.swift           ← new (P3-11)

Halo/Core/
└── AlertManager.swift             ← new (P3-08)

Halo/Core/Scanner/SystemMonitor.swift    ← modify: extend BatteryInfo (P3-04)
Halo/App/AppState.swift                  ← modify: bandwidth buffer, VPN flag, AlertManager (P3-04/05/08/10)

Halo/Features/Performance/
├── CPUCoresSection.swift          ← new (P3-01)
├── SensorsSection.swift           ← new (P3-02)
├── BatteryDetailSection.swift     ← new (P3-04)
├── NetworkDetailSection.swift     ← new (P3-05)
├── TopProcessesSection.swift      ← new (P3-11)
└── PerformanceView.swift          ← modify: add new sections

Halo/Features/Dashboard/
├── NetworkSparklineCard.swift     ← new (P3-10)
└── DashboardView.swift            ← modify: GPU card, sparkline card

Halo/Features/Cleanup/
└── DiskHealthSection.swift        ← new (P3-07)

Halo/Features/MenuBar/
└── MenuBarView.swift              ← modify: display styles, module config (P3-09)

Halo/Features/Onboarding/
└── SettingsView.swift             ← modify: Alerts + Menu Bar + Thresholds sections (P3-08/09/12)

Halo/Core/Models/Models.swift      ← modify: MenuBarModuleConfig, AlertKind enums
```

---

*Last updated: Phase 3 planning — v1.2 baseline*
*Previous phases → `docs/ROADMAP.md` (Phase 1 completed items) · `docs/PHASE2_DISPLAY_BRIGHTNESS.md`*
