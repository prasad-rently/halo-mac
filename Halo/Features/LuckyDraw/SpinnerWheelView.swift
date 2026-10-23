import SwiftUI

// MARK: - SpinnerWheelView

/// The wheel. One `Canvas` inside `TimelineView(.animation)` — the same engine
/// `CelebrationOverlay` uses.
///
/// Every per-frame value (angle, velocity, wind-up, the ratchet deflection, the
/// motion smear, the near-miss spotlight) is a *function* of elapsed time via
/// `SpinnerAnimator`. Nothing here holds frame-to-frame state, so the render pass
/// never writes to `@State` and the pointer can never disagree with the wheel about
/// where the wheel is.
struct SpinnerWheelView: View {
    let entries: [DrawEntry]
    let plan: SpinPlan?
    let spinStart: Date?
    let restAngle: Double
    let highlightID: UUID?
    let reducedMotion: Bool

    /// Labels stop being readable long before the segments do. Past this count the
    /// rim is still a legible ring of colour; the roster list is the label surface.
    private let labelLimit = 26

    var body: some View {
        TimelineView(.animation(paused: spinStart == nil)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        entries.isEmpty
            ? "Lucky draw wheel, empty"
            : "Lucky draw wheel with \(entries.count) entries"
    }

    // MARK: - Frame

    private func currentFrame(now: Date) -> SpinnerAnimator.Frame {
        guard let plan, let spinStart else {
            return .init(angle: restAngle, velocity: 0, windup: 0, phase: .idle, isFinished: true)
        }
        return SpinnerAnimator.frame(for: plan, elapsed: now.timeIntervalSince(spinStart))
    }

    // MARK: - Draw

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let frame = currentFrame(now: now)
        let side = min(size.width, size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = 1 - 0.03 * frame.windup
        let radius = (side / 2 - side * 0.045) * scale
        guard radius > 10 else { return }

        // The recoil: the wheel loads 8° backwards before it launches.
        let angle = frame.angle - 8 * frame.windup
        let peak = plan.map { SpinnerAnimator.peakVelocity(for: $0) } ?? 1
        let speed = min(frame.velocity / max(peak, 1), 1)

        drawBackplate(&context, centre: centre, radius: radius, speed: speed, side: side)

        if entries.isEmpty {
            drawEmptyState(&context, centre: centre, radius: radius, side: side)
            drawPointer(&context, centre: centre, radius: radius, side: side, frame: frame)
            return
        }

        let spotlit = spotlightID(frame: frame, angle: angle)
        drawSegments(&context, centre: centre, radius: radius, side: side,
                     angle: angle, speed: speed, spotlit: spotlit)

        if speed > 0.06 && !reducedMotion {
            drawSmear(&context, centre: centre, radius: radius, side: side, speed: speed)
        }

        drawHub(&context, centre: centre, radius: radius, side: side)
        drawPointer(&context, centre: centre, radius: radius, side: side, frame: frame)
    }

    /// Which segment gets lifted out of the dimmed wheel.
    ///
    /// During the last stretch of the spin this hands off from name to name as the
    /// wheel creeps — the beat that turns the final half-second from waiting into
    /// watching. Once the winner is known it stays on the winner.
    private func spotlightID(frame: SpinnerAnimator.Frame, angle: Double) -> UUID? {
        if let highlightID { return highlightID }
        guard frame.phase == .nearMiss || frame.phase == .settle else { return nil }
        let index = DrawEngine.segmentIndex(atAngle: angle, count: entries.count)
        return entries.indices.contains(index) ? entries[index].id : nil
    }

    private func drawBackplate(_ context: inout GraphicsContext, centre: CGPoint,
                               radius: CGFloat, speed: Double, side: CGFloat) {
        let disc = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
        var glow = context
        glow.addFilter(.shadow(color: Color.haloAccent.opacity(0.25 + 0.45 * speed),
                               radius: side * (0.03 + 0.07 * speed)))
        glow.fill(disc, with: .color(Color.haloBackground))
    }

    private func drawEmptyState(_ context: inout GraphicsContext, centre: CGPoint,
                                radius: CGFloat, side: CGFloat) {
        let text = context.resolve(
            Text("Nothing on the wheel")
                .font(.system(size: side * 0.042, weight: .semibold))
                .foregroundColor(.haloText3)
        )
        context.draw(text, at: centre, anchor: .center)
        context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(Color.haloBorder2), lineWidth: 1)
    }

