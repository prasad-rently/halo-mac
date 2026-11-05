import SwiftUI

// MARK: - HaloSectionHeader

/// Small-caps section label, with an optional trailing action and an optional (i) that opens a
/// `HaloInfoSheet`. Explanations live behind the (i); the header itself never carries a paragraph.
struct HaloSectionHeader: View {
    var title: String
    var actionLabel: String?
    var action: (() -> Void)?
    var onInfo: (() -> Void)?

    init(_ title: String, actionLabel: String? = nil, action: (() -> Void)? = nil, onInfo: (() -> Void)? = nil) {
        self.title = title; self.actionLabel = actionLabel; self.action = action; self.onInfo = onInfo
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(HaloFont.section).tracking(1.2)
                .foregroundColor(.haloText3)
                .accessibilityAddTraits(.isHeader)
            if let onInfo { HaloInfoButton(title: title, action: onInfo) }
            Spacer(minLength: 8)
            if let action, let actionLabel {
                Button(actionLabel) { HaloHaptics.tap(); action() }
                    .font(HaloFont.caption.weight(.semibold)).foregroundColor(.haloAccent)
                    .frame(minHeight: HaloLayout.minTarget, alignment: .trailing)
            }
        }
        .frame(minHeight: 28)
    }
}

/// Back-compat shim for the pre-design-system `SectionLabel("…")`. New code: `HaloSectionHeader`.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { HaloSectionHeader(text) }
}

// MARK: - HaloListRow

/// Compact row: icon tile, title, one-line subtitle, trailing value/accessory. Put several in one
/// `HaloCard(padding: 0)` separated by `HaloRowDivider()`, or use alone.
struct HaloListRow<Trailing: View>: View {
    var icon: String?
    var tint: Color
    var title: String
    var subtitle: String?
    var trailing: Trailing
    var showsChevron: Bool

    init(icon: String? = nil, tint: Color = .haloAccent, title: String, subtitle: String? = nil,
         showsChevron: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon; self.tint = tint; self.title = title; self.subtitle = subtitle
        self.showsChevron = showsChevron; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundColor(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(HaloFont.caption).foregroundColor(.haloText2).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
            if showsChevron {
                Image(systemName: "chevron.forward").font(.system(.caption).weight(.semibold))
                    .foregroundColor(.haloText3).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension HaloListRow where Trailing == EmptyView {
    init(icon: String? = nil, tint: Color = .haloAccent, title: String, subtitle: String? = nil, showsChevron: Bool = false) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle, showsChevron: showsChevron) { EmptyView() }
    }
}

struct HaloRowDivider: View {
    var inset: CGFloat = 62
    var body: some View {
        Rectangle().fill(Color.haloBorder).frame(height: 1).padding(.leading, inset)
    }
}

// MARK: - HaloEmptyState

/// One line + one action. Never a paragraph; the long version goes in a `HaloInfoSheet`.
/// Rooted so it is safe inside a `ScrollView` (no unbounded `maxHeight: .infinity` — see the
/// desktop `boundedEmptyState()` note in DesignSystem.swift).
struct HaloEmptyState: View {
    var icon: String
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.haloText3)
                .frame(width: 68, height: 68)
                .background(Circle().fill(Color.white.opacity(0.04)))
                .accessibilityHidden(true)
            Text(title).font(HaloFont.headline).foregroundColor(.haloText).multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle).font(HaloFont.caption).foregroundColor(.haloText2).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                HaloPrimaryButton(actionTitle, fullWidth: false, action: action).padding(.top, 4)
            }
        }
        .padding(.vertical, 28).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Lists") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HaloSectionHeader("Recent activity", actionLabel: "Clear", action: {}, onInfo: {})
            HaloCard(padding: 0) {
                VStack(spacing: 0) {
                    HaloListRow(icon: "arrow.down.circle.fill", tint: .haloGreen, title: "photo.jpg", subtitle: "Received from Gokul's Mac") {
                        Text("2 min ago").font(HaloFont.caption).foregroundColor(.haloText2)
                    }
                    HaloRowDivider()
                    HaloListRow(icon: "gearshape", tint: .haloAccent, title: "Cloud", subtitle: "Not set up", showsChevron: true)
                }
            }
            HaloCard { HaloEmptyState(icon: "tray", title: "Nothing received", subtitle: "Files sent to this phone show up here.", actionTitle: "Scan nearby") {} }
        }.padding()
    }.haloScreen()
}
