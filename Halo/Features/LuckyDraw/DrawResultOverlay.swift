import SwiftUI

// MARK: - DrawResultOverlay

/// The reveal. Card spring-in, per-character name rise, and a radial shockwave —
/// all suppressed to a plain fade when Reduced Motion is on.
struct DrawResultOverlay: View {
    let label: String
    /// F-053: the winner's avatar, shown large above the name. `showAvatar` is decided by the caller
    /// from the roster's display mode, so a name-only roster's popup is exactly what it was.
    var avatar: EntryAvatar? = nil
    var rosterID: UUID? = nil
    var showAvatar = false
    /// v2.6 C-1: when true the avatar is drawn by `WinnerHeroAvatar` (a separate layer that flies in
    /// from the wheel); this card then only keeps an empty slot of the same size and reports its frame.
    var heroManaged = false
    /// False holds the name's per-character reveal back until the hero avatar reports it has landed.
    var nameGate = true
    let reducedMotion: Bool
    let canPutBack: Bool
    var onSpinAgain: () -> Void
    var onPutBack: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void

    @State private var appeared = false
    @State private var shockwave = false

    static let avatarDiameter: CGFloat = 132

    private var revealed: Bool { appeared && nameGate }

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
                if showAvatar && heroManaged {
                    Color.clear
                        .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: HeroSlotKey.self,
                                                   value: g.frame(in: .named("luckyStage")))
                        })
                        .padding(.bottom, 2)
                } else if showAvatar {
                    AvatarView(avatar: avatar, label: label, rosterID: rosterID, diameter: Self.avatarDiameter,
                               ringColor: .haloAmber, ringStyle: AvatarView.winnerRing, ringFraction: 0.07)
                        .shadow(color: Color(hex: "#ffd36b").opacity(0.35), radius: 22)
                        // Reduced Motion: it simply fades in with the card; otherwise it springs up a
                        // beat after the card lands.
                        .scaleEffect(reducedMotion ? 1 : (appeared ? 1 : 0.4))
                        .animation(reducedMotion ? nil : .spring(response: 0.55, dampingFraction: 0.6).delay(0.12),
                                   value: appeared)
                        .padding(.bottom, 2)
                }
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
                    // FR-17: Esc dismisses the result.
                    Button("Close", action: onClose)
                        .buttonStyle(ResultButtonStyle())
                        .keyboardShortcut(.cancelAction)
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
                        .offset(y: revealed ? 0 : 10)
                        .opacity(revealed ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7)
                            .delay((heroManaged ? 0 : 0.3) + Double(index) * 0.012), value: revealed)
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

// MARK: - Hero avatar (v2.6 C-1)

/// The popup card's avatar slot, in the lucky-draw stage's coordinate space.
struct HeroSlotKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// The winner's avatar, flying from its wheel segment to the popup's avatar slot while it grows to
/// full size (450 ms ease-out). Reduced Motion — or a winner the wheel drew no avatar for — gets a
/// plain cross-fade at the slot, no movement. The geometry is `HeroTravel` (unit-tested); this view
/// only plays it. Must sit in the stage's own ZStack so `.position` is in stage coordinates.
struct WinnerHeroAvatar: View {
    let avatar: EntryAvatar?
    let label: String
    let rosterID: UUID?
    let target: CGRect
    let origin: (centre: CGPoint, diameter: CGFloat)?
    let reducedMotion: Bool
    /// Called once the flight (or fade) has finished.
    var onLanded: () -> Void = {}

    @State private var landed = false

    var body: some View {
        let style = HeroTravel.style(reducedMotion: reducedMotion, hasOrigin: origin != nil)
        let start = origin.map {
            HeroTravel.start(origin: $0.centre, originDiameter: $0.diameter,
                             target: CGPoint(x: target.midX, y: target.midY), targetDiameter: target.width)
        }
        let flying = style == .travel && !landed
        AvatarView(avatar: avatar, label: label, rosterID: rosterID, diameter: target.width,
                   ringColor: .haloAmber, ringStyle: AvatarView.winnerRing, ringFraction: 0.07)
            .shadow(color: Color(hex: "#ffd36b").opacity(0.35), radius: 22)
            .scaleEffect(flying ? (start?.scale ?? 1) : 1)
            .offset(flying ? (start?.offset ?? .zero) : .zero)
            .opacity(style == .crossfade && !landed ? 0 : 1)
            .position(x: target.midX, y: target.midY)
            .onAppear {
                let duration = style == .travel ? HeroTravel.duration : HeroTravel.crossfadeDuration
                if #available(macOS 14.0, *) {
                    // Completion of the animation itself, not a parallel timer.
                    withAnimation(.easeOut(duration: duration), completionCriteria: .logicallyComplete) {
                        landed = true
                    } completion: { onLanded() }
                } else {
                    // macOS 13 has no animation-completion callback; fall back to the animation's duration.
                    withAnimation(.easeOut(duration: duration)) { landed = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onLanded() }
                }
            }
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

struct ResultButtonStyle: ButtonStyle {
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
