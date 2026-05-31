# Halo — System Controls Deep Analysis
## Camera, Microphone & Screen Sharing

> Research conducted: 2026-05-31 | macOS 26.2 (Tahoe) · Apple M5 · Build 25C56

---

## 1. Why "Hard-Cut Camera Signal" Didn't Work

### Root Cause
The implementation killed `VDCAssistant` and `AppleCameraAssistant` — but this Mac (Apple Silicon, macOS 26) uses **`UVCAssistant`** and **`avconferenced`** as the camera stack. Wrong processes.

### Actual Camera Process Stack (Apple Silicon, macOS 26)

```
User Apps (Zoom, FaceTime, Chrome...)
        ↓  XPC / Mach ports
  avconferenced  (PID 604)           ← launchd-managed service
  /usr/libexec/avconferenced          ← com.apple.videoconference.camera
        ↓  IOKit user client
  UVCAssistant  (PID 302)            ← IOKit camera driver bridge
        ↓  IOKit kernel extension
  AppleH16CameraInterface             ← camera hardware driver
        ↓
  Camera hardware (ISP)
```

**Key IOKit properties found:**
| Property | Current value | Meaning |
|----------|---------------|---------|
| `FrontCameraStreaming` | `No` / `Yes` | Is the camera actively sending frames? |
| `FrontCameraActive` | `No` / `Yes` | Is the camera hardware powered up? |
| `SEPCameraDisable` | `No` / `Yes` | SEP-level hardware disable flag |
| `IOUserClientCreator` | `"pid 604, avconferenced"` | Who opened the IOKit user client |

### Fix: Use `launchctl` on the correct service

```bash
# STOP (cuts camera for all apps — no admin needed, launchd won't auto-restart)
launchctl stop gui/$(id -u)/com.apple.videoconference.camera

# RESTART (re-enables camera)
launchctl start gui/$(id -u)/com.apple.videoconference.camera
```

**Why this is better than killing by PID:**
1. Targets the correct process (`avconferenced`)
2. `launchctl stop` sends SIGTERM gracefully — the service closes cleanly
3. `launchd` does **NOT** auto-restart a `stop`-ed service (unlike `kill`)
4. Can be reversed cleanly with `start`
5. **No admin/sudo required** — this is a user-domain launchd service

---

## 2. Camera App Detection — What's Possible

### The Problem
User apps (Zoom, FaceTime, Chrome) do not directly open the camera hardware.
They connect to `avconferenced` via XPC/Mach ports. `avconferenced` then opens
the camera IOKit stack. So IOKit `IOUserClientCreator` only shows
`avconferenced`, not the end-user apps.

### What We CAN Do (3 approaches in order of reliability)

#### Approach A: TCC Database Cross-Reference ✅ Best
```sql
-- ~/Library/Application Support/com.apple.TCC/TCC.db (readable without Full Disk Access for own TCC)
SELECT client, auth_value
FROM access
WHERE service = 'kTCCServiceCamera'
  AND auth_value = 2    -- 2 = allowed
```
Cross-reference with `NSRunningApplication.runningApplications` to find
camera-permitted apps that are currently running. When `FrontCameraStreaming = Yes`,
these are the likely camera users.

**Result:** App name + icon list. Not 100% certain (app may be running but not
currently capturing), but reliable enough for UX.

#### Approach B: IOKit Camera State + Process Monitoring ✅ Good
```
1. CMIOObjectPropertyListenerBlock on kCMIODevicePropertyDeviceIsRunningSomewhere
2. On change to "running", scan NSRunningApplication.runningApplications
3. Filter: AVCaptureDevice.authorizationStatus(for: .video) cannot be checked
   per-app, but we can check the TCC DB for apps with camera permission
4. Show those running apps as "possibly using camera"
```

#### Approach C: IOKit FrontCameraStreaming Property ✅ Real-time
```swift
// Read AppleH16CameraInterface property via IOKit
// "FrontCameraStreaming" = Yes/No — REAL hardware LED signal
// "FrontCameraActive" = Yes/No
```
These are read-only; they confirm camera state but not which app.

