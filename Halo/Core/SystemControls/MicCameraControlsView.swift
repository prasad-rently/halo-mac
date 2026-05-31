import SwiftUI

// MARK: - MicCameraControlsView
// Three-section privacy strip: Microphone · Camera · Screen
// Used in both MenuBar popup (compact) and ActionsView (full).

struct MicCameraControlsView: View {
    @ObservedObject private var ctrl = SystemControlsManager.shared
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            micPill
            cameraPill
            screenPill
        }
    }

    // MARK: Mic pill

    private var micPill: some View {
        ControlPillButton(
            icon:     ctrl.isMicMuted ? "mic.slash.fill" : "mic.fill",
            label:    ctrl.isMicMuted ? "Muted"          : "Mic Live",
            sublabel: ctrl.isMicMuted ? "Tap to unmute"  : "Tap to mute",
            color:    ctrl.isMicMuted ? .haloRed         : .haloGreen,
            isActive: !ctrl.isMicMuted,
            compact:  compact
        ) {
            withAnimation(.spring(response: 0.2)) { ctrl.toggleMic() }
        }
    }

    // MARK: Camera pill

    @State private var showCameraPopover = false

    private var cameraPill: some View {
        ControlPillButton(
            icon:     ctrl.isCameraHardCut ? "video.slash.fill"
                    : ctrl.isCameraInUse   ? "video.fill"
                    : "video.slash",
            label:    ctrl.isCameraHardCut ? "Cam Blocked"
                    : ctrl.isCameraInUse   ? "Cam Active"
                    : "Cam Idle",
            sublabel: ctrl.isCameraHardCut ? "Tap to restore"
                    : ctrl.isCameraInUse   ? "\(max(ctrl.cameraApps.count, 1)) app\(ctrl.cameraApps.count == 1 ? "" : "s")"
                    : "Not in use",
            color:    ctrl.isCameraHardCut ? .haloText3
                    : ctrl.isCameraInUse   ? .haloAmber
                    : .haloText3,
            isActive: ctrl.isCameraInUse && !ctrl.isCameraHardCut,
            compact:  compact
        ) { showCameraPopover = true }
        .popover(isPresented: $showCameraPopover, arrowEdge: .bottom) {
            CameraPrivacyPopover()
        }
    }

    // MARK: Screen pill

    @State private var showScreenPopover = false

    private var screenPill: some View {
        let isActive = ctrl.isSharingScreen || ctrl.isScreenRecording
        return ControlPillButton(
            icon:     ctrl.isSharingScreen  ? "display.2"
                    : ctrl.isScreenRecording ? "record.circle.fill"
                    : "rectangle.on.rectangle.slash",
            label:    ctrl.isSharingScreen  ? "Sharing"
                    : ctrl.isScreenRecording ? "Recording"
                    : "Screen OK",
            sublabel: ctrl.isSharingScreen  ? "Screen is shared"
                    : ctrl.isScreenRecording ? "\(ctrl.screenRecordingApps.count) app\(ctrl.screenRecordingApps.count == 1 ? "" : "s")"
                    : "Not shared",
            color:    ctrl.isSharingScreen  ? .haloRed
                    : ctrl.isScreenRecording ? .haloAmber
                    : .haloText3,
            isActive: isActive,
            compact:  compact
        ) { showScreenPopover = true }
        .popover(isPresented: $showScreenPopover, arrowEdge: .bottom) {
            ScreenPrivacyPopover()
        }
    }
}

// MARK: - ControlPillButton

