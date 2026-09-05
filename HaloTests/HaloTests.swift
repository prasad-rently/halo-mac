import Testing
import Foundation
import AppKit
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

    // This test used to scan the real home directory to depth 10 and break
    // after 5 `.item` events. Two things made that unbounded:
    //
    //   * `.item` events are only emitted *after* `traverse` returns, so the
    //     early `break` could never fire until the entire home directory had
    //     been walked; and
    //   * nothing cancelled the producing task, so the walk ran to completion
    //     regardless.
    //
    // On a developer machine that is minutes, not seconds, and the duration
    // depends on whatever happens to be in `~` — so it passed most days and
    // hung on others. It now runs against a fixture it owns.
    @Test("Breaking out of the stream terminates it cleanly and promptly")
    func testCancellationStopsScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloScanCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough files, nested, that a runaway walk is measurably slower than
        // an early exit.
        for dir in 0..<20 {
            let sub = root.appendingPathComponent("d\(dir)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for file in 0..<50 {
                try Data(repeating: 0x41, count: 2048)
                    .write(to: sub.appendingPathComponent("f\(file).log"))
            }
        }

        var config = FileSystemScanner.ScanConfig()
        config.maxDepth = 10
        config.minSizeBytes = 0

        let scanner = FileSystemScanner()
        let started = Date()

        var progressSeen = 0
        for await event in await scanner.scanDirectory(root, config: config) {
            if case .progress = event {
                progressSeen += 1
                if progressSeen >= 5 { break }
            }
        }

        let elapsed = Date().timeIntervalSince(started)

        #expect(progressSeen == 5)
        // The real assertion is that this returns at all. Before the
        // `onTermination` fix the producing task kept walking after the
        // consumer left; the bound catches a regression to that.
        #expect(elapsed < 20, "Stream took \(elapsed)s to release the consumer")
    }

    @Test("A completed scan reports every file in a fixture tree")
    func testScanFindsFixtureFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloScanFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<12 {
            try Data(repeating: 0x42, count: 4096)
                .write(to: root.appendingPathComponent("file\(i).log"))
        }

        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 0

        var items = 0
        var completedCount: Int?
        for await event in await FileSystemScanner().scanDirectory(root, config: config) {
            switch event {
            case .item:                       items += 1
            case .completed(let count, _):    completedCount = count
            default:                          break
            }
        }

        #expect(items == 12)
        #expect(completedCount == 12)
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

// MARK: - ShellReader Tests
//
// The point of ShellReader is that it survives three things hand-rolled
// `Process` code did not: output larger than the 64 KB pipe buffer, an
// undrained stderr, and a child that never exits. Those are exactly what these
// tests exercise — a regression here shows up as a hang, so the large-output
// and timeout cases carry an explicit time limit rather than being left to
// block a CI run indefinitely.

@Suite("ShellReader")
struct ShellReaderTests {

    /// Darwin's pipe buffer. Anything at or above this deadlocks a
    /// `waitUntilExit()`-before-read implementation.
    private static let pipeBuffer = 65_536

