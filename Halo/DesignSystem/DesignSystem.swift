import SwiftUI

// MARK: - Color Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    // Halo Design Tokens
    static let haloBackground = Color(hex: "#080c14")
    static let haloSurface = Color(hex: "#0d1220")
    static let haloSurface2 = Color(hex: "#131928")
    static let haloBorder = Color.white.opacity(0.07)
    static let haloBorder2 = Color.white.opacity(0.12)
    static let haloText = Color(hex: "#f0f2f8")
    static let haloText2 = Color(hex: "#8892a8")
    static let haloText3 = Color(hex: "#4a5568")
    static let haloAccent = Color(hex: "#4f7cff")
    static let haloAccent2 = Color(hex: "#7b5ea7")
    static let haloGreen = Color(hex: "#22d97a")
    static let haloAmber = Color(hex: "#f5a623")
    static let haloRed = Color(hex: "#ff4d6a")
    static let haloCyan = Color(hex: "#00d4e8")
    static let haloPurple = Color(hex: "#b06cff")
}

// MARK: - Typography

struct HaloFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Reusable View Components

// Surface Card
struct HaloCard<Content: View>: View {
    let content: Content
    var accentTop: Color? = nil

    init(accentTop: Color? = nil, @ViewBuilder content: () -> Content) {
        self.accentTop = accentTop
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .background(Color.haloSurface2)
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.haloBorder, lineWidth: 1)
                )
            if let accent = accentTop {
                Rectangle()
                    .fill(LinearGradient(colors: [accent, .clear],
                                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .cornerRadius(1)
            }
        }
    }
}

// Section Header
struct HaloSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String = "See all"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HaloFont.display(15))
                    .foregroundColor(.haloText)
                if let sub = subtitle {
                    Text(sub)
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                }
            }
            Spacer()
            if let action = action {
                Button(actionLabel, action: action)
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloAccent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }
}

// Status Badge
struct HaloBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(HaloFont.body(10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(20)
    }
}

// Primary Button
struct HaloPrimaryButton: View {
    let title: String
    let icon: String?
    var isLoading: Bool = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(HaloFont.body(13, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: [.haloAccent, .haloAccent2],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .foregroundColor(.white)
            .cornerRadius(11)
            .shadow(color: Color.haloAccent.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// Ghost Button
struct HaloGhostButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(HaloFont.body(12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.clear)
            .foregroundColor(.haloText2)
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.haloBorder2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// Mini Progress Bar
struct HaloMiniBar: View {
    let value: Double // 0–1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.haloBorder)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(.easeOut(duration: 0.4), value: value)
            }
        }
        .frame(height: 3)
    }
}

// Health Ring
struct HaloHealthRing: View {
    let score: Int
    let size: CGFloat

    private var scoreColor: Color {
        if score >= 75 { return .haloGreen }
        if score >= 50 { return .haloAmber }
        return .haloRed
    }

    private var progress: Double { Double(score) / 100.0 }
    private var circumference: Double { Double.pi * Double(size - 12) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: 8)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [scoreColor, .haloAccent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: score)

            VStack(spacing: 1) {
                Text("\(score)")
                    .font(HaloFont.display(size * 0.27, weight: .heavy))
                    .foregroundColor(scoreColor)
                Text("health")
                    .font(HaloFont.body(size * 0.1))
                    .foregroundColor(.haloText2)
            }
        }
    }
}

// Mini Metric Ring
struct HaloMiniRing: View {
    let value: Double
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 4)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
        }
    }
}

// Toggle
struct HaloToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isOn ? Color.haloGreen : Color.haloBorder2)
            .frame(width: 36, height: 20)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.2), radius: 2)
                    .offset(x: isOn ? 8 : -8)
                    .animation(.easeInOut(duration: 0.2), value: isOn)
            )
            .onTapGesture { isOn.toggle() }
    }
}

// Sparkline graph
struct HaloSparkline: View {
    let values: [Double]
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let maxVal = values.max() ?? 1
            let barWidth = (geo.size.width - CGFloat(values.count - 1) * 2) / CGFloat(values.count)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { i in
                    let normalized = maxVal > 0 ? values[i] / maxVal : 0
                    let barHeight = CGFloat(normalized) * height
                    let isLast = i == values.count - 1

                    RoundedRectangle(cornerRadius: 2)
                        .fill(isLast ? color : color.opacity(0.3 + 0.2 * normalized))
                        .frame(width: barWidth, height: max(3, barHeight))
                }
            }
        }
        .frame(height: height)
    }
}

// File row checkbox
struct HaloCheckbox: View {
    @Binding var isChecked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.haloBorder2, lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isChecked ? Color.haloAccent.opacity(0.15) : Color.clear)
                )
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.haloAccent)
            }
        }
        .onTapGesture { isChecked.toggle() }
    }
}
