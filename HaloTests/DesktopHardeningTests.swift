import Testing
import Foundation
@testable import Halo

// v2.6 desktop hardening — Cleanup (H-02, H-03, H-05).

/// Thread-safe recorder for the closures the view model runs off the main actor.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0, _onMain = 0
    func note() { lock.lock(); _calls += 1; if Thread.isMainThread { _onMain += 1 }; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var onMain: Int { lock.lock(); defer { lock.unlock() }; return _onMain }
}

@MainActor
@Suite("Cleanup hardening (H-02, H-03)")
struct CleanupHardeningTests {
    typealias Fixture = CleanupViewModelTests.Fixture

    @Test("H-02: pruneMissing stats files off the main thread")
    func pruneMissingRunsOffMain() async throws {
        let f = try Fixture()
        for i in 0..<5 { try f.file("f\(i).bin") }
        let rec = Recorder()
        let root = f.root, trash = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] }, trash: { _ in })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches],
                                  existsOnDisk: { url in rec.note(); return CleanupPath.existsOnDisk(url) })
        await vm.scanAll()
        await vm.pruneMissing()
        #expect(rec.calls >= 5, "pruneMissing never consulted the existence check")
        #expect(rec.onMain == 0, "\(rec.onMain) existence checks ran on the main thread")
    }

    @Test("H-02: the existence sweep is bounded — it stops at its deadline instead of stat-ing everything")
    func missingIsBounded() {
        let urls = (0..<50_000).map { URL(fileURLWithPath: "/x/f\($0)") }
        let start = Date()
        let missing = CleanupPath.missing(among: urls, exists: { _ in Thread.sleep(forTimeInterval: 0.001); return false },
                                          deadline: 0.05)
        let elapsed = Date().timeIntervalSince(start)
        #expect(missing.count < urls.count, "ignored the deadline")
        #expect(elapsed < 5, "took \(elapsed)s")
    }

    @Test("H-02: a path the sweep did not reach is treated as present, never dropped on a guess")
    func uncheckedIsKept() {
        let urls = (0..<1000).map { URL(fileURLWithPath: "/x/f\($0)") }
        let missing = CleanupPath.missing(among: urls, exists: { _ in false }, deadline: -1)
        #expect(missing.count < urls.count)
    }

    @Test("H-03: partial failure produces 'Moved 2, 1 failed: …' and the banner survives")
    func partialFailureBanner() async throws {
        let f = try Fixture()
        try f.file("ok1.bin"); try f.file("bad.bin"); try f.file("ok2.bin")
        let vm = f.vm(failing: ["bad.bin"])
        await vm.scanAll()
        let snapshot = try #require(await vm.beginCleanAll(for: .userCaches))
        await vm.cleanAll(confirmed: snapshot)
        let outcome = try #require(vm.outcome, "no banner on partial failure")
        #expect(outcome.moved == 2 && outcome.failed == 1)
        #expect(outcome.message.hasPrefix("Moved 2, 1 failed: "))
        #expect(outcome.message.contains("bad.bin"))
        #expect(outcome.message.contains("denied"))
    }

    @Test("H-03: full success is a banner without failures")
    func successBanner() async throws {
        let f = try Fixture()
        try f.file("a.bin")
        let vm = f.vm()
        await vm.scanAll()
        let snapshot = try #require(await vm.beginCleanAll(for: .userCaches))
        await vm.cleanAll(confirmed: snapshot)
        let outcome = try #require(vm.outcome)
        #expect(outcome.moved == 1 && !outcome.hasFailures)
    }

    @Test("H-03: the banner is cleared by a category switch and by the next full rescan")
    func bannerClears() async throws {
        let f = try Fixture()
        try f.file("ok.bin"); try f.file("bad.bin")
        let vm = f.vm(failing: ["bad.bin"])
        await vm.scanAll()
        let first = try #require(await vm.beginCleanAll(for: .userCaches))
        await vm.cleanAll(confirmed: first)
        #expect(vm.outcome != nil)
        vm.clearOutcome()                          // what CleanupView does on a category switch
        #expect(vm.outcome == nil && vm.cleanError == nil && vm.lastCleanResult == nil)

        let second = try #require(await vm.beginCleanAll(for: .userCaches))
        await vm.cleanAll(confirmed: second)
        #expect(vm.outcome != nil)
        await vm.scanAll()                         // next rescan
        #expect(vm.outcome == nil)
    }

    @Test("H-03: the next operation replaces, never mixes with, the previous outcome")
    func outcomeIsPerOperation() async throws {
        let f = try Fixture()
        try f.file("bad.bin"); try f.file("ok.bin")
        let vm = f.vm(failing: ["bad.bin"])
        await vm.scanAll()
        let bad = try #require(vm.category(for: .userCaches)?.items.first { $0.name == "bad.bin" })
        let ok = try #require(vm.category(for: .userCaches)?.items.first { $0.name == "ok.bin" })
        await vm.cleanSingleItem(bad, for: .userCaches)
        #expect(vm.outcome?.failed == 1)
        await vm.cleanSingleItem(ok, for: .userCaches)
        #expect(vm.outcome?.failed == 0 && vm.outcome?.moved == 1, "the earlier failure leaked into the next banner")
    }
}

