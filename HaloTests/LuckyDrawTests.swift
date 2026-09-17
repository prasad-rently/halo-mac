import Testing
import SwiftUI
import AppKit
import Foundation
@testable import Halo

// MARK: - DrawEngine

@Suite("DrawEngine")
struct DrawEngineTests {

    /// A deterministic generator, so a uniformity failure is reproducible rather than
    /// a once-in-a-while red build.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private func plan(count: Int, angle: Double = 0, duration: Double = 5,
                      rng: inout some RandomNumberGenerator) -> SpinPlan? {
        let ids = (0..<count).map { _ in UUID() }
        return DrawEngine.plan(eligibleCount: count, currentAngle: angle,
                               duration: duration, idForIndex: { ids[$0] }, using: &rng)
    }

    @Test("Winner selection is uniform over the eligible pool")
    func uniformity() {
        let buckets = 10
        let draws = 100_000
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var counts = [Int](repeating: 0, count: buckets)
        for _ in 0..<draws {
            guard let p = plan(count: buckets, rng: &rng) else { Issue.record("no plan"); return }
            counts[p.winnerIndex] += 1
        }

        let expected = Double(draws) / Double(buckets)
        let chiSquare = counts.reduce(0.0) { acc, observed in
            let d = Double(observed) - expected
            return acc + (d * d) / expected
        }
        // 9 degrees of freedom, p = 0.01 → critical value 21.666.
        #expect(chiSquare < 21.666,
                "χ² = \(chiSquare) over \(counts) — distribution is not uniform")
    }

    /// The 0°/360° seam. This is the failure this whole test file exists for: an
    /// off-by-one here means the card names someone the pointer is not on.
    @Test("Landing angle resolves to the chosen winner for every roster size")
    func landingAngleResolvesToWinner() {
        var rng = SeededGenerator(seed: 42)
        for count in 1...500 {
            // A non-zero starting angle, since the plan advances from where the wheel
            // is — starting every case at 0 would hide a `fromAngle` bug entirely.
            let start = Double(count) * 7.3
            guard let p = plan(count: count, angle: start, rng: &rng) else {
                Issue.record("no plan for count \(count)"); continue
            }
            let landed = DrawEngine.segmentIndex(atAngle: p.targetAngle, count: count)
            #expect(landed == p.winnerIndex,
                    "count \(count): pointer is on segment \(landed) but the winner is \(p.winnerIndex)")
        }
    }

    @Test("The plan never rotates backwards or lands short of five turns")
    func forwardRotationOnly() {
        var rng = SeededGenerator(seed: 7)
        for count in [1, 2, 3, 7, 60, 120, 499, 500] {
            guard let p = plan(count: count, angle: 123.4, rng: &rng) else { continue }
            let travelled = p.targetAngle - p.fromAngle
            #expect(travelled >= Double(DrawEngine.minFullSpins) * 360)
            #expect(travelled <= Double(DrawEngine.maxFullSpins + 1) * 360)
        }
    }

    @Test("Jitter stays strictly inside the winning segment")
    func jitterStaysInSegment() {
        #expect(DrawEngine.jitterFraction < 0.5)
        var rng = SeededGenerator(seed: 99)
        for _ in 0..<2_000 {
            guard let p = plan(count: 12, angle: Double.random(in: 0...360), rng: &rng) else { continue }
            #expect(DrawEngine.segmentIndex(atAngle: p.targetAngle, count: 12) == p.winnerIndex)
        }
    }

    @Test("An empty pool produces no plan rather than a zero-segment wheel")
    func emptyPool() {
        var rng = SeededGenerator(seed: 1)
        #expect(plan(count: 0, rng: &rng) == nil)
    }

    @Test("segmentIndex is exact at the seam and at every boundary")
    func seamBoundaries() {
        // 4 segments of 90°. Angle 0 puts segment 0 under the pointer; rotating the
        // wheel +90° brings segment 3 (the one 90° anticlockwise) around to it.
        #expect(DrawEngine.segmentIndex(atAngle: 0, count: 4) == 0)
        #expect(DrawEngine.segmentIndex(atAngle: 90, count: 4) == 3)
        #expect(DrawEngine.segmentIndex(atAngle: 180, count: 4) == 2)
        #expect(DrawEngine.segmentIndex(atAngle: 270, count: 4) == 1)
        #expect(DrawEngine.segmentIndex(atAngle: 360, count: 4) == 0)
        #expect(DrawEngine.segmentIndex(atAngle: -1, count: 4) == 0)
        #expect(DrawEngine.segmentIndex(atAngle: 719.9, count: 4) == 0)
    }
}

// MARK: - SpinnerAnimator

@Suite("SpinnerAnimator")
struct SpinnerAnimatorTests {

    private let plan = SpinPlan(winnerID: UUID(), winnerIndex: 0, fromAngle: 0,
                                targetAngle: 2340, overshoot: 2, duration: 5)

