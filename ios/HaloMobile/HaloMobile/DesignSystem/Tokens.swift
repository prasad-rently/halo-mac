import SwiftUI
import UIKit

// MARK: - Halo design tokens (iOS)
//
// Ported from Halo/DesignSystem/DesignSystem.swift (desktop) so phone and Mac read as one product.
// Dark-only by design: never add adaptive colours. See ios/HaloMobile/DESIGN.md.

extension Color {
    /// `#rgb`, `#rrggbb` or `#aarrggbb`.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    // Surfaces — identical to desktop.
    static let haloBackground = Color(hex: "#080c14")
    static let haloSurface    = Color(hex: "#0d1220")
    static let haloSurface2   = Color(hex: "#131928")   // cards sit on this, as on desktop
    static let haloBorder     = Color.white.opacity(0.07)
    static let haloBorder2    = Color.white.opacity(0.12)

    // Brand + semantic — identical to desktop.
    static let haloAccent     = Color(hex: "#4f7cff")
    static let haloAccent2    = Color(hex: "#7b5ea7")   // gradient pair with accent (fill only, 3.5:1 — never text)
    static let haloGreen      = Color(hex: "#22d97a")   // healthy / ok
    static let haloAmber      = Color(hex: "#f5a623")   // warning / limit
    static let haloRed        = Color(hex: "#ff4d6a")   // problem
    static let haloCyan       = Color(hex: "#00d4e8")   // URLs
    static let haloPurple     = Color(hex: "#b06cff")   // code

    // Text. Primary and secondary are the desktop values (AA: 15.7:1 and 5.6:1 on surface2).
    // DELIBERATE DEVIATION: desktop's tertiary #4a5568 measures 2.3:1 on surface2 — it fails
    // AA for text. On a phone, read in daylight, that is unreadable, so tertiary text uses
    // #7a869e (4.8:1). The desktop value survives as `haloTextDecor` for non-text decoration only.
    static let haloText       = Color(hex: "#f0f2f8")
    static let haloText2      = Color(hex: "#8892a8")
    static let haloText3      = Color(hex: "#7a869e")
    static let haloTextDecor  = Color(hex: "#4a5568")
}

// MARK: - Semantic state

/// Green healthy / amber warning / red problem / blue info / grey neutral. Always pair the colour
/// with a word or an icon — colour alone is never the signal (accessibility).
enum HaloState: Equatable {
    case ok, warning, error, info, neutral

    var color: Color {
        switch self {
        case .ok: return .haloGreen
        case .warning: return .haloAmber
        case .error: return .haloRed
        case .info: return .haloAccent
        case .neutral: return .haloText2
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "circle.dashed"
        }
    }
}

/// Clipboard/content kinds use the same colours as the desktop Clipboard module.
enum HaloContentKind {
    case text, url, code
    var color: Color {
        switch self {
        case .text: return .haloText2
        case .url: return .haloCyan
        case .code: return .haloPurple
        }
    }
}

// MARK: - Typography
//
// Text styles, not fixed point sizes, so everything follows Dynamic Type. Key numbers also get
// `minimumScaleFactor` at the call site rather than being truncated.

enum HaloFont {
    /// Big hero numbers (ring centre, metric values).
    static func number(_ style: Font.TextStyle = .title) -> Font { .system(style, design: .rounded).weight(.bold) }
    static let title      = Font.system(.title3).weight(.bold)           // card titles, screen sections
    static let headline   = Font.system(.headline)                        // row titles
    static let body       = Font.system(.subheadline)                     // default copy
    static let bodyMedium = Font.system(.subheadline).weight(.medium)
    static let caption    = Font.system(.caption)                         // subtitles, timestamps
    static let micro      = Font.system(.caption2).weight(.semibold)      // badges, chips
    static let section    = Font.system(.caption).weight(.semibold)       // small-caps section labels
    static let mono       = Font.system(.footnote, design: .monospaced)   // addresses, fingerprints
    static let button     = Font.system(.body).weight(.semibold)
}

// MARK: - Layout constants

enum HaloLayout {
    static let screenPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 12
    /// Apple HIG minimum hit target.
    static let minTarget: CGFloat = 44
}

// MARK: - Haptics

enum HaloHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func primary() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Screen chrome

extension View {
    /// Standard Halo screen background (behind scroll content, under the safe area).
    func haloScreen() -> some View {
        background(Color.haloBackground.ignoresSafeArea())
    }

    /// Animation that collapses to nothing when the user has Reduce Motion on.
    func haloAnimation<V: Equatable>(_ animation: Animation = .easeOut(duration: 0.4), value: V) -> some View {
        modifier(HaloAnimationModifier(animation: animation, value: value))
    }
}

private struct HaloAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

enum HaloAppearance {
    /// Tab bar / navigation bar in desktop colours. Call once at launch.
    static func install() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Color.haloSurface)
        tab.shadowColor = UIColor(Color.haloBorder)
        let normal = UIColor(Color.haloText3), selected = UIColor(Color.haloAccent)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = normal
            item.normal.titleTextAttributes = [.foregroundColor: normal]
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [.foregroundColor: selected]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(Color.haloBackground)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Color.haloText)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Color.haloText)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

// MARK: - Formatting

enum Bytes {
    static func string(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

enum HaloTime {
    /// "2 min ago" / "Yesterday" — compact relative time for rows.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