struct ControlPillButton: View {
    let icon:     String
    let label:    String
    let sublabel: String
    let color:    Color
    let isActive: Bool
    var compact:  Bool = false
    let action:   () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 5 : 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(isActive ? 0.18 : 0.08))
                        .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)
                    Image(systemName: icon)
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .foregroundColor(isActive ? color : .haloText3)
                }
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(isActive ? .haloText : .haloText3)
                        Text(sublabel)
                            .font(HaloFont.body(9))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 7 : 11)
            .padding(.vertical, compact ? 5 : 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? color.opacity(0.10) : color.opacity(isActive ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? color.opacity(0.28) : Color.haloBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}

// MARK: - Camera Privacy Popover

struct CameraPrivacyPopover: View {
    @ObservedObject private var ctrl = SystemControlsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: ctrl.isCameraInUse ? "video.fill" : "video.slash")
                    .foregroundColor(ctrl.isCameraInUse ? .haloAmber : .haloText3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ctrl.isCameraHardCut ? "Camera Blocked by Halo"
                       : ctrl.isCameraInUse   ? "Camera is Active"
                       : "Camera is Idle")
                        .font(HaloFont.body(13, weight: .bold))
                    Text(ctrl.isCameraHardCut
                       ? "avconferenced stopped"
                       : ctrl.isCameraInUse ? "Green LED is on" : "Hardware idle")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
                Spacer()
            }
            .padding(14)

            Divider().background(Color.haloBorder)

            // Apps using camera
            if !ctrl.cameraApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("APPS WITH CAMERA ACCESS")
                        .font(HaloFont.body(9, weight: .semibold))
                        .foregroundColor(.haloText3)
                        .tracking(1)
                    ForEach(ctrl.cameraApps, id: \.bundleIdentifier) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(14)
                Divider().background(Color.haloBorder)
            } else if ctrl.isCameraInUse {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Identifying app…")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                }
                .padding(14)
                Divider().background(Color.haloBorder)
            }

            // Actions
            if ctrl.isCameraHardCut {
                popoverAction(icon: "video.fill", iconColor: .haloGreen,
                              title: "Restore Camera",
                              subtitle: "Restart avconferenced — all apps can use camera again") {
                    ctrl.restoreCamera(); dismiss()
                }
            } else {
                popoverAction(icon: "video.slash.fill", iconColor: .haloRed,
                              title: "Hard-Cut Camera Signal",
                              subtitle: "Stop avconferenced via launchctl — no admin required. Cuts camera for ALL apps.") {
                    ctrl.hardCutCamera(); dismiss()
                }
            }

            Divider().background(Color.haloBorder).padding(.leading, 44)

            popoverAction(icon: "lock.shield.fill", iconColor: .haloAccent,
                          title: "Manage Per-App Permissions",
                          subtitle: "System Settings → Privacy → Camera") {
                ctrl.openCameraPrivacySettings(); dismiss()
            }

            Divider().background(Color.haloBorder)
            infoFooter("macOS prevents apps from permanently blocking the camera for other processes. Hard-Cut stops the camera broker daemon — apps cannot restart it until you tap Restore.")
        }
        .frame(width: 340)
        .background(Color.haloBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Screen Privacy Popover

struct ScreenPrivacyPopover: View {
    @ObservedObject private var ctrl = SystemControlsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: ctrl.isSharingScreen ? "display.2"
                               : ctrl.isScreenRecording ? "record.circle.fill"
                               : "rectangle.on.rectangle.slash")
                    .foregroundColor(ctrl.isSharingScreen ? .haloRed
                                   : ctrl.isScreenRecording ? .haloAmber : .haloText3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ctrl.isSharingScreen  ? "Screen is Being Shared"
                       : ctrl.isScreenRecording ? "Screen is Being Recorded"
                       : "Screen is Private")
                        .font(HaloFont.body(13, weight: .bold))
                    Text(ctrl.isSharingScreen  ? "screensharing.agent active"
                       : ctrl.isScreenRecording ? "ScreenCaptureKit session detected"
                       : "No active capture")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
                Spacer()
            }
            .padding(14)

            Divider().background(Color.haloBorder)

            // Apps recording screen
            if !ctrl.screenRecordingApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("APPS WITH SCREEN RECORDING ACCESS")
                        .font(HaloFont.body(9, weight: .semibold))
                        .foregroundColor(.haloText3)
                        .tracking(1)
                    ForEach(ctrl.screenRecordingApps, id: \.bundleIdentifier) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(14)
                Divider().background(Color.haloBorder)
            }

            // Stop sharing (only shown when active)
            if ctrl.isSharingScreen {
                popoverAction(icon: "stop.fill", iconColor: .haloRed,
                              title: "Stop Screen Sharing",
                              subtitle: "Stops the macOS screensharing.agent — ends all Remote Desktop sessions") {
                    ctrl.stopScreenSharing(); dismiss()
                }
                Divider().background(Color.haloBorder).padding(.leading, 44)
            }

            popoverAction(icon: "lock.shield.fill", iconColor: .haloAccent,
                          title: "Manage Screen Recording Permissions",
                          subtitle: "System Settings → Privacy → Screen & System Audio Recording") {
                ctrl.openScreenPrivacySettings(); dismiss()
            }

            Divider().background(Color.haloBorder)
            infoFooter("Halo can stop the Screen Sharing agent (Remote Desktop). For app-based recording (Zoom, QuickTime), revoke screen recording permission in System Settings.")
        }
        .frame(width: 340)
        .background(Color.haloBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Shared Popover Components

private func popoverAction(icon: String, iconColor: Color,
                            title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.haloText)
                Text(subtitle)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

private func infoFooter(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Image(systemName: "info.circle")
            .font(.system(size: 10))
            .foregroundColor(.haloText3)
            .padding(.top, 1)
        Text(text)
            .font(HaloFont.body(10))
            .foregroundColor(.haloText3)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .background(Color.haloSurface2)
}

// MARK: - App row (icon + name + bundle ID)

private struct AppRowView: View {
    let app: NSRunningApplication
    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .cornerRadius(5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                if let id = app.bundleIdentifier {
                    Text(id)
                        .font(HaloFont.mono(9))
                        .foregroundColor(.haloText3)
                }
            }
            Spacer()
            Circle()
                .fill(Color.haloGreen)
                .frame(width: 6, height: 6)
                .help("Running")
        }
    }
}

// MARK: - Compact Status Badges (for MenuBar header)

struct MicCameraStatusBadges: View {
    @ObservedObject private var ctrl = SystemControlsManager.shared

    var body: some View {
        HStack(spacing: 5) {
            badge(icon: ctrl.isMicMuted ? "mic.slash.fill" : "mic.fill",
                  label: ctrl.isMicMuted ? "Muted" : "Live",
                  color: ctrl.isMicMuted ? .haloRed : .haloGreen)
            if ctrl.isCameraInUse || ctrl.isCameraHardCut {
                badge(icon: ctrl.isCameraHardCut ? "video.slash.fill" : "video.fill",
                      label: ctrl.isCameraHardCut ? "Blocked" : "Cam",
                      color: ctrl.isCameraHardCut ? .haloText3 : .haloAmber)
            }
            if ctrl.isSharingScreen || ctrl.isScreenRecording {
                badge(icon: ctrl.isSharingScreen ? "display.2" : "record.circle.fill",
                      label: ctrl.isSharingScreen ? "Sharing" : "Recording",
                      color: ctrl.isSharingScreen ? .haloRed : .haloAmber)
            }
        }
    }

    private func badge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label).font(HaloFont.body(9, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }
}
