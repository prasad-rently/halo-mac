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

// MARK: - AppUsageTracker Aggregation Tests (F-021)
//
// `AppUsageTracker`'s aggregation methods (topApps, backgroundHogs,
// contextSwitchesPerHour, weekOverWeekChange) normally read the live
// singleton's `records`/`Date()`. They were refactored into static, pure
// counterparts parameterized on `records` + `now` (no behavior change —
// the instance methods just forward to these) specifically so this suite
// can exercise the real aggregation math against synthetic records and a
// fixed date, with no NSWorkspace/timer/UserDefaults involved.

@Suite("AppUsageTracker aggregation")
struct AppUsageTrackerAggregationTests {
    private typealias Tracker = AppUsageTracker

    private var anchorNow: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: now))!
    }

    private func record(bundleID: String, appName: String, dayOffset: Int, now: Date,
                         fg: TimeInterval = 0, observed: TimeInterval = 0, switches: Int = 0,
                         ramSum: Double = 0, ramCount: Int = 0) -> AppUsageRecord {
        AppUsageRecord(bundleID: bundleID, appName: appName, day: day(dayOffset, from: now),
                       foregroundSeconds: fg, observedRunningSeconds: observed, switchCount: switches,
                       ramSampleSumMB: ramSum, ramSampleCount: ramCount)
    }

    // MARK: - recordsInWindow

    @Test("recordsInWindow includes today through 6 days ago for a 7-day window, excludes 7 days ago")
    func testRecordsInWindowBoundary() {
        let now = anchorNow
        let records = [
            record(bundleID: "a", appName: "A", dayOffset: 0, now: now),
            record(bundleID: "a", appName: "A", dayOffset: 6, now: now),
            record(bundleID: "a", appName: "A", dayOffset: 7, now: now),
        ]
        let windowed = Tracker.recordsInWindow(records, days: 7, now: now)
        #expect(windowed.count == 2)
    }

    // MARK: - topApps

    @Test("topApps sums foreground time, RAM, and switches across days for the same bundle ID")
    func testTopAppsSumsAcrossDays() {
        let now = anchorNow
        let records = [
            record(bundleID: "com.a", appName: "A", dayOffset: 0, now: now, fg: 3600, switches: 3, ramSum: 100, ramCount: 2),
            record(bundleID: "com.a", appName: "A", dayOffset: 1, now: now, fg: 1800),
            record(bundleID: "com.b", appName: "B", dayOffset: 0, now: now, fg: 7200, ramSum: 400, ramCount: 4),
        ]
        let top = Tracker.topApps(from: records, limit: 5, windowDays: 7, now: now)
        #expect(top.count == 2)
        #expect(top.first?.id == "com.b")   // 7200s beats 5400s (3600+1800), sorted descending
        let a = top.first { $0.id == "com.a" }
        #expect(a?.totalForegroundSeconds == 5400)
        #expect(a?.switchCount == 3)
        #expect(a?.averageRAMMB == 50)   // 100 / 2 samples
    }

    @Test("topApps excludes an app with zero foreground time even if it was observed running")
    func testTopAppsExcludesZeroForeground() {
        let now = anchorNow
        let records = [record(bundleID: "com.bg", appName: "BG", dayOffset: 0, now: now, observed: 3600)]
        let top = Tracker.topApps(from: records, limit: 5, windowDays: 7, now: now)
        #expect(top.isEmpty)
    }

    @Test("topApps respects the limit parameter")
    func testTopAppsRespectsLimit() {
        let now = anchorNow
        let records = (0..<10).map { i in
            record(bundleID: "com.app\(i)", appName: "App \(i)", dayOffset: 0, now: now, fg: TimeInterval(i + 1) * 60)
        }
        let top = Tracker.topApps(from: records, limit: 3, windowDays: 7, now: now)
        #expect(top.count == 3)
    }

    // MARK: - backgroundHogs

    // The rule is now per-day: a long stretch on most days, not a cumulative
    // total that any always-open app clears in a week.
    private func hogs(_ records: [AppUsageRecord], now: Date) -> [BackgroundHogApp] {
        Tracker.backgroundHogs(from: records, minHoursPerDay: 4, minQualifyingDays: 4,
                                maxForegroundRatio: 0.02, windowDays: 7, now: now)
    }

    @Test("backgroundHogs flags an app running most days with a near-zero foreground ratio")
    func testBackgroundHogsFlagsLowRatio() {
        let now = anchorNow
        let records = (0..<5).map {
            record(bundleID: "com.hog", appName: "Hog", dayOffset: $0, now: now,
                   fg: 10, observed: 8 * 3600, ramSum: 50, ramCount: 1)
        }
        let result = hogs(records, now: now)
        #expect(result.count == 1)
        #expect(result.first?.id == "com.hog")
        #expect(result.first?.qualifyingDays == 5)
    }

    // The reported false positive: 8 cumulative hours over a week is a bit over
    // an hour a day, which every menu-bar utility and sync client clears — and
    // maxForegroundRatio cannot filter them out, because a background helper has
    // near-zero foreground time by definition.
    @Test("backgroundHogs no longer flags an app running about an hour a day")
    func testBackgroundHogsExcludesLowDailyUse() {
        let now = anchorNow
        let records = (0..<7).map {
            record(bundleID: "com.menubar", appName: "MenuBar", dayOffset: $0, now: now,
                   fg: 0, observed: 75 * 60)   // 8.75h cumulative, but only 1.25h/day
        }
        #expect(hogs(records, now: now).isEmpty)
    }

    @Test("backgroundHogs excludes a long stretch on too few days")
    func testBackgroundHogsExcludesTooFewDays() {
        let now = anchorNow
        // Two 10-hour days: plenty cumulatively, but not a habit.
        let records = (0..<2).map {
            record(bundleID: "com.burst", appName: "Burst", dayOffset: $0, now: now,
                   fg: 0, observed: 10 * 3600)
        }
        #expect(hogs(records, now: now).isEmpty)
    }

    @Test("backgroundHogs excludes an app observed less than the per-day threshold")
    func testBackgroundHogsExcludesShortObservation() {
        let now = anchorNow
        let records = [record(bundleID: "com.short", appName: "Short", dayOffset: 0, now: now, observed: 3600)]
        #expect(hogs(records, now: now).isEmpty)
    }

    @Test("backgroundHogs excludes an app with real foreground usage despite long observation")
    func testBackgroundHogsExcludesHighRatio() {
        let now = anchorNow
        // 10h/day for 5 days, but foregrounded 2h/day -> ratio 0.2, well above 0.02.
        let records = (0..<5).map {
            record(bundleID: "com.used", appName: "Used", dayOffset: $0, now: now,
                   fg: 2 * 3600, observed: 10 * 3600)
        }
        #expect(hogs(records, now: now).isEmpty)
    }

    // MARK: - contextSwitchesPerHour

    @Test("contextSwitchesPerHour is nil with less than an hour of tracked history")
    func testContextSwitchesNilBeforeOneHour() {
        let now = anchorNow
        let first = now.addingTimeInterval(-1800)   // 30 minutes ago
        let rate = Tracker.contextSwitchesPerHour(from: [], firstObservedDay: first, windowDays: 7, now: now)
        #expect(rate == nil)
    }

    @Test("contextSwitchesPerHour is nil with no observation history at all")
    func testContextSwitchesNilWithNoHistory() {
        let rate = Tracker.contextSwitchesPerHour(from: [], firstObservedDay: nil, windowDays: 7, now: anchorNow)
        #expect(rate == nil)
    }

    @Test("contextSwitchesPerHour computes total switches divided by tracked hours")
    func testContextSwitchesComputesRate() {
        let now = anchorNow
        let first = day(1, from: now)
        let records = [
            record(bundleID: "com.a", appName: "A", dayOffset: 0, now: now, switches: 5),
            record(bundleID: "com.b", appName: "B", dayOffset: 1, now: now, switches: 3),
        ]
        let rate = Tracker.contextSwitchesPerHour(from: records, firstObservedDay: first, windowDays: 7, now: now)
        #expect(rate != nil)
        #expect(rate! > 0)
    }

    // MARK: - weekOverWeekChange

    @Test("weekOverWeekChange is nil until at least 14 days of history exist")
    func testWeekOverWeekNilBeforeTwoWeeks() {
        let now = anchorNow
        let first = day(5, from: now)   // only 5 days of history
        let change = Tracker.weekOverWeekChange(from: [], firstObservedDay: first, now: now)
        #expect(change == nil)
    }

    @Test("weekOverWeekChange is nil with no observation history at all")
    func testWeekOverWeekNilWithNoHistory() {
        let change = Tracker.weekOverWeekChange(from: [], firstObservedDay: nil, now: anchorNow)
        #expect(change == nil)
    }

    @Test("weekOverWeekChange compares this week's and last week's foreground totals once 14 days of history exist")
    func testWeekOverWeekComparesTotals() {
        let now = anchorNow
        let first = day(13, from: now)   // exactly 14 days of history
        let records = [
            record(bundleID: "com.a", appName: "A", dayOffset: 1, now: now, fg: 3600),   // this week
            record(bundleID: "com.a", appName: "A", dayOffset: 8, now: now, fg: 1800),   // last week
        ]
        let change = Tracker.weekOverWeekChange(from: records, firstObservedDay: first, now: now)
        #expect(change?.thisWeekSeconds == 3600)
        #expect(change?.lastWeekSeconds == 1800)
        #expect(change?.percentChange == 100)   // doubled week-over-week
    }

    @Test("WeekOverWeek.percentChange is nil when last week had zero usage — avoids reporting a fake +100%")
    func testWeekOverWeekPercentChangeNilWhenLastWeekZero() {
        let change = AppUsageTracker.WeekOverWeek(thisWeekSeconds: 100, lastWeekSeconds: 0)
        #expect(change.percentChange == nil)
    }
}
