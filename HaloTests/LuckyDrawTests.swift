import Testing
import SwiftUI
import AppKit
import Foundation
import AVFoundation
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

// MARK: - RosterImport (FR-2, FR-3, FR-4)

@Suite("RosterImport")
struct RosterImportTests {

    @Test("Pasted lines split per line; blanks and padding are dropped")
    func pastedLines() {
        #expect(RosterImport.labels(fromPasted: "  Anna \n\nMarcus\r\nYuki\n") == ["Anna", "Marcus", "Yuki"])
    }

    @Test("A single line with commas and no newline splits on the commas")
    func pastedCommas() {
        #expect(RosterImport.labels(fromPasted: "Anna, Marcus,,Yuki") == ["Anna", "Marcus", "Yuki"])
    }

    @Test("A line that merely contains a comma is NOT split when there is a newline")
    func commasInsideLines() {
        #expect(RosterImport.labels(fromPasted: "Doe, Jane\nSmith, John") == ["Doe, Jane", "Smith, John"])
    }

    @Test("Labels are truncated to the stored length before anything compares them")
    func truncation() {
        let long = String(repeating: "x", count: 100)
        #expect(RosterImport.labels(fromPasted: long).first?.count == RosterImport.labelLimit)
    }

    @Test("CSV: first column of each row")
    func csvFirstColumn() {
        #expect(RosterImport.labels(fromCSV: "Anna,Sales\nMarcus,Eng\nYuki,Design\n") == ["Anna", "Marcus", "Yuki"])
    }

    @Test("CSV: quoted cells keep their commas and escaped quotes")
    func csvQuoted() {
        let csv = "\"Doe, Jane\",Sales\n\"The \"\"Boss\"\"\",Eng\n"
        #expect(RosterImport.labels(fromCSV: csv) == ["Doe, Jane", "The \"Boss\""])
    }

    @Test("CSV: a single row is a comma list of names, like a paste")
    func csvSingleRow() {
        #expect(RosterImport.labels(fromCSV: "Anna,Marcus,Yuki") == ["Anna", "Marcus", "Yuki"])
    }

    @Test("CSV: no header row is guessed at and silently dropped")
    func csvKeepsHeaderLikeRows() {
        #expect(RosterImport.labels(fromCSV: "name,team\nAnna,Sales\n").first == "name")
    }

    @Test("Extension decides the parser, case-insensitively")
    func byExtension() {
        #expect(RosterImport.labels(fromFileContents: "a,b\nc,d", fileExtension: "CSV") == ["a", "c"])
        #expect(RosterImport.labels(fromFileContents: "a,b\nc,d", fileExtension: "txt") == ["a,b", "c,d"])
    }

    // MARK: Files

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-roster-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("A dropped .txt file is read into labels")
    func readTxt() throws {
        let url = try tempFile("names.txt", Data("Anna\nMarcus\n".utf8))
        #expect(try RosterImport.read(fileAt: url) == ["Anna", "Marcus"])
    }

    @Test("Accented names survive UTF-8 and the old Mac Roman encoding")
    func readEncodings() throws {
        let utf8 = try tempFile("a.txt", Data("Tomás\nZoë\n".utf8))
        #expect(try RosterImport.read(fileAt: utf8) == ["Tomás", "Zoë"])
        // 0x8E is é in Mac Roman and an invalid lone byte sequence in UTF-8.
        let roman = try tempFile("b.csv", Data([0x4A, 0x6F, 0x73, 0x8E, 0x0A, 0x41, 0x6E, 0x61, 0x0A]))
        #expect(try RosterImport.read(fileAt: roman) == ["José", "Ana"])
    }

