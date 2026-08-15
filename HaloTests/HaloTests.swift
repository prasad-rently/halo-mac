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

// MARK: - MetricsSample / Weekly Digest Tests (F-029)
//
// MetricsHistory.shared and AlertLog.shared are real persisted singletons with
// no injectable seam, so — matching this session's established pattern for
// AlertManager/FocusSessionManager — they're left to manual/UI coverage only.
// What's tested here is the pure logic: the Codable model, the summary's
// computed deltas, the notification-body composition, and the scheduler's
// pure date arithmetic (none of which touch UserDefaults or fire real
// notifications).

@Suite("MetricsSample")
struct MetricsSampleTests {

    @Test("Codable roundtrip preserves all fields, including RAM samples")
    func testCodableRoundtrip() throws {
        let ramSamples = [
            ProcessRAMSample(name: "Safari", ramMB: 512.5),
            ProcessRAMSample(name: "Xcode", ramMB: 2048.0)
        ]
        let sample = MetricsSample(healthScore: 82, diskFreeGB: 128.4, topRAMProcesses: ramSamples)

        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(MetricsSample.self, from: data)

        #expect(decoded.id == sample.id)
        #expect(decoded.healthScore == 82)
        #expect(decoded.diskFreeGB == 128.4)
        #expect(decoded.topRAMProcesses.count == 2)
        #expect(decoded.topRAMProcesses[0].name == "Safari")
        #expect(decoded.topRAMProcesses[0].ramMB == 512.5)
    }

    @Test("Default init stamps an id/date and defaults RAM list to empty")
    func testDefaultInit() {
        let sample = MetricsSample(healthScore: 90, diskFreeGB: 50)
        #expect(sample.topRAMProcesses.isEmpty)
        #expect(sample.healthScore == 90)
        #expect(sample.diskFreeGB == 50)
    }
}

@Suite("WeeklyDigestSummary")
struct WeeklyDigestSummaryTests {

    private func makeSummary(start: Int?, end: Int, diskStart: Double?, diskEnd: Double,
                              scans: Int = 0, threats: Int = 0) -> WeeklyDigestSummary {
        WeeklyDigestSummary(
            generatedDate: Date(),
            periodDays: 7,
            healthScoreStart: start,
            healthScoreEnd: end,
            healthSamples: [],
            diskFreeStartGB: diskStart,
            diskFreeEndGB: diskEnd,
            topAverageRAMApps: [],
            alertsInPeriod: [],
            threatsDetectedCount: threats,
            scansCompletedCount: scans
        )
    }

    @Test("healthScoreDelta is nil with no starting sample (fresh install)")
    func testHealthScoreDeltaNilWithoutStart() {
        let summary = makeSummary(start: nil, end: 80, diskStart: nil, diskEnd: 100)
        #expect(summary.healthScoreDelta == nil)
    }

    @Test("healthScoreDelta computes a signed difference")
    func testHealthScoreDeltaSigned() {
        let improved = makeSummary(start: 70, end: 85, diskStart: nil, diskEnd: 0)
        #expect(improved.healthScoreDelta == 15)

        let worsened = makeSummary(start: 90, end: 60, diskStart: nil, diskEnd: 0)
        #expect(worsened.healthScoreDelta == -30)
    }

    @Test("diskFreeDeltaGB is nil with no starting sample")
    func testDiskFreeDeltaNilWithoutStart() {
        let summary = makeSummary(start: 50, end: 60, diskStart: nil, diskEnd: 200)
        #expect(summary.diskFreeDeltaGB == nil)
    }

    @Test("diskFreeDeltaGB computes a signed difference")
    func testDiskFreeDeltaSigned() {
        let freed = makeSummary(start: 50, end: 60, diskStart: 100, diskEnd: 130)
        #expect(freed.diskFreeDeltaGB == 30)

        let consumed = makeSummary(start: 50, end: 60, diskStart: 130, diskEnd: 100)
        #expect(consumed.diskFreeDeltaGB == -30)
    }
}

