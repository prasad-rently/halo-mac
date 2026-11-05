import SwiftUI

// Local stand-ins for the shared design-system components (HaloChip, HaloInfoSheet,
// HaloPrimaryButton) that the ios-design workstream is building in DesignSystem/.
// On merge, delete this file and let the real components win — the names and call shapes match
// docs of the mobile design brief. Tokens come from Theme.swift.

struct HaloChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .haloText2

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

struct HaloPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.haloAccent, Color(hex: "#7b5ea7")], startPoint: .leading, endPoint: .trailing))
                .opacity(enabled ? 1 : 0.35))
        }
        .buttonStyle(.plain)
    }
}

/// An (i) button that opens a bottom sheet holding the explanation.
struct HaloInfoButton: View {
    let title: String
    let message: String
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle").font(.system(size: 16)).foregroundColor(.haloText3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("About \(title)")
        .sheet(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 18, weight: .semibold)).foregroundColor(.haloText)
                Text(message).font(.system(size: 14)).foregroundColor(.haloText2)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.haloBackground.ignoresSafeArea())
            .presentationDetents([.medium])
        }
    }
}