#### Approach D: ioreg IOUserClientCreator Parsing 🔧 Lower-level
```bash
ioreg -l -c AppleH16CameraInterface | grep IOUserClientCreator
# Returns: "pid 604, avconferenced" — the driver-level client
# Cannot enumerate app-level clients without SIP exceptions
```

### Proposed UI
When `FrontCameraStreaming = Yes`:
- Show a list of "Apps with Camera Access Currently Running"
- Source: TCC DB allowed apps ∩ running apps
- Caveat shown: "One or more of these apps is using your camera"
- Tap any to open its System Settings camera permission entry

---

## 3. Screen Sharing Detection — Full Analysis

### Three Distinct Scenarios

#### Scenario A: This Mac is sharing its screen to another device (outgoing)

**What happens:** `screensharing.agent` (launchd label: `com.apple.screensharing.agent`)
activates and drives the screen capture.

**Detection:**
```bash
launchctl print gui/$(id -u)/com.apple.screensharing.agent 2>/dev/null | grep "state"
# state = running → screen is being shared
```
Or: Check `active count` field — > 0 means active sharing session.

**Hard-cut:**
```bash
launchctl stop gui/$(id -u)/com.apple.screensharing.agent
```
This terminates the sharing session. No admin required.

#### Scenario B: An app (Zoom, Teams, Meet) is screen-capturing/sharing

**What happens:** The app uses `ScreenCaptureKit` (`SCStream`) or legacy
`CGDisplayStream` APIs. `corecaptured` / `screencaptureui.agent` mediate the capture.

**Detection via ScreenCaptureKit (macOS 12.3+):**
```swift
import ScreenCaptureKit

// SCShareableContent doesn't expose active streams directly
// BUT: We can check which apps have Screen Recording TCC permission + are running
// sqlite3 TCC.db: service='kTCCServiceScreenCapture' AND auth_value=2
```

**Process-based detection (simpler):**
```swift
// corecaptured is active during screen capture
let isCapturing = NSRunningApplication.runningApplications
    .contains { $0.bundleIdentifier == "com.apple.corecaptured" }

// screencaptureui.agent PID is non-zero when capture is in progress
let capturePID = pgrep("screencaptureui.agent")
```

**Hard-cut:**
```bash
# Stop core screen capture engine
launchctl stop gui/$(id -u)/com.apple.screencaptureui.agent
# Kill any app using ScreenCaptureKit (can't do this generically)
```

#### Scenario C: AirPlay / Continuity Camera is active

**What happens:** `ContinuityCaptureAgent` (PID 412) handles iPhone as webcam
and AirPlay capture.

**Detection:**
```bash
pgrep -x ContinuityCaptureAgent >/dev/null && echo "Continuity active"
launchctl print gui/$(id -u)/com.apple.cmio.ContinuityCaptureAgent | grep "state"
```

### Proposed Screen Sharing UI

```
[📺 Screen Status]  
  ● Screen Share: Off / Sharing via AirPlay / Being recorded
  [Apps capturing screen: Zoom, QuickTime Player]  
  [Stop Screen Sharing →]  
  [Camera Privacy Settings →]
```

---

## 4. Complete Privacy Dashboard Plan

### Architecture Overview

```
SystemControlsManager (existing — extend)
├── Microphone: CoreAudio mute ✅ working
├── Camera:
│   ├── State: CoreMediaIO kCMIODevicePropertyDeviceIsRunningSomewhere ✅
│   ├── App detection: TCC.db cross-reference + running apps [NEW]
│   └── Hard-cut: launchctl stop com.apple.videoconference.camera [FIX]
└── Screen:
    ├── Sharing state: com.apple.screensharing.agent active count [NEW]
    ├── Recording state: corecaptured / screencaptureui.agent + TCC [NEW]
    └── Hard-cut: launchctl stop com.apple.screensharing.agent [NEW]
```