    @Test("Unsupported types and oversized files are refused, not half-read")
    func refusals() throws {
        let pdf = try tempFile("names.pdf", Data("x".utf8))
        #expect(throws: RosterImport.ReadError.unsupportedType("pdf")) { try RosterImport.read(fileAt: pdf) }

        let big = try tempFile("big.txt", Data(repeating: 0x41, count: RosterImport.maxFileBytes + 1))
        #expect(throws: RosterImport.ReadError.tooLarge(bytes: RosterImport.maxFileBytes + 1)) {
            try RosterImport.read(fileAt: big)
        }
    }

    // MARK: Duplicates (FR-4)

    @Test("Case, accents and spacing do not make a different name")
    func keyNormalisation() {
        let key = RosterImport.key(for: "Anna")
        #expect(RosterImport.key(for: "  ANNA ") == key)
        #expect(RosterImport.key(for: "anna") == key)
        #expect(RosterImport.key(for: "Tomás") == RosterImport.key(for: "tomas"))
        #expect(RosterImport.key(for: "Mary   Jane") == RosterImport.key(for: "mary jane"))
        #expect(RosterImport.key(for: "Anna") != RosterImport.key(for: "Anne"))
    }

    @Test("A label already on the roster is flagged; new ones are not")
    func duplicatesAgainstExisting() {
        let plan = RosterImport.plan(incoming: ["anna", "Zed"], existing: ["Anna", "Marcus"])
        #expect(plan.items == [.init(label: "anna", isDuplicate: true),
                               .init(label: "Zed", isDuplicate: false)])
        #expect(plan.hasDuplicates)
    }

    @Test("A repeat within one batch is the duplicate — the first occurrence is not")
    func duplicatesWithinBatch() {
        let plan = RosterImport.plan(incoming: ["Sam", "Lee", "sam"], existing: [])
        #expect(plan.items.map(\.isDuplicate) == [false, false, true])
    }

    @Test("Keep both adds everything; Skip duplicates adds only the new — in arrival order")
    func policies() {
        let plan = RosterImport.plan(incoming: ["Anna", "Zed", "anna", "Yu"], existing: ["Anna"])
        #expect(plan.labels(for: .keepBoth) == ["Anna", "Zed", "anna", "Yu"])
        #expect(plan.labels(for: .skipDuplicates) == ["Zed", "Yu"])
        #expect(plan.duplicateCount == 2)
        #expect(plan.duplicateLabels == ["Anna", "anna"])
    }

    @Test("No duplicates means no prompt")
    func noDuplicates() {
        #expect(!RosterImport.plan(incoming: ["A", "B"], existing: ["C"]).hasDuplicates)
    }

    @Test("Names that only differ past the stored length are the same name")
    func duplicatesUseTheStoredForm() {
        let a = String(repeating: "x", count: 60) + "AAAA"
        let b = String(repeating: "x", count: 60) + "BBBB"
        let labels = RosterImport.labels(fromPasted: a + "\n" + b)
        #expect(RosterImport.plan(incoming: labels, existing: []).items.map(\.isDuplicate) == [false, true])
    }
}

// MARK: - DrawSequence (FR-10)

@Suite("DrawSequence")
struct DrawSequenceTests {

    private func entries(_ n: Int) -> [DrawEntry] { (0..<n).map { DrawEntry(label: "E\($0)") } }

    @Test("Requests are clamped to 2…10 and to what is eligible")
    func clamping() throws {
        #expect(try #require(DrawSequence(requested: 1, eligibleCount: 20)).total == 2)
        #expect(try #require(DrawSequence(requested: 99, eligibleCount: 20)).total == 10)
        let few = try #require(DrawSequence(requested: 5, eligibleCount: 3))
        #expect(few.total == 3)
        #expect(few.wasReducedToFit)
        #expect(try #require(DrawSequence(requested: 5, eligibleCount: 9)).wasReducedToFit == false)
    }

    @Test("Nothing eligible means no run at all")
    func nothingEligible() {
        #expect(DrawSequence(requested: 3, eligibleCount: 0) == nil)
    }

