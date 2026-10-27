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

    // MARK: F-053 — avatars (rendered for a human to look at; assertions only prove it draws)

    /// A photo-backed roster: real files through the real store and cache.
    private func avatarFixture() throws -> (roster: UUID, entries: [DrawEntry], root: URL) {
        let root = AvatarFixtures.tempRoot()
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let roster = UUID()
        let colours: [(UInt8, UInt8, UInt8)] = [(210, 80, 70), (60, 160, 200), (90, 190, 110)]
        var entries: [DrawEntry] = []
        let names = ["Priya", "Marcus", "Yuki", "Amara", "Tomás", "Nadia"]
        for (i, n) in names.enumerated() {
            switch i % 3 {
            case 0:  entries.append(DrawEntry(label: n, avatar: .photo(fileName:
                        try store.importPhoto(data: AvatarFixtures.png(width: 500, height: 500, color: colours[i % 3]), rosterID: roster))))
            case 1:  entries.append(DrawEntry(label: n, avatar: .emoji(["🦊", "🚀", "🌈"][i % 3])))
            default: entries.append(DrawEntry(label: n))                         // monogram
            }
        }
        AvatarImageCache.shared.store = store
        // Warm the cache so the render has the decoded photos: the first draw only starts the load.
        for e in entries { if case .photo(let f)? = e.avatar { _ = AvatarImageCache.shared.photo(fileName: f, rosterID: roster, points: 56) } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return (roster, entries, root)
    }

    @Test("The wheel draws avatars — photo, emoji and monogram — in each display mode")
    func wheelWithAvatars() throws {
        let fx = try avatarFixture(); defer { try? FileManager.default.removeItem(at: fx.root); AvatarImageCache.shared.store = nil }
        for mode in AvatarDisplayMode.allCases {
            let image = try render(SpinnerWheelView(entries: fx.entries, plan: nil, spinStart: nil, restAngle: 0,
                                                    highlightID: fx.entries[1].id, reducedMotion: true,
                                                    rosterID: fx.roster, avatarMode: mode),
                                   size: CGSize(width: 480, height: 480), name: "wheel-avatars-\(mode.rawValue)")
            #expect(isNotBlank(image))
        }
    }

    @Test("A wheel with an avatar-less roster is unchanged by Automatic mode")
    func autoModeLeavesAPlainRosterAlone() throws {
        let entries = ["Priya", "Marcus", "Yuki", "Amara"].map { DrawEntry(label: $0) }
        func pixels(_ mode: AvatarDisplayMode) throws -> Data {
            let img = try render(SpinnerWheelView(entries: entries, plan: nil, spinStart: nil, restAngle: 0,
                                                  highlightID: nil, reducedMotion: true, rosterID: UUID(), avatarMode: mode),
                                 size: CGSize(width: 420, height: 420), name: "wheel-plain-\(mode.rawValue)")
            return img.dataProvider?.data as Data? ?? Data()
        }
        #expect(try pixels(.auto) == pixels(.nameOnly), "Automatic must not change a wheel nobody has given an avatar to")
    }

    @Test("A busy wheel past the avatar limit stays plain")
    func manyEntriesStayPlain() throws {
        let many = (0..<(SpinnerWheelView.avatarLimit + 10)).map { DrawEntry(label: "E\($0)", avatar: .emoji("🦊")) }
        func pixels(_ mode: AvatarDisplayMode) throws -> Data {
            let img = try render(SpinnerWheelView(entries: many, plan: nil, spinStart: nil, restAngle: 0,
                                                  highlightID: nil, reducedMotion: true, rosterID: UUID(), avatarMode: mode),
                                 size: CGSize(width: 420, height: 420), name: "wheel-many-\(mode.rawValue)")
            return img.dataProvider?.data as Data? ?? Data()
        }
        #expect(try pixels(.avatarOnly) == pixels(.nameOnly))
    }

    @Test("The winner popup shows a large avatar — emoji, photo and monogram")
    func winnerPopupWithAvatar() throws {
        let fx = try avatarFixture(); defer { try? FileManager.default.removeItem(at: fx.root); AvatarImageCache.shared.store = nil }
        for (i, e) in [fx.entries[0], fx.entries[1], fx.entries[2]].enumerated() {
            let image = try render(DrawResultOverlay(label: e.label, avatar: e.avatar, rosterID: fx.roster, showAvatar: true,
                                                     reducedMotion: true, canPutBack: true,
                                                     onSpinAgain: {}, onPutBack: {}, onCopy: {}, onClose: {}),
                                   size: CGSize(width: 520, height: 420), name: "winner-popup-avatar-\(i)")
            #expect(isNotBlank(image))
        }
    }

    @Test("The winners strip shows an avatar beside each name")
    func sequenceWithAvatars() throws {
        let fx = try avatarFixture(); defer { try? FileManager.default.removeItem(at: fx.root); AvatarImageCache.shared.store = nil }
        let image = try render(DrawSequenceOverlay(winners: Array(fx.entries.prefix(5)), rosterID: fx.roster,
                                                   avatarMode: .avatarAndName, plannedCount: 5, reducedMotion: true,
                                                   onCopy: {}, onClose: {}),
                               size: CGSize(width: 520, height: 420), name: "sequence-avatars")
        #expect(isNotBlank(image))
    }

    @Test("The avatar picker renders")
    func picker() throws {
        let store = LuckyDrawStore(fileURL: AvatarFixtures.tempRoot().appendingPathComponent("luckyDraw.json"),
                                   notificationCenter: NotificationCenter())
        let image = try render(AvatarPickerView(store: store, entry: store.selected!.entries[0],
                                                rosterID: store.selected!.id, dismiss: {}),
                               size: CGSize(width: 330, height: 360), name: "avatar-picker")
        #expect(isNotBlank(image))
    }
}


