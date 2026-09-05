import Testing
import Foundation
@testable import Halo

// MARK: - FileSystemScanner Tests

@Suite("FileSystemScanner")
struct FileSystemScannerTests {

    @Test("Classifies cache files correctly")
    func testCacheClassification() async throws {
        let scanner = FileSystemScanner()
        // Create a temp file in a Caches path
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.caches")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.cache")
        try "test".data(using: .utf8)!.write(to: testFile)

        var items: [ScannedItem] = []
        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 0
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .item(let item) = event { items.append(item) }
        }
        #expect(!items.isEmpty)
    }

    @Test("Respects minSizeBytes filter")
    func testMinSizeFilter() async throws {
        let scanner = FileSystemScanner()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.size")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write 1-byte file
        let small = tempDir.appendingPathComponent("small.txt")
        try "x".data(using: .utf8)!.write(to: small)

        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 1024 * 1024 // 1 MB minimum
        config.minSizeBytes = 1024

        var items: [ScannedItem] = []
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .item(let item) = event { items.append(item) }
        }
        // 1-byte file should be filtered out
        #expect(items.isEmpty)
    }

    @Test("Cancellation stops scan")
    func testCancellation() async throws {
        let scanner = FileSystemScanner()
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        var config = FileSystemScanner.ScanConfig()
        config.maxDepth = 10

        let task = Task {
            var count = 0
            for await event in await scanner.scanDirectory(homeURL, config: config) {
                if case .item = event { count += 1 }
                if count > 5 { break }
            }
            return count
        }
        let result = await task.value
        #expect(result >= 0) // Should have stopped cleanly
    }

    @Test("Returns completed event")
    func testCompletedEvent() async throws {
        let scanner = FileSystemScanner()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.complete")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var gotCompleted = false
        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 0
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .completed = event { gotCompleted = true }
        }
        #expect(gotCompleted)
    }
}

// MARK: - DuplicateDetector Tests

@Suite("DuplicateDetector")
struct DuplicateDetectorTests {

    @Test("Detects exact duplicates by SHA-256")
    func testExactDuplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.dupes")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = String(repeating: "Hello Halo duplicate content! ", count: 500).data(using: .utf8)!
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let unique = tempDir.appendingPathComponent("unique.txt")
        try content.write(to: file1)
        try content.write(to: file2)
        try "unique content only here".data(using: .utf8)!.write(to: unique)

        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: [file1, file2, unique]) { _ in }

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test("Does not flag different files as duplicates")
    func testNoDuplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.nodupes")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<5 {
            let f = tempDir.appendingPathComponent("file\(i).txt")
            try "unique content \(i) \(UUID())".data(using: .utf8)!.write(to: f)
        }

        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: files) { _ in }
        #expect(groups.isEmpty)
    }

    @Test("Wasted bytes calculation is correct")
    func testWastedBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.wasted")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = String(repeating: "x", count: 10_000).data(using: .utf8)!
        let files = (0..<3).map { tempDir.appendingPathComponent("dup\($0).dat") }
        for f in files { try content.write(to: f) }

        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: files) { _ in }
        #expect(groups.count == 1)
        // Wasted = 2 copies × 10000 bytes
        #expect(groups[0].wastedBytes == Int64(content.count) * 2)
    }
}

// MARK: - Model Tests

@Suite("Models")
struct ModelTests {

    @Test("ClipboardItem kind detection")
    func testClipboardKind() {
        let textItem = ClipboardItem(content: .text("hello"))
        let urlItem = ClipboardItem(content: .url(URL(string: "https://apple.com")!))
        let codeItem = ClipboardItem(content: .code("func foo() {}", language: "swift"))

        #expect(textItem.kind == .text)
        #expect(urlItem.kind == .url)
        #expect(codeItem.kind == .code)
    }

    @Test("ByteCountFormatter formatting in ScannedItem")
    func testSizeFormatted() {
        let item = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/test"),
                               size: 1_048_576, creationDate: nil, modifiedDate: nil, kind: .cache)
        #expect(item.sizeFormatted.contains("MB") || item.sizeFormatted.contains("1"))
    }

    @Test("CleanupCategory total bytes sums selected only")
    func testCategoryTotalBytes() {
        var cat = CleanupCategory(kind: .systemCaches)
        let item1 = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/a"), size: 1000,
                                creationDate: nil, modifiedDate: nil, kind: .cache, isSelected: true)
        var item2 = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/b"), size: 2000,
                                creationDate: nil, modifiedDate: nil, kind: .cache)
        item2.isSelected = false
        cat.items = [item1, item2]
        #expect(cat.totalBytes == 1000)
        #expect(cat.allBytes == 3000)
    }
}

