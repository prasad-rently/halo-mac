import Foundation
import CoreAudio
import AVFoundation
import AppKit

// MARK: - SystemControlsManager

/// Manages universal microphone mute and camera-in-use state.
///
/// Microphone:
///   Uses CoreAudio to set `kAudioDevicePropertyMute` on the default
///   input device — a true hardware-level mute that affects ALL apps
///   (Zoom, Teams, Meet, FaceTime, Discord, etc.) simultaneously.
///   Falls back to setting input volume = 0 on devices that don't support mute.
///
/// Camera:
///   macOS does not expose a public API to block camera access for running apps.
///   We detect whether the camera is likely in use by checking if any known
///   video-calling app is running, and provide a direct link to
///   System Settings → Privacy → Camera to manage per-app permissions.
@MainActor
final class SystemControlsManager: ObservableObject {

    static let shared = SystemControlsManager()

    // MARK: - Published state

    @Published private(set) var isMicMuted       = false
    @Published private(set) var cameraAppRunning = false   // known video-call app is active
    @Published private(set) var cameraGranted    = false   // Halo has camera auth

    // MARK: - Private

    private var defaultInputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var supportsMuteProperty = false
    private var preMuteVolume: Int = 75    // saved input volume before soft-mute

    // Bundle IDs of apps that commonly activate the camera/mic
    private static let videoCallBundles: Set<String> = [
        "us.zoom.xos", "us.zoom.ZoomRooms",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.google.Chrome", "org.chromium.Chromium",
        "com.apple.FaceTime",
        "com.cisco.webex.meetings", "com.cisco.webex.FTEPlugin",
        "com.skype.skype",
        "com.discord.Discord",
        "com.bluejeans.BlueJeans",
        "com.ringcentral.glip",
        "com.slack.Slack",
        "com.apple.Safari",          // for browser-based calls
        "com.whereby.Whereby",
        "com.loom.desktop",
        "io.dyte.desktop",
    ]

    // MARK: - Init

    private init() {
        resolveDefaultInputDevice()
        refreshMuteState()
        refreshCameraState()
        installNotifications()
    }

    // MARK: - Microphone

    func toggleMic() {
        setMicMuted(!isMicMuted)
    }

    func setMicMuted(_ muted: Bool) {
        if supportsMuteProperty {
            hardwareMute(muted)
        } else {
            softMute(muted)
        }
        // Re-read so the published value reflects hardware truth
        refreshMuteState()
    }

    // MARK: - Camera

    func refreshCameraState() {
        let running = NSWorkspace.shared.runningApplications
        cameraAppRunning = running.contains {
            SystemControlsManager.videoCallBundles.contains($0.bundleIdentifier ?? "")
        }
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private: audio

    private func resolveDefaultInputDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devID = AudioDeviceID(kAudioObjectUnknown)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        defaultInputDevice = devID

        // Check if this device supports mute
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        supportsMuteProperty = AudioObjectHasProperty(devID, &muteAddr)
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
            // Soft-mute: check input volume
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
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil, size, &val)
        isMicMuted = muted
    }

    private func softMute(_ muted: Bool) {
        if muted {
            preMuteVolume = getInputVolume()
            setInputVolume(0)
            isMicMuted = true
        } else {
            setInputVolume(max(preMuteVolume, 50))  // restore (min 50 so it's audible)
            isMicMuted = false
        }
    }

    private func getInputVolume() -> Int {
        var vol: Float32 = 0
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
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(defaultInputDevice, &addr, 0, nil, size, &vol)
    }

    // MARK: - Notifications

    private func installNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCameraState() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCameraState() }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCameraState() }
        }
    }
}
