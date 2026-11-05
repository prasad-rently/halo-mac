import SwiftUI

// MARK: - HaloRing

/// Status ring (desktop `HaloHealthRing`): coloured arc + big centre value + one-word caption.
/// `progress` is 0…1. Colour is explicit so callers choose the semantics (green ok / amber / red).
struct HaloRing: View {
    var progress: Double
    var tint: Color = .haloGreen
    var value: String
    var caption: String?
    var size: CGFloat = 120
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                // Linear (not angular) gradient: no colour seam on the round start cap.
                .stroke(LinearGradient(colors: [tint, .haloAccent], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .haloAnimation(.easeOut(duration: 0.8), value: progress)
            VStack(spacing: 1) {
                Text(value)
                    .font(HaloFont.number(.title2))
                    .foregroundColor(tint)
                    .minimumScaleFactor(0.5).lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(HaloFont.caption).foregroundColor(.haloText2)
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
            }
            .padding(lineWidth + 6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([value, caption].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - HaloSparkline

/// Mini bar chart (desktop `HaloSparkline`). Latest bar is full-strength. With no data it draws
/// flat stubs rather than a blank hole, so cards don't jump when the first sample arrives.
struct HaloSparkline: View {
    var values: [Double]
    var color: Color = .haloAccent
    var height: CGFloat = 36
    var placeholderBars = 12

    var body: some View {
        let data = values.isEmpty ? Array(repeating: 0.0, count: placeholderBars) : values
        let maxVal = max(data.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(data.indices, id: \.self) { i in
                let n = data[i] / maxVal
                RoundedRectangle(cornerRadius: 2)
                    .fill(values.isEmpty ? Color.white.opacity(0.08)
                          : (i == data.count - 1 ? color : color.opacity(0.3 + 0.2 * n)))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(n) * height))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)      // decorative: the number next to it carries the meaning
    }
}

// MARK: - HaloMetricTile

/// One glanceable number: icon, big value (+unit), label, optional sparkline / meter. Used 2-up on Home.
/// Pass `action` to make the whole tile tappable (≥44pt by construction).
struct HaloMetricTile: View {
    var title: String
    var value: String
    var unit: String?
    var subtitle: String?
    var icon: String
    var tint: Color = .haloAccent
    var spark: [Double]?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button { HaloHaptics.tap(); action() } label: { tile }
                .buttonStyle(HaloPressStyle())
        } else {
            tile
        }
    }

    private var tile: some View {
        HaloCard(accentTop: tint, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(.footnote).weight(.semibold)).foregroundColor(tint)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(HaloFont.number(.title)).foregroundColor(tint)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    if let unit {
                        Text(unit).font(HaloFont.caption).foregroundColor(.haloText2).lineLimit(1)
                    }
                }
                Text(subtitle ?? title)
                    .font(HaloFont.caption).foregroundColor(.haloText2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let spark { HaloSparkline(values: spark, color: tint, height: 22) }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)\(unit.map { " \($0)" } ?? "")\(subtitle.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

/// Subtle press feedback for card-sized buttons.
struct HaloPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Ring + tiles") {
    ScrollView {
        VStack(spacing: 14) {
            HaloCard { HStack { HaloRing(progress: 0.92, tint: .haloGreen, value: "OK", caption: "Ready"); Spacer() } }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                HaloMetricTile(title: "Messages today", value: "24", icon: "message.fill", tint: .haloAccent,
                               spark: [2, 4, 3, 8, 6, 9, 12])
                HaloMetricTile(title: "Clipboard items", value: "7", icon: "doc.on.clipboard", tint: .haloPurple)
                HaloMetricTile(title: "Nearby devices", value: "3", icon: "dot.radiowaves.left.and.right", tint: .haloGreen)
                HaloMetricTile(title: "Last sync", value: "2", unit: "min ago", icon: "arrow.triangle.2.circlepath", tint: .haloCyan)
            }
        }.padding()
    }.haloScreen()
}
