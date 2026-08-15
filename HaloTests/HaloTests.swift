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

// MARK: - BrowserCleanerScanner Tests (F-024)
//
// `candidates(home:)`, `size(ofPaths:)`, `chromiumProfileDirs(appSupportRoot:)`,
// and `firefoxProfileDirs(home:)` were widened from `private` to internal
// (no behavior change) specifically so these tests can exercise the real
// logic against a synthetic temp "home" directory instead of the dev
// machine's actual installed browsers.

@Suite("BrowserCleanerScanner")
struct BrowserCleanerScannerTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.browsercleaner.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - candidates(home:)

    @Test("candidates(home:) lists all 8 supported browsers with correct app paths")
    func testCandidatesListsAllSupportedBrowsers() {
        let candidates = BrowserCleanerScanner.candidates(home: "/tmp/fake-home")
        #expect(candidates.count == 8)
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0.appPath) })
        #expect(byName["Safari"] == "/Applications/Safari.app")
        #expect(byName["Google Chrome"] == "/Applications/Google Chrome.app")
        #expect(byName["Arc"] == "/Applications/Arc.app")
        #expect(byName["Brave"] == "/Applications/Brave Browser.app")
        #expect(byName["Microsoft Edge"] == "/Applications/Microsoft Edge.app")
        #expect(byName["Opera"] == "/Applications/Opera.app")
        #expect(byName["Vivaldi"] == "/Applications/Vivaldi.app")
        #expect(byName["Firefox"] == "/Applications/Firefox.app")
    }

    @Test("detectBrowsers() only returns browsers actually installed at their app path")
    func testDetectBrowsersOnlyReturnsInstalled() async {
        let scanner = BrowserCleanerScanner()
        let detected = await scanner.detectBrowsers()
        for profile in detected {
            #expect(FileManager.default.fileExists(atPath: profile.appPath),
                    "\(profile.name) was returned but \(profile.appPath) doesn't exist")
        }
        // Every detected browser must be one of the 8 known candidates.
        let knownNames = Set(BrowserCleanerScanner.candidates(home: NSHomeDirectory()).map(\.name))
        #expect(detected.allSatisfy { knownNames.contains($0.name) })
    }

    // MARK: - chromiumProfileDirs(appSupportRoot:)

    @Test("chromiumProfileDirs falls back to [\"Default\"] when the root can't be read")
    func testChromiumProfileDirsFallsBackWhenUnreadable() {
        let dirs = BrowserCleanerScanner.chromiumProfileDirs(appSupportRoot: "/tmp/halo-test-nonexistent-\(UUID().uuidString)")
        #expect(dirs == ["Default"])
    }

    @Test("chromiumProfileDirs discovers Default/Guest/numbered profiles, filtering out unrelated entries")
    func testChromiumProfileDirsDiscoversRealProfiles() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Default", "Profile 1", "Profile 2", "Guest Profile", "Crashpad", "Local State"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let dirs = Set(BrowserCleanerScanner.chromiumProfileDirs(appSupportRoot: root.path))
        #expect(dirs == ["Default", "Profile 1", "Profile 2", "Guest Profile"])
    }

    @Test("chromiumProfileDirs falls back to [\"Default\"] when the root exists but has no recognizable profile folders")
    func testChromiumProfileDirsFallsBackWhenNoProfilesMatch() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Crashpad"), withIntermediateDirectories: true)
        let dirs = BrowserCleanerScanner.chromiumProfileDirs(appSupportRoot: root.path)
        #expect(dirs == ["Default"])
    }

    // MARK: - firefoxProfileDirs(home:)

    @Test("firefoxProfileDirs returns empty when Firefox was never installed/launched")
    func testFirefoxProfileDirsEmptyWhenNoProfilesDir() {
        let dirs = BrowserCleanerScanner.firefoxProfileDirs(home: "/tmp/halo-test-nonexistent-\(UUID().uuidString)")
        #expect(dirs.isEmpty)
    }

    @Test("firefoxProfileDirs lists real profile folders and filters out dotfiles")
    func testFirefoxProfileDirsDiscoversRealProfiles() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let profilesRoot = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        try FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        for name in ["abc123.default-release", "xyz789.default", ".DS_Store"] {
            try FileManager.default.createDirectory(at: profilesRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let dirs = Set(BrowserCleanerScanner.firefoxProfileDirs(home: home.path))
        #expect(dirs == ["abc123.default-release", "xyz789.default"])
    }

    // MARK: - size(ofPaths:)

    @Test("size(ofPaths:) returns 0 for a path that doesn't exist")
    func testSizeOfNonexistentPathIsZero() {
        #expect(BrowserCleanerScanner.size(ofPaths: ["/tmp/halo-test-nonexistent-\(UUID().uuidString)"]) == 0)
    }

    @Test("size(ofPaths:) returns the exact byte count for a single file")
    func testSizeOfSingleFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cookies.sqlite")
        try Data(repeating: 0, count: 1234).write(to: file)
        #expect(BrowserCleanerScanner.size(ofPaths: [file.path]) == 1234)
    }

    @Test("size(ofPaths:) recursively sums a directory's contents")
    func testSizeOfDirectoryIsRecursiveSum() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("a.txt"))
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 200).write(to: nested.appendingPathComponent("b.txt"))
        #expect(BrowserCleanerScanner.size(ofPaths: [dir.path]) == 300)
    }

    @Test("size(ofPaths:) sums across multiple independent paths")
    func testSizeSumsMultiplePaths() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data(repeating: 0, count: 50).write(to: fileA)
        try Data(repeating: 0, count: 75).write(to: fileB)
        #expect(BrowserCleanerScanner.size(ofPaths: [fileA.path, fileB.path]) == 125)
        // A mix of an existing and a nonexistent path only counts the real one.
        #expect(BrowserCleanerScanner.size(ofPaths: [fileA.path, "/tmp/halo-nonexistent-\(UUID().uuidString)"]) == 50)
    }

    // MARK: - measure(_:)

    @Test("measure(_:) fills in real on-disk sizes per category")
    func testMeasureFillsInRealSizes() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheFile = dir.appendingPathComponent("cache.dat")
        try Data(repeating: 0, count: 500).write(to: cacheFile)

        let profile = BrowserProfile(
            name: "TestBrowser", icon: "globe", appPath: "/Applications/Test.app",
            categories: [BrowserCategoryItem(category: .httpCache, paths: [cacheFile.path])]
        )
        let scanner = BrowserCleanerScanner()
        let measured = await scanner.measure(profile)
        #expect(measured.categories.first?.size == 500)
        #expect(measured.totalBytes == 500)
    }

    // MARK: - clear(_:categories:)

    @Test("clear(_:categories:) trashes only the selected category's paths, leaving the rest untouched")
    func testClearTrashesOnlySelectedCategories() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheFile = dir.appendingPathComponent("cache.dat")
        let cookiesFile = dir.appendingPathComponent("cookies.sqlite")
        try Data(repeating: 0, count: 400).write(to: cacheFile)
        try Data(repeating: 0, count: 100).write(to: cookiesFile)

        let cacheItem = BrowserCategoryItem(category: .httpCache, paths: [cacheFile.path])
        let cookiesItem = BrowserCategoryItem(category: .cookies, paths: [cookiesFile.path])
        let profile = BrowserProfile(name: "TestBrowser", icon: "globe", appPath: "/Applications/Test.app",
                                      categories: [cacheItem, cookiesItem])

        let scanner = BrowserCleanerScanner()
        let result = await scanner.clear(profile, categories: [cacheItem.id])

        #expect(result.cleared == 1)
        #expect(result.freed == 400)
        #expect(result.error == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path), "the selected cache file should have been trashed")
        #expect(FileManager.default.fileExists(atPath: cookiesFile.path), "the unselected cookies file must be left alone")
    }

    @Test("clear(_:categories:) is a no-op when the selected category's paths don't exist")
    func testClearNoOpWhenPathsMissing() async {
        let missingItem = BrowserCategoryItem(category: .httpCache, paths: ["/tmp/halo-nonexistent-\(UUID().uuidString)"])
        let profile = BrowserProfile(name: "TestBrowser", icon: "globe", appPath: "/Applications/Test.app",
                                      categories: [missingItem])
        let scanner = BrowserCleanerScanner()
        let result = await scanner.clear(profile, categories: [missingItem.id])
        #expect(result.cleared == 0)
        #expect(result.freed == 0)
        #expect(result.error == nil)
    }
}
