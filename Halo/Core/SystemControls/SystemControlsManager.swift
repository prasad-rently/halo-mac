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

    /// Refresh which running apps have been granted camera TCC permission.
    func refreshCameraApps() {
        let permitted = cameraPermittedBundleIDs()
        cameraApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return permitted.contains(id) && id != Bundle.main.bundleIdentifier
        }
    }

    /// Read ~/Library/Application Support/com.apple.TCC/TCC.db for camera grants.
    private func cameraPermittedBundleIDs() -> Set<String> {
        let tccPath = NSHomeDirectory() +
            "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: tccPath) else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [
            tccPath,
            "SELECT client FROM access WHERE service='kTCCServiceCamera' AND auth_value=2"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()   // discard errors silently
        do {
            try proc.run(); proc.waitUntilExit()
        } catch { return [] }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Set(raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                      .filter { !$0.isEmpty })
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Screen Sharing & Recording (Phase 3)
    // ──────────────────────────────────────────────────────────────────────

    private func startPolling() {
        // Poll every 2 seconds — fast enough for UX, cheap enough for battery
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshScreenState() }
        }
        refreshScreenState()
    }

    func refreshScreenState() {
        // Outgoing screen share via macOS Screen Sharing / Remote Desktop
        isSharingScreen   = launchctlServiceActive("com.apple.screensharing.agent")
        // App-based screen recording (ScreenCaptureKit / ReplayKit)
        isScreenRecording = launchctlServiceActive("com.apple.screencaptureui.agent")
        screenRecordingApps = isScreenRecording ? screenRecordingPermittedApps() : []
    }

    /// Stop outgoing screen sharing (e.g. Remote Desktop session).
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

    /// Returns `true` when the launchd service has active count > 0.
    private func launchctlServiceActive(_ label: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["print", "gui/\(uid)/\(label)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Active service shows "active count = N" where N > 0
        if let range = out.range(of: #"active count = (\d+)"#, options: .regularExpression),
           let numStr = out[range].split(separator: "=").last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           let count  = Int(numStr) {
            return count > 0
        }
        return false
    }

    /// TCC-permitted screen-recording apps that are currently running.
    private func screenRecordingPermittedApps() -> [NSRunningApplication] {
        let tccPath = NSHomeDirectory() +
            "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: tccPath) else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [
            tccPath,
            "SELECT client FROM access WHERE service='kTCCServiceScreenCapture' AND auth_value=2"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        let raw   = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ids   = Set(raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return ids.contains(id) && id != Bundle.main.bundleIdentifier
        }
    }

    func refreshAll() {
        refreshMuteState()
        isCameraInUse = queryCameraInUse()
        refreshCameraApps()
        refreshScreenState()
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Process Helpers (non-actor, pure C-level)
// ──────────────────────────────────────────────────────────────────────────

private func pidOf(_ name: String) -> pid_t? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", name]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try? proc.run(); proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus
}