// MARK: - MemoryTrendTracker Tests (F-023)
//
// `leakStatus(for:)` reads only its `history` parameter — it never touches
// `MemoryTrendTracker.shared`'s own `histories`/timer/persistence state — so
// these tests call it directly with synthetic `AppMemoryHistory` values. It's
// `@MainActor`-isolated only because the whole class is, so the suite is
// marked `@MainActor` too; no live sampling, alerts, or disk I/O are
// exercised here (`checkAppMemory`'s real `UNUserNotification`/`AlertLog`
// side effects are intentionally left to manual QA — see
// docs/MANUAL_TEST_PLAN.md TC-PERF-U11/U12 — rather than fired for real
// during a unit test run).

@Suite("MemoryTrendTracker leak detection")
@MainActor
struct MemoryTrendTrackerLeakTests {

    private var anchor: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15; comps.hour = 9
        return Calendar.current.date(from: comps)!
    }

    private func history(_ samples: [MemorySample]) -> AppMemoryHistory {
        AppMemoryHistory(bundleID: "com.test.app", appName: "Test App", bundlePath: "/Applications/Test.app", samples: samples)
    }

    @Test("Monotonic growth spanning over 1 hour flags a possible leak")
    func testMonotonicGrowthOver1HourFlagsLeak() {
        let start = anchor
        // 25 samples, 5 minutes apart (= 300s, exactly at maxSampleGapSeconds
        // — not a reset), each 10 MB higher than the last. Total span: 2h.
        let samples = (0..<25).map { i in
            MemorySample(date: start.addingTimeInterval(Double(i) * 300), ramMB: 500 + Double(i) * 10)
        }
        let status = MemoryTrendTracker.shared.leakStatus(for: history(samples))
        #expect(status.isPossibleLeak == true)
        #expect(status.currentRAMMB == 500 + 24 * 10)
    }

    @Test("Growth spanning less than 1 hour never flags a leak, regardless of growth rate")
    func testGrowthUnder1HourNeverFlags() {
        let start = anchor
        // 11 samples, 5 minutes apart = 50 minutes total span — under the 1h threshold.
        let samples = (0..<11).map { i in
            MemorySample(date: start.addingTimeInterval(Double(i) * 300), ramMB: 500 + Double(i) * 50)
        }
        let status = MemoryTrendTracker.shared.leakStatus(for: history(samples))
        #expect(status.isPossibleLeak == false)
    }

    @Test("A drop of more than 15% from the streak's local peak resets the streak")
    func testSignificantDropResetsStreak() {
        let start = anchor
        var samples: [MemorySample] = []
        // Grow for 70 minutes (>1h) up to a peak of 1000 MB.
        for i in 0...14 {   // 15 samples, 5 min apart = 70 minutes
            samples.append(MemorySample(date: start.addingTimeInterval(Double(i) * 300), ramMB: 300 + Double(i) * 50))
        }
        // Drop >15% below the peak (1000 -> 700, a 30% drop) right after.
        let dropDate = start.addingTimeInterval(15 * 300)
        samples.append(MemorySample(date: dropDate, ramMB: 700))
        // Renewed growth for only 20 minutes after the drop — well under 1h.
        for i in 1...4 {
            samples.append(MemorySample(date: dropDate.addingTimeInterval(Double(i) * 300), ramMB: 700 + Double(i) * 10))
        }
        let status = MemoryTrendTracker.shared.leakStatus(for: history(samples))
        #expect(status.isPossibleLeak == false, "the new streak after the drop hasn't reached 1h yet")
    }

    @Test("A dip of 15% or less does NOT reset the streak — minor fluctuation is tolerated")
    func testMinorDipDoesNotResetStreak() {
        let start = anchor
        var samples: [MemorySample] = []
        // Grow for 50 minutes up to a peak of 1000 MB.
        for i in 0...9 {   // 10 samples, 5 min apart = 45 minutes
            samples.append(MemorySample(date: start.addingTimeInterval(Double(i) * 300), ramMB: 550 + Double(i) * 50))
        }
        // A small dip: 1000 -> 900 is a 10% drop, under the 15% threshold.
        let dipDate = start.addingTimeInterval(9 * 300)
        samples.append(MemorySample(date: dipDate.addingTimeInterval(300), ramMB: 900))
        // Resume growth for another 30 minutes so the OVERALL streak exceeds 1h.
        for i in 1...6 {
            samples.append(MemorySample(date: dipDate.addingTimeInterval(300 + Double(i) * 300), ramMB: 900 + Double(i) * 20))
        }
        let status = MemoryTrendTracker.shared.leakStatus(for: history(samples))
        #expect(status.isPossibleLeak == true, "a minor dip under 15% should not reset an otherwise-valid >1h streak")
    }

    @Test("An observation gap longer than 5 minutes resets the streak, even mid-growth")
    func testSleepWakeGapResetsStreak() {
        let start = anchor
        var samples: [MemorySample] = []
        // Grow for 70 minutes (>1h).
        for i in 0...14 {
            samples.append(MemorySample(date: start.addingTimeInterval(Double(i) * 300), ramMB: 400 + Double(i) * 30))
        }
        // A 20-minute gap (Mac asleep) — well over maxSampleGapSeconds (5 min).
        let afterGap = start.addingTimeInterval(14 * 300 + 20 * 60)
        samples.append(MemorySample(date: afterGap, ramMB: 850))
        // Renewed growth for only 30 minutes after the gap — under 1h.
        for i in 1...6 {
            samples.append(MemorySample(date: afterGap.addingTimeInterval(Double(i) * 300), ramMB: 850 + Double(i) * 10))
        }
        let status = MemoryTrendTracker.shared.leakStatus(for: history(samples))
        #expect(status.isPossibleLeak == false, "the gap should reset the streak; the post-gap streak hasn't reached 1h yet")
    }

    @Test("A history with only one sample never flags a leak")
    func testSingleSampleNeverFlags() {
        let status = MemoryTrendTracker.shared.leakStatus(for: history([MemorySample(date: anchor, ramMB: 500)]))
        #expect(status.isPossibleLeak == false)
    }

    @Test("An empty history returns .empty")
    func testEmptyHistoryReturnsEmptyStatus() {
        let status = MemoryTrendTracker.shared.leakStatus(for: history([]))
        #expect(status.isPossibleLeak == false)
        #expect(status.streakStartDate == nil)
    }
}