// MARK: - Durability and export safety

@Suite("Lucky Draw durability")
@MainActor
struct LuckyDrawDurabilityTests {

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-draw-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("luckyDraw.json")
    }

    @Test("An edit made just before quitting is written on app termination, not lost to the debounce")
    func editSurvivesQuit() throws {
        let file = scratchFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let center = NotificationCenter()
        let store = LuckyDrawStore(fileURL: file, notificationCenter: center)

        store.addEntries(from: "quit-survivor")
        #expect(!FileManager.default.fileExists(atPath: file.path), "precondition: the 0.6 s debounce has not fired yet")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        let data = try Data(contentsOf: file)
        #expect(String(decoding: data, as: UTF8.self).contains("quit-survivor"))
        // And a second launch sees it.
        let reopened = LuckyDrawStore(fileURL: file, notificationCenter: NotificationCenter())
        #expect(reopened.selected?.entries.contains { $0.label == "quit-survivor" } == true)
    }

    @Test("Quitting without having edited anything does not touch the file")
    func quitWithoutEditsWritesNothing() throws {
        let file = scratchFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let center = NotificationCenter()
        _ = LuckyDrawStore(fileURL: file, notificationCenter: center)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A name that would be a spreadsheet formula is exported as text")
    func csvFormulaGuard() throws {
        let file = scratchFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LuckyDrawStore(fileURL: file, notificationCenter: NotificationCenter())
        for label in ["=HYPERLINK(\"http://evil\",\"x\")", "+1+1", "-2", "@SUM(A1)", "Anna"] {
            store.recordWin(entryID: UUID(), label: label)
        }
        let csv = store.historyCSV()
        #expect(csv.contains("\"'=HYPERLINK("), Comment(rawValue: csv))
        #expect(csv.contains("\"'+1+1\"") && csv.contains("\"'-2\"") && csv.contains("\"'@SUM(A1)\""))
        #expect(csv.contains("\"Anna\""), "an ordinary name must be left alone")
        for line in csv.split(separator: "\n").dropFirst() {
            let cell = line.split(separator: ",", maxSplits: 2)[1]
            #expect(!"=+-@".contains(cell.dropFirst().first ?? " "), "unguarded cell: \(cell)")
        }
    }
}

// MARK: - F-053 Lucky Draw avatars

/// Test helper: a real, small picture on disk and in memory.
private enum AvatarFixtures {
    static func png(width: Int, height: Int, color: (UInt8, UInt8, UInt8) = (200, 60, 60)) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A lighter block so a crop that lands in the wrong place is visible in a render.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("halo-avatars-\(UUID().uuidString)", isDirectory: true)
    }
}

