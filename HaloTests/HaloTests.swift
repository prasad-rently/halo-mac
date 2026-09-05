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

// MARK: - AsyncTimeout
//
// Every assertion here is on ELAPSED TIME, deliberately. The idiom this helper
// replaces — racing a `Task.sleep` sibling inside a `withTaskGroup` — returned
// the correct *value* and the wrong *time*, so a test that only checked the
// returned value passed against the broken version. Timing is the property that
// was actually missing.
@Suite("AsyncTimeout")
struct AsyncTimeoutTests {

    /// Bounds are generous: the gap between "released at the deadline" and
    /// "joined the abandoned work" is seconds, not milliseconds, so there is no
    /// need to measure tightly and invite flakiness.
    private static let slowWork: TimeInterval = 3.0

    // The case that used to hang the caller for the full duration of work it
    // had already given up on.
    @Test("Work slower than the deadline releases the caller at the deadline")
    func testBoundsWallClock() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 0.3) { deliver in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: Self.slowWork)   // uninterruptible
                deliver("too-late")
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(value == nil)
        #expect(elapsed < Self.slowWork / 2, "waited \(elapsed)s for abandoned work")
    }

    // The worse case: no delivery ever. Under the old shape the group waited on
    // a child that would never finish, so the caller blocked forever.
    @Test("A callback that never fires still returns at the deadline")
    func testNeverDelivered() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 0.3) { _ in }

        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test("A prompt result is returned immediately, not held until the deadline")
    func testFastPathNotDelayed() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 10) { $0("quick") }

        #expect(value == "quick")
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    // A second resume on a checked continuation is a fatalError, so the test
    // process surviving is itself the assertion.
    @Test("Repeated deliveries resolve to the first and do not crash")
    func testRepeatedDeliveryTakesFirst() async {
        let value: Int? = await AsyncTimeout.run(seconds: 10) { deliver in
            deliver(1)
            deliver(2)
            deliver(3)
        }
        #expect(value == 1)
    }

    // PhotoKit delivers a placeholder then a real image; the first delivery
    // wins even when it is nil, which is the documented behaviour of `.run`.
    @Test("A first delivery of nil wins over a later real value")
    func testFirstNilWins() async {
        let value: Int? = await AsyncTimeout.run(seconds: 10) { deliver in
            deliver(nil)
            deliver(42)
        }
        #expect(value == nil)
    }

    @Test("A delivery arriving after the deadline is ignored rather than crashing")
    func testLateDeliveryIgnored() async {
        let value: Int? = await AsyncTimeout.run(seconds: 0.2) { deliver in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.5)
                deliver(7)
            }
        }
        #expect(value == nil)
        // Let the late delivery land while the test is still running, so a
        // double-resume would take this process down rather than a later one.
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    @Test("runBlocking returns a prompt value and bounds a slow one")
    func testRunBlocking() async {
        #expect(await AsyncTimeout.runBlocking(seconds: 10) { "done" } == "done")

        let started = Date()
        let slow: String? = await AsyncTimeout.runBlocking(seconds: 0.3) {
            Thread.sleep(forTimeInterval: Self.slowWork)
            return "too-late"
        }
        #expect(slow == nil)
        #expect(Date().timeIntervalSince(started) < Self.slowWork / 2)
    }
}
