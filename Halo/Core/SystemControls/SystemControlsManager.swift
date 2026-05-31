import Foundation
import CoreAudio
import CoreMediaIO
import AVFoundation
import AppKit

// MARK: - SystemControlsManager

/// Manages universal microphone mute and real camera-in-use detection.
///
/// ──────────────────────────────────────────────────────────────────────
///  MICROPHONE
///  Uses CoreAudio kAudioDevicePropertyMute on the default input device —
///  a true hardware mute that silences ALL apps simultaneously.
///  Falls back to setting input volume = 0 on unsupported devices.
///
///  CAMERA — what macOS actually allows:
///
///  Detection (✅ implemented):
///    CoreMediaIO property kCMIODevicePropertyDeviceIsRunningSomewhere
///    returns 1 when any process on the system is actively capturing from
///    the camera. This is the same signal that drives the green LED.
///    A CMIOObjectPropertyListener fires immediately when state changes.
///
///  "Turn off" (⚠️ macOS limitation):
///    There is no public API to block camera access for running apps.
///    Options and their trade-offs:
///
///    A) Kill VDCAssistant (the camera daemon) — requires admin; Zoom/FaceTime
///       will simply restart it on their next frame request. Unreliable.
///
///    B) CMIOExtension (System Extension) — can intercept camera frames and
///       inject black video when "muted". How Snap Camera / Camo work.
///       Requires a notarised system extension + user approval. Out of scope
///       for Halo's current entitlements.
///
///    C) Revoke per-app TCC permission — reliable and persistent. We provide
///       a direct deep-link to System Settings → Privacy → Camera so the
///       user can revoke individual app permissions in 2 taps.
///
///    Halo implements (A) as an optional "force-kill camera daemon" action
///    (requires admin, user must re-enable after) and (C) as the primary UX.
/// ──────────────────────────────────────────────────────────────────────
@MainActor
final class SystemControlsManager: ObservableObject {

    static let shared = SystemControlsManager()

    // MARK: - Published state

    @Published private(set) var isMicMuted:      Bool = false
    @Published private(set) var isCameraInUse:   Bool = false  // driven by CoreMediaIO
    @Published private(set) var cameraGranted:   Bool = false

    // MARK: - Private: audio

    private var defaultInputDevice   = AudioDeviceID(kAudioObjectUnknown)
    private var supportsMuteProperty = false
    private var preMuteVolume: Int   = 75

    // MARK: - Private: camera

    /// Camera device IDs discovered from CoreMediaIO at init.
    private var cmioDeviceIDs: [CMIODeviceID] = []

    // MARK: - Init

    private init() {
        setupAudio()
        setupCamera()
    }

    // Listeners live for the app's lifetime (singleton); no explicit teardown needed.

    // ──────────────────────────────────────────────────────────────────
    // MARK: - Microphone
    // ──────────────────────────────────────────────────────────────────

    func toggleMic() { setMicMuted(!isMicMuted) }

    func setMicMuted(_ muted: Bool) {
        if supportsMuteProperty { hardwareMute(muted) } else { softMute(muted) }
        refreshMuteState()
    }

    // MARK: Private audio helpers

    private func setupAudio() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size   = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devID  = AudioDeviceID(kAudioObjectUnknown)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        defaultInputDevice = devID

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        supportsMuteProperty = AudioObjectHasProperty(devID, &muteAddr)
        refreshMuteState()
    }

    private func refreshMuteState() {
        if supportsMuteProperty {
            var val:  UInt32 = 0
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope:    kAudioDevicePropertyScopeInput,
                mElement:  kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(defaultInputDevice, &addr, 0, nil, &size, &val)
            isMicMuted = val == 1
        } else {
            isMicMuted = (getInputVolume() == 0)
        }
    }

    private func hardwareMute(_ muted: Bool) {
        var val:  UInt32 = muted ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &val)
        isMicMuted = muted
    }

    private func softMute(_ muted: Bool) {
        if muted { preMuteVolume = getInputVolume(); setInputVolume(0); isMicMuted = true }
        else      { setInputVolume(max(preMuteVolume, 50));             isMicMuted = false }
    }

    private func getInputVolume() -> Int {
        var vol  = Float32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(defaultInputDevice, &addr, 0, nil, &size, &vol)
        return Int(vol * 100)
    }

    private func setInputVolume(_ percent: Int) {
        var vol  = Float32(percent) / 100.0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
    }

    // ──────────────────────────────────────────────────────────────────
    // MARK: - Camera (CoreMediaIO real detection)
    // ──────────────────────────────────────────────────────────────────

    private func setupCamera() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        discoverCMIODevices()
        installCameraListeners()
        isCameraInUse = queryCameraInUse()
    }

    /// Enumerate all CoreMediaIO camera devices on the system.
    private func discoverCMIODevices() {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count    = Int(dataSize) / MemoryLayout<CMIODeviceID>.stride
        var devices  = [CMIODeviceID](repeating: CMIODeviceID(), count: count)
        var usedSize = UInt32(0)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &usedSize, &devices
        ) == noErr else { return }

        cmioDeviceIDs = devices
    }

    /// Read kCMIODevicePropertyDeviceIsRunningSomewhere for every CMIO device.
    /// Returns true as soon as any device is actively capturing.
    private func queryCameraInUse() -> Bool {
        for deviceID in cmioDeviceIDs {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }

            var isRunning: UInt32 = 0
            let bufSize   = UInt32(MemoryLayout<UInt32>.size)
            var usedSize  = UInt32(0)
            let status    = CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, bufSize, &usedSize, &isRunning)
            if status == noErr && isRunning != 0 { return true }
        }
        return false
    }

    // MARK: Property change listeners (live LED-matching updates)

    private var listenerBlock: CMIOObjectPropertyListenerBlock?

    private func installCameraListeners() {
        for deviceID in cmioDeviceIDs {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }

            // Store block so it stays alive
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.isCameraInUse = self?.queryCameraInUse() ?? false
                }
            }
            listenerBlocks.append(block)
            CMIOObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
        }
    }

    // Keep listener blocks alive
    private var listenerBlocks: [CMIOObjectPropertyListenerBlock] = []

    // MARK: Camera actions

    /// Deep-link to System Settings → Privacy → Camera.
    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Force-terminates VDCAssistant / AppleCameraAssistant to cut camera signal.
    /// Requires administrator privileges. Running apps will restart the daemon
    /// on their next frame request, so this is only a momentary hard-cut.
    /// Use openCameraPrivacySettings() for a persistent solution.
    func forceKillCameraDaemon() {
        Task.detached(priority: .userInitiated) {
            let script = "killall VDCAssistant 2>/dev/null; killall AppleCameraAssistant 2>/dev/null; echo done"
            let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            try? process.run()
            process.waitUntilExit()
        }
    }

    func refreshCameraState() {
        isCameraInUse = queryCameraInUse()
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
}
