import SwiftUI

// MARK: - CelebrationType

enum CelebrationType: Equatable {
    case healthySystem      // Green sparkle burst — health score >= 90 after scan
    case spaceRecovered     // Blue particles floating up — cleanup freed > 1 GB
    case scanComplete       // Subtle expanding ring pulse — any scan completes
    case actionSuccess      // Brief green checkmark flash — action completes
}

// MARK: - CelebrationManager

/// Global celebration trigger. Post from anywhere; the overlay observes.
@MainActor
final class CelebrationManager: ObservableObject {
    static let shared = CelebrationManager()

    @Published var isActive = false
    @Published var currentType: CelebrationType = .actionSuccess

    @AppStorage("enableCelebrations") var celebrationsEnabled = true

    private init() {}

    func trigger(_ type: CelebrationType) {
        guard celebrationsEnabled else { return }
        currentType = type
        withAnimation(.easeIn(duration: 0.15)) { isActive = true }

        let duration: Double = type == .actionSuccess ? 1.2 : 2.0
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
