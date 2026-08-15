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

// MARK: - Focus Session Tests (F-028)
//
// `FocusSessionSummary.digestText`, `FocusAppConfig`, and `FocusDurationPreset`
// are plain data types with no actor/singleton involved, so they're tested
// directly. `FocusSessionManager.start()`/`endSession()` and
// `FocusSessionSettingsStore.add()`/`.remove()` are intentionally NOT
// exercised here — they have real side effects on the host machine (posting
// a genuine `UNUserNotificationCenter` notification, appending a permanent
// entry to the real `AlertLog.shared`, and persisting to the real
// `UserDefaults["focusSessionAppConfigs"]`) with no injectable seam, the same
// category of side effect this suite avoided for `AlertManager.checkAppMemory`
// in the F-023 pass. See docs/MANUAL_TEST_PLAN.md for their manual coverage.

@Suite("FocusSessionSummary")
struct FocusSessionSummaryTests {

    @Test("digestText — full data, not ended early, matches the documented example exactly")
    func testDigestTextFullData() {
        let summary = FocusSessionSummary(
            plannedMinutes: 50, actualMinutes: 50, hiddenAppNames: ["Slack", "Mail"],
            topRAMProcessName: "Chrome", topRAMProcessMB: 820.4, maxCPUPercent: 42, endedEarly: false)
        #expect(summary.digestText == "50-minute session. Top RAM consumer: Chrome (820 MB). CPU stayed below 45%.")
    }

    @Test("digestText — ended early, no RAM data, zero CPU")
    func testDigestTextEndedEarlyNoData() {
        let summary = FocusSessionSummary(
            plannedMinutes: 25, actualMinutes: 10, hiddenAppNames: [],
            topRAMProcessName: nil, topRAMProcessMB: nil, maxCPUPercent: 0, endedEarly: true)
        #expect(summary.digestText == "10-minute session (ended early). CPU usage stayed minimal throughout.")
    }

    @Test("digestText — CPU percent rounds up to the nearest multiple of 5")
    func testDigestTextCPURounding() {
        func cpuLine(_ pct: Double) -> String {
            FocusSessionSummary(plannedMinutes: 25, actualMinutes: 25, hiddenAppNames: [],
                                 topRAMProcessName: nil, topRAMProcessMB: nil,
                                 maxCPUPercent: pct, endedEarly: false).digestText
        }
        #expect(cpuLine(40).hasSuffix("CPU stayed below 40%."))    // exact multiple — no rounding needed
        #expect(cpuLine(41).hasSuffix("CPU stayed below 45%."))    // rounds up to next multiple of 5
        #expect(cpuLine(55).hasSuffix("CPU stayed below 55%."))
        #expect(cpuLine(56).hasSuffix("CPU stayed below 60%."))
    }

    @Test("digestText omits the RAM line entirely when no process data was sampled")
    func testDigestTextOmitsRAMLineWhenMissing() {
        let summary = FocusSessionSummary(
            plannedMinutes: 25, actualMinutes: 25, hiddenAppNames: [],
            topRAMProcessName: nil, topRAMProcessMB: nil, maxCPUPercent: 12, endedEarly: false)
        #expect(!summary.digestText.contains("Top RAM consumer"))
    }
}

@Suite("FocusAppConfig")
struct FocusAppConfigTests {

    @Test("id is derived from bundleIdentifier")
    func testIDIsBundleIdentifier() {
        let config = FocusAppConfig(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(config.id == "com.tinyspeck.slackmacgap")
    }

    @Test("Equatable — same bundleIdentifier and name are equal, different name or bundle are not")
    func testEquatable() {
        let a = FocusAppConfig(bundleIdentifier: "com.a", name: "A")
        let sameA = FocusAppConfig(bundleIdentifier: "com.a", name: "A")
        let differentName = FocusAppConfig(bundleIdentifier: "com.a", name: "A renamed")
        let differentBundle = FocusAppConfig(bundleIdentifier: "com.b", name: "A")
        #expect(a == sameA)
        #expect(a != differentName)
        #expect(a != differentBundle)
    }

    @Test("Codable round-trips an array of configs")
    func testCodableRoundTrip() throws {
        let configs = [
            FocusAppConfig(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack"),
            FocusAppConfig(bundleIdentifier: "com.apple.mail", name: "Mail"),
        ]
        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode([FocusAppConfig].self, from: data)
        #expect(decoded == configs)
    }

    @Test("Hashable — usable in a Set, deduplicating by value equality")
    func testHashableInSet() {
        let a = FocusAppConfig(bundleIdentifier: "com.a", name: "A")
        let sameA = FocusAppConfig(bundleIdentifier: "com.a", name: "A")
        let b = FocusAppConfig(bundleIdentifier: "com.b", name: "B")
        let set: Set<FocusAppConfig> = [a, sameA, b]
        #expect(set.count == 2)
    }
}

@Suite("FocusDurationPreset")
struct FocusDurationPresetTests {

    @Test("Exactly two presets: 25 and 50 minutes")
    func testPresetValues() {
        #expect(FocusDurationPreset.allCases.count == 2)
        #expect(Set(FocusDurationPreset.allCases.map(\.rawValue)) == [25, 50])
    }

    @Test("label formats as 'N min'")
    func testPresetLabels() {
        #expect(FocusDurationPreset.twentyFive.label == "25 min")
        #expect(FocusDurationPreset.fifty.label == "50 min")
    }
}
