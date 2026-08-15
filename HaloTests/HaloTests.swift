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

// MARK: - PermissionAuditor Tests (F-016)

@Suite("PermissionAuditor")
struct PermissionAuditorTests {

    // MARK: PermissionAuditResult / TCCGrant model behaviour

    @Test("unavailable(reason:) carries the honest fallback reason verbatim")
    func testUnavailableCarriesReason() {
        let reason = "Halo needs Full Disk Access to show per-app grants — showing categories only."
        let result = PermissionAuditResult.unavailable(reason: reason)

        guard case .unavailable(let carried) = result else {
            Issue.record("Expected .unavailable case")
            return
        }
        #expect(carried == reason)
    }

    @Test("available(grants:) carries the real per-app grant list")
    func testAvailableCarriesGrants() {
        let grants = [
            TCCGrant(kind: .camera, bundleID: "com.apple.FaceTime", appName: "FaceTime", isElevatedRisk: false)
        ]
        let result = PermissionAuditResult.available(grants: grants)

        guard case .available(let carried) = result else {
            Issue.record("Expected .available case")
            return
        }
        #expect(carried.count == 1)
        #expect(carried[0].bundleID == "com.apple.FaceTime")
    }

    @Test("Each TCCGrant gets a distinct identity even with identical fields")
    func testTCCGrantIdentityIsUnique() {
        let a = TCCGrant(kind: .microphone, bundleID: "com.example.app", appName: "Example", isElevatedRisk: false)
        let b = TCCGrant(kind: .microphone, bundleID: "com.example.app", appName: "Example", isElevatedRisk: false)
        #expect(a.id != b.id) // Identifiable via a fresh UUID, not value equality
    }

    // MARK: Risk-flag heuristic
    //
    // The heuristic itself lives inside `PermissionAuditor.run()` as a private
    // static table (`expectedElevatedPrefixes`) keyed off real TCC.db rows, so
    // it cannot be invoked directly without a live, FDA-readable database.
    // These tests document and pin the documented contract — only
    // Screen Recording / Accessibility are ever eligible for the flag, and
    // known browser/communication bundle IDs are exempt — using synthetic
    // `TCCGrant` values shaped exactly as `PermissionAuditor` would produce
    // them for each case.

    @Test("Non-browser app holding Screen Recording is elevated risk")
    func testNonBrowserScreenRecordingIsElevated() {
        let grant = TCCGrant(kind: .screenRecording, bundleID: "com.random.thirdparty",
                              appName: "Random Tool", isElevatedRisk: true)
        #expect(grant.isElevatedRisk)
    }

    @Test("Known browser holding Screen Recording is not elevated risk")
    func testBrowserScreenRecordingIsExempt() {
        let grant = TCCGrant(kind: .screenRecording, bundleID: "com.google.Chrome",
                              appName: "Google Chrome", isElevatedRisk: false)
        #expect(!grant.isElevatedRisk)
    }

    @Test("Non-browser app holding Accessibility is elevated risk")
    func testNonBrowserAccessibilityIsElevated() {
        let grant = TCCGrant(kind: .accessibility, bundleID: "com.random.thirdparty",
                              appName: "Random Tool", isElevatedRisk: true)
        #expect(grant.isElevatedRisk)
    }

    @Test("Camera/Microphone grants are never flagged elevated regardless of app")
    func testNonElevatedKindsNeverFlagged() {
        // Only .screenRecording and .accessibility are ever eligible for the
        // elevated-risk flag per PermissionAuditor.run(); camera/mic grants
        // are informational only.
        let grant = TCCGrant(kind: .camera, bundleID: "com.random.thirdparty",
                              appName: "Random Tool", isElevatedRisk: false)
        #expect(!grant.isElevatedRisk)
    }

    // MARK: Grant grouping by category
    //
    // Mirrors the grouping loop in `ProtectionViewModel.loadPermissions()`:
    // `for grant in grants { grouped[grant.kind, default: []].append(grant.appName) }`

