import SwiftUI

// MARK: - DrawResultOverlay

/// The reveal. Card spring-in, per-character name rise, and a radial shockwave —
/// all suppressed to a plain fade when Reduced Motion is on.
struct DrawResultOverlay: View {
    let label: String
    let reducedMotion: Bool
    let canPutBack: Bool
    var onSpinAgain: () -> Void
    var onPutBack: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void

    @State private var appeared = false
    @State private var shockwave = false

    /// Past this length a 12 ms per-character stagger reads as a stutter rather than
    /// a flourish, so long names fade in whole.
    private let staggerLimit = 24

    var body: some View {
        ZStack {
            if !reducedMotion {
                Circle()
                    .stroke(Color.haloAccent, lineWidth: 3)
                    .scaleEffect(shockwave ? 2.6 : 0.25)
                    .opacity(shockwave ? 0 : 0.5)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                Text("WINNER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2.6)
                    .foregroundColor(.haloGreen)

                nameView

                HStack(spacing: 7) {
                    Button("Spin again", action: onSpinAgain)
                        .buttonStyle(ResultButtonStyle(prominent: true))
                    if canPutBack {
                        Button("Put back", action: onPutBack)
                            .buttonStyle(ResultButtonStyle())
                            .help("Return to the wheel for the next draw — the log keeps the row")
                    }
                    Button("Copy", action: onCopy)
                        .buttonStyle(ResultButtonStyle())
                    Button("Close", action: onClose)
                        .buttonStyle(ResultButtonStyle())
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.haloBackground.opacity(0.95))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.haloBorder2, lineWidth: 1))
            )
            .background(haloGlow)
            .scaleEffect(reducedMotion ? 1 : (appeared ? 1 : 0.8))
            .blur(radius: reducedMotion ? 0 : (appeared ? 0 : 8))
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(reducedMotion ? .easeOut(duration: 0.32)
                                        : .spring(response: 0.42, dampingFraction: 0.68)) {
                appeared = true
            }
            guard !reducedMotion else { return }
            withAnimation(.easeOut(duration: 0.7).delay(0.45)) { shockwave = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Winner: \(label)")
    }

    @ViewBuilder
    private var nameView: some View {
        if reducedMotion || label.count > staggerLimit {
            Text(label)
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .foregroundColor(.haloText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(label.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundColor(.haloText)
                        .offset(y: appeared ? 0 : 10)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7)
                            .delay(0.3 + Double(index) * 0.012), value: appeared)
                }
            }
        }
    }

    /// A slow conic sweep behind the card while the result is up. Reduced Motion gets
    /// the same colour as a static wash rather than a rotating one.
    private var haloGlow: some View {
        Group {
            if reducedMotion {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.haloAccent.opacity(0.22))
                    .blur(radius: 10)
            } else {
                ConicHalo()
            }
        }
        .padding(-2)
    }
}

// MARK: - ConicHalo

private struct ConicHalo: View {
    @State private var angle: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            // Accent → violet only. Running the full palette through here put a green
            // wash across the wheel behind the card, which read as a rendering fault.
            .fill(AngularGradient(colors: [.haloAccent, .haloPurple, .haloAccent2,
                                           .haloAccent],
                                  center: .center, angle: .degrees(angle)))
            .opacity(0.45)
            .blur(radius: 7)
            .onAppear {
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

// MARK: - ResultButtonStyle

private struct ResultButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.haloText)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent
                          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#5b86ff"), Color(hex: "#3a63e6")],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.haloSurface2))
            )
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(prominent ? Color.clear : Color.haloBorder2, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
