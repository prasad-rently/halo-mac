import SwiftUI

// Halo's dark-only design tokens (docs/DESIGN_SYSTEM.md), mirrored for iOS. Dark-only by design.
extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let haloBackground = Color(hex: "#080c14")
    static let haloSurface    = Color(hex: "#0d1220")
    static let haloSurface2   = Color(hex: "#131928")
    static let haloAccent     = Color(hex: "#4f7cff")
    static let haloGreen      = Color(hex: "#22d97a")
    static let haloAmber      = Color(hex: "#f5a623")
    static let haloRed        = Color(hex: "#ff4d6a")
    static let haloText       = Color(hex: "#eef2fb")
    static let haloText2      = Color(hex: "#a9b4cc")
    static let haloText3      = Color(hex: "#6b7791")
    static let haloBorder     = Color.white.opacity(0.08)
}

struct HaloCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.haloSurface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(1.4)
            .foregroundColor(.haloText3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Bytes {
    static func string(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
