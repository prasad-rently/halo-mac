import Foundation
import CoreAudio
import CoreMediaIO
import AVFoundation
import AppKit

// MARK: - SystemControlsManager

/// Manages microphone mute, camera state, and screen-sharing state.
///
/// Camera daemon stack (Apple Silicon / macOS 13+):
///   avconferenced  → com.apple.videoconference.camera  (launchd user service)
///   UVCAssistant   → IOKit camera driver bridge
///   AppleH16CameraInterface → hardware
///
/// Hard-cut uses `launchctl stop gui/<uid>/com.apple.videoconference.camera`
/// — no admin required, launchd does not auto-restart a stop()ed service.
@MainActor
final class SystemControlsManager: ObservableObject {

    static let shared = SystemControlsManager()

    // MARK: - Published

    // Microphone
    @Published private(set) var isMicMuted      = false

    // Camera
    @Published private(set) var isCameraInUse   = false  // CoreMediaIO real state
    @Published private(set) var isCameraHardCut = false  // we cut it via launchctl
    @Published private(set) var cameraApps: [NSRunningApplication] = []

    // Screen
    @Published private(set) var isSharingScreen    = false  // screensharing.agent
    @Published private(set) var isScreenRecording  = false  // ScreenCaptureKit / corecaptured
    @Published private(set) var screenRecordingApps: [NSRunningApplication] = []

    // MARK: - Private: audio

    private var defaultInputDevice   = AudioDeviceID(kAudioObjectUnknown)
    private var supportsMuteProperty = false
    private var preMuteVolume: Int   = 75

    // MARK: - Private: camera CoreMediaIO

    private var cmioDeviceIDs: [CMIODeviceID] = []
    private var listenerBlocks: [CMIOObjectPropertyListenerBlock] = []

    // MARK: - Private: polling timer (for screen share)

    private var pollTimer: Timer?
    private let uid = getuid()

    // MARK: - Init

    private init() {
        setupAudio()
        setupCameraIOKit()
        startPolling()
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Microphone (CoreAudio)
    // ──────────────────────────────────────────────────────────────────────

    func toggleMic() { setMicMuted(!isMicMuted) }

    func setMicMuted(_ muted: Bool) {
        if supportsMuteProperty { hardwareMute(muted) } else { softMute(muted) }
        refreshMuteState()
    }

    private func setupAudio() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devID = AudioDeviceID(kAudioObjectUnknown)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        defaultInputDevice = devID

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        supportsMuteProperty = AudioObjectHasProperty(devID, &muteAddr)
        refreshMuteState()
    }

    private func refreshMuteState() {
        if supportsMuteProperty {
            var val:  UInt32 = 0
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope:    kAudioDevicePropertyScopeInput,
                mElement:  kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(defaultInputDevice, &addr, 0, nil, &size, &val)
            isMicMuted = val == 1
        } else {
            isMicMuted = getInputVolume() == 0
        }
    }