@Suite("Avatar model")
struct AvatarModelTests {

    private func roundTrip(_ a: EntryAvatar) throws -> EntryAvatar {
        let data = try JSONEncoder().encode(DrawEntry(label: "X", avatar: a))
        return try #require(try JSONDecoder().decode(DrawEntry.self, from: data).avatar)
    }

    @Test("Every avatar kind survives a save and load")
    func codableRoundTrip() throws {
        let photo = "\(UUID().uuidString).jpg"
        for a in [EntryAvatar.emoji("🦊"), .emoji("🧑‍🚀"), .animated(pack: "fun", item: "wave-1"),
                  .character(pack: "people", item: "c_07"), .photo(fileName: photo)] {
            #expect(try roundTrip(a) == a)
        }
    }

    @Test("A roster file written before avatars existed still loads, with no avatar and the Automatic mode")
    func oldRosterFileDecodes() throws {
        let id = UUID(), entry = UUID()
        let json = """
        [{"id":"\(id)","name":"Old","entries":[{"id":"\(entry)","label":"Priya","isExcluded":false,"isRetired":false,"addedAt":0}],
          "history":[],"autoRetireWinner":true,"spinDuration":"standard","soundEnabled":false,"modifiedAt":0}]
        """
        let rosters = try JSONDecoder().decode([DrawRoster].self, from: Data(json.utf8))
        #expect(rosters.count == 1)
        #expect(rosters[0].entries[0].avatar == nil)
        #expect(rosters[0].avatarDisplay == .auto)
    }

    @Test("An unknown avatar kind, or an invalid payload, becomes 'no avatar' — it never fails the roster")
    func hostileOrFutureAvatarIsTolerated() throws {
        let id = UUID()
        func entry(_ avatar: String) -> String {
            "{\"id\":\"\(id)\",\"label\":\"A\",\"isExcluded\":false,\"isRetired\":false,\"addedAt\":0,\"avatar\":\(avatar)}"
        }
        for bad in ["{\"kind\":\"hologram\",\"value\":\"x\"}",                          // a future kind
                    "{\"kind\":\"emoji\",\"value\":\"not an emoji\"}",
                    "{\"kind\":\"emoji\",\"value\":\"🙂🙂\"}",
                    "{\"kind\":\"photo\",\"file\":\"../../etc/passwd\"}",
                    "{\"kind\":\"photo\",\"file\":\"/etc/passwd\"}",
                    "{\"kind\":\"photo\",\"file\":\"photo.jpg\"}",
                    "{\"kind\":\"animated\",\"pack\":\"../x\",\"item\":\"y\"}",
                    "{\"kind\":\"photo\"}", "\"just a string\"", "42"] {
            let decoded = try JSONDecoder().decode(DrawEntry.self, from: Data(entry(bad).utf8))
            #expect(decoded.avatar == nil, "accepted a bad avatar: \(bad)")
            #expect(decoded.label == "A")
        }
    }

    @Test("Photo file names must be a generated UUID.jpg; identifiers can't carry a path")
    func nameValidation() {
        #expect(AvatarFileName.isValid("\(UUID().uuidString).jpg"))
        for bad in ["", "a.jpg", "../\(UUID().uuidString).jpg", "\(UUID().uuidString).png", "\(UUID().uuidString)",
                    "/\(UUID().uuidString).jpg", "\(UUID().uuidString).jpg/"] {
            #expect(!AvatarFileName.isValid(bad), "accepted \(bad)")
        }
        #expect(AvatarIdentifier.isValid("wave-1_a.b"))
        for bad in ["", ".hidden", "..", "a/b", "a b", "é", String(repeating: "a", count: 65)] {
            #expect(!AvatarIdentifier.isValid(bad), "accepted \(bad)")
        }
    }