    @Test("A run counts down, completes, and reports its position")
    func progress() throws {
        var run = try #require(DrawSequence(requested: 3, eligibleCount: 10))
        let pool = entries(10)
        #expect(run.position == 1 && run.remaining == 3 && run.shouldContinue)
        run.record(pool[0]); run.record(pool[1])
        #expect(run.position == 3 && run.remaining == 1 && !run.isComplete)
        run.record(pool[2])
        #expect(run.isComplete && !run.shouldContinue && run.position == 3)
    }

    @Test("Winners within a run are drawn without replacement — even with retire off")
    func withoutReplacement() throws {
        var run = try #require(DrawSequence(requested: 3, eligibleCount: 5))
        let all = entries(5)
        run.record(all[1])
        let pool = run.pool(from: all)
        #expect(pool.count == 4)
        #expect(!pool.contains(all[1]))
    }

    @Test("Stop blocks the next spin but does not undo winners already drawn")
    func stop() throws {
        var run = try #require(DrawSequence(requested: 5, eligibleCount: 9))
        run.record(entries(1)[0])
        run.requestStop()
        #expect(run.stopRequested && !run.shouldContinue)
        #expect(run.winners.count == 1)
    }

    @Test("End to end: N spins from the real engine name N distinct winners")
    func distinctWinnersFromTheEngine() throws {
        var rng = DrawEngineTests.SeededGenerator(seed: 7)
        let all = entries(8)
        var run = try #require(DrawSequence(requested: 8, eligibleCount: all.count))
        while run.shouldContinue {
            let pool = run.pool(from: all)
            let plan = try #require(DrawEngine.plan(eligibleCount: pool.count, currentAngle: 0,
                                                    duration: 5, idForIndex: { pool[$0].id }, using: &rng))
            run.record(try #require(pool.first { $0.id == plan.winnerID }))
        }
        #expect(run.isComplete)
        #expect(Set(run.winners.map(\.id)).count == 8, "a run named someone twice")
    }
}

// MARK: - Roster persistence & duplication

@Suite("DrawRoster persistence")
struct DrawRosterPersistenceTests {

    /// A roster file as it was written **before** `soundEnabled` existed.
    private let legacyJSON = """
    [{"id":"8E1B5B64-7C6A-4B0B-9E55-2F8C2E5C7A11","name":"Standup order",
      "entries":[{"id":"1A1B5B64-7C6A-4B0B-9E55-2F8C2E5C7A11","label":"Priya","isExcluded":false,
                  "isRetired":true,"addedAt":0}],
      "history":[],"autoRetireWinner":true,"spinDuration":"standard","modifiedAt":0}]
    """

    @Test("A roster file written before soundEnabled existed still decodes — nobody's rosters vanish")
    func legacyFileDecodes() throws {
        let rosters = try JSONDecoder().decode([DrawRoster].self, from: Data(legacyJSON.utf8))
        #expect(rosters.count == 1)
        #expect(rosters[0].name == "Standup order")
        #expect(rosters[0].soundEnabled == false, "sound must default OFF for existing rosters")
        #expect(rosters[0].entries.first?.isRetired == true)
    }

    @Test("soundEnabled round-trips")
    func soundRoundTrips() throws {
        var roster = DrawRoster(name: "R", entries: [DrawEntry(label: "A")])
        roster.soundEnabled = true
        let back = try JSONDecoder().decode(DrawRoster.self, from: JSONEncoder().encode(roster))
        #expect(back.soundEnabled)
        #expect(back.entries.map(\.label) == ["A"])
    }

    @Test("Sound is off by default (D9)")
    func soundDefaultsOff() {
        #expect(DrawRoster(name: "x").soundEnabled == false)
    }

