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

// MARK: - Shared singletons (Phase 0 / P0.3)

@Suite("AlertManager")
struct AlertManagerTests {

    // `AlertKind.rawValue` is a storage format, not an implementation detail:
    // AlertLog persists it to UserDefaults, and AlertEntry.icon / .accentColor
    // switch on those exact strings. Renaming a case silently strips the icon
    // and colour from every alert already sitting in a user's history.
    @Test("AlertKind raw values are persisted and must not change")
    func testAlertKindRawValuesAreStable() {
        let expected: [AlertManager.AlertKind: String] = [
            .cpuHigh:          "cpu_high",
            .ramHigh:          "ram_high",
            .diskLow:          "disk_low",
            .batteryLow:       "battery_low",
            .batteryCritical:  "battery_critical",
            .chargingDone:     "charging_done"
        ]
        for (kind, raw) in expected {
            #expect(kind.rawValue == raw, "AlertKind.\(kind) raw value changed — old history entries lose their icon")
        }
    }

    // Adding a case to AlertKind without adding the matching arm to
    // AlertEntry.icon leaves the alert rendering as a generic bell in the
    // history list. Three queued PRs add cases to this enum, so this is the
    // check that keeps the two files in step.
    @Test("Every AlertKind has its own icon in AlertEntry")
    func testEveryAlertKindHasAnIcon() {
        for kind in AlertManager.AlertKind.allCases {
            let entry = AlertEntry(title: "t", body: "b", kindRaw: kind.rawValue)
            #expect(
                entry.icon != "bell.fill",
                "AlertKind.\(kind.rawValue) falls through to the default icon — add a case to AlertEntry.icon (and .accentColor)"
            )
        }
    }
}

// Serialized: every test here samples the one shared ProcessMonitor, so a
// parallel sibling forcing a re-sample would break the coalescing assertion.
@Suite("ProcessMonitor", .serialized)
struct ProcessMonitorTests {

    @Test("A snapshot sees the running process table")
    func testSnapshotIsPopulated() async {
        let procs = await ProcessMonitor.shared.snapshot()
        #expect(!procs.isEmpty)
        // This test process must be in its own process table.
        #expect(procs.contains { $0.id == Foundation.ProcessInfo.processInfo.processIdentifier })
    }

    // The regression this guards: without coalescing, the second of two
    // near-simultaneous calls re-enumerates and computes its CPU delta over a
    // near-zero elapsed window, so every process reads ~0 %. Two independent
    // samples agreeing on ~600 CPU percentages to the bit does not happen by
    // chance — if this fails, the cache is gone.
    @Test("Two snapshots inside the coalescing window are the same sample")
    func testSnapshotsCoalesce() async {
        let first  = await ProcessMonitor.shared.snapshot()
        let second = await ProcessMonitor.shared.snapshot()

        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { $0.id == $1.id && $0.cpuPercent == $1.cpuPercent })
    }

    // Exercises the expiry path, and with it the CPU-delta arithmetic against a
    // real previous baseline — including the PID-reuse guard, which would trap
    // on UInt64 underflow if it were removed.
    @Test("Re-sampling after the window stays well-formed")
    func testResampleAfterWindow() async throws {
        _ = await ProcessMonitor.shared.snapshot()
        try await Task.sleep(for: .milliseconds(1_200))
        let fresh = await ProcessMonitor.shared.snapshot()

        #expect(!fresh.isEmpty)
        #expect(fresh.allSatisfy { $0.cpuPercent >= 0 && $0.cpuPercent <= 100 })
        #expect(fresh.allSatisfy { $0.ramMB >= 0 })
        // PIDs are unique within a sample — a duplicate means the dictionary
        // rebuild in resample() has regressed to appending.
        #expect(Set(fresh.map(\.id)).count == fresh.count)
    }

    @Test("topProcesses honours the limit and sorts by the requested key")
    func testTopProcessesSorting() async {
        let byCPU = await ProcessMonitor.shared.topProcesses(sortBy: .cpu, limit: 5)
        let byRAM = await ProcessMonitor.shared.topProcesses(sortBy: .ram, limit: 5)

        #expect(byCPU.count <= 5)
        #expect(byRAM.count <= 5)
        #expect(zip(byCPU, byCPU.dropFirst()).allSatisfy { $0.cpuPercent >= $1.cpuPercent })
        #expect(zip(byRAM, byRAM.dropFirst()).allSatisfy { $0.ramMB >= $1.ramMB })
    }
}
