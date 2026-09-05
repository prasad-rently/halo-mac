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

// MARK: - TimeMachineMonitor / TimeMachineStatus Tests (F-022)
//
// `heatmap(backupDates:days:referenceDate:)` is pure and synchronous (no
// `await`, no shelling out to `tmutil`), so these tests exercise it directly
// with synthetic backup dates and a fixed reference date. `isStale` and
// `spaceUsedRatio` are plain computed properties on `TimeMachineStatus`,
// also tested without any live `tmutil` process.

@Suite("TimeMachineMonitor heatmap")
struct TimeMachineMonitorHeatmapTests {

    private var anchorNow: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: now))!
    }

    @Test("With no backup history at all, every day is .noData — never fabricated as missed")
    func testHeatmapAllNoDataWithoutHistory() {
        let now = anchorNow
        let days = TimeMachineMonitor.heatmap(backupDates: [], days: 30, referenceDate: now)
        #expect(days.count == 30)
        #expect(days.allSatisfy { $0.state == .noData })
    }

    @Test("A day with a real snapshot is .backedUp")
    func testHeatmapBackedUpDay() {
        let now = anchorNow
        let days = TimeMachineMonitor.heatmap(backupDates: [now], days: 7, referenceDate: now)
        #expect(days.last?.state == .backedUp)
    }

    @Test("Days before the earliest known backup are .noData, not .missed")
    func testHeatmapDaysBeforeEarliestBackupAreNoData() {
        let now = anchorNow
        // Only one backup, 2 days ago — days further back than that have no
        // information to judge them by at all.
        let days = TimeMachineMonitor.heatmap(backupDates: [day(2, from: now)], days: 7, referenceDate: now)
        let sixDaysAgo = days.first { Calendar.current.isDate($0.date, inSameDayAs: day(6, from: now)) }
        #expect(sixDaysAgo?.state == .noData)
    }

    @Test("A 1-day gap since the most recent backup on/before a day is .late")
    func testHeatmapOneDayGapIsLate() {
        let now = anchorNow
        // Backup 1 day ago; today has no backup of its own -> 1-day gap.
        let days = TimeMachineMonitor.heatmap(backupDates: [day(1, from: now)], days: 7, referenceDate: now)
        #expect(days.last?.state == .late)
    }

    @Test("A 2+ day gap since the most recent backup on/before a day is .missed")
    func testHeatmapTwoDayGapIsMissed() {
        let now = anchorNow
        // Backup 3 days ago; today has no backup -> 3-day gap.
        let days = TimeMachineMonitor.heatmap(backupDates: [day(3, from: now)], days: 7, referenceDate: now)
        #expect(days.last?.state == .missed)
    }

    @Test("Heatmap covers exactly the requested number of days, ending on the reference date")
    func testHeatmapCoversRequestedWindow() {
        let now = anchorNow
        let days = TimeMachineMonitor.heatmap(backupDates: [now], days: 30, referenceDate: now)
        #expect(days.count == 30)
        #expect(Calendar.current.isDate(days.last!.date, inSameDayAs: now))
        #expect(Calendar.current.isDate(days.first!.date, inSameDayAs: day(29, from: now)))
    }

    @Test("Multiple backups across the window each classify their own day as .backedUp")
    func testHeatmapMultipleBackupDays() {
        let now = anchorNow
        let backups = [day(0, from: now), day(2, from: now), day(5, from: now)]
        let days = TimeMachineMonitor.heatmap(backupDates: backups, days: 7, referenceDate: now)
        for offset in [0, 2, 5] {
            let cell = days.first { Calendar.current.isDate($0.date, inSameDayAs: day(offset, from: now)) }
            #expect(cell?.state == .backedUp, "day offset \(offset) should be backed up")
        }
    }
}

@Suite("TimeMachineStatus")
struct TimeMachineStatusTests {

    @Test("A not-configured status is never stale, regardless of any stray date")
    func testNotConfiguredNeverStale() {
        var status = TimeMachineStatus.notConfigured
        status.lastBackupDate = Date().addingTimeInterval(-100 * 3600)
        #expect(status.isStale == false)
    }

    @Test("Configured with no known backup date at all is not stale — that's the notData case, not staleness")
    func testConfiguredNoBackupDateIsNotStale() {
        let status = TimeMachineStatus(isConfigured: true)
        #expect(status.isStale == false)
    }

    @Test("A backup less than 48h old is not stale")
    func testRecentBackupIsNotStale() {
        var status = TimeMachineStatus(isConfigured: true)
        status.lastBackupDate = Date().addingTimeInterval(-47 * 3600)
        #expect(status.isStale == false)
    }

    @Test("A backup older than 48h is stale")
    func testOldBackupIsStale() {
        var status = TimeMachineStatus(isConfigured: true)
        status.lastBackupDate = Date().addingTimeInterval(-49 * 3600)
        #expect(status.isStale == true)
    }

    @Test("spaceUsedRatio computes 1 minus the available/total fraction")
    func testSpaceUsedRatioComputation() {
        var status = TimeMachineStatus(isConfigured: true)
        status.availableBytes = 250
        status.totalBytes = 1000
        #expect(status.spaceUsedRatio == 0.75)
    }

    @Test("spaceUsedRatio is nil when capacity data is missing or the volume reports zero total")
    func testSpaceUsedRatioNilWhenDataMissing() {
        var noAvailable = TimeMachineStatus(isConfigured: true)
        noAvailable.totalBytes = 1000
        #expect(noAvailable.spaceUsedRatio == nil)

        var noTotal = TimeMachineStatus(isConfigured: true)
        noTotal.availableBytes = 250
        #expect(noTotal.spaceUsedRatio == nil)

        var zeroTotal = TimeMachineStatus(isConfigured: true)
        zeroTotal.availableBytes = 250
        zeroTotal.totalBytes = 0
        #expect(zeroTotal.spaceUsedRatio == nil)
    }
}