    @Test("Duplicating a roster copies entries and settings but starts a fresh round")
    func duplicate() {
        var original = DrawRoster(name: "Team", entries: [DrawEntry(label: "A"), DrawEntry(label: "B", isExcluded: true)],
                                  autoRetireWinner: false, spinDuration: .dramatic, soundEnabled: true)
        original.recordWin(entryID: original.entries[0].id, label: "A")

        let copy = original.duplicated(named: "Team copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Team copy")
        #expect(copy.entries.map(\.label) == ["A", "B"])
        #expect(copy.entries[1].isExcluded, "exclusions are a user choice and carry over")
        #expect(copy.history.isEmpty, "a copy does not inherit the old draw log")
        #expect(copy.entries.allSatisfy { !$0.isRetired })
        #expect(Set(copy.entries.map(\.id)).isDisjoint(with: original.entries.map(\.id)))
        #expect(copy.autoRetireWinner == false && copy.spinDuration == .dramatic && copy.soundEnabled)
    }
}

// MARK: - Sound (D9)

@Suite("Lucky Draw sound")
struct LuckyDrawSoundTests {

    private func plan(count: Int, duration: Double = 5, seed: UInt64 = 3) -> SpinPlan {
        var rng = DrawEngineTests.SeededGenerator(seed: seed)
        let ids = (0..<count).map { _ in UUID() }
        return DrawEngine.plan(eligibleCount: count, currentAngle: 0, duration: duration,
                               idForIndex: { ids[$0] }, using: &rng)!
    }

    @Test("Ticks never exceed the 20-per-second cap — even on a 200-entry wheel")
    func rateCap() {
        let p = plan(count: 200)
        let times = RatchetSchedule.tickTimes(for: p, segmentCount: 200)
        #expect(!times.isEmpty)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b - a >= RatchetSchedule.minimumInterval - 1e-9, "ticks \(a) and \(b) are closer than 50 ms")
        }
        #expect(Double(times.count) <= RatchetSchedule.maxTicksPerSecond * p.totalDuration + 1)
    }

    @Test("Ticks are ordered and fall inside the spin")
    func ordered() {
        let p = plan(count: 12)
        let times = RatchetSchedule.tickTimes(for: p, segmentCount: 12)
        #expect(times == times.sorted())
        #expect(times.allSatisfy { $0 >= SpinPlan.windupDuration && $0 <= p.totalDuration })
    }

    @Test("There is nothing to tick on a one-entry wheel")
    func singleEntry() {
        #expect(RatchetSchedule.tickTimes(for: plan(count: 1), segmentCount: 1).isEmpty)
    }

    @Test("The ratchet audibly slows: gaps widen into countable clicks rather than a buzz")
    func slowingIsAudible() {
        let p = plan(count: 24)
        let times = RatchetSchedule.tickTimes(for: p, segmentCount: 24)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.count > 10)

        // Deceleration shows up as widening gaps: the final stretch is slower than the
        // stretch before it.
        let tail = Array(gaps.suffix(5)), before = Array(gaps.dropLast(5).suffix(5))
        #expect(tail.reduce(0, +) / 5 > before.reduce(0, +) / 5,
                "the ticks are not slowing down — the wheel's deceleration is inaudible")
        // The last clicks are distinct and countable, not a blur.
        #expect((gaps.last ?? 0) >= 0.10, "the final ticks run together")
        // And it keeps ticking well into the decay rather than falling silent early. After
        // the last crossing the wheel only creeps *inside* the winning segment, so there is
        // nothing further to tick — which is why this is measured against the spin, not the
        // final second.
        #expect((times.last ?? 0) > p.totalDuration * 0.6)
    }

    @Test("A spin crossing N boundaries produces about N ticks when slow enough not to be capped")
    func tickPerCrossing() {
        // 4 segments over a long, slow spin: far below 20 crossings/s, so nothing is dropped.
        let p = plan(count: 4, duration: 8)
        let times = RatchetSchedule.tickTimes(for: p, segmentCount: 4)
        let crossings = Int(abs(p.targetAngle + p.overshoot - p.fromAngle) / 90)
        #expect(abs(times.count - crossings) <= 2, "\(times.count) ticks for ≈\(crossings) crossings")
    }

    @Test("The synthesised cues are non-silent, never clip, and decay to silence")
    func synthesis() {
        for samples in [SoundSynth.tickSamples(), SoundSynth.fanfareSamples()] {
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak > 0.05, "silent")
            #expect(peak < 0.98, "clips")
            let tail = samples.suffix(samples.count / 20).map { abs($0) }.max() ?? 0
            #expect(tail < 0.01, "does not decay to silence — will click at the end")
        }
        #expect(SoundSynth.tickSamples().count < SoundSynth.sampleRate / 20, "a tick must be well under 50 ms")
    }

    @Test("The WAV container is well-formed")
    func wavHeader() {
        let samples = SoundSynth.tickSamples()
        let wav = SoundSynth.wav(from: samples)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(wav.count == 44 + samples.count * 2)
        let declared = wav[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: declared)) == wav.count - 8)
    }

    @Test("AVFoundation accepts the generated audio")
    func playable() throws {
        // Construction only — nothing is played, so this does not need an audio device.
        _ = try AVAudioPlayer(data: SoundSynth.wav(from: SoundSynth.tickSamples()))
        _ = try AVAudioPlayer(data: SoundSynth.wav(from: SoundSynth.fanfareSamples()))
    }
}

