import XCTest
import HaloShareKit
import HaloShareStaging
@testable import HaloMobile

// MARK: - Rig

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _offers = 0
    var decision: ConsentDecision = .accept
    var delay: TimeInterval = 0
    var offers: Int { lock.withLock { _offers } }
    func hit() { lock.withLock { _offers += 1 } }
}

@MainActor
private final class FakeBG: BackgroundTaskProviding {
    var begun = 0
    var expire: (@MainActor () -> Void)?
    func beginTask(name: String, expiration: @escaping @MainActor () -> Void) -> Int? { begun += 1; expire = expiration; return begun }
    func endTask(_ token: Int) {}
}

@MainActor
private final class FakeNotifier: InterruptionNotifying {
    var posted = 0
    func notifyInterrupted(_ work: Set<BackgroundTransferGuard.Work>) { posted += 1 }
}

@MainActor
private struct Rig {
    let model: AppModel
    let staging: ShareStagingStore
    let server: HaloShareServer
    let counter: Counter
    let receiveDir: URL
    let bg: FakeBG
    let notifier: FakeNotifier
    let peerID: String

    static func make(decision: ConsentDecision = .accept, consentDelay: TimeInterval = 0) async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hm-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = tmp.appendingPathComponent("staging"), rxDir = tmp.appendingPathComponent("rx"), appRx = tmp.appendingPathComponent("app-received")
        try FileManager.default.createDirectory(at: rxDir, withIntermediateDirectories: true)