    private func drawSegments(_ context: inout GraphicsContext, centre: CGPoint,
                              radius: CGFloat, side: CGFloat, angle: Double,
                              speed: Double, spotlit: UUID?) {
        let count = entries.count
        let sweep = 360.0 / Double(count)
        let showLabels = count <= labelLimit && side > 260
        let dim = spotlit == nil ? 1.0 : 0.5
        // Labels fade as the wheel picks up speed — at cruise they are a smear
        // anyway, and holding them at full opacity just muddies the ring.
        let labelAlpha = 1 - 0.75 * min(speed * 1.6, 1)

        for (index, entry) in entries.enumerated() {
            let start = angle + Double(index) * sweep - 90
            let end = start + sweep
            let lit = spotlit == entry.id
            let r = lit ? radius * 1.035 : radius

            var wedge = Path()
            wedge.move(to: centre)
            wedge.addArc(center: centre, radius: r,
                         startAngle: .degrees(start), endAngle: .degrees(end),
                         clockwise: false)
            wedge.closeSubpath()

            context.opacity = lit ? 1 : dim
            if lit {
                context.fill(wedge, with: .color(Color.haloAccent))
            } else {
                // Radial shading — darker at the hub, full colour at the rim. A flat
                // fill at this size reads as construction paper; the gradient is what
                // makes the ring look like one object rather than N coloured triangles.
                context.fill(wedge, with: .radialGradient(
                    Gradient(colors: [SegmentPalette.core(for: index, of: count),
                                      SegmentPalette.fill(for: index, of: count)]),
                    center: centre, startRadius: 0, endRadius: r))
            }

            // A lifted rim band gives the ring an edge without a per-segment stroke
            // colour, and reads as depth rather than as a second palette.
            var band = Path()
            band.addArc(center: centre, radius: r * 0.955,
                        startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            context.stroke(band,
                           with: .color(lit ? Color.haloCyan
                                            : SegmentPalette.rim(for: index, of: count).opacity(0.55)),
                           lineWidth: max(1, side * 0.011))

            if count <= 160 {
                var divider = Path()
                divider.move(to: centre)
                divider.addLine(to: CGPoint(x: centre.x + cos(start * .pi / 180) * r,
                                            y: centre.y + sin(start * .pi / 180) * r))
                context.stroke(divider, with: .color(Color.haloBackground.opacity(0.42)),
                               lineWidth: max(0.5, side * 0.0025))
            }
            context.opacity = 1

            guard showLabels else { continue }
            let alpha = lit ? 1 : labelAlpha
            guard alpha > 0.05 else { continue }
            drawLabel(&context, entry: entry, centre: centre, radius: r, side: side,
                      midAngle: start + sweep / 2, sweep: sweep, alpha: alpha, lit: lit)
        }
    }

    private func drawLabel(_ context: inout GraphicsContext, entry: DrawEntry,
                           centre: CGPoint, radius: CGFloat, side: CGFloat,
                           midAngle: Double, sweep: Double, alpha: Double, lit: Bool) {
        // Cap the size by the arc height as well as the wheel, so a 40-segment wheel
        // doesn't stack overlapping text around the rim.
        let arcHeight = (sweep * .pi / 180) * radius
        let fontSize = min(side * 0.042, arcHeight * 0.62)
        guard fontSize >= 7 else { return }

        let label = entry.label.count > 18 ? entry.label.prefix(17) + "…" : entry.label[...]
        let text = context.resolve(
            Text(String(label))
                .font(.system(size: fontSize, weight: lit ? .bold : .semibold, design: .rounded))
                .foregroundColor(SegmentPalette.label)
        )

        // Text runs along the radius, as it does on a real wheel. On the left half that
        // transform alone would render every name upside-down, so those are flipped
        // 180° and anchored from the other end — the name still reads outward, and no
        // name is ever inverted.
        let normalised = DrawEngine.normalised(midAngle)
        let flipped = normalised > 90 && normalised < 270
        let inset = side * 0.035

        var layer = context
        layer.opacity = alpha
        layer.translateBy(x: centre.x, y: centre.y)
        layer.rotate(by: .degrees(flipped ? midAngle + 180 : midAngle))
        // Every segment fill is built to carry one near-white label colour, so the
        // shadow is for separation from the rim band, not for contrast.
        layer.addFilter(.shadow(color: Color.black.opacity(0.6), radius: fontSize * 0.2,
                                x: 0, y: fontSize * 0.06))
        layer.draw(text,
                   at: CGPoint(x: flipped ? -(radius - inset) : radius - inset, y: 0),
                   anchor: flipped ? .leading : .trailing)
    }

    /// Angular motion smear — concentric arc strokes trailing the rim.
    ///
    /// A real Gaussian blur on a rotating canvas costs far more than the effect is
    /// worth; this reads the same at speed and holds 60 fps at 200 segments.
    private func drawSmear(_ context: inout GraphicsContext, centre: CGPoint,
                           radius: CGFloat, side: CGFloat, speed: Double) {
        var layer = context
        layer.blendMode = .plusLighter
        for ring in 1...5 {
            let r = radius * (1 - Double(ring) * 0.022)
            layer.opacity = 0.055 * speed * (1 - Double(ring) / 6)
            layer.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(Color(hex: "#8fb0ff")),
                         lineWidth: side * 0.02)
        }
    }