// MARK: - Rendering smoke

/// Renders the real SwiftUI views offscreen. This is not a pixel-diff test — it proves
/// the views construct, lay out and draw something (a `fixedSize` or layout mistake in
/// the new overlays would otherwise only show up at runtime), and, when
/// `HALO_RENDER_DIR` is set, writes PNGs so a human can look at them.
@Suite("Lucky Draw rendering", .serialized)
@MainActor
struct LuckyDrawRenderingTests {

    /// Renders through a real (offscreen) window rather than `ImageRenderer`, because
    /// `ImageRenderer` cannot draw AppKit-backed controls: a `ScrollView` comes out blank
    /// and a `Stepper` as a "no entry" placeholder — which is most of the roster panel.
    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> CGImage {
        let framed = view
            .frame(width: size.width, height: size.height)
            .background(Color.haloBackground)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle: onAppear work and the first layout pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                               "\(name): no bitmap")
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage, "\(name) did not render")

        if let dir = ProcessInfo.processInfo.environment["HALO_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        return image
    }

    /// More than one distinct colour somewhere — i.e. something was actually drawn.
    private func isNotBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
        let bpp = image.bitsPerPixel / 8
        let first = (ptr[0], ptr[1], ptr[2])
        let total = image.width * image.height
        var i = 0
        while i < total {
            let o = i * bpp
            if (ptr[o], ptr[o + 1], ptr[o + 2]) != first { return true }
            i += 997
        }
        return false
    }

    @Test("The winners list renders, in order, at a sensible size")
    func sequenceOverlay() throws {
        let winners = ["Priya", "Marcus", "Yuki", "Amara"].map { DrawEntry(label: $0) }
        let image = try render(DrawSequenceOverlay(winners: winners, plannedCount: 6,
                                                   reducedMotion: true, onCopy: {}, onClose: {}),
                               size: CGSize(width: 520, height: 360), name: "sequence-overlay-stopped")
        #expect(isNotBlank(image))
    }

    @Test("The whole Lucky Draw screen renders")
    func wholeView() throws {
        let image = try render(LuckyDrawView(), size: CGSize(width: 1080, height: 720), name: "lucky-draw-screen")
        #expect(isNotBlank(image))
    }

    @Test("The roster panel renders with its new controls")
    func rosterPanel() throws {
        let image = try render(RosterPanelView(store: LuckyDrawStore.shared,
                                               viewModel: LuckyDrawViewModel(),
                                               addFieldIsFocused: .constant(false)),
                               size: CGSize(width: 312, height: 760), name: "roster-panel")
        #expect(isNotBlank(image))
    }
}
