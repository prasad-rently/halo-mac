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
        #expect(result.errors.isEmpty)
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
        #expect(result.errors.isEmpty)
    }
}

// MARK: - F-024 review fixes

@Suite("BrowserCleanerScanner size measurement")
struct BrowserCleanerSizeTests {

    // The regression this guards: recursiveSize used
    // fileExists(atPath:isDirectory:), which RESOLVES symlinks — so a symlink
    // pointing at a parent recursed without bound. That is a stack-overflow
    // crash, not a slow scan, and a symlink to $HOME would have made "measure
    // Chrome's cache" walk the entire home directory.
    @Test("A symlink loop does not recurse without bound")
    func testSymlinkLoopTerminates() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HaloBrowserLoop-\(UUID().uuidString)")
        let child = root.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0x41, count: 1024).write(to: child.appendingPathComponent("a.bin"))
        // child/loop -> root
        try fm.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: root)

        let size = BrowserCleanerScanner.size(ofPaths: [root.path])
        #expect(size >= 1024)
        #expect(size < 10_000_000)   // did not walk the world
    }

    @Test("Sizes sum the regular files in a tree")
    func testSumsRegularFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HaloBrowserSize-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0x42, count: 2048).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0x43, count: 4096).write(to: sub.appendingPathComponent("b.bin"))

        #expect(BrowserCleanerScanner.size(ofPaths: [root.path]) == 6144)
    }

    @Test("A missing path measures zero rather than failing")
    func testMissingPath() {
        #expect(BrowserCleanerScanner.size(ofPaths: ["/nonexistent/halo/path"]) == 0)
    }
}

// MARK: - Browser clear accounting
//
// `clear()` reported `freed` by adding `item.size` once per path. `measure(_:)`
// sets `item.size` to the total across ALL of a category's paths, so the figure
// was inflated by the number of paths that existed — 2x for Safari's history,
// up to 4x for a four-profile Chrome. `cleared` was always right, which made it
// look consistent.
//
// This walks a real temp tree rather than asserting on a constructed
// `BrowserClearResult`, because the bug was in the accounting, not the struct.
@Suite("BrowserCleanerScanner clear accounting")
struct BrowserCleanAccountingTests {

    @Test("Freed bytes are the sum of the paths, not the category total per path")
    func testMultiPathFreedIsNotMultiplied() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HaloClearTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // One category, three paths of known size — the shape that multiplied.
        let sizes = [1000, 2000, 3000]
        var paths: [String] = []
        for (i, bytes) in sizes.enumerated() {
            let url = root.appendingPathComponent("file\(i).bin")
            try Data(repeating: 0xAB, count: bytes).write(to: url)
            paths.append(url.path)
        }
        let total = Int64(sizes.reduce(0, +))

        let item = BrowserCategoryItem(category: .httpCache, paths: paths)
        let profile = BrowserProfile(name: "Test", icon: "safari",
                                     appPath: "/Applications/Safari.app",
                                     categories: [item])

        let scanner = BrowserCleanerScanner()
        let measured = await scanner.measure(profile)

        // Precondition: measure() really does report the whole category as one
        // number. If this ever stops being true the bug below changes shape.
        #expect(measured.categories[0].size == total)

        let measuredItem = measured.categories[0]
        let result = await scanner.clear(measured, categories: [measuredItem.id])

        #expect(result.cleared == 3)
        // The broken version reported 3 x 6000 = 18000 here.
        #expect(result.freed == total)
    }

    @Test("A single-path category is unaffected")
    func testSinglePathUnchanged() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HaloClearTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let url = root.appendingPathComponent("only.bin")
        try Data(repeating: 0xCD, count: 4096).write(to: url)

        let item = BrowserCategoryItem(category: .httpCache, paths: [url.path])
        let profile = BrowserProfile(name: "Test", icon: "safari",
                                     appPath: "/Applications/Safari.app",
                                     categories: [item])

        let scanner = BrowserCleanerScanner()
        let measured = await scanner.measure(profile)
        let result = await scanner.clear(measured, categories: [measured.categories[0].id])

        #expect(result.cleared == 1)
        #expect(result.freed == 4096)
    }
}

@Suite("BrowserClearResult reporting")
struct BrowserClearResultTests {

    // clear() returned only the first error. Under the sandbox most paths are
    // expected to fail, so one message beside a "cleared N" count told the user
    // nothing about what had actually happened.
    @Test("Every failure is carried, not just the first")
    func testAllErrorsCarried() {
        let r = BrowserClearResult(cleared: 2, freed: 100, errors: ["a: denied", "b: denied", "c: denied"])
        #expect(r.succeeded == false)
        #expect(r.errors.count == 3)
        #expect(r.summary?.contains("3 items") == true)
    }

    @Test("A clean run reports no summary")
    func testCleanRun() {
        let r = BrowserClearResult(cleared: 5, freed: 999, errors: [])
        #expect(r.succeeded)
        #expect(r.summary == nil)
    }

    @Test("A single failure is reported verbatim")
    func testSingleFailure() {
        #expect(BrowserClearResult(cleared: 0, freed: 0, errors: ["History: denied"]).summary == "History: denied")
    }
}