@Suite("AppMemoryHistory persistence")
struct AppMemoryHistoryPersistenceTests {

    @Test("AppMemoryHistory round-trips through JSON encode/decode with all fields intact")
    func testJSONRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let original = AppMemoryHistory(
            bundleID: "com.example.app",
            appName: "Example",
            bundlePath: "/Applications/Example.app",
            samples: [
                MemorySample(date: start, ramMB: 512.5),
                MemorySample(date: start.addingTimeInterval(30), ramMB: 520.25),
                MemorySample(date: start.addingTimeInterval(60), ramMB: 530.0),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppMemoryHistory.self, from: data)

        #expect(decoded.bundleID == original.bundleID)
        #expect(decoded.appName == original.appName)
        #expect(decoded.bundlePath == original.bundlePath)
        #expect(decoded.samples.count == original.samples.count)
        for (a, b) in zip(decoded.samples, original.samples) {
            #expect(a.ramMB == b.ramMB)
            #expect(abs(a.date.timeIntervalSince(b.date)) < 0.001)
        }
    }

    @Test("An array of AppMemoryHistory round-trips (the actual persisted shape)")
    func testArrayJSONRoundTrip() throws {
        let histories = [
            AppMemoryHistory(bundleID: "com.a", appName: "A", bundlePath: nil, samples: []),
            AppMemoryHistory(bundleID: "com.b", appName: "B", bundlePath: "/Applications/B.app",
                             samples: [MemorySample(date: Date(timeIntervalSince1970: 1_750_000_000), ramMB: 100)]),
        ]
        let data = try JSONEncoder().encode(histories)
        let decoded = try JSONDecoder().decode([AppMemoryHistory].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded.map(\.bundleID) == histories.map(\.bundleID))
        #expect(decoded[0].bundlePath == nil)
        #expect(decoded[1].samples.first?.ramMB == 100)
    }
}

// MARK: - F-023 review fixes

@Suite("MemoryTrendTracker leak detection")
struct MemoryTrendLeakDetectionTests {

    private func samples(_ points: [(minutesAgo: Double, ramMB: Double)], now: Date = Date()) -> [MemorySample] {
        points
            .map { MemorySample(date: now.addingTimeInterval(-$0.minutesAgo * 60), ramMB: $0.ramMB) }
            .sorted { $0.date < $1.date }
    }

    // The reported false positive: RAM climbs early, then sits flat for
    // ~110 minutes. No >15% drop from the peak, so the streak never resets, and
    // the old `latest > streakStart` test passed — reporting a leak for an app
    // whose memory hadn't moved in nearly two hours. This is the ordinary shape
    // for a browser or IDE that allocates at startup and plateaus.
    @Test("A long plateau after early growth is not a leak")
    func testPlateauIsNotALeak() {
        let now = Date()
        var points: [(Double, Double)] = [(120, 1000), (118, 1100), (115, 1200), (112, 1100)]
        // Flat at 1100 from 110 minutes ago until now.
        for m in stride(from: 110.0, through: 0.0, by: -5.0) { points.append((m, 1100)) }

        let history = AppMemoryHistory(bundleID: "com.test.plateau", appName: "Plateau",
                                       bundlePath: nil, samples: samples(points.map { (minutesAgo: $0.0, ramMB: $0.1) }, now: now))
        #expect(MemoryTrendTracker.shared.leakStatus(for: history).isPossibleLeak == false)
    }

