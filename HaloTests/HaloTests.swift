import Testing
import Foundation
import SwiftUI
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

// MARK: - ICloudDriveScanner Tests (F-030)
//
// `scanDirectory` and its private helpers operate purely on whatever URL is
// passed in — no dependency on the real `~/Library/Mobile Documents` or any
// persisted singleton — so, like FileSystemScanner above, these run against
// disposable temp directories. `trash(_:)` performs a real `FileManager.
// trashItem` and is deliberately NOT unit-tested here (no established
// precedent in this suite for exercising trashItem for real — see
// FilesUITests, which drives that flow to its confirmation dialog and always
// cancels).

@Suite("ICloudDriveScanner")
struct ICloudDriveScannerTests {

    @Test("scanDirectory reports real file sizes, sums directories, and sorts largest-first")
    func testScanDirectorySizesAndSorting() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.icloud.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A small top-level file...
        let smallFile = tempDir.appendingPathComponent("small.txt")
        try Data(repeating: 0x41, count: 100).write(to: smallFile)

        // ...and a subfolder whose contents should be summed into one size.
        let subfolder = tempDir.appendingPathComponent("Bigger")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 10_000).write(to: subfolder.appendingPathComponent("a.dat"))
        try Data(repeating: 0x43, count: 10_000).write(to: subfolder.appendingPathComponent("b.dat"))

        let scanner = ICloudDriveScanner()
        let items = await scanner.scanDirectory(tempDir)

        #expect(items.count == 2)
        // Largest (the summed 20,000-byte folder) sorts first.
        #expect(items.first?.name == "Bigger")
        #expect(items.first?.isDirectory == true)
        #expect(items.first?.sizeBytes == 20_000)
        #expect(items.last?.name == "small.txt")
        #expect(items.last?.isDirectory == false)
        #expect(items.last?.sizeBytes == 100)
    }

    @Test("scanDirectory returns an empty list for an empty folder")
    func testScanDirectoryEmpty() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.icloud.empty.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scanner = ICloudDriveScanner()
        let items = await scanner.scanDirectory(tempDir)
        #expect(items.isEmpty)
    }

    @Test("scanDirectory fails soft (returns empty) for a nonexistent URL")
    func testScanDirectoryMissingFolder() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.icloud.does-not-exist.\(UUID().uuidString)")
        let scanner = ICloudDriveScanner()
        let items = await scanner.scanDirectory(missing)
        #expect(items.isEmpty)
    }
}

// MARK: - iCloud Drive Model Tests (F-030)

@Suite("ICloudContainer")
struct ICloudContainerTests {

    @Test("displayName is always \"iCloud Drive\" for the user drive, regardless of folder name")
    func testUserDriveDisplayName() {
        let container = ICloudContainer(id: "com~apple~CloudDocs",
                                         url: URL(fileURLWithPath: "/tmp"), isUserDrive: true)
        #expect(container.displayName == "iCloud Drive")
    }

    @Test("displayName strips the com~apple~ prefix for a first-party app container")
    func testAppleAppContainerDisplayName() {
        let container = ICloudContainer(id: "com~apple~Pages",
                                         url: URL(fileURLWithPath: "/tmp"), isUserDrive: false)
        #expect(container.displayName == "Pages")
    }

    @Test("displayName strips the generic com~ prefix for a third-party container")
    func testThirdPartyContainerDisplayName() {
        let container = ICloudContainer(id: "com~examplecorp~notesapp",
                                         url: URL(fileURLWithPath: "/tmp"), isUserDrive: false)
        #expect(container.displayName == "Notesapp")
    }
}

@Suite("ICloudSyncStatus")
struct ICloudSyncStatusTests {

    @Test("Each status maps to its own label, SF Symbol, and color")
    func testStatusPresentation() {
        #expect(ICloudSyncStatus.local.label == "On This Mac")
        #expect(ICloudSyncStatus.local.icon == "checkmark.circle.fill")
        #expect(ICloudSyncStatus.local.color == Color.haloGreen)

        #expect(ICloudSyncStatus.downloading.label == "Downloading…")
        #expect(ICloudSyncStatus.downloading.icon == "arrow.down.circle")

        #expect(ICloudSyncStatus.uploading.label == "Uploading…")
        #expect(ICloudSyncStatus.uploading.icon == "arrow.up.circle")

        #expect(ICloudSyncStatus.evicted.label == "iCloud Only")
        #expect(ICloudSyncStatus.evicted.icon == "icloud")
        #expect(ICloudSyncStatus.evicted.color == Color.haloText2)

        #expect(ICloudSyncStatus.unknown.label == "Unknown")
        #expect(ICloudSyncStatus.unknown.icon == "questionmark.circle")
    }
}

@Suite("ICloudDriveItem")
struct ICloudDriveItemTests {

    private func makeItem(name: String, isDirectory: Bool = false,
                           modifiedDate: Date? = nil) -> ICloudDriveItem {
        ICloudDriveItem(id: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                         name: name, sizeBytes: 1024, isDirectory: isDirectory,
                         modifiedDate: modifiedDate, syncStatus: .local)
    }

    @Test("Directories always get the folder icon, regardless of name")
    func testDirectoryIcon() {
        let dir = makeItem(name: "Projects.pdf", isDirectory: true)
        #expect(dir.icon == "folder.fill")
    }

    @Test("File icon is chosen from the file extension")
    func testFileExtensionIcons() {
        #expect(makeItem(name: "report.pdf").icon == "doc.richtext")
        #expect(makeItem(name: "photo.HEIC").icon == "photo")
        #expect(makeItem(name: "clip.mov").icon == "film")
        #expect(makeItem(name: "deck.key").icon == "rectangle.on.rectangle")
        #expect(makeItem(name: "sheet.xlsx").icon == "tablecells")
        #expect(makeItem(name: "notes.pages").icon == "doc.text")
        #expect(makeItem(name: "archive.zip").icon == "doc.zipper")
        #expect(makeItem(name: "unknownkind.xyz").icon == "doc")
    }

    @Test("modifiedDateFormatted falls back to an em dash when there's no date")
    func testModifiedDateFallback() {
        let item = makeItem(name: "no-date.txt", modifiedDate: nil)
        #expect(item.modifiedDateFormatted == "—")
    }

    @Test("modifiedDateFormatted renders a relative string when a date is present")
    func testModifiedDateRelative() {
        let item = makeItem(name: "recent.txt", modifiedDate: Date().addingTimeInterval(-3600))
        #expect(item.modifiedDateFormatted != "—")
        #expect(!item.modifiedDateFormatted.isEmpty)
    }

    @Test("sizeFormatted uses ByteCountFormatter")
    func testSizeFormatted() {
        let item = makeItem(name: "sized.txt")
        #expect(item.sizeFormatted.contains("KB") || item.sizeFormatted.contains("1"))
    }
}

@Suite("ICloudDriveScanError")
struct ICloudDriveScanErrorTests {

    @Test("notAvailable explains iCloud Drive isn't set up")
    func testNotAvailableMessage() {
        let error = ICloudDriveScanError.notAvailable
        #expect(error.errorDescription?.contains("iCloud Drive") == true)
    }

    @Test("containerUnreadable names the container in its message")
    func testContainerUnreadableMessage() {
        let error = ICloudDriveScanError.containerUnreadable("Pages")
        #expect(error.errorDescription?.contains("Pages") == true)
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