    @Test("Emoji validation accepts one emoji — ZWJ, flag, keycap, skin tone — and nothing else")
    func emojiValidation() {
        for ok in ["🙂", "🧑‍🚀", "👩‍👩‍👧", "🇮🇳", "1️⃣", "👍🏽", "❤️", "🦊"] { #expect(EmojiValidation.isSingleEmoji(ok), "rejected \(ok)") }
        for bad in ["", "a", "1", "ab", "🙂🙂", "🙂 ", "©", "#", "é"] { #expect(!EmojiValidation.isSingleEmoji(bad), "accepted \(bad)") }
    }

    @Test("Every quick-pick emoji passes the validator, so no button silently does nothing")
    func shortlistIsValid() {
        for e in AvatarEmojiCatalog.common { #expect(EmojiValidation.isSingleEmoji(e), "\(e) is rejected") }
        #expect(Set(AvatarEmojiCatalog.common).count == AvatarEmojiCatalog.common.count, "duplicate in the shortlist")
    }

    @Test("Monogram: grapheme-aware initials")
    func monograms() {
        #expect(Monogram.initials(for: "Priya") == "P")
        #expect(Monogram.initials(for: "anna maria") == "AM")
        #expect(Monogram.initials(for: "Åsa Lindqvist") == "ÅL")
        #expect(Monogram.initials(for: "Jean Luc Picard") == "JL")           // two words at most
        #expect(Monogram.initials(for: "  spaced   out  ") == "SO")
        #expect(Monogram.initials(for: "田中太郎") == "田")                      // no spaces: first character
        #expect(Monogram.initials(for: "🦊 Fox") == "🦊F")                     // the emoji stays whole
        #expect(Monogram.initials(for: "👩‍🚀 Sam") == "👩‍🚀S")
        #expect(Monogram.initials(for: "") == "?")
        #expect(Monogram.initials(for: "   ") == "?")
    }

    @Test("Folder matching ignores case, accents, spacing and extension; leaves ambiguity alone")
    func folderMatching() {
        let anna = DrawEntry(label: "Anna Maria"), asa = DrawEntry(label: "Åsa")
        let alex1 = DrawEntry(label: "Alex"), alex2 = DrawEntry(label: "alex"), solo = DrawEntry(label: "Solo")
        let entries = [anna, asa, alex1, alex2, solo]
        func f(_ n: String) -> URL { URL(fileURLWithPath: "/photos/\(n)") }
        let r = AvatarFolderMatcher.match(
            files: [f("anna_maria.JPG"), f("ASA.png"), f("Alex.jpg"), f("nobody.jpg"), f("notes.txt"), f("Solo.heic"), f("solo.png")],
            entries: entries)
        #expect(Set(r.matches.map(\.entryID)) == [anna.id, asa.id, solo.id])
        #expect(r.unmatchedFiles.map(\.lastPathComponent).sorted() == ["Alex.jpg", "nobody.jpg", "solo.png"],
                "ambiguous 'Alex', the stranger, and a second picture for the same entry stay unmatched; notes.txt isn't an image")
        #expect(r.ambiguousLabels == ["Alex"])
        #expect(Set(r.entriesWithoutPhoto) == [alex1.id, alex2.id])
    }

    @Test("Crop: centred without a face, on the face with one, never outside the picture")
    func cropGeometry() {
        let plain = AvatarCrop.squareRect(imageWidth: 400, imageHeight: 300, face: nil)
        #expect(plain == CGRect(x: 50, y: 0, width: 300, height: 300))
        let face = CGRect(x: 20, y: 30, width: 40, height: 50)                 // near the top-left corner
        let r = AvatarCrop.squareRect(imageWidth: 400, imageHeight: 300, face: face)
        #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 400 && r.maxY <= 300)
        #expect(r.width == r.height && abs(r.width - 110) < 0.001)             // 2.2 × the larger face edge
        #expect(r.contains(face), "the face must be inside its own crop")
        let big = AvatarCrop.squareRect(imageWidth: 100, imageHeight: 100, face: CGRect(x: 10, y: 10, width: 90, height: 90))
        #expect(big.width == 100, "capped at the picture's shorter side")
    }
}

@Suite("Avatar store")
struct AvatarStoreTests {

    @Test("A photo is copied in, square, downsampled to 256 px, as a JPEG named by a UUID")
    func importDownsamples() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let roster = UUID()
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AvatarFixtures.png(width: 1600, height: 900).write(to: source)

        let name = try store.importPhoto(from: source, rosterID: roster)
        #expect(AvatarFileName.isValid(name))
        let stored = try #require(store.url(for: name, rosterID: roster))
        let image = try #require(store.loadImage(fileName: name, rosterID: roster, maxPixel: 1024))
        #expect(image.width == 256 && image.height == 256)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(try Data(contentsOf: stored).count < 60_000, "a 256-px JPEG is well under 60 KB")
        #expect(FileManager.default.fileExists(atPath: source.path), "the original is never touched")
    }

    @Test("Face detection never blocks an import: a picture with no face still imports, within the timeout")
    func faceDetectionDoesNotBlock() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: true, faceTimeout: 3)
        let started = Date()
        let name = try store.importPhoto(data: AvatarFixtures.png(width: 600, height: 400), rosterID: UUID())
        #expect(AvatarFileName.isValid(name))
        #expect(Date().timeIntervalSince(started) < 8, "the import waited on Vision far longer than the timeout")
    }

    @Test("A picture past the pixel limit is refused from its header, before any decode")
    func tooManyPixels() throws {
        // The production limit is 100 MP; lowering it here lets a small real file stand in for a bomb.
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, pixelLimit: 10_000, detectFaces: false)
        #expect(throws: AvatarStore.AvatarError.tooManyPixels) {
            _ = try store.importPhoto(data: AvatarFixtures.png(width: 200, height: 200), rosterID: UUID())   // 40 000 px
        }
        #expect(!FileManager.default.fileExists(atPath: root.path), "nothing is written for a refused picture")
        #expect(AvatarStore.maxPixels == 100_000_000 && AvatarStore.maxFileBytes == 50_000_000)
        _ = try store.importPhoto(data: AvatarFixtures.png(width: 90, height: 90), rosterID: UUID())        // 8 100 px — fine
    }

    @Test("Something that isn't a picture is refused")
    func notAnImage() throws {
        let store = AvatarStore(rootURL: AvatarFixtures.tempRoot(), detectFaces: false)
        #expect(throws: AvatarStore.AvatarError.notAnImage) {
            _ = try store.importPhoto(data: Data("hello, I am text".utf8), rosterID: UUID())
        }
    }

    @Test("A stored name can never resolve outside the roster's folder")
    func pathContainment() {
        let store = AvatarStore(rootURL: AvatarFixtures.tempRoot(), detectFaces: false)
        let roster = UUID()
        #expect(store.url(for: "\(UUID().uuidString).jpg", rosterID: roster) != nil)
        for bad in ["../../etc/passwd", "../\(UUID().uuidString).jpg", "/etc/passwd", "x.jpg", "", "..", "\(UUID().uuidString).jpg/../../x.jpg"] {
            #expect(store.url(for: bad, rosterID: roster) == nil, "resolved \(bad)")
            #expect(store.loadImage(fileName: bad, rosterID: roster, maxPixel: 64) == nil)
        }
        #expect(AvatarStore.isInside(URL(fileURLWithPath: "/a/b/c"), URL(fileURLWithPath: "/a/b")))
        #expect(!AvatarStore.isInside(URL(fileURLWithPath: "/a/bc"), URL(fileURLWithPath: "/a/b")), "a look-alike sibling is not inside")
        #expect(!AvatarStore.isInside(URL(fileURLWithPath: "/a/b/../x"), URL(fileURLWithPath: "/a/b")))
    }

    @Test("Deleting a photo, a roster's photos, or everything removes only Halo's own files")
    func deletion() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let r1 = UUID(), r2 = UUID()
        let a = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: r1)
        let b = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: r1)
        let c = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: r2)
        let outsider = root.deletingLastPathComponent().appendingPathComponent("halo-bystander-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outsider); defer { try? FileManager.default.removeItem(at: outsider) }

        store.delete(fileName: a, rosterID: r1)
        #expect(store.url(for: a, rosterID: r1).map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(store.url(for: b, rosterID: r1).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        store.deleteAll(rosterID: r1)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: r1).path))
        #expect(store.url(for: c, rosterID: r2).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(store.totalBytes() > 0)
        store.deleteEverything()
        #expect(store.totalBytes() == 0)
        #expect(FileManager.default.fileExists(atPath: outsider.path), "a file outside the avatars root is never touched")
    }

    @Test("The orphan sweep removes unreferenced photos and unknown roster folders, and nothing else")
    func orphanSweep() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let live = UUID(), gone = UUID()
        let kept = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: live)
        let orphan = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: live)
        _ = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: gone)
        let stray = store.directory(for: live).appendingPathComponent("notes.txt")      // not Halo's naming
        try Data("mine".utf8).write(to: stray)

        let removed = store.sweepOrphans(referenced: [live: [kept]])
        #expect(removed == 2)
        #expect(store.url(for: kept, rosterID: live).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(store.url(for: orphan, rosterID: live).map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: gone).path))
        #expect(FileManager.default.fileExists(atPath: stray.path), "a file that doesn't match Halo's naming is left alone")
    }

    @Test("A copied photo is a new file in the target roster")
    func copy() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let from = UUID(), to = UUID()
        let name = try store.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: from)
        let copied = try #require(store.copyPhoto(fileName: name, from: from, to: to))
        #expect(copied != name)
        #expect(store.loadImage(fileName: copied, rosterID: to, maxPixel: 256) != nil)
        #expect(store.copyPhoto(fileName: "../x", from: from, to: to) == nil)
    }
}