    private func hardwareMute(_ muted: Bool) {
        var val:  UInt32 = muted ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &val)
        isMicMuted = muted
    }

    private func softMute(_ muted: Bool) {
        if muted { preMuteVolume = getInputVolume(); setInputVolume(0); isMicMuted = true }
        else      { setInputVolume(max(preMuteVolume, 50)); isMicMuted = false }
    }

    private func getInputVolume() -> Int {
        var vol = Float32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(defaultInputDevice, &addr, 0, nil, &size, &vol)
        return Int(vol * 100)
    }

    private func setInputVolume(_ percent: Int) {
        var vol = Float32(percent) / 100.0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Camera (CoreMediaIO real detection)
    // ──────────────────────────────────────────────────────────────────────

    private func setupCameraIOKit() {
        discoverCMIODevices()
        installCameraListeners()
        isCameraInUse = queryCameraInUse()
    }

    private func discoverCMIODevices() {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count   = Int(dataSize) / MemoryLayout<CMIODeviceID>.stride
        var devices = [CMIODeviceID](repeating: CMIODeviceID(), count: count)
        var used    = UInt32(0)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &used, &devices
        ) == noErr else { return }
        cmioDeviceIDs = devices
    }

    private func queryCameraInUse() -> Bool {
        for deviceID in cmioDeviceIDs {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }
            var running = UInt32(0)
            let bufSize = UInt32(MemoryLayout<UInt32>.size)
            var used    = UInt32(0)
            if CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, bufSize, &used, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    private func installCameraListeners() {
        for deviceID in cmioDeviceIDs {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.isCameraInUse = self?.queryCameraInUse() ?? false
                    if self?.isCameraInUse == true { self?.refreshCameraApps() }
                    else { self?.cameraApps = [] }
                }
            }
            listenerBlocks.append(block)
            CMIOObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
        }
    }

    // MARK: - Camera hard-cut (Phase 1 fix — correct daemon)

    /// Stops the avconferenced launchd service — cuts camera for ALL apps.
    /// No admin required. launchd will not auto-restart a stop()ed service.
    func hardCutCamera() {
        isCameraHardCut = true
        Task.detached(priority: .userInitiated) { [uid = self.uid] in
            // Primary: stop the videoconference camera launchd service
            runLaunchctl(["stop", "gui/\(uid)/com.apple.videoconference.camera"])
            // Secondary: suspend UVCAssistant (IOKit bridge)
            if let pid = pidOf("UVCAssistant") {
                kill(pid, SIGSTOP)
            }
        }
    }

    /// Re-enables the camera by restarting the avconferenced service.
    func restoreCamera() {
        isCameraHardCut = false
        Task.detached(priority: .userInitiated) { [uid = self.uid] in
            runLaunchctl(["start", "gui/\(uid)/com.apple.videoconference.camera"])
            if let pid = pidOf("UVCAssistant") {
                kill(pid, SIGCONT)
            }
        }
    }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Camera App Detection (Phase 2)
    // ──────────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Camera App Detection (Phase 2) — fully async, never blocks main
    // ──────────────────────────────────────────────────────────────────────

    /// Fire-and-forget: resolves camera apps on a background thread, then
    /// publishes results back to the main actor.
    func refreshCameraApps() {
        Task.detached(priority: .utility) { [weak self] in
            let ids  = tccPermittedIDs(service: "kTCCServiceCamera")
            let apps = NSWorkspace.shared.runningApplications.filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return ids.contains(id) && id != Bundle.main.bundleIdentifier
            }
            await MainActor.run { self?.cameraApps = apps }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Screen Sharing & Recording (Phase 3) — fully async
    // ──────────────────────────────────────────────────────────────────────

    private func startPolling() {
        // Timer fires on main run loop; callback dispatches work to background
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshScreenState()
        }
        refreshScreenState()   // initial probe — also dispatches to background
    }

    /// Fire-and-forget: probes launchctl on a background thread, publishes results.
    func refreshScreenState() {
        let capturedUID = uid
        Task.detached(priority: .utility) { [weak self] in
            let sharing   = launchctlActive("com.apple.screensharing.agent",   uid: capturedUID)
            let recording = launchctlActive("com.apple.screencaptureui.agent", uid: capturedUID)
            let recApps: [NSRunningApplication]
            if recording {
                let ids = tccPermittedIDs(service: "kTCCServiceScreenCapture")
                recApps = NSWorkspace.shared.runningApplications.filter { app in
                    guard let id = app.bundleIdentifier else { return false }
                    return ids.contains(id) && id != Bundle.main.bundleIdentifier
                }
            } else {
                recApps = []
            }
            await MainActor.run {
                self?.isSharingScreen     = sharing
                self?.isScreenRecording   = recording
                self?.screenRecordingApps = recApps
            }
        }
    }

    /// Stop outgoing screen sharing — launchctl in background, no admin needed.
    func stopScreenSharing() {
        Task.detached(priority: .userInitiated) { [uid = self.uid] in
            runLaunchctl(["stop", "gui/\(uid)/com.apple.screensharing.agent"])
        }
    }

    func openScreenPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Kicks off all async refreshes — returns immediately, never blocks.
    func refreshAll() {
        refreshMuteState()                   // CoreAudio read — fast, synchronous ok
        isCameraInUse = queryCameraInUse()   // CoreMediaIO read — fast, synchronous ok
        refreshCameraApps()                  // async → background
        refreshScreenState()                 // async → background
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Free-function helpers (nonisolated — safe to call from background)
// All Process.waitUntilExit() calls live here, NEVER on the main actor.
// ──────────────────────────────────────────────────────────────────────────

/// Returns bundle IDs granted the given TCC service (auth_value = 2 = allowed).
/// Runs sqlite3 synchronously — must only be called from a background thread.
private func tccPermittedIDs(service: String) -> Set<String> {
    let tccPath = NSHomeDirectory() +
        "/Library/Application Support/com.apple.TCC/TCC.db"
    guard FileManager.default.fileExists(atPath: tccPath) else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = [tccPath,
        "SELECT client FROM access WHERE service='\(service)' AND auth_value=2"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()
    do { try proc.run(); proc.waitUntilExit() } catch { return [] }
    let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    return Set(raw.components(separatedBy: "\n")
                  .map { $0.trimmingCharacters(in: .whitespaces) }
                  .filter { !$0.isEmpty })
}

/// Returns true if the launchd service's active count > 0.
/// Runs launchctl synchronously — must only be called from a background thread.
private func launchctlActive(_ label: String, uid: uid_t) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = ["print", "gui/\(uid)/\(label)"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()
    do { try proc.run(); proc.waitUntilExit() } catch { return false }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    guard let match = out.range(of: #"active count = (\d+)"#, options: .regularExpression),
          let numStr = out[match].split(separator: "=").last
                           .map({ String($0).trimmingCharacters(in: .whitespaces) }),
          let count = Int(numStr) else { return false }
    return count > 0
}

/// Finds the PID of a process by exact name — background-safe.
private func pidOf(_ name: String) -> pid_t? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", name]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try? proc.run(); proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    guard let pid = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return pid_t(pid)
}

@discardableResult
private func runLaunchctl(_ args: [String]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    proc.standardOutput = Pipe()
    proc.standardError  = Pipe()
    try? proc.run(); proc.waitUntilExit()
    return proc.terminationStatus
}