@Suite("Cleanup path keys (H-05)")
struct CleanupPathKeyTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("halo-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The two spellings of a temp path: `/var/folders/…` and `/private/var/folders/…`.
    private func spellings(of url: URL) throws -> (viaVar: URL, viaPrivate: URL) {
        let bare = url.path.hasPrefix("/private") ? String(url.path.dropFirst("/private".count)) : url.path
        try #require(bare.hasPrefix("/var/"), "temp dir is not under /var on this machine")
        return (URL(fileURLWithPath: bare), URL(fileURLWithPath: "/private" + bare))
    }

    @Test("/var and /private/var spell one key")
    func varAndPrivateVarAgree() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: file)
        let s = try spellings(of: file)
        #expect(CleanupPath.key(s.viaVar) == CleanupPath.key(s.viaPrivate))
    }

    @Test("A path that no longer exists still resolves its existing ancestors")
    func missingLeafStillNormalises() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try spellings(of: dir.appendingPathComponent("gone/deep.bin"))
        #expect(CleanupPath.key(s.viaVar) == CleanupPath.key(s.viaPrivate))
    }

    @Test("A row addressed by one spelling reconciles when the other is reported removed")
    func reconcilesAcrossSpellings() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: file)
        let s = try spellings(of: file)
        var cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [ScannedItem(id: UUID(), url: s.viaVar, size: 1, creationDate: nil, modifiedDate: nil, kind: .cache)]
        let changed = CleanupReconciler.apply(removedKeys: [CleanupPath.key(s.viaPrivate)], to: &cats)
        #expect(changed == [.userCaches])
        #expect(cats[0].items.isEmpty)
    }

    @Test("The same file listed under both spellings is counted once")
    func totalsCountOnce() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: file)
        let s = try spellings(of: file)
        func item(_ u: URL) -> ScannedItem { ScannedItem(id: UUID(), url: u, size: 100, creationDate: nil, modifiedDate: nil, kind: .cache) }
        var cats = [CleanupCategory(kind: .systemCaches), CleanupCategory(kind: .userCaches)]
        cats[0].items = [item(s.viaVar)]; cats[1].items = [item(s.viaPrivate)]
        #expect(CleanupReconciler.distinctBytes(cats) == 100)
    }

    @Test("Any symlinked directory spells one key — and one row reconciles through either spelling")
    func symlinkedDirectoryAgrees() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real"); let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let viaReal = real.appendingPathComponent("a.bin"); try Data([1]).write(to: viaReal)
        let viaLink = link.appendingPathComponent("a.bin")
        #expect(CleanupPath.key(viaReal) == CleanupPath.key(viaLink))

        var cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [ScannedItem(id: UUID(), url: viaLink, size: 1, creationDate: nil, modifiedDate: nil, kind: .cache)]
        CleanupReconciler.apply(removedKeys: [CleanupPath.key(viaReal)], to: &cats)
        #expect(cats[0].items.isEmpty, "the row survived its file being removed under the other spelling")
    }

    @Test("A symlink item keeps its own identity — trashing the link must not erase its target's row")
    func leafSymlinkNotFollowed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.bin"); try Data([1]).write(to: target)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        #expect(CleanupPath.key(link) != CleanupPath.key(target))
    }

    @Test("Case policy: keys are case-sensitive (documented in CleanupPath.key)")
    func casePolicy() {
        #expect(CleanupPath.key(URL(fileURLWithPath: "/x/Caches/A.bin")) != CleanupPath.key(URL(fileURLWithPath: "/x/Caches/a.bin")))
    }

    @Test("Root-overlap detection sees through symlinked spellings")
    func overlapUsesResolvedKeys() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try spellings(of: dir)
        let overlaps = CleanupPath.overlappingRoots([(.systemCaches, [s.viaVar.path]), (.userCaches, [s.viaPrivate.path])])
        #expect(overlaps.count == 1)
    }
}