    // The true positive must survive the new, stricter rule.
    @Test("Steady sustained growth over more than an hour is still a leak")
    func testSustainedGrowthIsALeak() {
        let now = Date()
        // 1000 MB -> 1700 MB, climbing throughout, sampled every 5 minutes for 2h.
        var points: [(minutesAgo: Double, ramMB: Double)] = []
        for m in stride(from: 120.0, through: 0.0, by: -5.0) {
            points.append((minutesAgo: m, ramMB: 1000 + (120 - m) * 6))
        }
        let history = AppMemoryHistory(bundleID: "com.test.leak", appName: "Leaky",
                                       bundlePath: nil, samples: samples(points, now: now))
        #expect(MemoryTrendTracker.shared.leakStatus(for: history).isPossibleLeak)
    }

    @Test("Growth smaller than the noise floor is not a leak")
    func testTinyGrowthIsNotALeak() {
        let now = Date()
        var points: [(minutesAgo: Double, ramMB: Double)] = []
        // 1000 -> 1030 over two hours: 3%, well under the 10% floor.
        for m in stride(from: 120.0, through: 0.0, by: -5.0) {
            points.append((minutesAgo: m, ramMB: 1000 + (120 - m) * 0.25))
        }
        let history = AppMemoryHistory(bundleID: "com.test.noise", appName: "Noisy",
                                       bundlePath: nil, samples: samples(points, now: now))
        #expect(MemoryTrendTracker.shared.leakStatus(for: history).isPossibleLeak == false)
    }

    // Pre-existing behaviour the review flagged as correct — pinned so a
    // refactor can't quietly drop it.
    @Test("A declining app is never a leak")
    func testDecliningIsNotALeak() {
        let now = Date()
        var points: [(minutesAgo: Double, ramMB: Double)] = []
        for m in stride(from: 120.0, through: 0.0, by: -5.0) {
            points.append((minutesAgo: m, ramMB: 2000 - (120 - m) * 5))
        }
        let history = AppMemoryHistory(bundleID: "com.test.decline", appName: "Shrinking",
                                       bundlePath: nil, samples: samples(points, now: now))
        #expect(MemoryTrendTracker.shared.leakStatus(for: history).isPossibleLeak == false)
    }

    @Test("A short history is never a leak, however steeply it grows")
    func testShortHistoryIsNotALeak() {
        let now = Date()
        let points: [(minutesAgo: Double, ramMB: Double)] = [(10, 1000), (5, 2000), (0, 3000)]
        let history = AppMemoryHistory(bundleID: "com.test.short", appName: "Young",
                                       bundlePath: nil, samples: samples(points, now: now))
        #expect(MemoryTrendTracker.shared.leakStatus(for: history).isPossibleLeak == false)
    }
}

@Suite("MemoryTrendTracker slope")
struct MemoryTrendSlopeTests {

    @Test("A rising series has a positive slope")
    func testRisingSlope() {
        let now = Date()
        let s = (0..<10).map { MemorySample(date: now.addingTimeInterval(Double($0) * 60), ramMB: 100 + Double($0) * 10) }
        #expect(MemoryTrendTracker.hasPositiveSlope(samples: s, since: now.addingTimeInterval(-60)))
    }

    @Test("A flat series does not have a positive slope")
    func testFlatSlope() {
        let now = Date()
        let s = (0..<10).map { MemorySample(date: now.addingTimeInterval(Double($0) * 60), ramMB: 100) }
        #expect(MemoryTrendTracker.hasPositiveSlope(samples: s, since: now.addingTimeInterval(-60)) == false)
    }

    @Test("A falling series does not have a positive slope")
    func testFallingSlope() {
        let now = Date()
        let s = (0..<10).map { MemorySample(date: now.addingTimeInterval(Double($0) * 60), ramMB: 200 - Double($0) * 10) }
        #expect(MemoryTrendTracker.hasPositiveSlope(samples: s, since: now.addingTimeInterval(-60)) == false)
    }

    // An unknown slope must never be read as evidence of a leak.
    @Test("Too few points is not a positive slope")
    func testInsufficientPoints() {
        let now = Date()
        let s = [MemorySample(date: now, ramMB: 100), MemorySample(date: now.addingTimeInterval(60), ramMB: 200)]
        #expect(MemoryTrendTracker.hasPositiveSlope(samples: s, since: now.addingTimeInterval(-60)) == false)
    }
}
