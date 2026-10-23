import Foundation

// MARK: - SpinPlan

/// Everything the animation needs, computed once at the moment Spin is pressed.
///
/// All angles are degrees, clockwise, with the pointer at 12 o'clock and segment 0
/// starting there. `fromAngle` is the wheel's *current* angle, so the animation never
/// snaps backwards on the first frame.
struct SpinPlan: Equatable {
    let winnerID: UUID
    let winnerIndex: Int
    let fromAngle: Double
    let targetAngle: Double
    /// Degrees past `targetAngle` the wheel reaches before the settle spring pulls it
    /// back into the detent. A wheel that arrives exactly on its mark and stops dead
    /// reads as a bug even when it is correct.
    let overshoot: Double
    let duration: Double

    static let windupDuration = 0.28
    static let settleDuration = 0.45

    var totalDuration: Double { Self.windupDuration + duration + Self.settleDuration }
}

// MARK: - DrawEngine

/// The whole of the randomness, in one testable place.
///
/// **The winner is chosen before the wheel moves.** `SystemRandomNumberGenerator`
/// picks the index and the wheel is then animated to a pre-computed angle. The
/// alternative — simulating friction and reading off whatever lands under the
/// pointer — makes the distribution a property of the physics code, which is far
/// harder to prove uniform and trivially skewed by a single rounding bug. The
/// animation presents the result; it never produces it.
enum DrawEngine {

    /// Fraction of the half-arc the landing point may stray from segment centre, so
    /// two wins for the same name never stop at a visibly identical angle. Strictly
    /// below 0.5, or the landing would cross into a neighbouring segment — which is
    /// the one way jitter could turn a correct draw into a wrong-looking one.
    static let jitterFraction = 0.38

    static let minFullSpins = 5
    static let maxFullSpins = 8

    /// Plans a spin over `eligibleCount` segments. This is the only place a winner is
    /// ever drawn; both public entry points funnel through it so there can never be
    /// two random draws with the animation honouring one and the card naming the other.
    ///
    /// - Parameter currentAngle: the wheel's present rotation, so the plan starts
    ///   where the wheel actually is.
    static func plan(eligibleCount: Int,
                     currentAngle: Double,
                     duration: Double,
                     idForIndex: (Int) -> UUID,
                     using generator: inout some RandomNumberGenerator) -> SpinPlan? {
        guard eligibleCount > 0 else { return nil }

        let winner = Int.random(in: 0..<eligibleCount, using: &generator)
        let segment = 360.0 / Double(eligibleCount)
        let jitter = Double.random(in: -jitterFraction...jitterFraction,
                                   using: &generator) * (segment / 2)

        // Bring the winner's arc centre back under the 12 o'clock pointer.
        let landing = normalised(360.0 - (Double(winner) * segment + segment / 2) + jitter)
        let spins = Double(Int.random(in: minFullSpins...maxFullSpins, using: &generator)) * 360

        // Advance from where the wheel is, never from a normalised 0 — the latter
        // snaps the wheel backwards by up to a full turn on frame one.
        let delta = normalised(landing - normalised(currentAngle))

        return SpinPlan(winnerID: idForIndex(winner),
                        winnerIndex: winner,
                        fromAngle: currentAngle,
                        targetAngle: currentAngle + spins + delta,
                        overshoot: Double.random(in: 1.5...3.0, using: &generator),
                        duration: duration)
    }

    /// Production entry point.
    static func plan(for entries: [DrawEntry],
                     currentAngle: Double,
                     duration: Double) -> SpinPlan? {
        var rng = SystemRandomNumberGenerator()
        return plan(eligibleCount: entries.count,
                    currentAngle: currentAngle,
                    duration: duration,
                    idForIndex: { entries[$0].id },
                    using: &rng)
    }

    /// Which segment index sits under the pointer at a given wheel angle.
    ///
    /// The 0°/360° seam bug hides in this arithmetic, so it exists once and is used by
    /// both the renderer and the tests rather than being written twice.
    static func segmentIndex(atAngle angle: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let segment = 360.0 / Double(count)
        // The pointer is fixed; rotating the wheel by +angle moves whatever sits under
        // it to -angle in the wheel's own coordinates.
        let local = normalised(-angle)
        return min(Int(local / segment), count - 1)
    }

    static func normalised(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