    private func drawHub(_ context: inout GraphicsContext, centre: CGPoint,
                         radius: CGFloat, side: CGFloat) {
        let r = radius * 0.17
        let rect = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect),
                     with: .linearGradient(Gradient(colors: [Color.haloSurface2, Color.haloBackground]),
                                           startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        context.stroke(Path(ellipseIn: rect), with: .color(Color.haloBorder2),
                       lineWidth: max(1, side * 0.004))
        let text = context.resolve(
            Text("\(entries.count)")
                .font(.system(size: side * 0.028, weight: .bold, design: .rounded))
                .foregroundColor(.haloText3)
        )
        context.draw(text, at: centre, anchor: .center)
    }

    /// The ratchet flipper at 12 o'clock.
    ///
    /// Its deflection is a closed form rather than an integrated spring: the time
    /// since the last segment boundary passed under it is derivable from the current
    /// angle and velocity, so a damped oscillation of that time gives the same wild
    /// flutter at speed and the same discrete, countable clicks at the end — with no
    /// state to keep and nothing to drift out of sync with the wheel.
    private func drawPointer(_ context: inout GraphicsContext, centre: CGPoint,
                             radius: CGFloat, side: CGFloat, frame: SpinnerAnimator.Frame) {
        var deflection = 0.0
        if !reducedMotion, !entries.isEmpty, frame.velocity > 1 {
            let sweep = 360.0 / Double(entries.count)
            let local = DrawEngine.normalised(-frame.angle)
            let intoSegment = local.truncatingRemainder(dividingBy: sweep)
            let sinceBoundary = (sweep - intoSegment) / frame.velocity   // seconds
            let kick = min(18.0, frame.velocity / 50)
            deflection = kick * exp(-7 * sinceBoundary) * cos(19.5 * sinceBoundary)
        }

        var layer = context
        layer.translateBy(x: centre.x, y: centre.y - radius - side * 0.008)
        layer.rotate(by: .degrees(deflection))
        var nib = Path()
        nib.move(to: CGPoint(x: 0, y: side * 0.055))
        nib.addLine(to: CGPoint(x: -side * 0.026, y: -side * 0.018))
        nib.addLine(to: CGPoint(x: side * 0.026, y: -side * 0.018))
        nib.closeSubpath()
        layer.addFilter(.shadow(color: Color.black.opacity(0.75), radius: side * 0.02,
                                x: 0, y: side * 0.004))
        layer.fill(nib, with: .color(Color.haloText))
    }
}
