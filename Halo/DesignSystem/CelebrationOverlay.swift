import SwiftUI

// MARK: - CelebrationType

enum CelebrationType: Equatable {
    case healthySystem      // Green sparkle burst — health score >= 90 after scan
    case spaceRecovered     // Blue particles floating up — cleanup freed > 1 GB
    case scanComplete       // Subtle expanding ring pulse — any scan completes
    case actionSuccess      // Brief green checkmark flash — action completes
    case luckyDrawWinner    // Two confetti cannons — F-051 draw reveals a winner
}

// MARK: - CelebrationManager

/// Global celebration trigger. Post from anywhere; the overlay observes.
@MainActor
final class CelebrationManager: ObservableObject {
    static let shared = CelebrationManager()

    @Published var isActive = false
    @Published var currentType: CelebrationType = .actionSuccess
    /// Where the celebration is aimed, in the window's global coordinate space.
    /// `nil` centres it. Set by callers whose celebration belongs to a particular
    /// piece of the UI — the Lucky Draw poppers fired from the window corners until
    /// this existed, which put half the confetti behind the sidebar.
    @Published var focusPoint: CGPoint?

    @AppStorage("enableCelebrations") var celebrationsEnabled = true

    private init() {}

    func trigger(_ type: CelebrationType, focus: CGPoint? = nil) {
        guard celebrationsEnabled else { return }
        currentType = type
        focusPoint = focus
        withAnimation(.easeIn(duration: 0.15)) { isActive = true }

        let duration: Double
        switch type {
        case .actionSuccess:   duration = 1.2
        // The poppers need their arcs to land, not be cut off mid-air.
        case .luckyDrawWinner: duration = 2.9
        default:               duration = 2.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.isActive = false }
        }
    }
}

// MARK: - Particle

private struct Particle: Identifiable {
    let id: Int
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var size: Double
    var opacity: Double
    var color: Color
    var rotation: Double
}

// MARK: - CelebrationOverlay

struct CelebrationOverlay: View {
    @ObservedObject var manager: CelebrationManager

    var body: some View {
        if manager.isActive {
            switch manager.currentType {
            case .healthySystem:  SparkleburstView()
            case .spaceRecovered: FloatingParticlesView()
            case .scanComplete:   PulseRingView()
            case .actionSuccess:  CheckmarkFlashView()
            case .luckyDrawWinner: ConfettiPopperView(focus: manager.focusPoint)
            }
        }
    }
}

// MARK: - Healthy System — Green sparkle burst

private struct SparkleburstView: View {
    @State private var particles: [Particle] = []
    @State private var elapsed: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                for p in particles {
                    let age = min(elapsed / 2.0, 1.0)
                    let alpha = p.opacity * (1.0 - age)
                    guard alpha > 0.01 else { continue }

                    let cx = size.width / 2 + p.x * elapsed * 120
                    let cy = size.height / 2 + p.y * elapsed * 120

                    context.opacity = alpha
                    let rect = CGRect(x: cx - p.size / 2, y: cy - p.size / 2,
                                      width: p.size, height: p.size)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(p.color)
                    )
                }
            }
            .onChange(of: timeline.date) { _ in
                elapsed += 0.016
            }
        }
        .allowsHitTesting(false)
        .onAppear { spawnParticles() }
    }

    private func spawnParticles() {
        elapsed = 0
        particles = (0..<35).map { i in
            let angle = Double.random(in: 0...(2 * .pi))
            let speed = Double.random(in: 0.5...1.5)
            return Particle(
                id: i,
                x: cos(angle) * speed,
                y: sin(angle) * speed,
                vx: 0, vy: 0,
                size: Double.random(in: 3...8),
                opacity: Double.random(in: 0.6...1.0),
                color: [Color.haloGreen, Color(hex: "#00d4e8"), Color(hex: "#22d97a"),
                        Color.white.opacity(0.8)].randomElement()!,
                rotation: 0
            )
        }
    }
}

// MARK: - Space Recovered — Blue particles floating up

private struct FloatingParticlesView: View {
    @State private var particles: [Particle] = []
    @State private var elapsed: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                for p in particles {
                    let age = min(elapsed / 2.0, 1.0)
                    let alpha = p.opacity * (1.0 - age * age)
                    guard alpha > 0.01 else { continue }

                    let cx = size.width * p.x + sin(elapsed * 2 + p.rotation) * 15
                    let cy = size.height * (1.0 - elapsed * 0.4) * p.y

                    context.opacity = alpha
                    let rect = CGRect(x: cx - p.size / 2, y: cy - p.size / 2,
                                      width: p.size, height: p.size)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(p.color)
                    )
                }
            }
            .onChange(of: timeline.date) { _ in
                elapsed += 0.016
            }
        }
        .allowsHitTesting(false)
        .onAppear { spawnParticles() }
    }

    private func spawnParticles() {
        elapsed = 0
        particles = (0..<25).map { i in
            Particle(
                id: i,
                x: Double.random(in: 0.1...0.9),
                y: Double.random(in: 0.3...0.9),
                vx: 0, vy: Double.random(in: -0.3 ... -0.1),
                size: Double.random(in: 4...10),
                opacity: Double.random(in: 0.4...0.9),
                color: [Color.haloAccent, Color(hex: "#8b5cf6"), Color(hex: "#4f7cff"),
                        Color(hex: "#00d4e8")].randomElement()!,
                rotation: Double.random(in: 0...(2 * .pi))
            )
        }
    }
}

// MARK: - Scan Complete — Expanding ring pulse