    @Test("Progress runs from 0 to exactly 1 and never goes backwards")
    func progressIsMonotonic() {
        #expect(abs(SpinnerAnimator.progress(0)) < 1e-12)
        #expect(abs(SpinnerAnimator.progress(1) - 1) < 1e-9)
        var previous = -1.0
        for step in 0...1000 {
            let value = SpinnerAnimator.progress(Double(step) / 1000)
            #expect(value >= previous, "progress went backwards at u = \(Double(step) / 1000)")
            previous = value
        }
    }

    @Test("Velocity rests at both ends and peaks across the cruise")
    func velocityProfile() {
        #expect(SpinnerAnimator.velocityShape(0) == 0)
        #expect(abs(SpinnerAnimator.velocityShape(1)) < 1e-9)
        #expect(abs(SpinnerAnimator.velocityShape(SpinnerAnimator.launchEnd) - 1) < 1e-9)
        #expect(abs(SpinnerAnimator.velocityShape(SpinnerAnimator.cruiseEnd) - 1) < 1e-9)
        #expect(SpinnerAnimator.velocityShape(0.3) == 1)
    }

    /// The tuned number. At 4.2 the final second falls to ~2 °/s and reads as a
    /// frozen app; this pins it to a band that is still visibly motion.
    @Test("The last second of a 5-second spin crawls without stalling")
    func decayLandsInTheReadableBand() {
        let peak = SpinnerAnimator.peakVelocity(for: plan)
        let atOneSecondLeft = SpinnerAnimator.frame(for: plan,
                                                    elapsed: SpinPlan.windupDuration + 4.0)
        #expect(atOneSecondLeft.velocity > 12, "too slow to read as motion")
        #expect(atOneSecondLeft.velocity < 90, "too fast to count names against")
        #expect(peak > 500, "peak velocity should be a real spin, not a drift")
    }

    @Test("The wind-up holds the wheel still, then it arrives exactly on target")
    func windupAndArrival() {
        let early = SpinnerAnimator.frame(for: plan, elapsed: 0.1)
        #expect(early.phase == .windup)
        #expect(early.angle == plan.fromAngle)
        #expect(early.windup > 0)

        let done = SpinnerAnimator.frame(for: plan, elapsed: plan.totalDuration)
        #expect(done.isFinished)
        #expect(abs(done.angle - plan.targetAngle) < 1e-9)
        #expect(done.velocity == 0)
    }

    @Test("The pointer ends on the winner the plan chose")
    func pointerAgreesWithPlan() {
        for count in [3, 8, 37, 120] {
            var rng = SystemRandomNumberGenerator()
            let ids = (0..<count).map { _ in UUID() }
            guard let p = DrawEngine.plan(eligibleCount: count, currentAngle: 61.7,
                                          duration: 5, idForIndex: { ids[$0] },
                                          using: &rng) else { continue }
            let final = SpinnerAnimator.frame(for: p, elapsed: p.totalDuration)
            #expect(DrawEngine.segmentIndex(atAngle: final.angle, count: count) == p.winnerIndex)
        }
    }

    @Test("Phases run in order and the near-miss window opens before the settle")
    func phaseOrder() {
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.1).phase == .windup)
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.28 + 0.2).phase == .launch)
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.28 + 1.5).phase == .cruise)
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.28 + 3.0).phase == .decay)
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.28 + 4.9).phase == .nearMiss)
        #expect(SpinnerAnimator.frame(for: plan, elapsed: 0.28 + 5.1).phase == .settle)
    }
}

// MARK: - DrawRoster

@Suite("DrawRoster")
struct DrawRosterTests {

    private func roster(_ names: [String] = ["A", "B", "C"]) -> DrawRoster {
        DrawRoster(name: "T", entries: names.map { DrawEntry(label: $0) })
    }

    @Test("Eligible excludes both excluded and retired entries")
    func eligibility() {
        var r = roster()
        r.entries[0].isExcluded = true
        r.entries[1].isRetired = true
        #expect(r.eligible.map(\.label) == ["C"])
        #expect(r.canSpin)
        r.entries[2].isExcluded = true
        #expect(!r.canSpin)
    }

    @Test("A win is logged, and retires the winner only when the roster asks")
    func recordWin() {
        var r = roster()
        r.recordWin(entryID: r.entries[0].id, label: "A")
        #expect(r.history.count == 1)
        #expect(r.entries[0].isRetired)

        var loose = roster()
        loose.autoRetireWinner = false
        loose.recordWin(entryID: loose.entries[0].id, label: "A")
        #expect(loose.history.count == 1)
        #expect(!loose.entries[0].isRetired, "winner should stay on the wheel")
    }