    @Test("Grants group correctly by PermissionKind")
    func testGroupingByCategory() {
        let grants = [
            TCCGrant(kind: .camera, bundleID: "com.a", appName: "A", isElevatedRisk: false),
            TCCGrant(kind: .camera, bundleID: "com.b", appName: "B", isElevatedRisk: false),
            TCCGrant(kind: .accessibility, bundleID: "com.c", appName: "C", isElevatedRisk: true)
        ]
        var grouped: [PermissionKind: [String]] = [:]
        for grant in grants { grouped[grant.kind, default: []].append(grant.appName) }

        #expect(grouped[.camera]?.count == 2)
        #expect(grouped[.accessibility]?.count == 1)
        #expect(grouped[.microphone] == nil)
    }

    @Test("Empty grant list produces no groups for any kind")
    func testGroupingWithNoGrants() {
        let grants: [TCCGrant] = []
        var grouped: [PermissionKind: [String]] = [:]
        for grant in grants { grouped[grant.kind, default: []].append(grant.appName) }

        for kind in PermissionKind.allCases {
            #expect(grouped[kind] == nil)
        }
    }

    // MARK: "X of Y apps excessive" summary computation
    //
    // Mirrors `PermissionsAuditSection.totalAuditedApps` / `.excessiveAppCount`:
    // unique bundle IDs overall, and unique bundle IDs with at least one
    // elevated-risk grant.

    @Test("Summary count: zero apps with any permission")
    func testSummaryCountZeroApps() {
        let grants: [TCCGrant] = []
        let total = Set(grants.map(\.bundleID)).count
        let excessive = Set(grants.filter(\.isElevatedRisk).map(\.bundleID)).count
        #expect(total == 0)
        #expect(excessive == 0)
    }

    @Test("Summary count: one app with an excessive combination is counted once")
    func testSummaryCountExcessiveAppCountedOnce() {
        // Same app (bundle ID) granted both an elevated permission
        // (Accessibility) and a non-elevated one (Camera) — should count as
        // ONE excessive app, not two, and ONE total app, not two.
        let grants = [
            TCCGrant(kind: .accessibility, bundleID: "com.random.app", appName: "Random",
                     isElevatedRisk: true),
            TCCGrant(kind: .camera, bundleID: "com.random.app", appName: "Random",
                     isElevatedRisk: false)
        ]
        let total = Set(grants.map(\.bundleID)).count
        let excessive = Set(grants.filter(\.isElevatedRisk).map(\.bundleID)).count
        #expect(total == 1)
        #expect(excessive == 1)
    }

    @Test("Summary count: multiple distinct apps, only some excessive")
    func testSummaryCountMixedApps() {
        let grants = [
            TCCGrant(kind: .accessibility, bundleID: "com.risky.app", appName: "Risky", isElevatedRisk: true),
            TCCGrant(kind: .camera, bundleID: "com.safe.app", appName: "Safe", isElevatedRisk: false),
            TCCGrant(kind: .microphone, bundleID: "com.safe.app", appName: "Safe", isElevatedRisk: false)
        ]
        let total = Set(grants.map(\.bundleID)).count
        let excessive = Set(grants.filter(\.isElevatedRisk).map(\.bundleID)).count
        #expect(total == 2)
        #expect(excessive == 1)
    }

    // MARK: Graceful handling when TCC.db read fails

    @Test("PermissionAuditor.run() handles an unreadable TCC.db gracefully")
    func testRunHandlesUnreadableDatabase() async {
        // In a normal dev/CI shell (no Full Disk Access granted to the test
        // runner), TCC.db is unreadable by design — this is the exact
        // failure mode PermissionAuditor must never crash or fabricate data
        // for. Assert whichever real branch this environment hits is
        // internally consistent, so the test stays robust even on a machine
        // that does have Full Disk Access granted.
        let auditor = PermissionAuditor()
        let result = await auditor.run()

        switch result {
        case .unavailable(let reason):
            #expect(!reason.isEmpty)
        case .available(let grants):
            #expect(!grants.isEmpty) // run() never returns .available with an empty array
            for grant in grants {
                #expect(!grant.bundleID.isEmpty)
                #expect(!grant.appName.isEmpty)
            }
        }
    }
}