@MainActor
@Suite("Lucky Draw store avatars")
struct LuckyDrawStoreAvatarTests {

    private final class Scratch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-draw-av-\(UUID().uuidString)", isDirectory: true)
        var file: URL { dir.appendingPathComponent("luckyDraw.json") }
        init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: dir) }
        @MainActor func store() -> LuckyDrawStore { LuckyDrawStore(fileURL: file, notificationCenter: NotificationCenter(), detectFaces: false) }
    }

    private func photoCount(_ store: LuckyDrawStore, _ roster: UUID) -> Int {
        let dir = store.avatarStore!.directory(for: roster)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    private func importPhoto(_ store: LuckyDrawStore, for entry: DrawEntry) async throws {
        let src = store.avatarStore!.rootURL.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AvatarFixtures.png(width: 400, height: 400).write(to: src)
        try await store.setPhoto(from: src, for: entry)
    }

    @Test("Setting an emoji, replacing it with a photo, then another photo leaves exactly one file")
    func replaceRemovesTheOldPhoto() async throws {
        let s = Scratch(); let store = s.store()
        let roster = store.selected!.id
        let entry = store.selected!.entries[0]

        store.setAvatar(.emoji("🦊"), for: entry)
        #expect(store.selected!.entries[0].avatar == .emoji("🦊"))
        try await importPhoto(store, for: entry)
        #expect(photoCount(store, roster) == 1)
        try await importPhoto(store, for: entry)
        #expect(photoCount(store, roster) == 1, "the first photo must be deleted when it is replaced")
        store.setAvatar(nil, for: entry)
        #expect(photoCount(store, roster) == 0)
        #expect(store.selected!.entries[0].avatar == nil)
    }

    @Test("Removing an entry, clearing entries, and deleting a roster each remove their photos")
    func cascades() async throws {
        let s = Scratch(); let store = s.store()
        let first = store.selected!.id
        let e0 = store.selected!.entries[0], e1 = store.selected!.entries[1]
        try await importPhoto(store, for: e0); try await importPhoto(store, for: e1)
        #expect(photoCount(store, first) == 2)

        store.removeEntry(e0)
        #expect(photoCount(store, first) == 1)
        store.clearEntries()
        #expect(photoCount(store, first) == 0)

        store.addRoster(named: "Second")
        let second = store.selected!.id
        store.addEntries(from: "Zed")
        try await importPhoto(store, for: store.selected!.entries[0])
        #expect(photoCount(store, second) == 1)
        store.deleteSelected()
        #expect(!FileManager.default.fileExists(atPath: store.avatarStore!.directory(for: second).path))
    }

    @Test("Duplicating a roster copies photos into the copy, and the two are independent")
    func duplicateCopiesPhotos() async throws {
        let s = Scratch(); let store = s.store()
        let original = store.selected!.id
        try await importPhoto(store, for: store.selected!.entries[0])
        store.setAvatar(.emoji("🐼"), for: store.selected!.entries[1])

        store.duplicateSelected()
        let copy = try #require(store.selected)
        #expect(copy.id != original)
        let photo = try #require(copy.entries[0].avatar?.photoFileName)
        #expect(store.avatarStore!.loadImage(fileName: photo, rosterID: copy.id, maxPixel: 64) != nil)
        #expect(copy.entries[1].avatar == .emoji("🐼"))
        #expect(copy.avatarDisplay == store.rosters.first { $0.id == original }?.avatarDisplay)

        store.deleteSelected()                                      // the copy goes…
        #expect(photoCount(store, original) == 1, "…and the original's photo is untouched")
    }

    @Test("Avatars persist across a relaunch")
    func persists() async throws {
        let s = Scratch(); let store = s.store()
        let entry = store.selected!.entries[0]
        try await importPhoto(store, for: entry)
        store.setAvatar(.emoji("🚀"), for: store.selected!.entries[1])
        store.setAvatarDisplay(.avatarOnly)
        store.flushToDisk()

        let reopened = s.store()
        #expect(reopened.selected!.entries[0].avatar?.isPhoto == true)
        #expect(reopened.selected!.entries[1].avatar == .emoji("🚀"))
        #expect(reopened.selected!.avatarDisplay == .avatarOnly)
    }

    @Test("The orphan sweep runs after a clean load — and never after an unreadable roster file")
    func sweepIsSafe() async throws {
        let s = Scratch()
        do {
            let store = s.store()
            try await importPhoto(store, for: store.selected!.entries[0])
            store.flushToDisk()
        }
        let root = s.dir.appendingPathComponent("luckydraw/avatars")
        let stray = root.appendingPathComponent("\(UUID().uuidString)/\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray)

        // Corrupt the roster file: the photos must survive, because "unreadable" is not "unreferenced".
        try Data("{ not json".utf8).write(to: s.file)
        _ = s.store()
        try await Task.sleep(nanoseconds: 400_000_000)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(survivors.count == 2, "a failed read must not trigger a sweep (found \(survivors.count) roster folders)")
    }

    @Test("Clearing all photos removes the files and un-points every entry")
    func clearAll() async throws {
        let s = Scratch(); let store = s.store()
        let roster = store.selected!.id
        try await importPhoto(store, for: store.selected!.entries[0])
        store.setAvatar(.emoji("🐸"), for: store.selected!.entries[1])
        store.clearAllPhotos()
        #expect(photoCount(store, roster) == 0)
        #expect(store.selected!.entries[0].avatar == nil)
        #expect(store.selected!.entries[1].avatar == .emoji("🐸"), "emoji avatars have no file and are kept")
    }

    @Test("A photo imported for an entry that vanished meanwhile is not left behind")
    func vanishedEntryLeavesNoOrphan() async throws {
        let s = Scratch(); let store = s.store()
        let roster = store.selected!.id
        let ghost = DrawEntry(label: "Ghost")                       // never added to the roster
        let name = "\(UUID().uuidString).jpg"
        let dest = try #require(store.avatarStore!.url(for: name, rosterID: roster))
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: dest)
        store.setAvatar(.photo(fileName: name), for: ghost, inRoster: roster)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}

@Suite("Avatars never influence the draw")
struct DrawFairnessWithAvatarsTests {

    @Test("The same seed picks the same winner whether or not entries carry avatars")
    func sameSeedSameWinner() {
        let plain = (0..<12).map { DrawEntry(label: "N\($0)") }
        let adorned = plain.map { DrawEntry(id: $0.id, label: $0.label,
                                            avatar: .emoji("🦊")) }
        for seed in UInt64(1)...200 {
            var a = DrawEngineTests.SeededGenerator(seed: seed), b = DrawEngineTests.SeededGenerator(seed: seed)
            let p1 = DrawEngine.plan(eligibleCount: plain.count, currentAngle: 0, duration: 5,
                                     idForIndex: { plain[$0].id }, using: &a)
            let p2 = DrawEngine.plan(eligibleCount: adorned.count, currentAngle: 0, duration: 5,
                                     idForIndex: { adorned[$0].id }, using: &b)
            #expect(p1?.winnerIndex == p2?.winnerIndex)
            #expect(p1?.targetAngle == p2?.targetAngle)
            #expect(p1?.winnerID == p2?.winnerID)
        }
    }

    @Test("Eligibility ignores avatars")
    func eligibilityIgnoresAvatars() {
        let e = DrawEntry(label: "A", avatar: .emoji("🦊"))
        #expect(e.isEligible)
        #expect(DrawEntry(label: "A", isExcluded: true, avatar: .emoji("🦊")).isEligible == false)
        #expect(DrawRoster(name: "r", entries: [e, DrawEntry(label: "B")]).eligible.count == 2)
    }
}

// MARK: - F-053 independent review regressions

@Suite("Avatar store — symlink containment")
struct AvatarSymlinkTests {

    /// A real stored photo (made by a throwaway store elsewhere) that lives *outside* the avatars root.
    private func outsidePhoto() throws -> (dir: URL, name: String, file: URL) {
        let other = AvatarStore(rootURL: AvatarFixtures.tempRoot(), detectFaces: false)
        let r = UUID()
        let name = try other.importPhoto(data: AvatarFixtures.png(width: 300, height: 300), rosterID: r)
        let file = try #require(other.url(for: name, rosterID: r))
        return (file.deletingLastPathComponent(), name, file)
    }

    @Test("A roster folder that is a symlink out of the root is never read, swept, deleted or written through")
    func symlinkedRosterFolder() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let victim = try outsidePhoto(); defer { try? FileManager.default.removeItem(at: victim.dir) }
        let roster = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.directory(for: roster), withDestinationURL: victim.dir)

        #expect(store.url(for: victim.name, rosterID: roster) == nil, "resolved a path through a symlinked roster folder")
        #expect(store.loadImage(fileName: victim.name, rosterID: roster, maxPixel: 64) == nil)

        store.delete(fileName: victim.name, rosterID: roster)
        #expect(FileManager.default.fileExists(atPath: victim.file.path), "delete followed the symlink")

        store.sweepOrphans(referenced: [roster: []])
        #expect(FileManager.default.fileExists(atPath: victim.file.path), "the orphan sweep followed the symlink")

        let target = UUID()
        try FileManager.default.createSymbolicLink(at: store.directory(for: target), withDestinationURL: victim.dir)
        let before = try FileManager.default.contentsOfDirectory(atPath: victim.dir.path).count
        #expect(store.copyPhoto(fileName: victim.name, from: roster, to: target) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: victim.dir.path).count == before, "a copy was written outside the root")

        store.sweepOrphans(referenced: [:])                                  // unknown roster: the folder goes ...
        store.deleteAll(rosterID: roster)
        store.deleteEverything()
        #expect(FileManager.default.fileExists(atPath: victim.file.path), "... but only the link, never what it points at")
    }

    @Test("A photo file that is a symlink is never read through; the sweep removes the link, not its target")
    func symlinkedPhotoFile() throws {
        let root = AvatarFixtures.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let victim = try outsidePhoto(); defer { try? FileManager.default.removeItem(at: victim.dir) }
        let roster = UUID()
        let dir = store.directory(for: roster)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(victim.name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim.file)

        #expect(store.loadImage(fileName: victim.name, rosterID: roster, maxPixel: 64) == nil, "read an arbitrary file through a link")
        store.sweepOrphans(referenced: [roster: []])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil, "the link should be swept")
        #expect(FileManager.default.fileExists(atPath: victim.file.path), "the target must survive")
    }
}

@Suite("Avatar emoji — bounded")
struct AvatarEmojiBoundTests {
    @Test("One grapheme is not enough: a pile of combining marks on an emoji is refused")
    func zalgoEmoji() throws {
        let pile = "🙂" + String(repeating: "\u{0301}", count: 500)
        #expect(pile.count == 1, "premise: Swift sees this as a single Character")
        #expect(!EmojiValidation.isSingleEmoji(pile))
        #expect(EmojiValidation.isSingleEmoji("👩🏽‍❤️‍💋‍👨🏿"), "the longest real sequences still pass")
        #expect(EmojiValidation.isSingleEmoji("🏴󠁧󠁢󠁥󠁮󠁧󠁿"))
        let data = Data("{\"id\":\"\(UUID())\",\"label\":\"A\",\"avatar\":{\"kind\":\"emoji\",\"value\":\"\(pile)\"}}".utf8)
        #expect(try JSONDecoder().decode(DrawEntry.self, from: data).avatar == nil)
    }
}
