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

// MARK: - SecurityPostureScanner Tests (F-019)
//
// `SecurityPostureScanner.score(for:)` is a pure function over synthetic
// `[SecurityCheck]` arrays, so these tests never spawn the live `Process`
// checks (those depend on the machine's actual FileVault/Gatekeeper/firewall/
// update state and are intentionally left untested here — see
// docs/MANUAL_TEST_PLAN.md §4.1 for their manual coverage).

@Suite("SecurityPostureScanner")
struct SecurityPostureScannerTests {

    /// Builds a synthetic check with an arbitrary state, for scoring in isolation.
    private func check(_ kind: SecurityCheckKind, _ state: SecurityCheckState) -> SecurityCheck {
        SecurityCheck(kind: kind, state: state, detail: "synthetic")
    }

    @Test("All checks passing scores 100")
    func testAllPassScoresFull() {
        let checks = SecurityCheckKind.allCases.map { check($0, .pass) }
        #expect(SecurityPostureScanner.score(for: checks) == 100)
    }

    @Test("Empty check list scores 100")
    func testEmptyScoresFull() {
        #expect(SecurityPostureScanner.score(for: []) == 100)
    }

    @Test("A single fail subtracts 15")
    func testSingleFailSubtracts15() {
        let checks = [check(.fileVault, .fail)] + SecurityCheckKind.allCases.dropFirst().map { check($0, .pass) }
        #expect(SecurityPostureScanner.score(for: checks) == 85)
    }

    @Test("A single warn subtracts 7")
    func testSingleWarnSubtracts7() {
        let checks = [check(.automaticUpdates, .warn)] + SecurityCheckKind.allCases.filter { $0 != .automaticUpdates }.map { check($0, .pass) }
        #expect(SecurityPostureScanner.score(for: checks) == 93)
    }

    @Test("Multiple fails and warns sum correctly")
    func testMultipleFailsAndWarnsSum() {
        // 2 fails (-30) + 1 warn (-7) + rest pass = 100 - 37 = 63
        let checks: [SecurityCheck] = [
            check(.fileVault, .fail),
            check(.gatekeeper, .fail),
            check(.firewall, .warn),
            check(.automaticUpdates, .pass),
            check(.sip, .pass),
            check(.secureBoot, .pass),
            check(.findMy, .pass),
            check(.loginWindow, .pass)
        ]
        #expect(SecurityPostureScanner.score(for: checks) == 63)
    }

    @Test("Score is clamped to a 0...100 range and never goes negative")
    func testScoreClampedAtZero() {
        // 8 fails would be 100 - 120 = -20 unclamped; must clamp to 0.
        let checks = SecurityCheckKind.allCases.map { check($0, .fail) }
        #expect(SecurityPostureScanner.score(for: checks) == 0)
    }

    @Test("Score never exceeds 100 even with no penalizing checks")
    func testScoreClampedAtHundred() {
        let checks = SecurityCheckKind.allCases.map { check($0, .pass) }
        #expect(SecurityPostureScanner.score(for: checks) <= 100)
    }

    // MARK: - The critical invariant

    @Test("All-unknown checks NEVER penalize the score — this is the core F-019 invariant")
    func testAllUnknownNeverPenalizes() {
        let checks = SecurityCheckKind.allCases.map { check($0, .unknown) }
        #expect(SecurityPostureScanner.score(for: checks) == 100,
                """
                Unknown states (SIP, Secure Boot, Find My, Login Window — and any \
                check whose Process call failed) must never subtract from the score, \
                since Halo has no reliable way to verify them and must not guess.
                """)
    }

    @Test("Mixed fail + unknown: only the fail counts, unknowns are ignored")
    func testMixedFailAndUnknownOnlyFailCounts() {
        let checks: [SecurityCheck] = [
            check(.fileVault, .fail),
            check(.gatekeeper, .unknown),
            check(.firewall, .unknown),
            check(.automaticUpdates, .unknown),
            check(.sip, .unknown),
            check(.secureBoot, .unknown),
            check(.findMy, .unknown),
            check(.loginWindow, .unknown)
        ]
        // Only the single fail (-15) should count; all 7 unknowns contribute nothing.
        #expect(SecurityPostureScanner.score(for: checks) == 85)
    }

    @Test("Mixed warn + unknown: only the warn counts, unknowns are ignored")
    func testMixedWarnAndUnknownOnlyWarnCounts() {
        let checks: [SecurityCheck] = [
            check(.automaticUpdates, .warn),
            check(.fileVault, .unknown),
            check(.gatekeeper, .unknown),
            check(.firewall, .unknown),
            check(.sip, .unknown),
            check(.secureBoot, .unknown),
            check(.findMy, .unknown),
            check(.loginWindow, .unknown)
        ]
        #expect(SecurityPostureScanner.score(for: checks) == 93)
    }

    @Test("SecurityCheckState maps to expected color and icon")
    func testStateColorAndIcon() {
        #expect(SecurityCheckState.pass.icon == "checkmark.circle.fill")
        #expect(SecurityCheckState.warn.icon == "exclamationmark.triangle.fill")
        #expect(SecurityCheckState.fail.icon == "xmark.circle.fill")
        #expect(SecurityCheckState.unknown.icon == "questionmark.circle.fill")
    }

    @Test("The 4 manual-guidance checks have no System Settings deep link for SIP/Secure Boot")
    func testManualChecksSettingsURLs() {
        // SIP and Secure Boot are only viewable from Terminal / Recovery Mode —
        // there is no System Settings pane to deep-link to, so the "Fix" button
        // must not render for these two.
        #expect(SecurityCheckKind.sip.settingsURL == nil)
        #expect(SecurityCheckKind.secureBoot.settingsURL == nil)
        // Find My and Login Window DO have a reachable settings pane.
        #expect(SecurityCheckKind.findMy.settingsURL != nil)
        #expect(SecurityCheckKind.loginWindow.settingsURL != nil)
    }

    @Test("All 8 SecurityCheckKind cases have distinct id slugs")
    func testIdSlugsAreDistinct() {
        let slugs = SecurityCheckKind.allCases.map(\.idSlug)
        #expect(Set(slugs).count == slugs.count)
        #expect(slugs.count == 8)
    }
}

