import SwiftUI

// MARK: - HaloPrimaryButton

/// Accent-gradient primary action with haptic. Full width by default (a phone's primary action
/// should be a big thumb target). Disable with `.disabled(_:)`.
struct HaloPrimaryButton: View {
    var title: String
    var icon: String?
    var isLoading = false
    var fullWidth = true
    var enabledOverride = true
    let action: () -> Void
    @Environment(\.isEnabled) private var envEnabled
    private var isEnabled: Bool { envEnabled && enabledOverride }

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, fullWidth: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.isLoading = isLoading; self.fullWidth = fullWidth; self.action = action
    }

    /// Labelled form used by the cloud screens (`HaloPrimaryButton(title:icon:enabled:action:)`).
    init(title: String, icon: String? = nil, enabled: Bool = true, isLoading: Bool = false, action: @escaping () -> Void) {
        self.init(title, icon: icon, isLoading: isLoading, action: action)
        self.enabledOverride = enabled
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
            .background(LinearGradient(colors: [.haloAccentFill, .haloAccent2], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HaloLayout.controlRadius + 2, style: .continuous))
            .shadow(color: Color.haloAccent.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(HaloPressStyle())
        .disabled(isLoading || !enabledOverride)
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

    init(icon: String, label: String, tint: Color = .haloText2, filled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.label = label; self.tint = tint; self.filled = filled; self.action = action
    }

    /// Source-compatible with the cloud workstream's `HaloIconButton(icon:label:color:action:)`.
    init(icon: String, label: String, color: Color, action: @escaping () -> Void) {
        self.init(icon: icon, label: label, tint: color, action: action)
    }

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
    var tint: Color
    var isSelected: Bool
    var action: (() -> Void)?

    /// Neutral by default (grey); pass `tint` for a coloured / selected filter chip.
    init(text: String, icon: String? = nil, tint: Color = .haloText2, isSelected: Bool = true, action: (() -> Void)? = nil) {
        self.text = text; self.icon = icon; self.tint = tint; self.isSelected = isSelected; self.action = action
    }

    /// Source-compatible with the cloud workstream's `HaloChip(text:icon:color:)`.
    init(text: String, icon: String? = nil, color: Color) { self.init(text: text, icon: icon, tint: color) }

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
        .foregroundColor(isSelected ? Color.haloReadable(tint) : .haloText2)
        .background(Capsule().fill(isSelected ? tint.opacity(0.10) : Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(isSelected ? tint.opacity(0.35) : Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - HaloStatusBadge

/// State pill: dot/icon + word. `HaloStatusBadge("Ready", .ok)`. The word is the signal; colour reinforces it.
struct HaloStatusBadge: View {
    var text: String
    var state: HaloState
    var showsIcon = true
    /// Line limit at normal text sizes. Pass a larger value (or 0 for unlimited) when the text is a
    /// reason the person must be able to read in full, e.g. why the receiver could not start.
    var maxLines = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String, _ state: HaloState = .neutral, showsIcon: Bool = true, maxLines: Int = 1) {
        self.text = text; self.state = state; self.showsIcon = showsIcon; self.maxLines = maxLines
    }

    /// Source-compatible with the cloud workstream's `HaloStatusBadge(text:level:)`.
    enum Level {
        case good, warn, bad, idle
        var state: HaloState { switch self { case .good: return .ok; case .warn: return .warning; case .bad: return .error; case .idle: return .neutral } }
    }
    init(text: String, level: Level) { self.init(text, level.state) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if showsIcon { Image(systemName: state.symbol).font(.system(.caption2).weight(.bold)).accessibilityHidden(true) }
            Text(text).font(HaloFont.micro)
                .lineLimit(maxLines == 0 ? nil : (typeSize.isAccessibilitySize ? max(maxLines, 4) : maxLines))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundColor(Color.haloReadable(state.color))
        // RoundedRectangle (radius clamps to a capsule on one line) so a wrapped reason doesn't turn into a blob.
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(state.color.opacity(0.10)))
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
