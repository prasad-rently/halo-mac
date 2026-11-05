import SwiftUI

// MARK: - HaloPrimaryButton

/// Accent-gradient primary action with haptic. Full width by default (a phone's primary action
/// should be a big thumb target). Disable with `.disabled(_:)`.
struct HaloPrimaryButton: View {
    var title: String
    var icon: String?
    var isLoading = false
    var fullWidth = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, fullWidth: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.isLoading = isLoading; self.fullWidth = fullWidth; self.action = action
    }

    var body: some View {
        Button {
            HaloHaptics.primary()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let icon {
                    Image(systemName: icon).font(.system(.body).weight(.semibold))
                }
                Text(title).font(HaloFont.button).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 52)
            .background(LinearGradient(colors: [.haloAccent, .haloAccent2], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HaloLayout.controlRadius + 2, style: .continuous))
            .shadow(color: Color.haloAccent.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(HaloPressStyle())
        .disabled(isLoading)
    }
}

/// Quiet secondary action (desktop `HaloGhostButton`).
struct HaloSecondaryButton: View {
    var title: String
    var icon: String?
    var tint: Color = .haloText
    var fullWidth = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, icon: String? = nil, tint: Color = .haloText, fullWidth: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.tint = tint; self.fullWidth = fullWidth; self.action = action
    }

    var body: some View {
        Button { HaloHaptics.tap(); action() } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(.subheadline).weight(.semibold)) }
                Text(title).font(HaloFont.bodyMedium).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: HaloLayout.minTarget)
            .overlay(RoundedRectangle(cornerRadius: HaloLayout.controlRadius, style: .continuous).stroke(Color.haloBorder2, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(HaloPressStyle())
    }
}

// MARK: - HaloIconButton

/// Icon-only button. `label` is mandatory because VoiceOver has nothing else to read.
struct HaloIconButton: View {
    var icon: String
    var label: String
    var tint: Color = .haloText2
    var filled = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { HaloHaptics.tap(); action() } label: {
            Image(systemName: icon)
                .font(.system(.body).weight(.semibold))
                .foregroundColor(filled ? .white : tint)
                .frame(width: HaloLayout.minTarget, height: HaloLayout.minTarget)
                .background(Circle().fill(filled ? tint.opacity(0.9) : Color.white.opacity(0.05)))
                .overlay(Circle().stroke(Color.haloBorder, lineWidth: filled ? 0 : 1))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(HaloPressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - HaloChip

/// Small pill. Static (a label) or, with `action`, a filter/selection chip. The tappable area is
/// padded out to 44pt while the visible pill stays compact.
struct HaloChip: View {
    var text: String
    var icon: String?
    var tint: Color = .haloAccent
    var isSelected = true
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button { HaloHaptics.selection(); action() } label: {
                pill.frame(minHeight: HaloLayout.minTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(.caption2).weight(.bold)) }
            Text(text).font(HaloFont.micro).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundColor(isSelected ? tint : .haloText2)
        .background(Capsule().fill(isSelected ? tint.opacity(0.15) : Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(isSelected ? tint.opacity(0.35) : Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - HaloStatusBadge

/// State pill: dot/icon + word. `HaloStatusBadge("Ready", .ok)`. The word is the signal; colour reinforces it.
struct HaloStatusBadge: View {
    var text: String
    var state: HaloState
    var showsIcon = true

    init(_ text: String, _ state: HaloState = .neutral, showsIcon: Bool = true) {
        self.text = text; self.state = state; self.showsIcon = showsIcon
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsIcon { Image(systemName: state.symbol).font(.system(.caption2).weight(.bold)).accessibilityHidden(true) }
            Text(text).font(HaloFont.micro).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundColor(state.color)
        .background(Capsule().fill(state.color.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#Preview("Controls") {
    VStack(alignment: .leading, spacing: 16) {
        HaloPrimaryButton("Choose files", icon: "doc.badge.plus") {}
        HaloPrimaryButton("Disabled", icon: "paperplane") {}.disabled(true)
        HaloSecondaryButton("Scan nearby", icon: "dot.radiowaves.left.and.right") {}
        HStack {
            HaloIconButton(icon: "doc.on.doc", label: "Copy") {}
            HaloIconButton(icon: "pin", label: "Pin", tint: .haloAmber) {}
            HaloIconButton(icon: "paperplane.fill", label: "Send", tint: .haloAccent, filled: true) {}
        }
        HStack {
            HaloChip(text: "All") {}
            HaloChip(text: "SIM 1", isSelected: false) {}
            HaloChip(text: "Viewer only", icon: "eye", tint: .haloAmber)
        }
        HStack {
            HaloStatusBadge("Ready", .ok); HaloStatusBadge("Offline", .warning)
            HaloStatusBadge("Failed", .error); HaloStatusBadge("Not set up")
        }
    }
    .padding().haloScreen()
}