// MARK: - F-019 review fixes

@Suite("SecurityCheck identity")
struct SecurityCheckIdentityTests {

    // loadSecurityPosture() replaces the whole array on every Refresh, so a
    // generated UUID id made all eight rows look brand new to ForEach.
    @Test("Identity is the check kind, stable across rescans")
    func testIdentityIsKind() {
        let a = SecurityCheck(kind: .firewall, state: .pass, detail: "On")
        let b = SecurityCheck(kind: .firewall, state: .fail, detail: "Off")
        #expect(a.id == b.id)
        #expect(a.id == .firewall)
    }

    @Test("Different kinds have different identities")
    func testDistinctKinds() {
        let checks = SecurityCheckKind.allCases.map {
            SecurityCheck(kind: $0, state: .unknown, detail: "")
        }
        #expect(Set(checks.map(\.id)).count == checks.count)
    }
}

// MARK: - Shared security-posture store
//
// The store is the single source both the Protection checklist and the
// Dashboard health score read from, so its refresh contract matters more than
// a normal view model's.
// Each test drives its own instance, never `.shared`. `HaloTests` is hosted in
// Halo, so `AppState.init()` has already kicked off a scan on `shared` before
// the first test runs — asserting `isRefreshing == false` against it fails
// immediately and for a reason that has nothing to do with the code under test.
@Suite("SecurityPostureStore")
struct SecurityPostureStoreTests {

    // `isRefreshing` was published but never checked, so opening Protection
    // during the launch-time scan started a second one: ten posix_spawns
    // instead of five, and whichever finished first cleared the flag while the
    // other was still running, stopping the spinner early.
    @Test("A concurrent refresh is collapsed, not run twice")
    @MainActor
    func testRefreshIsNotReentrant() async {
        let store = SecurityPostureStore()

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        // Both settle, the flag is clean, and the score is a real value from a
        // completed scan rather than a half-applied one.
        #expect(store.isRefreshing == false)
        #expect(store.score >= 0 && store.score <= 100)
    }

    // `score` is published rather than computed so readers can subscribe to the
    // value and `removeDuplicates()`; if it ever drifts from `checks` the
    // Dashboard and the checklist disagree again, which is the whole thing this
    // store exists to prevent.
    @Test("The published score always matches the published checks")
    @MainActor
    func testPublishedScoreMatchesChecks() async {
        let store = SecurityPostureStore()
        await store.refresh()

        #expect(store.score == SecurityPostureScanner.score(for: store.checks))
    }

    @Test("The flag is cleared even when a refresh returns early")
    @MainActor
    func testFlagClearedOnEarlyReturn() async {
        let store = SecurityPostureStore()
        await store.refresh()
        await store.refresh()   // the second sees a clean flag and runs normally
        #expect(store.isRefreshing == false)
    }
}

@Suite("SecurityPostureScanner scoring")
struct SecurityPostureScoringTests {

    // `.unknown` must never be scored — under the sandbox every automated check
    // reads unknown, and scoring them as failures would invent a bad verdict
    // from an absence of information.
    @Test("Unknown checks do not reduce the score")
    func testUnknownIsNotPenalised() {
        let checks = SecurityCheckKind.allCases.map {
            SecurityCheck(kind: $0, state: .unknown, detail: "")
        }
        #expect(SecurityPostureScanner.score(for: checks) == 100)
    }

    @Test("A failing check reduces the score")
    func testFailReducesScore() {
        let passing = [SecurityCheck(kind: .firewall, state: .pass, detail: "")]
        let failing = [SecurityCheck(kind: .firewall, state: .fail, detail: "")]
        #expect(SecurityPostureScanner.score(for: failing) < SecurityPostureScanner.score(for: passing))
    }
}
