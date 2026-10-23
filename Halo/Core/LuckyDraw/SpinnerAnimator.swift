import Foundation

// MARK: - SpinPhase

enum SpinPhase: String {
    case idle, windup, launch, cruise, decay, nearMiss, settle, done

    var title: String {
        switch self {
        case .idle:     return "Idle"
        case .windup:   return "Wind-up"
        case .launch:   return "Launch"
        case .cruise:   return "Cruise"
        case .decay:    return "Slowing"
        case .nearMiss: return "Near miss"
        case .settle:   return "Settling"
        case .done:     return "Done"
        }
    }
}

// MARK: - SpinnerAnimator

/// Pure functions of elapsed time. No UI, no state — which is what makes the spin
/// unit-testable and keeps the renderer a thin reader of one source of truth, so the
/// ratchet pointer, the motion smear and the near-miss spotlight cannot disagree
/// about where the wheel is.
enum SpinnerAnimator {

    /// Phase boundaries as fractions of the spin proper (excluding wind-up and settle).
    static let launchEnd = 0.12
    static let cruiseEnd = 0.45

    /// Exponent of the deceleration ease-out.
    ///
    /// **3.4, not the 4.2 this started at.** At 4.2 the wheel's velocity over the final
    /// 0.8 s falls to roughly 2 °/s, which does not read as suspense — it reads as the
    /// app having frozen. 3.4 lands the last second in the 20–60 °/s band: slow enough
    /// to count the remaining names, fast enough to still be motion.
    static let decayExponent = 3.4

    /// Angular velocity below which the near-miss spotlight takes over, °/s.
    static let nearMissVelocity = 45.0

    /// Normalising constant: the integral of `velocityShape` over 0…1. Rotation is
    /// distributed in proportion to it, so `progress(1) == 1` exactly.
    static let shapeArea: Double = {
        let launch = launchEnd / 3
        let cruise = cruiseEnd - launchEnd
        let decay = (1 - cruiseEnd) / decayExponent
        return launch + cruise + decay
    }()

    /// Fraction of total rotation completed at normalised time `u` (0…1).
    static func progress(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        let cumulative: Double
        if u <= launchEnd {
            cumulative = (u * u * u) / (3 * launchEnd * launchEnd)
        } else if u <= cruiseEnd {
            cumulative = launchEnd / 3 + (u - launchEnd)
        } else {
            let w = (u - cruiseEnd) / (1 - cruiseEnd)
            cumulative = launchEnd / 3 + (cruiseEnd - launchEnd)
                + ((1 - cruiseEnd) / decayExponent) * (1 - pow(1 - w, decayExponent))
        }
        return cumulative / shapeArea
    }

    /// Velocity profile, 0…1. Ease-in to peak, hold, then decay to rest.
    static func velocityShape(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        if u <= launchEnd { return pow(u / launchEnd, 2) }
        if u <= cruiseEnd { return 1 }
        return pow(1 - (u - cruiseEnd) / (1 - cruiseEnd), decayExponent - 1)
    }

    // MARK: - Frame state

    struct Frame {
        var angle: Double
        /// Degrees per second — a real figure, not a normalised one, so the
        /// near-miss threshold is a real threshold.
        var velocity: Double
        /// 0…1 wind-up recoil, driving an 8° counter-rotation and a 0.97 scale.
        var windup: Double
        var phase: SpinPhase
        var isFinished: Bool
    }

    /// Peak angular velocity this plan reaches, °/s.
    static func peakVelocity(for plan: SpinPlan) -> Double {
        (plan.targetAngle + plan.overshoot - plan.fromAngle) / (shapeArea * plan.duration)
    }

    static func frame(for plan: SpinPlan, elapsed: Double) -> Frame {
        let peak = peakVelocity(for: plan)

        // 1. Wind-up — the wheel loads backwards before it launches.
        if elapsed < SpinPlan.windupDuration {
            let u = elapsed / SpinPlan.windupDuration
            return Frame(angle: plan.fromAngle,
                         velocity: 0,
                         windup: sin(u * .pi / 2),
                         phase: .windup,
                         isFinished: false)
        }

        let spinElapsed = elapsed - SpinPlan.windupDuration
        let u = spinElapsed / plan.duration

        // 2. Launch → cruise → decay, one continuous rotation.
        if u < 1 {
            let span = plan.targetAngle + plan.overshoot - plan.fromAngle
            let velocity = velocityShape(u) * peak
            let phase: SpinPhase
            if u <= launchEnd { phase = .launch }
            else if u <= cruiseEnd { phase = .cruise }
            else { phase = velocity < nearMissVelocity ? .nearMiss : .decay }
            // The recoil unwinds through zero into the launch rather than stopping
            // and restarting — two animations meeting at a standstill is visible.
            let windupTail = max(0, 1 - spinElapsed / 0.16)
            return Frame(angle: plan.fromAngle + span * progress(u),
                         velocity: velocity,
                         windup: windupTail,
                         phase: phase,
                         isFinished: false)
        }

        // 3. Settle — overshoot springs back into the detent.
        let settleElapsed = spinElapsed - plan.duration
        if settleElapsed < SpinPlan.settleDuration {
            let s = settleElapsed / SpinPlan.settleDuration
            let damping = exp(-6.2 * s) * cos(10.5 * s)
            return Frame(angle: plan.targetAngle + plan.overshoot * damping,
                         velocity: abs(damping) * 40,
                         windup: 0,
                         phase: .settle,
                         isFinished: false)
        }

        return Frame(angle: plan.targetAngle, velocity: 0, windup: 0,
                     phase: .done, isFinished: true)
    }
}