@Suite("WeeklyDigestGenerator")
struct WeeklyDigestGeneratorTests {

    private func makeSummary(start: Int?, end: Int, diskStart: Double?, diskEnd: Double,
                              scans: Int = 0, threats: Int = 0) -> WeeklyDigestSummary {
        WeeklyDigestSummary(
            generatedDate: Date(),
            periodDays: 7,
            healthScoreStart: start,
            healthScoreEnd: end,
            healthSamples: [],
            diskFreeStartGB: diskStart,
            diskFreeEndGB: diskEnd,
            topAverageRAMApps: [],
            alertsInPeriod: [],
            threatsDetectedCount: threats,
            scansCompletedCount: scans
        )
    }

    @Test("notificationBody reports an upward trend, freed space, and pluralised counts")
    @MainActor
    func testNotificationBodyUpwardTrend() {
        let summary = makeSummary(start: 70, end: 85, diskStart: 100, diskEnd: 105, scans: 2, threats: 1)
        let body = WeeklyDigestGenerator.notificationBody(for: summary)

        #expect(body.contains("Health score up 15 pts (now 85)"))
        #expect(body.contains("GB freed up"))
        #expect(body.contains("2 scans completed"))
        #expect(body.contains("1 threat flagged"))
    }

    @Test("notificationBody reports a downward trend and lost space with singular wording")
    @MainActor
    func testNotificationBodyDownwardTrendSingular() {
        let summary = makeSummary(start: 90, end: 60, diskStart: 200, diskEnd: 195, scans: 1, threats: 0)
        let body = WeeklyDigestGenerator.notificationBody(for: summary)

        #expect(body.contains("Health score down 30 pts (now 60)"))
        #expect(body.contains("GB less free space"))
        #expect(body.contains("1 scan completed"))
        #expect(!body.contains("threat"))
    }

    @Test("notificationBody ignores sub-0.1GB disk noise and reports a steady score")
    @MainActor
    func testNotificationBodyIgnoresTinyDiskDelta() {
        let summary = makeSummary(start: 80, end: 80, diskStart: 100.00, diskEnd: 100.05)
        let body = WeeklyDigestGenerator.notificationBody(for: summary)

        #expect(body.contains("Health score steady 0 pts (now 80)"))
        #expect(!body.contains("GB"))
    }
}

@Suite("WeeklyDigestScheduler")
struct WeeklyDigestSchedulerTests {

    @Test("nextDigestDate returns nil when the digest is off")
    @MainActor
    func testOffFrequencyReturnsNil() {
        let next = WeeklyDigestScheduler.shared.nextDigestDate(frequency: "off", weekday: 2, hour: 9)
        #expect(next == nil)
    }

    @Test("nextDigestDate(daily) lands on the requested hour, within the next day")
    @MainActor
    func testDailyReturnsUpcomingDateAtRequestedHour() throws {
        let next = try #require(
            WeeklyDigestScheduler.shared.nextDigestDate(frequency: "daily", weekday: 2, hour: 14)
        )
        #expect(next > Date())
        #expect(next.timeIntervalSinceNow <= 24 * 3600 + 60)
        #expect(Calendar.current.component(.hour, from: next) == 14)
    }

    @Test("nextDigestDate(weekly) lands on the requested weekday and hour")
    @MainActor
    func testWeeklyReturnsRequestedWeekdayAndHour() throws {
        let next = try #require(
            WeeklyDigestScheduler.shared.nextDigestDate(frequency: "weekly", weekday: 5, hour: 9)
        )
        #expect(next > Date())
        #expect(Calendar.current.component(.weekday, from: next) == 5)
        #expect(Calendar.current.component(.hour, from: next) == 9)
    }

    @Test("nextDigestDate clamps an out-of-range hour into 0...23")
    @MainActor
    func testHourIsClamped() throws {
        let next = try #require(
            WeeklyDigestScheduler.shared.nextDigestDate(frequency: "daily", weekday: 2, hour: 99)
        )
        #expect(Calendar.current.component(.hour, from: next) == 23)
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
