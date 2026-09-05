import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

// MARK: - PerceptualDuplicateDetector Tests (F-025)
//
// `hammingDistance` is already `nonisolated static` and directly testable.
// The DCT/pHash pipeline itself (grayscale32x32, dct2D, perceptualHash,
// computeHash) is private, so instead of widening internals, these tests
// exercise the real, public `detect(in:hammingThreshold:onProgress:)` against
// small synthetic images rendered and written to disk with CoreGraphics/
// ImageIO — the same "generate real fixtures, run the real pipeline" approach
// already used for DriveSpeedTester (real I/O) and BrowserCleanerScanner
// (real temp files) in this test suite.

@Suite("PerceptualDuplicateDetector")
struct PerceptualDuplicateDetectorTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.phash.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A checkerboard test pattern — structured enough to produce non-degenerate
    /// DCT coefficients (unlike a flat solid color, which would collapse to a
    /// near-all-zero AC block and make every hash trivially "similar").
    private func makeCheckerboardImage(
        color1: (CGFloat, CGFloat, CGFloat), color2: (CGFloat, CGFloat, CGFloat),
        size: Int, cell: Int
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let useFirst = ((x / cell) + (y / cell)).isMultiple(of: 2)
                let c = useFirst ? color1 : color2
                context.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return try #require(context.makeImage())
    }

    private func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            struct DestinationCreationFailed: Error {}
            throw DestinationCreationFailed()
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            struct FinalizeFailed: Error {}
            throw FinalizeFailed()
        }
    }

    // MARK: - hammingDistance

    @Test("hammingDistance is 0 for identical hashes")
    func testHammingDistanceIdentical() {
        #expect(PerceptualDuplicateDetector.hammingDistance(0x1234_5678_9ABC_DEF0, 0x1234_5678_9ABC_DEF0) == 0)
    }

    @Test("hammingDistance counts exactly the differing bits")
    func testHammingDistanceCountsDifferingBits() {
        #expect(PerceptualDuplicateDetector.hammingDistance(0b0000, 0b0001) == 1)
        #expect(PerceptualDuplicateDetector.hammingDistance(0b0000, 0b1111) == 4)
        #expect(PerceptualDuplicateDetector.hammingDistance(0, .max) == 64)
    }

    // MARK: - detect(in:) — filtering / trivial cases

    @Test("detect(in:) returns no groups for an empty input")
    func testDetectEmptyInput() async throws {
        let groups = try await PerceptualDuplicateDetector().detect(in: [], onProgress: { _ in })
        #expect(groups.isEmpty)
    }

    @Test("detect(in:) filters out non-image files entirely")
    func testDetectFiltersNonImageFiles() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let textFile = dir.appendingPathComponent("notes.txt")
        try "hello".data(using: .utf8)!.write(to: textFile)

        let groups = try await PerceptualDuplicateDetector().detect(in: [textFile], onProgress: { _ in })
        #expect(groups.isEmpty)
    }

    @Test("detect(in:) never groups a single image alone")
    func testDetectSingleImageNoGroup() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try makeCheckerboardImage(color1: (0.8, 0.2, 0.2), color2: (0.2, 0.2, 0.8), size: 128, cell: 16)
        let url = dir.appendingPathComponent("solo.png")
        try writeImage(image, to: url, type: .png)

        let groups = try await PerceptualDuplicateDetector().detect(in: [url], onProgress: { _ in })
        #expect(groups.isEmpty, "a cluster of exactly one image is not a 'duplicate group'")
    }

    // MARK: - detect(in:) — real clustering behavior

    @Test("detect(in:) clusters byte-identical copies of the same file, but not a visually distinct image")
    func testDetectClustersIdenticalCopiesNotDistinct() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two byte-identical copies of the same file guarantee a Hamming
        // distance of 0 — a deterministic "near-duplicate" case that doesn't
        // depend on tuning a pattern to survive re-encoding/resizing.
        let image = try makeCheckerboardImage(color1: (0.85, 0.25, 0.15), color2: (0.15, 0.3, 0.8), size: 128, cell: 16)
        let originalURL = dir.appendingPathComponent("photo.png")
        let copyURL = dir.appendingPathComponent("photo_copy.png")
        try writeImage(image, to: originalURL, type: .png)
        try FileManager.default.copyItem(at: originalURL, to: copyURL)

        // Deliberately different structure and palette — small cells + inverted
        // near-monochrome palette gives very different low-frequency DCT content.
        let distinct = try makeCheckerboardImage(color1: (0.02, 0.02, 0.02), color2: (0.98, 0.98, 0.98), size: 128, cell: 4)
        let distinctURL = dir.appendingPathComponent("unrelated.png")
        try writeImage(distinct, to: distinctURL, type: .png)

        let groups = try await PerceptualDuplicateDetector().detect(
            in: [originalURL, copyURL, distinctURL], hammingThreshold: 8, onProgress: { _ in }
        )

        #expect(groups.count == 1, "only the identical-copy pair should form a group")
        let group = try #require(groups.first)
        #expect(Set(group.items.map(\.url)) == Set([originalURL, copyURL]))
        #expect(!group.items.contains { $0.url == distinctURL })
    }

    // MARK: - makeGroup(from:) — recommended-keep tie-break logic
    //
    // Tested directly against synthetic PhotoHashResult values (bypassing the
    // real image-hashing pipeline entirely) since the tie-break rule itself —
    // highest resolution wins, ties broken by most recent — is deterministic
    // and shouldn't depend on tuning a real image pair to actually cluster.

    @Test("makeGroup recommends keeping the highest-resolution item in a cluster")
    func testMakeGroupRecommendsHighestResolution() {
        let low = PerceptualDuplicateDetector.PhotoHashResult(
            url: URL(fileURLWithPath: "/tmp/small.png"), hash: 0,
            pixelWidth: 100, pixelHeight: 100, sizeBytes: 500, modifiedDate: Date())
        let high = PerceptualDuplicateDetector.PhotoHashResult(
            url: URL(fileURLWithPath: "/tmp/big.png"), hash: 0,
            pixelWidth: 400, pixelHeight: 400, sizeBytes: 2000, modifiedDate: Date().addingTimeInterval(-1000))

        let group = PerceptualDuplicateDetector.makeGroup(from: [low, high])
        let lowItem = group.items.first { $0.url.path == "/tmp/small.png" }
        let highItem = group.items.first { $0.url.path == "/tmp/big.png" }
        #expect(highItem?.isRecommendedKeep == true)
        #expect(highItem?.isMarkedForDeletion == false)
        #expect(lowItem?.isRecommendedKeep == false)
        #expect(lowItem?.isMarkedForDeletion == true)
    }

    @Test("makeGroup breaks a same-resolution tie by most recent modification date")
    func testMakeGroupBreaksTieByMostRecent() {
        let older = PerceptualDuplicateDetector.PhotoHashResult(
            url: URL(fileURLWithPath: "/tmp/older.png"), hash: 0,
            pixelWidth: 200, pixelHeight: 200, sizeBytes: 500,
            modifiedDate: Date(timeIntervalSince1970: 1_000))
        let newer = PerceptualDuplicateDetector.PhotoHashResult(
            url: URL(fileURLWithPath: "/tmp/newer.png"), hash: 0,
            pixelWidth: 200, pixelHeight: 200, sizeBytes: 500,
            modifiedDate: Date(timeIntervalSince1970: 2_000))

        let group = PerceptualDuplicateDetector.makeGroup(from: [older, newer])
        let olderItem = group.items.first { $0.url.path == "/tmp/older.png" }
        let newerItem = group.items.first { $0.url.path == "/tmp/newer.png" }
        #expect(newerItem?.isRecommendedKeep == true)
        #expect(olderItem?.isRecommendedKeep == false)
    }

    @Test("wastedBytes sums every item's size except the recommended keep")
    func testWastedBytesExcludesRecommendedKeep() {
        let keep = PhotoHashItem(url: URL(fileURLWithPath: "/tmp/a.png"), sizeBytes: 1000,
                                  modifiedDate: nil, pixelWidth: 100, pixelHeight: 100, hash: 0,
                                  isMarkedForDeletion: false, isRecommendedKeep: true)
        let dupe1 = PhotoHashItem(url: URL(fileURLWithPath: "/tmp/b.png"), sizeBytes: 400,
                                   modifiedDate: nil, pixelWidth: 100, pixelHeight: 100, hash: 0,
                                   isMarkedForDeletion: true, isRecommendedKeep: false)
        let dupe2 = PhotoHashItem(url: URL(fileURLWithPath: "/tmp/c.png"), sizeBytes: 300,
                                   modifiedDate: nil, pixelWidth: 100, pixelHeight: 100, hash: 0,
                                   isMarkedForDeletion: true, isRecommendedKeep: false)
        let group = PhotoSimilarGroup(items: [keep, dupe1, dupe2])
        #expect(group.wastedBytes == 700)
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