    /// Writes `bytes` of printable ASCII to a temp file and returns its path.
    private func makeLargeFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo.shellreader.\(UUID().uuidString).txt")
        // One long line of 'a' plus newlines, so the output is valid UTF-8 and
        // the byte count is exact.
        let chunk = String(repeating: "a", count: 1023) + "\n"
        var text = ""
        text.reserveCapacity(bytes + chunk.count)
        while text.utf8.count < bytes { text += chunk }
        try Data(text.utf8.prefix(bytes)).write(to: url)
        return url
    }

    // MARK: - Basics

    @Test("Captures stdout and a zero exit status")
    func testSimpleOutput() {
        let result = ShellReader.run("/bin/echo", ["hello halo"])
        #expect(result.standardOutput == "hello halo\n")
        #expect(result.standardError.isEmpty)
        #expect(result.exitCode == 0)
        #expect(result.didTimeOut == false)
        #expect(result.launchFailure == nil)
        #expect(result.succeeded)
    }

    @Test("A non-zero exit status is reported, not swallowed")
    func testNonZeroExit() {
        let result = ShellReader.run("/bin/sh", ["-c", "exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.succeeded == false)
        #expect(result.outputIfSucceeded == nil)
    }

    @Test("stderr is captured separately and never pollutes stdout")
    func testStreamsKeptSeparate() {
        let result = ShellReader.run("/bin/sh", ["-c", "echo out; echo err >&2"])
        #expect(result.standardOutput == "out\n")
        #expect(result.standardError == "err\n")
        #expect(result.succeeded,
                "Writing to stderr is not itself a failure — only the exit status decides.")
    }

    // MARK: - The deadlock cases
    //
    // These are the regression tests for the bug this type was extracted to
    // fix. Under a `waitUntilExit()`-before-read implementation they hang
    // forever rather than failing.

    @Test("Output larger than the 64 KB pipe buffer does not deadlock",
          .timeLimit(.minutes(1)))
    func testLargeStdoutDoesNotDeadlock() throws {
        let size = Self.pipeBuffer * 4          // 256 KB — comfortably past one buffer
        let file = try makeLargeFile(bytes: size)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = ShellReader.run("/bin/cat", [file.path])

        #expect(result.succeeded)
        #expect(result.standardOutput.utf8.count == size,
                "Expected all \(size) bytes back; got \(result.standardOutput.utf8.count). A short read means a pipe was not fully drained.")
    }

    @Test("Large output on BOTH streams at once does not deadlock",
          .timeLimit(.minutes(1)))
    func testLargeStdoutAndStderrDoNotDeadlock() throws {
        // The case a stdout-only fix still misses: draining stdout but leaving
        // stderr on an unread Pipe() deadlocks identically once stderr fills.
        let size = Self.pipeBuffer * 2          // 128 KB down each stream
        let file = try makeLargeFile(bytes: size)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = ShellReader.run("/bin/sh", ["-c", #"cat "$0"; cat "$0" >&2"#, file.path])

        #expect(result.succeeded)
        #expect(result.standardOutput.utf8.count == size)
        #expect(result.standardError.utf8.count == size,
                "stderr must be drained concurrently, not left on a Pipe nobody reads.")
    }

    // MARK: - Timeout
    //
    // The hazard that survives fixing the pipe ordering: waitUntilExit() takes
    // no deadline, so a child that never exits blocks the caller forever.

    @Test("A child that overruns its timeout is terminated and reported",
          .timeLimit(.minutes(1)))
    func testTimeoutTerminatesChild() {
        let start = Date()
        let result = ShellReader.run("/bin/sleep", ["60"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.didTimeOut)
        #expect(result.succeeded == false)
        #expect(elapsed < 10,
                "Should have returned about a second in, not waited out the full sleep. Took \(elapsed)s.")
    }

    @Test("Partial output is still returned when a child times out",
          .timeLimit(.minutes(1)))
    func testTimeoutStillReturnsPartialOutput() {
        // Prints immediately, then hangs. The early output must survive.
        let result = ShellReader.run("/bin/sh", ["-c", "echo early; sleep 60"], timeout: 2)
        #expect(result.didTimeOut)
        #expect(result.standardOutput.contains("early"),
                "Output written before the timeout should not be discarded.")
    }

    // MARK: - Launch failure
    //
    // Under the release App Sandbox posix_spawn is denied, so this is the path
    // every call takes in an App Store build. It has to be distinguishable from
    // "the tool ran and found nothing", or the UI reports a confident zero.

    @Test("A missing executable is a launch failure, not an empty success")
    func testLaunchFailureIsDistinctFromEmptyOutput() {
        let result = ShellReader.run("/usr/bin/definitely-not-a-real-halo-binary")

        #expect(result.launchFailure != nil,
                "Callers must be able to tell 'we could not ask' from 'the answer was empty'.")
        #expect(result.succeeded == false)
        #expect(result.standardOutput.isEmpty)
        #expect(result.exitCode == -1)
    }

    @Test("A successful empty result is not mistaken for a launch failure")
    func testEmptyOutputStillSucceeds() {
        let result = ShellReader.run("/usr/bin/true")
        #expect(result.launchFailure == nil)
        #expect(result.succeeded)
        #expect(result.standardOutput.isEmpty)
        #expect(result.outputIfSucceeded == "")
    }

    // MARK: - Concurrency
    //
    // This is the regression test for the bug that the *first* implementation
    // of ShellReader shipped with, and which only surfaced because the suite
    // above runs in parallel: draining each pipe with a blocking read on
    // DispatchQueue.global() and waiting on a DispatchGroup parks two pool
    // threads per call while a third waits on them. Once enough calls overlap,
    // the pool has no thread left to run a drain block, `leave()` is never
    // reached, and the wait never returns — a hang, not a failure.
    //
    // Halo really does have several of these in flight at once (AppState's
    // SMART timer, SystemControlsManager's poll loop, an AI tool call), so this
    // is a production case and not a test artifact. Kept explicit so a future
    // "tidy-up" back to a worker-per-pipe design fails here loudly.

    @Test("Many overlapping calls with large output on both streams all complete",
          .timeLimit(.minutes(2)))
    func testConcurrentCallsDoNotStarveOrDeadlock() throws {
        let size = Self.pipeBuffer * 2          // 128 KB down each stream, per call
        let file = try makeLargeFile(bytes: size)
        defer { try? FileManager.default.removeItem(at: file) }

        let callCount = 24
        let collector = ResultCollector()
        DispatchQueue.concurrentPerform(iterations: callCount) { _ in
            collector.add(ShellReader.run(
                "/bin/sh", ["-c", #"cat "$0"; cat "$0" >&2"#, file.path]
            ))
        }

        let collected = collector.all
        #expect(collected.count == callCount)
        #expect(collected.allSatisfy { $0.succeeded })
        #expect(collected.allSatisfy { $0.standardOutput.utf8.count == size },
                "Every concurrent call must get its full stdout back, not a short read.")
        #expect(collected.allSatisfy { $0.standardError.utf8.count == size },
                "…and its full stderr.")
    }

    @Test("Overlapping timeouts all resolve independently", .timeLimit(.minutes(2)))
    func testConcurrentTimeoutsDoNotBlockEachOther() {
        // Each call parks for its whole timeout, which is the worst case for a
        // thread-pool-based design.
        let callCount = 12
        let collector = ResultCollector()
        DispatchQueue.concurrentPerform(iterations: callCount) { _ in
            collector.add(ShellReader.run("/bin/sleep", ["60"], timeout: 1))
        }
        let collected = collector.all
        #expect(collected.count == callCount)
        #expect(collected.allSatisfy { $0.didTimeOut })
        #expect(collected.allSatisfy { !$0.succeeded })
    }

    /// Thread-safe sink for results gathered off `concurrentPerform`.
    private final class ResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [ShellReader.Result] = []

        func add(_ result: ShellReader.Result) {
            lock.lock(); results.append(result); lock.unlock()
        }

        var all: [ShellReader.Result] {
            lock.lock(); defer { lock.unlock() }
            return results
        }
    }

    // MARK: - Argument handling

    @Test("Arguments are passed as argv, so no shell quoting is needed")
    func testArgumentsAreNotShellInterpreted() {
        // If these were interpolated into a shell command line, the semicolon
        // and backtick would be interpreted. As argv they are literal text.
        let hostile = "a; rm -rf /tmp/nothing; `whoami`"
        let result = ShellReader.run("/bin/echo", [hostile])
        #expect(result.standardOutput == hostile + "\n")
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

    // The deadline is a cancellable `Task` so the fast path reclaims it instead
    // of leaving it queued for the full timeout. This exercises that path hard:
    // 400 fast calls against a 60 s ceiling. If cancellation raced the gate the
    // deadline could resume an already-resumed continuation, which is a hard
    // fatalError — so the suite surviving is the assertion, alongside the wall
    // clock staying nowhere near the timeout.
    @Test("Many fast calls with a long ceiling all settle promptly")
    func testFastPathReclaimsTheDeadline() async {
        let started = Date()
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 0..<400 {
                group.addTask { await AsyncTimeout.run(seconds: 60) { $0(i) } }
            }
            var seen: [Int] = []
            for await r in group { if let r { seen.append(r) } }
            return seen
        }
        #expect(results.count == 400)
        #expect(Set(results) == Set(0..<400))
        #expect(Date().timeIntervalSince(started) < 10)
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

// MARK: - SMARTDiskMonitor Tests (F-020)
//
// `classify(...)` and `nonEmpty(_:)` are pure/static, so these tests never
// shell out to `diskutil` or touch IOKit (those depend on the real machine's
// actual drives — see docs/MANUAL_TEST_PLAN.md for their manual coverage).

@Suite("SMARTDiskMonitor")
struct SMARTDiskMonitorTests {

    private typealias Status = SMARTDiskMonitor.SMARTOverallStatus
    private typealias Info = SMARTDiskMonitor.SMARTDiskInfo

    // MARK: - classify(status:percentageUsed:mediaErrorCount:availableSpare:availableSpareThreshold:)

    @Test("A failing SMART status is always .failing, regardless of every other signal")
    func testClassifyFailingStatusOverridesEverything() {
        let level = Info.classify(status: .failing, percentageUsed: 0, mediaErrorCount: 0,
                                   availableSpare: 100, availableSpareThreshold: 10)
        #expect(level == .failing)
    }

    @Test("Available spare BELOW a credible threshold is a critical failing condition")
    func testClassifyAvailableSpareBelowThresholdIsFailing() {
        // The NVMe spec's condition is spare falling *below* the threshold, so
        // spare == threshold is not yet critical.
        let atThreshold = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 0,
                                         availableSpare: 20, availableSpareThreshold: 20)
        let belowThreshold = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 0,
                                            availableSpare: 19, availableSpareThreshold: 20)
        #expect(atThreshold == .good)
        #expect(belowThreshold == .failing)
    }

    // MARK: - The Apple Silicon threshold trap
    //
    // Verified by hand on this Mac: `diskutil info -plist /` reports
    // AVAILABLE_SPARE = 100 with AVAILABLE_SPARE_THRESHOLD = 99 — nothing like
    // the ~10% the NVMe spec's own examples use. Trusting that literally would
    // declare a healthy drive Failing the first time spare ticks 100 -> 99 and
    // then fire "back up your data immediately" every hour, forever. These are
    // the regression tests for that.

    @Test("Apple's implausible 99% spare threshold never produces a Failing verdict on a healthy drive")
    func testClassifyIgnoresImplausibleAppleSpareThreshold() {
        // Real values read from this machine today.
        let today = Info.classify(status: .verified, percentageUsed: 16, mediaErrorCount: 0,
                                   availableSpare: 100, availableSpareThreshold: 99)
        // The very next percentage point of entirely normal wear.
        let tomorrow = Info.classify(status: .verified, percentageUsed: 16, mediaErrorCount: 0,
                                      availableSpare: 99, availableSpareThreshold: 99)
        // And well beyond it — still nowhere near a real problem.
        let later = Info.classify(status: .verified, percentageUsed: 20, mediaErrorCount: 0,
                                   availableSpare: 80, availableSpareThreshold: 99)
        #expect(today == .good)
        #expect(tomorrow == .good,
                "A drive at 99% spare is healthy. Trusting Apple's threshold of 99 literally would page the user with a false 'drive is failing' alarm.")
        #expect(later == .good)
    }

    @Test("A genuinely low spare still fails, even when the vendor threshold is discarded")
    func testClassifyLowSpareFailsWithoutCredibleThreshold() {
        // Threshold of 99 is discarded, so the backstop has to catch this.
        let withNonsenseThreshold = Info.classify(status: .verified, percentageUsed: 50, mediaErrorCount: 0,
                                                   availableSpare: 5, availableSpareThreshold: 99)
        // No threshold reported at all.
        let withNoThreshold = Info.classify(status: .verified, percentageUsed: 50, mediaErrorCount: 0,
                                             availableSpare: 5, availableSpareThreshold: nil)
        #expect(withNonsenseThreshold == .failing)
        #expect(withNoThreshold == .failing)
    }

    @Test("Spare exactly at the backstop is not yet failing")
    func testClassifySpareAtBackstopBoundary() {
        let at = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 0,
                                availableSpare: SMARTDiskMonitor.SMARTDiskInfo.criticalSparePercent,
                                availableSpareThreshold: nil)
        let below = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 0,
                                   availableSpare: SMARTDiskMonitor.SMARTDiskInfo.criticalSparePercent - 1,
                                   availableSpareThreshold: nil)
        #expect(at == .good)
        #expect(below == .failing)
    }

    @Test("Available spare comfortably above threshold does not fail on its own")
    func testClassifySpareAboveThresholdIsNotFailingByItself() {
        let level = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 0,
                                   availableSpare: 50, availableSpareThreshold: 10)
        #expect(level == .good)
    }

    @Test("100% or greater wear (percentageUsed) is failing")
    func testClassifyFullWearIsFailing() {
        let level = Info.classify(status: .verified, percentageUsed: 100, mediaErrorCount: 0,
                                   availableSpare: nil, availableSpareThreshold: nil)
        #expect(level == .failing)
    }

    @Test("Any non-zero media error count is a warning, not a failure")
    func testClassifyMediaErrorsAreWarning() {
        let level = Info.classify(status: .verified, percentageUsed: 0, mediaErrorCount: 1,
                                   availableSpare: nil, availableSpareThreshold: nil)
        #expect(level == .warning)
    }

    @Test("90-99% wear is a warning, not yet a failure")
    func testClassifyHighWearIsWarning() {
        let level = Info.classify(status: .verified, percentageUsed: 90, mediaErrorCount: 0,
                                   availableSpare: nil, availableSpareThreshold: nil)
        let level99 = Info.classify(status: .verified, percentageUsed: 99, mediaErrorCount: 0,
                                     availableSpare: nil, availableSpareThreshold: nil)
        #expect(level == .warning)
        #expect(level99 == .warning)
    }

    @Test("An unrecognized (.other) SMART status is Unknown, not Warning")
    func testClassifyOtherStatusIsUnknown() {
        // Verified on this Mac: every USB/Thunderbolt bridge enclosure reports
        // SMARTStatus = "Not Supported" (the external SSD at /Volumes/SSDA does).
        // That is the enclosure's normal, healthy state — an amber Warning badge
        // on a perfectly good drive is a false positive, and "can't tell" is
        // exactly what .unknown is for.
        let notSupported = Info.classify(status: .other("Not Supported"), percentageUsed: nil, mediaErrorCount: nil,
                                          availableSpare: nil, availableSpareThreshold: nil)
        let vendorString = Info.classify(status: .other("Some Vendor String"), percentageUsed: 0, mediaErrorCount: 0,
                                          availableSpare: nil, availableSpareThreshold: nil)
        #expect(notSupported == .unknown)
        #expect(vendorString == .unknown)
    }

    @Test("A real problem still outranks an unreadable status")
    func testClassifyOtherStatusDoesNotMaskRealSignals() {
        // .other must not swallow signals we *did* read — the status check sits
        // after the wear/spare/error checks for this reason.
        let worn = Info.classify(status: .other("Not Supported"), percentageUsed: 100, mediaErrorCount: nil,
                                  availableSpare: nil, availableSpareThreshold: nil)
        let lowSpare = Info.classify(status: .other("Not Supported"), percentageUsed: nil, mediaErrorCount: nil,
                                      availableSpare: 2, availableSpareThreshold: nil)
        #expect(worn == .failing)
        #expect(lowSpare == .failing)
    }

    // MARK: - healthLevel vs alertLevel
    //
    // The card can afford to surface anything notable; a system notification is
    // pushed at someone who didn't ask, so it has to clear a higher bar.

    @Test("A single media error colours the card but never pages the user")
    func testMediaErrorWarnsOnCardButNotInAlert() {
        let info = Info(
            id: "/", bsdWholeDiskID: "disk0", model: "APPLE SSD", serialNumber: nil,
            busProtocol: "Apple Fabric", isSolidState: true, capacityBytes: 256_000_000_000,
            overallStatus: .verified, temperatureCelsius: 52, powerOnHours: 3260, powerCycles: 364,
            unsafeShutdowns: 26, totalBytesWritten: nil, totalBytesRead: nil,
            availableSparePercent: 100, availableSpareThresholdPercent: 99, percentageUsed: 16,
            mediaErrorCount: 1, errorLogEntryCount: 0,
            reallocatedSectorCount: nil, pendingSectorCount: nil, scannedAt: Date()
        )
        #expect(info.healthLevel == .warning,
                "One unrecovered read is worth showing on the card.")
        #expect(info.alertLevel == .good,
                "…but a single lifetime error must not fire a daily 'back up important files' banner forever.")
    }

    @Test("A genuinely failing drive still alerts")
    func testFailingDriveAlerts() {
        let info = Info(
            id: "/", bsdWholeDiskID: "disk0", model: "APPLE SSD", serialNumber: nil,
            busProtocol: "Apple Fabric", isSolidState: true, capacityBytes: 256_000_000_000,
            overallStatus: .failing, temperatureCelsius: nil, powerOnHours: nil, powerCycles: nil,
            unsafeShutdowns: nil, totalBytesWritten: nil, totalBytesRead: nil,
            availableSparePercent: nil, availableSpareThresholdPercent: nil, percentageUsed: nil,
            mediaErrorCount: nil, errorLogEntryCount: nil,
            reallocatedSectorCount: nil, pendingSectorCount: nil, scannedAt: Date()
        )
        #expect(info.healthLevel == .failing)
        #expect(info.alertLevel == .failing)
    }

    @Test("High wear alerts, since it is both real and actionable")
    func testHighWearAlerts() {
        let info = Info(
            id: "/", bsdWholeDiskID: "disk0", model: "APPLE SSD", serialNumber: nil,
            busProtocol: "Apple Fabric", isSolidState: true, capacityBytes: 256_000_000_000,
            overallStatus: .verified, temperatureCelsius: nil, powerOnHours: nil, powerCycles: nil,
            unsafeShutdowns: nil, totalBytesWritten: nil, totalBytesRead: nil,
            availableSparePercent: nil, availableSpareThresholdPercent: nil, percentageUsed: 95,
            mediaErrorCount: nil, errorLogEntryCount: nil,
            reallocatedSectorCount: nil, pendingSectorCount: nil, scannedAt: Date()
        )
        #expect(info.healthLevel == .warning)
        #expect(info.alertLevel == .warning)
    }

    @Test("An external enclosure that reports nothing never alerts")
    func testUnsupportedExternalNeverAlerts() {
        // The /Volumes/SSDA case: USB bridge, no SMART dict at all.
        let info = Info(
            id: "/Volumes/SSDA", bsdWholeDiskID: "disk4", model: nil, serialNumber: nil,
            busProtocol: "USB", isSolidState: nil, capacityBytes: 2_000_000_000_000,
            overallStatus: .other("Not Supported"), temperatureCelsius: nil, powerOnHours: nil,
            powerCycles: nil, unsafeShutdowns: nil, totalBytesWritten: nil, totalBytesRead: nil,
            availableSparePercent: nil, availableSpareThresholdPercent: nil, percentageUsed: nil,
            mediaErrorCount: nil, errorLogEntryCount: nil,
            reallocatedSectorCount: nil, pendingSectorCount: nil, scannedAt: Date()
        )
        #expect(info.healthLevel == .unknown)
        #expect(info.alertLevel == .unknown)
    }

    @Test("Verified status with no red flags at all is good")
    func testClassifyVerifiedWithNoIssuesIsGood() {
        let level = Info.classify(status: .verified, percentageUsed: 10, mediaErrorCount: 0,
                                   availableSpare: 90, availableSpareThreshold: 10)
        #expect(level == .good)
    }

    @Test("Unavailable status with no other signal is unknown, never guessed as good")
    func testClassifyUnavailableWithNoSignalsIsUnknown() {
        let level = Info.classify(status: .unavailable, percentageUsed: nil, mediaErrorCount: nil,
                                   availableSpare: nil, availableSpareThreshold: nil)
        #expect(level == .unknown)
    }

    @Test("All-nil optional signals with a verified status still classify as good")
    func testClassifyVerifiedWithAllNilOptionalsIsGood() {
        let level = Info.classify(status: .verified, percentageUsed: nil, mediaErrorCount: nil,
                                   availableSpare: nil, availableSpareThreshold: nil)
        #expect(level == .good)
    }

    // MARK: - nonEmpty(_:)

    @Test("nonEmpty returns nil for a nil input")
    func testNonEmptyNilInput() {
        #expect(SMARTDiskMonitor.nonEmpty(nil) == nil)
    }

    @Test("nonEmpty returns nil for an empty string — the diskutil MediaName-by-mount-path gotcha")
    func testNonEmptyEmptyString() {
        #expect(SMARTDiskMonitor.nonEmpty("") == nil)
    }

    @Test("nonEmpty returns nil for a whitespace-only string")
    func testNonEmptyWhitespaceOnlyString() {
        #expect(SMARTDiskMonitor.nonEmpty("   ") == nil)
    }

    @Test("nonEmpty passes through a real value unchanged")
    func testNonEmptyRealValue() {
        #expect(SMARTDiskMonitor.nonEmpty("APPLE SSD AP0512Z") == "APPLE SSD AP0512Z")
    }

    // MARK: - SMARTDiskInfo.lifespanRemainingPercent

    private func makeInfo(percentageUsed: Int?) -> Info {
        Info(id: "test", bsdWholeDiskID: "disk0", model: nil, serialNumber: nil, busProtocol: nil,
             isSolidState: true, capacityBytes: 0, overallStatus: .verified,
             temperatureCelsius: nil, powerOnHours: nil, powerCycles: nil, unsafeShutdowns: nil,
             totalBytesWritten: nil, totalBytesRead: nil, availableSparePercent: nil,
             availableSpareThresholdPercent: nil, percentageUsed: percentageUsed, mediaErrorCount: nil,
             errorLogEntryCount: nil, reallocatedSectorCount: nil, pendingSectorCount: nil,
             scannedAt: .distantPast)
    }

    @Test("lifespanRemainingPercent is nil when the drive never reported a wear percentage")
    func testLifespanRemainingNilWhenNoWearReported() {
        #expect(makeInfo(percentageUsed: nil).lifespanRemainingPercent == nil)
    }

    @Test("lifespanRemainingPercent is 100 minus the reported wear")
    func testLifespanRemainingIsInverseOfWear() {
        #expect(makeInfo(percentageUsed: 30).lifespanRemainingPercent == 70)
        #expect(makeInfo(percentageUsed: 0).lifespanRemainingPercent == 100)
    }

    @Test("lifespanRemainingPercent never goes negative even if wear reports over 100%")
    func testLifespanRemainingClampsAtZero() {
        #expect(makeInfo(percentageUsed: 110).lifespanRemainingPercent == 0)
    }
}

