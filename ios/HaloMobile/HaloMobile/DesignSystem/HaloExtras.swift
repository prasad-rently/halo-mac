import SwiftUI

// MARK: - Toast

/// Short-lived confirmation pill: `.toast($model.toast)` — set the binding to a string, it clears itself.
struct ToastModifier: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text).font(HaloFont.bodyMedium).foregroundColor(.haloText)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.haloSurface2)).overlay(Capsule().stroke(Color.haloBorder2))
                    .padding(.bottom, 12).transition(.opacity)
                    .task(id: text) { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { self.text = nil } }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: text)
    }
}

extension View { func toast(_ text: Binding<String?>) -> some View { modifier(ToastModifier(text: text)) } }

// MARK: - HaloAvatar

/// Monogram avatar: first letter on a stable colour per name (message threads, contacts).
struct HaloAvatar: View {
    let name: String
    var size: CGFloat = 42

    private var initial: String {
        let letters = name.filter { $0.isLetter }
        return letters.isEmpty ? "#" : String(letters.prefix(1)).uppercased()
    }
    private var color: Color {
        let palette: [Color] = [.haloAccent, .haloAccent2, .haloGreen, .haloAmber, .haloCyan, .haloPurple]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
    var body: some View {
        Text(initial).font(.system(.callout, design: .rounded).weight(.bold)).foregroundColor(color)
            .frame(width: size, height: size).background(Circle().fill(color.opacity(0.18)))
            .accessibilityHidden(true)
    }
}