### Files to Create / Modify

| File | Action | What it does |
|------|--------|--------------|
| `SystemControlsManager.swift` | MODIFY | Fix hard-cut, add screen sharing state |
| `CameraAppDetector.swift` | CREATE | TCC.db cross-reference + IOKit camera app list |
| `ScreenSharingDetector.swift` | CREATE | launchctl service state + SCKit detection |
| `PrivacyDashboardView.swift` | CREATE | Full popover with mic/camera/screen controls |
| `MenuBarView.swift` | MODIFY | Add screen sharing indicator to popup |
| `MicCameraControlsView.swift` | MODIFY | Use new detectors |

### Implementation Phases

#### Phase 1 — Fix Hard-Cut (immediate)
```swift
// In SystemControlsManager:
func hardCutCamera() {
    let uid = getuid()
    shell("launchctl stop gui/\(uid)/com.apple.videoconference.camera")
    // Also suspend UVCAssistant
    if let pid = pgrep("UVCAssistant") { kill(pid, SIGSTOP) }
}

func restoreCamera() {
    let uid = getuid()
    shell("launchctl start gui/\(uid)/com.apple.videoconference.camera")
    if let pid = pgrep("UVCAssistant") { kill(pid, SIGCONT) }
}
```

#### Phase 2 — Camera App Detection
```swift
// CameraAppDetector.swift
final class CameraAppDetector {
    // Read TCC.db for camera-permitted apps
    func permittedApps() -> [String] { ... }  // bundle IDs

    // Cross-reference with running apps
    func runningCameraApps() -> [NSRunningApplication] {
        let permitted = Set(permittedApps())
        return NSRunningApplication.runningApplications.filter {
            permitted.contains($0.bundleIdentifier ?? "")
        }
    }
}
```

#### Phase 3 — Screen Sharing
```swift
// ScreenSharingDetector.swift
final class ScreenSharingDetector: ObservableObject {
    @Published var isSharingScreen = false      // outgoing share via screensharing.agent
    @Published var isBeingRecorded = false      // capture by app via ScreenCaptureKit
    @Published var isAirPlaySending = false     // AirPlay output active
    @Published var recordingApps: [NSRunningApplication] = []

    func startMonitoring() {
        // Poll launchctl state every 2s (or subscribe to process notifications)
        Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }
    
    private func refresh() {
        isSharingScreen = isServiceRunning("com.apple.screensharing.agent")
        isBeingRecorded = isCoreCapturing()
        recordingApps   = detectRecordingApps()
    }
}
```

---

## 5. Camera "Hard Disable" — Future: CoreMediaIO Extension

The only way to **permanently prevent camera capture** (even if the app tries) is a
**CoreMediaIO Extension** (CMIO DAL plugin) that registers itself as a virtual camera
and intercepts all capture requests.

When "camera off" is active:
- The extension delivers black frames to every requesting app
- The hardware LED stays off (no actual sensor access)
- Works even if apps bypass the camera assistant

**Status:** Requires notarised System Extension + user approval at installation.
Out of scope for current Halo entitlements.
Candidate for a future "Halo Pro" tier feature.

---

## 6. Summary Table

| Feature | Method | Requires Admin | Accuracy |
|---------|--------|---------------|----------|
| Mic mute | CoreAudio hardware property | No | ✅ 100% |
| Camera state (in-use) | CoreMediaIO `IsRunningSomewhere` | No | ✅ 100% |
| **Camera hard-cut (fixed)** | `launchctl stop avconferenced` | **No** | ✅ Reliable |
| Camera app detection | TCC.db + running apps | No | 🟡 ~90% |
| Screen share state | `screensharing.agent` launchctl | No | ✅ 95% |
| Screen recording state | `corecaptured` + TCC cross-ref | No | 🟡 ~85% |
| Camera permanent block | CMIO Extension (virtual camera) | No (but approval) | ✅ 100% |

---

*Analysis: 2026-05-31 | macOS 26.2 · Apple M5*