// MARK: - AlertKind icon coverage
//
// Adding a case to `AlertKind` without adding the matching arm to
// `AlertEntry.icon` / `.accentColor` leaves the alert rendering as a generic
// bell in Alert History. F-020 shipped exactly that gap for both of its kinds.
//
// `phase0/shared-singletons` carries a version of the first test; it is here
// too so this branch is covered before Phase 0 merges.
@Suite("AlertEntry icon coverage")
struct AlertEntryIconCoverageTests {

    @Test("Every AlertKind has its own icon and colour")
    func testEveryKindIsMapped() {
        for kind in AlertManager.AlertKind.allCases {
            let entry = AlertEntry(title: "t", body: "b", kindRaw: kind.rawValue)
            #expect(entry.icon != "bell.fill",
                    "AlertKind.\(kind) has no arm in AlertEntry.icon — renders as a generic bell")
            #expect(entry.accentColor != .haloAccent,
                    "AlertKind.\(kind) has no arm in AlertEntry.accentColor")
        }
    }

    // An SF Symbol name that does not exist renders as a *blank*, not an error,
    // so a typo or an invented name ships silently. Writing these two arms, the
    // obvious `internaldrive.badge.exclamationmark` and `internaldrive.badge.xmark`
    // both turned out not to exist — this is the check that catches that class.
    @Test("Every AlertKind icon resolves to a real SF Symbol")
    func testEveryIconResolves() {
        for kind in AlertManager.AlertKind.allCases {
            let name = AlertEntry(title: "t", body: "b", kindRaw: kind.rawValue).icon
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "AlertKind.\(kind) uses \"\(name)\", which is not an SF Symbol on this OS — it renders blank")
        }
    }
}
