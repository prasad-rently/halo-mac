import CoreGraphics
import Foundation

// MARK: - WheelGeometry (F-053 / v2.6 C-1, C-2)
//
// The wheel's avatar layout as pure functions. `SpinnerWheelView` draws with these, and the hero
// travel into the winner popup is computed from the same numbers — so "where the avatar was on the
// wheel" and "where the popup flies it from" cannot drift apart, and both are unit-testable without
// a window.
//
// DISPLAY ONLY. Nothing here is an input to `DrawEngine`: the winner is chosen before any of this
// is consulted, and none of it reads an entry's avatar. (`LuckyDrawCompletionTests` pins that.)

enum WheelGeometry {

    /// Wheel radius for a square of `side`. `windup` (0…1) is the pre-spin recoil that shrinks the
    /// wheel by 3 %; at rest it is 0.
    static func radius(side: CGFloat, windup: Double = 0) -> CGFloat {
        (side / 2 - side * 0.045) * CGFloat(1 - 0.03 * windup)
    }

    /// Avatars sit at this fraction of the radius, on the segment's mid-line.
    static let avatarRadiusFraction: CGFloat = 0.80
    /// The winning segment is "lifted": its avatar is drawn 15 % larger.
    static let liftedScale: CGFloat = 1.15
    /// Smallest avatar worth drawing; below this a face is a smudge.
    static let minAvatarDiameter: CGFloat = 20
    /// The hub (centre disc) is this fraction of the radius.
    static let hubRadiusFraction: CGFloat = 0.17

    /// Diameter that fits the arc where the avatar sits, capped so it never swallows the wedge.
    static func fittedAvatarDiameter(count: Int, radius: CGFloat, side: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let arc = (360.0 / Double(count)) * .pi / 180 * Double(radius) * 0.80
        return min(CGFloat(arc) * 0.82, radius * 0.34, side * 0.14)
    }

    /// The diameter the wheel actually draws avatars at, or 0 when it draws none (name-only mode,
    /// too many entries — `limit`, the roster is too small on screen, or the fitted size is below
    /// `minAvatarDiameter`).
    static func wheelAvatarDiameter(mode: AvatarDisplayMode, count: Int, side: CGFloat,
                                    radius: CGFloat, limit: Int) -> CGFloat {
        guard mode != .nameOnly, count > 0, count <= limit, side > 260 else { return 0 }
        let d = fittedAvatarDiameter(count: count, radius: radius, side: side)
        return d >= minAvatarDiameter ? d : 0
    }

    /// Angle, in degrees, of segment `index`'s mid-line for a wheel rotated by `angle`. 0° is
    /// 3 o'clock, as in the Canvas; the pointer is at -90°.
    static func midAngle(index: Int, count: Int, angle: Double) -> Double {
        let sweep = 360.0 / Double(count)
        return angle + Double(index) * sweep - 90 + sweep / 2
    }

    /// Centre of segment `index`'s avatar, in the wheel's own coordinate space.
    static func avatarCentre(index: Int, count: Int, angle: Double,
                             wheelCentre: CGPoint, radius: CGFloat) -> CGPoint {
        let rad = midAngle(index: index, count: count, angle: angle) * .pi / 180
        let place = radius * avatarRadiusFraction
        return CGPoint(x: wheelCentre.x + CGFloat(cos(rad)) * place,
                       y: wheelCentre.y + CGFloat(sin(rad)) * place)
    }

    /// Diameter of the hub disc.
    static func hubDiameter(radius: CGFloat) -> CGFloat { radius * hubRadiusFraction * 2 }
}

// MARK: - Hero travel (C-1)

/// Where the winner's avatar was on the wheel when the spin stopped. Captured at the moment of
/// the win, because with auto-retire the winner leaves the wheel a frame later and the segment
/// count changes — the popup must fly from where the avatar *was*.
struct WheelHeroOrigin: Equatable {
    let index: Int
    let count: Int
    /// The wheel's rest angle at the win.
    let angle: Double
}

enum HeroTravel {

    /// FR-P2: 450 ms ease-out.
    static let duration: TimeInterval = 0.45
    /// Reduced Motion: a plain fade, no movement.
    static let crossfadeDuration: TimeInterval = 0.32

    enum Style: Equatable {
        /// Fly from the wheel segment to the popup, scaling up.
        case travel
        /// Reduced Motion, or the wheel drew no avatar for this winner: fade in where it lands.
        case crossfade
    }

    /// What the wheel should draw. `recordWin` retires the winner the instant the spin ends, so the
    /// live pool has one segment fewer — and every segment after the winner has moved — before the
    /// hero starts. While the result popup is up the wheel keeps drawing the pool as it was at the
    /// win (`snapshot`), so the winner's segment is still there for the hero to leave from and
    /// `WheelHeroOrigin.index` still means what it meant. Display only: the draw already happened,
    /// and retirement itself is untouched.
    static func displayedEntries(live: [DrawEntry], snapshot: [DrawEntry]?, popupShowing: Bool) -> [DrawEntry] {
        popupShowing ? (snapshot ?? live) : live
    }

    static func style(reducedMotion: Bool, hasOrigin: Bool) -> Style {
        reducedMotion || !hasOrigin ? .crossfade : .travel
    }

    /// What to apply to a view that RESTS at `target` (diameter `targetDiameter`) so that it
    /// starts out looking like the avatar at `origin` (diameter `originDiameter`).
    /// Offset first, scale about the view's own centre — the composition SwiftUI applies for
    /// `.scaleEffect(scale).offset(offset)`.
    struct Start: Equatable {
        let offset: CGSize
        let scale: CGFloat
    }

    static func start(origin: CGPoint, originDiameter: CGFloat,
                      target: CGPoint, targetDiameter: CGFloat) -> Start {
        Start(offset: CGSize(width: origin.x - target.x, height: origin.y - target.y),
              scale: targetDiameter > 0 ? originDiameter / targetDiameter : 1)
    }

    /// The avatar's on-screen centre and diameter on the wheel at the win, in the space of the
    /// wheel's own `wheelCentre`/`side`. Nil when the wheel was not drawing avatars for this roster
    /// (so there is nothing to fly from).
    static func wheelOrigin(_ o: WheelHeroOrigin, mode: AvatarDisplayMode, side: CGFloat,
                            wheelCentre: CGPoint, avatarLimit: Int) -> (centre: CGPoint, diameter: CGFloat)? {
        let radius = WheelGeometry.radius(side: side)
        let d = WheelGeometry.wheelAvatarDiameter(mode: mode, count: o.count, side: side,
                                                  radius: radius, limit: avatarLimit)
        guard d > 0, o.index >= 0, o.index < o.count else { return nil }
        // The winner is the spotlit ("lifted") segment: drawn at the larger size, on the lifted rim.
        let lifted = radius * 1.035
        let c = WheelGeometry.avatarCentre(index: o.index, count: o.count, angle: o.angle,
                                           wheelCentre: wheelCentre, radius: lifted)
        return (c, d * WheelGeometry.liftedScale)
    }
}

// MARK: - Hub (C-2)

extension DrawRoster {
    /// The entry to show in the wheel's hub between spins: the most recent winner, if that entry
    /// still exists (it may have been deleted since). Display only — never an input to the draw.
    var lastWinnerEntry: DrawEntry? {
        guard let r = history.first else { return nil }
        return entries.first { $0.id == r.entryID }
    }
}
