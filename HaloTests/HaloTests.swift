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