        let counter = Counter(); counter.decision = decision; counter.delay = consentDelay
        let identity = DeviceIdentity(alias: "Mac", fingerprint: DeviceIdentity.randomFingerprint(), deviceType: "desktop")
        let server = HaloShareServer(configuration: .init(identity: identity, receiveDirectory: rxDir)) { _ in
            counter.hit()
            if counter.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(counter.delay * 1e9)) }
            return counter.decision
        }
        let port = Int(try await server.start(port: 0))

        let defaults = UserDefaults(suiteName: "hm-tests-\(UUID().uuidString)")!
        let staging = ShareStagingStore(root: stagingRoot)
        let bg = FakeBG(), notifier = FakeNotifier()
        let model = AppModel(defaults: defaults, staging: staging, receiveDirectory: appRx, backgroundTasks: bg, notifier: notifier)

        // Find the "Mac" the way the app would: by address.
        model.addManualPeer(address: "127.0.0.1:\(port)")
        try await waitUntil { !model.peers.isEmpty }
        let peerID = try XCTUnwrap(model.peers.first?.id)
        return Rig(model: model, staging: staging, server: server, counter: counter, receiveDir: rxDir, bg: bg, notifier: notifier, peerID: peerID)
    }

    @discardableResult
    func stage(_ name: String = "shared.bin", bytes: Int = 2048) throws -> StagedBatch {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)-\(name)")
        try Data(repeating: 7, count: bytes).write(to: src)
        let b = try staging.makeBatchBuilder()
        try b.addFile(copying: src, suggestedName: name)
        return try XCTUnwrap(try b.commit())
    }
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 8, _ cond: @MainActor () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { XCTFail("timed out waiting"); return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

// MARK: - Tests

@MainActor
final class OutboxTests: XCTestCase {

    /// F-050 D7 / the core safety rule: an item shared from another app is *lined up*, the device
    /// picker opens, and **nothing goes on the wire** until the person taps Send.
    func testStagedShareIsLinedUpButNeverSentWithoutATap() async throws {
        let rig = try await Rig.make()
        let batch = try rig.stage()

        rig.model.loadStagedShares()

        XCTAssertNotNil(rig.model.outbox)
        XCTAssertEqual(rig.model.outbox?.source, .sharedFromApp(batchID: batch.id))
        XCTAssertTrue(rig.model.showSendSheet, "the device picker opens")
        XCTAssertNil(rig.model.selectedPeerID, "no device is pre-selected for the person")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(rig.counter.offers, 0, "no prepare-upload reached the receiver")
        XCTAssertEqual(rig.model.transfer, .idle)
        XCTAssertEqual(rig.staging.pendingBatches().count, 1, "still staged")
    }

    func testTappingSendDeliversTheFileAndCleansTheStagingDirectory() async throws {
        let rig = try await Rig.make()
        let batch = try rig.stage("hello.bin", bytes: 4096)
        rig.model.loadStagedShares()

        rig.model.sendOutbox(to: rig.peerID)
        try await waitUntil { if case .finished = rig.model.transfer { return true } else { return false } }

        XCTAssertEqual(rig.counter.offers, 1)
        let got = try Data(contentsOf: rig.receiveDir.appendingPathComponent("hello.bin"))
        XCTAssertEqual(got, Data(repeating: 7, count: 4096))
        XCTAssertNil(rig.model.outbox)
        XCTAssertTrue(rig.staging.pendingBatches().isEmpty, "staging cleaned after send")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.staging.root.appendingPathComponent(batch.id).path))
    }

    func testDeclinedKeepsTheSelectionSoItCanBeSentElsewhere() async throws {
        let rig = try await Rig.make(decision: .decline)
        try rig.stage()
        rig.model.loadStagedShares()
        rig.model.sendOutbox(to: rig.peerID)
        try await waitUntil { if case .finished = rig.model.transfer { return true } else { return false } }
        XCTAssertNotNil(rig.model.outbox)
        XCTAssertEqual(rig.staging.pendingBatches().count, 1)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: rig.receiveDir.path)) ?? []
        XCTAssertTrue(written.isEmpty, "declined ⇒ nothing written")
    }

    func testSendWithoutAChosenDeviceDoesNothing() async throws {
        let rig = try await Rig.make()
        try rig.stage()
        rig.model.loadStagedShares()
        rig.model.sendOutbox(to: "no-such-device")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rig.counter.offers, 0)
        XCTAssertEqual(rig.model.transfer, .idle)
    }

    func testDiscardRemovesTheStagedCopy() async throws {
        let rig = try await Rig.make()
        try rig.stage()
        rig.model.loadStagedShares()
        rig.model.discardOutbox()
        XCTAssertNil(rig.model.outbox)
        XCTAssertFalse(rig.model.showSendSheet)
        XCTAssertTrue(rig.staging.pendingBatches().isEmpty)
        XCTAssertEqual(rig.counter.offers, 0)
    }

    func testASecondSharedBatchIsPickedUpAfterTheFirstIsDone() async throws {
        let rig = try await Rig.make()
        try rig.stage("one.bin"); try rig.stage("two.bin")
        rig.model.loadStagedShares()
        XCTAssertEqual(rig.model.otherStagedBatchCount, 1)
        rig.model.discardOutbox()
        XCTAssertNotNil(rig.model.outbox, "the next batch is lined up")
        XCTAssertEqual(rig.model.otherStagedBatchCount, 0)
    }

    /// SwiftUI reads `otherStagedBatchCount` from a view body. It must be a cached value, not a
    /// directory listing: a batch staged *behind the model's back* is not seen by a read, only by the
    /// next refresh (foreground / outbox change). If this were computed, the read would see it at once.
    func testOtherStagedBatchCountIsCachedNotReadFromDiskDuringRender() async throws {
        let rig = try await Rig.make()
        try rig.stage("one.bin")
        rig.model.loadStagedShares()
        XCTAssertEqual(rig.model.otherStagedBatchCount, 0)
        try rig.stage("two.bin")                                   // arrives while the first is in the outbox
        XCTAssertEqual(rig.model.otherStagedBatchCount, 0, "a render must not hit the disk")
        rig.model.loadStagedShares()                               // the foreground hook refreshes it
        XCTAssertEqual(rig.model.otherStagedBatchCount, 1)
    }

    // MARK: Inbox

    func testInboxDeleteOnlyReachesFilesInsideTheReceiveFolder() async throws {
        let rig = try await Rig.make()
        let inside = rig.model.receiveDirectory.appendingPathComponent("keep-me.txt")
        try Data("x".utf8).write(to: inside)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: outside)

        XCTAssertFalse(rig.model.deleteInboxItem(InboxItem(url: outside, size: 1, date: Date())))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a path outside the inbox is untouchable")
        // A traversal spelled through the inbox folder is no better.
        let sneaky = rig.model.receiveDirectory.appendingPathComponent("../\(outside.lastPathComponent)")
        XCTAssertFalse(rig.model.deleteInboxItem(InboxItem(url: sneaky, size: 1, date: Date())))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        XCTAssertTrue(rig.model.deleteInboxItem(InboxItem(url: inside, size: 1, date: Date())))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: Background (D8)

    func testLeavingMidSendHoldsABackgroundTaskAndExpiryNotifiesAndFailsHonestly() async throws {
        // The receiver keeps the sender waiting on consent, so the send is reliably "in flight".
        let rig = try await Rig.make(consentDelay: 30)
        try rig.stage()
        rig.model.loadStagedShares()
        rig.model.sendOutbox(to: rig.peerID)
        try await waitUntil { rig.model.transfer.isBusy }

        rig.model.didEnterBackground()
        XCTAssertEqual(rig.bg.begun, 1, "a background task was requested for the transfer in flight")

        rig.bg.expire?()                                  // iOS: out of time
        XCTAssertEqual(rig.notifier.posted, 1, "exactly one 'tap to finish' notification")
        try await waitUntil { if case .failed = rig.model.transfer { return true } else { return false } }
        if case .failed(let why) = rig.model.transfer { XCTAssertTrue(why.contains("background")) }
        XCTAssertNotNil(rig.model.outbox, "the selection survives, so the person can send again")
    }

    /// Closing the send sheet mid-send leaves the Share tab's pickers reachable. Picking again used
    /// to replace the selection, which cleaned up the old one — deleting the staged copy (and ending
    /// the security scope) under an upload that was still reading it.
    func testPickingWhileASendIsInFlightCannotReplaceTheSelectionUnderIt() async throws {
        let rig = try await Rig.make(consentDelay: 30)
        let batch = try rig.stage()
        rig.model.loadStagedShares()
        rig.model.sendOutbox(to: rig.peerID)
        try await waitUntil { rig.model.transfer.isBusy }

        let other = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 64).write(to: other)
        rig.model.queue(pickedFiles: [other])
        rig.model.queueTestFile(megabytes: 1)

        XCTAssertEqual(rig.model.outbox?.source, .sharedFromApp(batchID: batch.id), "the in-flight selection is untouched")
        XCTAssertTrue(rig.model.transfer.isBusy, "and the transfer is not reset to idle")
        XCTAssertEqual(rig.staging.pendingBatches().count, 1, "its staged copy is still on disk")
    }

    func testLeavingWithNothingInFlightRequestsNoBackgroundTask() async throws {
        let rig = try await Rig.make()
        rig.model.didEnterBackground()
        XCTAssertEqual(rig.bg.begun, 0)
        XCTAssertEqual(rig.notifier.posted, 0)
        XCTAssertEqual(rig.model.listenState, .stopped)
    }

    // MARK: Discovery

    func testManualAddressIsRemembered() async throws {
        let rig = try await Rig.make()
        XCTAssertEqual(rig.model.recentAddresses.count, 1)
        XCTAssertEqual(rig.model.peers.count, 1)
    }
}
