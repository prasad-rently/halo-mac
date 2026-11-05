import SwiftUI
import UIKit

// TEMPORARY SHIM. The shared design system (HaloMetricTile, HaloChip, HaloPrimaryButton, …) is being built on
// feat/v2.6-m-ios-design (ios/HaloMobile/HaloMobile/DesignSystem). These are minimal stand-ins under the SAME
// component names so the cloud screens are written against the final vocabulary. When that branch is merged,
// DELETE THIS FILE — the call sites do not change.
// (If the real components have different initialisers, adjust the call sites; there are few.)

struct HaloChip: View {
    let text: String
    var icon: String? = nil
    var color: Color = .haloText2
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct HaloStatusBadge: View {
    enum Level { case good, warn, bad, idle
        var color: Color { switch self { case .good: return .haloGreen; case .warn: return .haloAmber; case .bad: return .haloRed; case .idle: return .haloText3 } }
    }
    let text: String
    var level: Level
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(level.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(level.color)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HaloMetricTile: View {
    let title: String
    let value: String
    var icon: String
    var color: Color = .haloAccent
    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 16))
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.haloText).minimumScaleFactor(0.7).lineLimit(1)
                Text(title).font(.system(size: 11)).foregroundColor(.haloText3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct HaloPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 16))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.haloAccent, Color(hex: "#7b5ea7")], startPoint: .leading, endPoint: .trailing)))
            .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
    }
}

struct HaloIconButton: View {
    let icon: String
    let label: String
    var color: Color = .haloAccent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color.opacity(0.14)))
        }
        .accessibilityLabel(label)
    }
}

struct HaloEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundColor(.haloText3)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.haloText)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(.haloText3).multilineTextAlignment(.center) }
            if let actionTitle, let action { HaloPrimaryButton(title: actionTitle, action: action).frame(maxWidth: 260).padding(.top, 6) }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An (i) button that opens a bottom sheet — where the explanations live, off the main surface.
struct HaloInfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: { Image(systemName: "info.circle").foregroundColor(.haloText2).frame(width: 44, height: 44) }
            .accessibilityLabel("About \(title)")
            .sheet(isPresented: $shown) {
                NavigationStack {
                    ScrollView { VStack(alignment: .leading, spacing: 12) { content }.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(Color.haloBackground)
                        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { shown = false } } }
                }
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
            }
    }
}

struct InfoLine: View {
    let icon: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(.haloAccent).frame(width: 22)
            Text(text).font(.system(size: 14)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Short-lived confirmation pill.
struct ToastModifier: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(.haloText)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.haloSurface2)).overlay(Capsule().stroke(Color.haloBorder))
                    .padding(.bottom, 12).transition(.opacity)
                    .task(id: text) { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { self.text = nil } }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: text)
    }
}
extension View { func toast(_ text: Binding<String?>) -> some View { modifier(ToastModifier(text: text)) } }

/// A monogram avatar: first letter(s) on a stable colour per sender.
struct HaloAvatar: View {
    let name: String
    private var initials: String {
        let letters = name.filter { $0.isLetter }
        if letters.isEmpty { return "#" }
        return String(letters.prefix(1)).uppercased()
    }
    private var color: Color {
        let palette: [Color] = [.haloAccent, Color(hex: "#7b5ea7"), .haloGreen, .haloAmber, Color(hex: "#00d4e8"), Color(hex: "#b06cff")]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
    var body: some View {
        Text(initials).font(.system(size: 16, weight: .bold)).foregroundColor(color)
            .frame(width: 42, height: 42).background(Circle().fill(color.opacity(0.18)))
            .accessibilityHidden(true)
    }
}
