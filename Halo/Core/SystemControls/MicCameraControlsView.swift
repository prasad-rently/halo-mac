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

    private var cameraButton: some View {
        ControlPillButton(
            icon:     controls.cameraAppRunning ? "video.fill"        : "video.slash",
            label:    controls.cameraAppRunning ? "Cam Active"        : "Cam Idle",
            sublabel: controls.cameraAppRunning ? "Meeting app open"  : "No video calls",
            color:    controls.cameraAppRunning ? Color.haloAmber     : Color.haloText3,
            isActive: controls.cameraAppRunning,
            compact:  compact
        ) {
            controls.openCameraPrivacySettings()
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
            if controls.cameraAppRunning {
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
