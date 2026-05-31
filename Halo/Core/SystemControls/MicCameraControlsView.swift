import SwiftUI

// MARK: - MicCameraControlsView
// Reusable mic-mute + camera-status strip.
// Used in both the MenuBar popup and the ActionsView header.

struct MicCameraControlsView: View {

    @ObservedObject private var controls = SystemControlsManager.shared

    var compact: Bool = false   // true = menu bar size, false = full size

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            micButton
            cameraButton
        }
    }

    // MARK: - Mic

    private var micButton: some View {
        ControlPillButton(
            icon:     controls.isMicMuted ? "mic.slash.fill" : "mic.fill",
            label:    controls.isMicMuted ? "Muted"          : "Mic Live",
            sublabel: controls.isMicMuted ? "Tap to unmute"  : "Tap to mute",
            color:    controls.isMicMuted ? Color.haloRed    : Color.haloGreen,
            isActive: !controls.isMicMuted,
            compact:  compact
        ) {
            withAnimation(.spring(response: 0.25)) {
                controls.toggleMic()
            }
        }
    }

    // MARK: - Camera

    @State private var showCameraMenu = false

    private var cameraButton: some View {
        ControlPillButton(
            icon:     controls.isCameraInUse ? "video.fill"             : "video.slash",
            label:    controls.isCameraInUse ? "Camera Active"          : "Camera Idle",
            sublabel: controls.isCameraInUse ? "LED is on — tap options": "Not in use",
            color:    controls.isCameraInUse ? Color.haloAmber          : Color.haloText3,
            isActive: controls.isCameraInUse,
            compact:  compact
        ) {
            showCameraMenu = true
        }
        .popover(isPresented: $showCameraMenu, arrowEdge: .bottom) {
            CameraOptionsPopover()
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
            HStack(spacing: compact ? 6 : 8) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(color.opacity(isActive ? 0.18 : 0.08))
                        .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                    Image(systemName: icon)
                        .font(.system(size: compact ? 13 : 16, weight: .semibold))
                        .foregroundColor(isActive ? color : .haloText3)
                }
                // Labels (hidden in compact mode to keep it tight)
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(HaloFont.body(12, weight: .semibold))
                            .foregroundColor(isActive ? .haloText : .haloText3)
                        Text(sublabel)
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical,   compact ? 6 : 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered
                          ? color.opacity(0.10)
                          : color.opacity(isActive ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? color.opacity(0.30) : Color.haloBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}

// MARK: - Camera Options Popover

struct CameraOptionsPopover: View {
    @ObservedObject private var controls = SystemControlsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: controls.isCameraInUse ? "video.fill" : "video.slash")
                    .foregroundColor(controls.isCameraInUse ? .haloAmber : .haloText3)
                Text(controls.isCameraInUse ? "Camera is Active" : "Camera is Idle")
                    .font(HaloFont.body(13, weight: .bold))
                    .foregroundColor(.haloText)
            }
            .padding(14)

            Divider().background(Color.haloBorder)

            // Option 1 — Privacy settings
            optionRow(
                icon: "lock.shield.fill",
                iconColor: .haloAccent,
                title: "Manage App Permissions",
                subtitle: "Revoke camera access per-app in System Settings → Privacy → Camera"
            ) {
                controls.openCameraPrivacySettings()
                dismiss()
            }

            Divider().background(Color.haloBorder).padding(.leading, 44)

            // Option 2 — Force-kill daemon
            optionRow(
                icon: "power",
                iconColor: .haloRed,
                title: "Hard-Cut Camera Signal",
                subtitle: "Kills VDCAssistant daemon (admin required). Apps will restart it on next frame request — temporary only."
            ) {
                controls.forceKillCameraDaemon()
                dismiss()
            }

            Divider().background(Color.haloBorder)

            // Info footer
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.haloText3)
                Text("macOS does not allow apps to permanently block camera access for other running processes. Per-app TCC permissions are the reliable solution.")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.haloSurface2)
        }
        .frame(width: 320)
        .background(Color.haloBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }

    private func optionRow(icon: String, iconColor: Color,
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
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview helper (compact status-only display)

struct MicCameraStatusBadges: View {
    @ObservedObject private var controls = SystemControlsManager.shared

    var body: some View {
        HStack(spacing: 6) {
            // Mic badge
            HStack(spacing: 3) {
                Image(systemName: controls.isMicMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(controls.isMicMuted ? .haloRed : .haloGreen)
                Text(controls.isMicMuted ? "Muted" : "Live")
                    .font(HaloFont.body(9, weight: .semibold))
                    .foregroundColor(controls.isMicMuted ? .haloRed : .haloGreen)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((controls.isMicMuted ? Color.haloRed : Color.haloGreen).opacity(0.12))
            .cornerRadius(4)

            // Camera badge (only shown when active)
            if controls.isCameraInUse {
                HStack(spacing: 3) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.haloAmber)
                    Text("Cam")
                        .font(HaloFont.body(9, weight: .semibold))
                        .foregroundColor(.haloAmber)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.haloAmber.opacity(0.12))
                .cornerRadius(4)
            }
        }
    }
}
