import SwiftUI

/// Surface card — the container for everything on a Halo screen. Mirrors the desktop `HaloCard`
/// (surface2 fill, 14pt radius, hairline border, optional accent bar clipped to the curve).
///
/// Source-compatible with the previous `HaloCard { … }` call sites: content-only init still works
/// and still pads 14pt.
struct HaloCard<Content: View>: View {
    var accentTop: Color?
    var padding: CGFloat
    var fill: Color
    let content: Content

    init(accentTop: Color? = nil, padding: CGFloat = 14, fill: Color = .haloSurface2,
         @ViewBuilder content: () -> Content) {
        self.accentTop = accentTop
        self.padding = padding
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill)
            if let accent = accentTop {
                Rectangle()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }
        }
        // Clip to the card's own shape so the accent bar follows the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous).stroke(Color.haloBorder, lineWidth: 1))
    }
}

#Preview("HaloCard") {
    VStack(spacing: 12) {
        HaloCard { Text("Plain card").foregroundColor(.haloText) }
        HaloCard(accentTop: .haloGreen) { Text("Accent card").foregroundColor(.haloText) }
    }
    .padding().haloScreen()
}