private struct PulseRingView: View {
    @State private var scale: Double = 0.3
    @State private var opacity: Double = 0.6

    var body: some View {
        GeometryReader { geo in
            Circle()
                .stroke(
                    LinearGradient(colors: [.haloAccent, .haloAccent2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2
                )
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
                .opacity(opacity)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.5)) {
                scale = 3.0
                opacity = 0
            }
        }
    }
}

// MARK: - Action Success — Green checkmark flash

private struct CheckmarkFlashView: View {
    @State private var checkScale: Double = 0.5
    @State private var checkOpacity: Double = 0
    @State private var glowRadius: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Glow
                Circle()
                    .fill(Color.haloGreen.opacity(0.15))
                    .frame(width: 60 + glowRadius, height: 60 + glowRadius)

                // Checkmark circle
                ZStack {
                    Circle()
                        .fill(Color.haloGreen)
                        .frame(width: 36, height: 36)
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                .scaleEffect(checkScale)
                .opacity(checkOpacity)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                checkScale = 1.0
                checkOpacity = 1.0
                glowRadius = 40
            }
            // Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 0.4)) {
                    checkOpacity = 0
                    glowRadius = 60
                }
            }
        }
    }
}

// MARK: - Lucky Draw Winner — Two confetti cannons

/// Real popper physics: launch speed, gravity, air drag, per-piece spin, and a
/// lateral wobble on the ribbons so they tumble instead of falling straight.
///
/// The other celebrations here drift particles along a fixed vector, which is right
/// for a sparkle burst and wrong for a popper — a confetti cannon is recognisable
/// precisely by the arc, so this one integrates rather than interpolates.
private struct ConfettiPopperView: View {
    /// Where the burst comes from, in the window's coordinate space. `nil` falls back
    /// to the lower corners of the window.
    var focus: CGPoint?

    private struct Piece: Identifiable {
        let id: Int
        var position: CGPoint
        var velocity: CGVector
        var size: Double
        var rotation: Double
        var spin: Double
        var wobble: Double
        var life: Double
        var color: Color
        var isRibbon: Bool
    }

    @State private var pieces: [Piece] = []
    @State private var lastTick: Date?

    /// Points per second squared. Everything here is in real points rather than unit
    /// space, so the numbers are the ones the spec states and a piece's arc doesn't
    /// change shape with the window.
    private let gravity: Double = 1600
    private let drag: Double = 0.985
    private let lifetime: Double = 2.6

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { context, _ in
                    for p in pieces {
                        let fade = p.life > lifetime - 0.8 ? max(0, (lifetime - p.life) / 0.8) : 1
                        guard fade > 0.01 else { continue }
                        var layer = context
                        layer.opacity = fade
                        let wobbleX = p.isRibbon ? sin(p.wobble) * 9 : 0
                        layer.translateBy(x: p.position.x + wobbleX, y: p.position.y)
                        layer.rotate(by: .degrees(p.rotation))
                        let rect = CGRect(x: -p.size * (p.isRibbon ? 0.28 : 0.5),
                                          y: -p.size * (p.isRibbon ? 0.9 : 0.5),
                                          width: p.size * (p.isRibbon ? 0.56 : 1),
                                          height: p.size * (p.isRibbon ? 1.8 : 1))
                        let path = p.isRibbon ? Path(rect) : Path(ellipseIn: rect)
                        layer.fill(path, with: .color(p.color))
                    }
                }
                .onChange(of: timeline.date) { date in
                    step(to: date)
                }
            }
            .onAppear { fire(in: geo.size) }
        }
        .allowsHitTesting(false)
    }

    private func step(to date: Date) {
        let dt = min(lastTick.map { date.timeIntervalSince($0) } ?? 0.016, 0.05)
        lastTick = date
        guard dt > 0 else { return }
        pieces = pieces.compactMap { piece in
            var p = piece
            p.life += dt
            guard p.life < lifetime else { return nil }
            p.velocity.dy += gravity * dt
            let decay = pow(drag, dt * 60)
            p.velocity.dx *= decay
            p.velocity.dy *= decay
            p.position.x += p.velocity.dx * dt
            p.position.y += p.velocity.dy * dt
            p.rotation += p.spin * dt
            p.wobble += dt * 7
            return p
        }
    }

    private func fire(in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let palette: [Color] = [.haloAccent, .haloAccent2, .haloGreen,
                                .haloAmber, .haloPurple, .haloCyan]
        // Two cannons flanking whatever is being celebrated, firing inward and up so
        // the arcs cross over it.
        let centre = focus ?? CGPoint(x: size.width / 2, y: size.height * 0.62)
        let dx = min(size.width * 0.18, 240)
        let dy = min(size.height * 0.2, 190)
        var next = 0

        func cannon(origin: CGPoint, direction: Double, count: Int) -> [Piece] {
            (0..<count).map { _ in
                let angle = (direction + Double.random(in: -22...22)) * .pi / 180
                let speed = Double.random(in: 900...1400)
                next += 1
                return Piece(id: next,
                             position: origin,
                             velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                             size: Double.random(in: 6...15),
                             rotation: Double.random(in: 0...360),
                             spin: Double.random(in: -720...720),
                             wobble: Double.random(in: 0...6.28),
                             life: 0,
                             color: palette.randomElement()!,
                             isRibbon: Bool.random())
            }
        }

        lastTick = nil
        pieces = cannon(origin: CGPoint(x: centre.x - dx, y: centre.y + dy),
                        direction: -56, count: 70)
               + cannon(origin: CGPoint(x: centre.x + dx, y: centre.y + dy),
                        direction: -124, count: 70)
    }
}