    /// The behaviour the module is built around: put back returns someone to the
    /// wheel **without** erasing the fact that they were drawn.
    @Test("Put back returns the entry to the wheel and keeps its log row")
    func putBackKeepsTheLogRow() {
        var r = roster()
        let winner = r.entries[0]
        r.recordWin(entryID: winner.id, label: winner.label)
        #expect(r.eligible.count == 2)

        let row = r.history[0]
        r.putBack(row)

        #expect(r.history.count == 1, "the draw still happened — the row must remain")
        #expect(r.history[0].wasReturned)
        #expect(r.history[0].label == winner.label)
        #expect(r.eligible.count == 3, "the entry is eligible for the next draw again")
        #expect(!r.entries[0].isRetired)
    }

    @Test("A put-back entry can win again, and logs a second row")
    func putBackEntryCanWinAgain() {
        var r = roster()
        let winner = r.entries[0]
        r.recordWin(entryID: winner.id, label: winner.label)
        r.putBack(r.history[0])
        r.recordWin(entryID: winner.id, label: winner.label)

        #expect(r.history.count == 2)
        #expect(r.history[0].wasReturned == false, "the newest row is the live win")
        #expect(r.history[1].wasReturned == true, "the earlier row stays flagged as returned")
        #expect(r.entries[0].isRetired)
    }

    @Test("Reset puts everyone back and clears the log, leaving exclusions alone")
    func resetDraw() {
        var r = roster(["A", "B", "C", "D"])
        r.entries[3].isExcluded = true
        for entry in r.entries.prefix(3) {
            r.recordWin(entryID: entry.id, label: entry.label)
        }
        #expect(r.eligible.isEmpty)
        #expect(r.canReset)

        r.resetDraw()

        #expect(r.history.isEmpty)
        #expect(r.retiredCount == 0)
        #expect(r.entries[3].isExcluded, "exclusion is a separate user choice; reset must not touch it")
        #expect(r.eligible.count == 3)
        #expect(!r.canReset)
    }

    @Test("Drawing a roster down produces no repeats and ends in an empty pool")
    func fullRoundHasNoRepeats() {
        var r = roster(["A", "B", "C", "D", "E", "F", "G"])
        var seen = Set<UUID>()
        while !r.eligible.isEmpty {
            guard let plan = DrawEngine.plan(for: r.eligible, currentAngle: 0, duration: 3) else { break }
            #expect(!seen.contains(plan.winnerID), "the same entry was drawn twice")
            seen.insert(plan.winnerID)
            let won = r.eligible.first { $0.id == plan.winnerID }!
            r.recordWin(entryID: won.id, label: won.label)
        }
        #expect(seen.count == 7)
        #expect(r.history.count == 7)
        #expect(r.canReset)
    }

    @Test("The log is capped and the newest rows survive")
    func historyCap() {
        var r = roster(["A"])
        r.autoRetireWinner = false
        for i in 0..<(DrawRoster.historyCap + 25) {
            r.recordWin(entryID: r.entries[0].id, label: "draw \(i)")
        }
        #expect(r.history.count == DrawRoster.historyCap)
        #expect(r.history.first?.label == "draw \(DrawRoster.historyCap + 24)")
    }

    @Test("A roster round-trips through JSON")
    func codableRoundTrip() throws {
        var r = roster()
        r.recordWin(entryID: r.entries[0].id, label: "A")
        r.putBack(r.history[0])
        let data = try JSONEncoder().encode([r])
        let back = try JSONDecoder().decode([DrawRoster].self, from: data)
        #expect(back.first?.entries.count == 3)
        #expect(back.first?.history.first?.wasReturned == true)
        #expect(back.first?.eligible.count == 3)
    }
}

// MARK: - SegmentPalette

@Suite("SegmentPalette")
struct SegmentPaletteTests {

    /// The single label colour only works because every fill is dark by construction.
    /// If a future tweak brightens the ramp, this fails before the wheel ships with
    /// unreadable names on it.
    @Test("Every segment fill clears 4.5:1 against the one label colour")
    func labelContrast() {
        for count in [1, 2, 5, 12, 60, 200, 500] {
            for index in stride(from: 0, to: count, by: max(1, count / 40)) {
                let ratio = contrastRatio(SegmentPalette.fill(for: index, of: count),
                                          SegmentPalette.label)
                #expect(ratio >= 4.5,
                        "count \(count) index \(index): contrast \(ratio) is below 4.5:1")
            }
        }
    }

    @Test("Neighbouring segments separate on luminance, not only hue")
    func neighboursSeparate() {
        for count in [8, 40, 200] {
            for index in 0..<(count - 1) {
                let a = relativeLuminance(SegmentPalette.fill(for: index, of: count))
                let b = relativeLuminance(SegmentPalette.fill(for: index + 1, of: count))
                #expect(abs(a - b) > 0.004,
                        "count \(count): segments \(index) and \(index + 1) are indistinguishable")
            }
        }
    }

    private func relativeLuminance(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(ns.redComponent)
             + 0.7152 * channel(ns.greenComponent)
             + 0.0722 * channel(ns.blueComponent)
    }

    private func contrastRatio(_ a: Color, _ b: Color) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