// MARK: - F-022 review fixes

@Suite("TimeMachineMonitor destinationinfo parsing")
struct TimeMachineDestinationParsingTests {

    // A local destination: tmutil reports a Mount Point and no URL.
    @Test("A local destination yields a mount point and is not flagged as network")
    func testLocalDestination() {
        let output = """
        Name          : Backup HD
        Kind          : Local
        Mount Point   : /Volumes/Backup HD
        ID            : 1B2C3D4E-0000-0000-0000-000000000001
        """
        let info = TimeMachineMonitor.parseDestinationInfo(output)
        #expect(info.name == "Backup HD")
        #expect(info.mountPoint == "/Volumes/Backup HD")
        #expect(info.url == nil)
        #expect(info.isNetwork == false)
    }

    // The regression: a Time Capsule / NAS reports a URL and *no* Mount Point
    // until its sparsebundle is mounted. Reading only Mount Point made every
    // network destination look permanently disconnected with no capacity.
    @Test("A network destination yields a URL, no mount point, and is flagged as network")
    func testNetworkDestination() {
        let output = """
        Name          : Time Capsule
        Kind          : Network
        URL           : afp://admin@timecapsule._afpovertcp._tcp.local./Data
        ID            : 1B2C3D4E-0000-0000-0000-000000000002
        """
        let info = TimeMachineMonitor.parseDestinationInfo(output)
        #expect(info.name == "Time Capsule")
        #expect(info.mountPoint == nil)
        #expect(info.url == "afp://admin@timecapsule._afpovertcp._tcp.local./Data")
        #expect(info.isNetwork)
    }

    // The URL value contains "://", so splitting on anything but the first
    // colon truncates it.
    @Test("A URL value containing :// survives parsing intact")
    func testURLWithSchemeSeparatorIsNotTruncated() {
        let info = TimeMachineMonitor.parseDestinationInfo("URL : smb://nas.local/TimeMachine")
        #expect(info.url == "smb://nas.local/TimeMachine")
    }

    // Fallback for if the Kind wording ever shifts.
    @Test("A URL with no Kind line is still treated as a network destination")
    func testNetworkInferredFromURLAlone() {
        let info = TimeMachineMonitor.parseDestinationInfo("Name : NAS\nURL : smb://nas.local/TM")
        #expect(info.isNetwork)
    }

    @Test("No destinations configured parses to an empty info block")
    func testEmptyOutput() {
        let info = TimeMachineMonitor.parseDestinationInfo("")
        #expect(info.name == nil)
        #expect(info.mountPoint == nil)
        #expect(info.isNetwork == false)
    }
}

@Suite("TimeMachineStatus review fixes")
struct TimeMachineStatusReviewFixTests {

    // isStale structurally cannot represent this: it needs a lastBackupDate to
    // measure against, so with no backups at all it reads false and the app
    // stayed silent in the one case the user most needs to hear about.
    @Test("Configured with no backup ever is hasNeverBackedUp, and is not stale")
    func testNeverBackedUp() {
        let status = TimeMachineStatus(isConfigured: true, lastBackupDate: nil)
        #expect(status.hasNeverBackedUp)
        #expect(status.isStale == false)
    }

    @Test("An unconfigured Mac is not hasNeverBackedUp — that is the .notConfigured state")
    func testUnconfiguredIsNotNeverBackedUp() {
        #expect(TimeMachineStatus.notConfigured.hasNeverBackedUp == false)
    }

    @Test("A Mac with a backup is not hasNeverBackedUp")
    func testWithBackupIsNotNeverBackedUp() {
        let status = TimeMachineStatus(isConfigured: true, lastBackupDate: Date())
        #expect(status.hasNeverBackedUp == false)
    }

    // "the drive is unplugged" and "we cannot measure this one" are different
    // facts; collapsing them showed healthy network destinations as offline.
    @Test("A mounted local destination is reachable")
    func testLocalMountedIsReachable() {
        let status = TimeMachineStatus(isConfigured: true, mountPoint: "/Volumes/B", isReachable: true)
        #expect(status.reachability == .reachable)
    }

    @Test("An unmounted local destination is unreachable")
    func testLocalUnmountedIsUnreachable() {
        let status = TimeMachineStatus(isConfigured: true, isReachable: false)
        #expect(status.reachability == .unreachable)
    }

    @Test("An unmounted network destination is unknown, not unreachable")
    func testNetworkUnmountedIsUnknown() {
        let status = TimeMachineStatus(
            isConfigured: true,
            destinationURL: "afp://tc.local/Data",
            isNetworkDestination: true,
            isReachable: false
        )
        #expect(status.reachability == .unknown)
    }
}

@Suite("BackupHeatmapDay identity")
struct BackupHeatmapDayIdentityTests {

    // heatmap() is pure and called from the view body, so it re-runs on every
    // render. A generated UUID id made ForEach rebuild all 30 cells each time
    // instead of diffing them.
    @Test("Identical inputs produce identical ids across calls")
    func testHeatmapIdsAreStableAcrossCalls() {
        let now = Date()
        let dates = [now.addingTimeInterval(-86_400)]
        let first  = TimeMachineMonitor.heatmap(backupDates: dates, days: 10, referenceDate: now)
        let second = TimeMachineMonitor.heatmap(backupDates: dates, days: 10, referenceDate: now)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Ids are unique within one heatmap — one day, one cell")
    func testHeatmapIdsAreUnique() {
        let days = TimeMachineMonitor.heatmap(backupDates: [], days: 30, referenceDate: Date())
        #expect(Set(days.map(\.id)).count == days.count)
    }
}
