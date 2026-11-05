import Testing
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
@testable import Halo

// v2.6 desktop hardening — Cleanup (H-02, H-03, H-05), Lucky Draw (H-08, H-09, H-10),
// phone wire contract (H-20a) and live line changes (H-21a).

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

    @Test("H-02 (review): cancelling the caller stops the detached existence sweep")
    func pruneMissingHonoursCancellation() async throws {
        let f = try Fixture()
        for i in 0..<1500 { try f.file("f\(i).bin", bytes: 1) }
        let root = f.root, trash = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] }, trash: { _ in })
        // 1500 checks x 2 ms = ~3 s if nothing stops the sweep.
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches],
                                  existsOnDisk: { _ in Thread.sleep(forTimeInterval: 0.002); return true },
                                  pruneDeadline: 30)
        await vm.scanAll()
        let start = Date()
        let task = Task { await vm.pruneMissing() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await task.value
        #expect(Date().timeIntervalSince(start) < 2.0, "the sweep kept running after its caller was cancelled")
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

    // HONESTY NOTE (review of #60): `URL.standardizedFileURL` already maps `/private/var` to `/var`, so the
    // tests that only compare those two spellings (`varAndPrivateVarAgree`, `missingLeafStillNormalises`,
    // `reconcilesAcrossSpellings`, `totalsCountOnce`, `overlapUsesResolvedKeys`) pass even WITHOUT the
    // realpath work. They are regression GUARDS — they go red if the key degrades to comparing raw strings —
    // not proofs of H-05. The tests that actually discriminate are `symlinkedDirectoryAgrees`,
    // `symlinkedRootCoversItems` and, in `CleanupPathVolumeTests`, the firmlink and per-volume case tests.

    /// The two spellings of a temp path: `/var/folders/…` and `/private/var/folders/…`.
    private func spellings(of url: URL) throws -> (viaVar: URL, viaPrivate: URL) {
        let bare = url.path.hasPrefix("/private") ? String(url.path.dropFirst("/private".count)) : url.path
        try #require(bare.hasPrefix("/var/"), "temp dir is not under /var on this machine")
        return (URL(fileURLWithPath: bare), URL(fileURLWithPath: "/private" + bare))
    }

    @Test("guard: /var and /private/var spell one key")
    func varAndPrivateVarAgree() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: file)
        let s = try spellings(of: file)
        #expect(CleanupPath.key(s.viaVar) == CleanupPath.key(s.viaPrivate))
    }

    @Test("guard: a path that no longer exists still resolves its existing ancestors")
    func missingLeafStillNormalises() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try spellings(of: dir.appendingPathComponent("gone/deep.bin"))
        #expect(CleanupPath.key(s.viaVar) == CleanupPath.key(s.viaPrivate))
    }

    @Test("guard: a row addressed by one spelling reconciles when the other is reported removed")
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

    @Test("guard: the same file listed under both spellings is counted once")
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

    @Test("A scan root / Trash that is itself a symlink still covers the items under it")
    func symlinkedRootCoversItems() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real"); let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let item = link.appendingPathComponent("a.bin"); try Data([1]).write(to: item)
        // `key(link)` leaves the leaf alone (a link item is its own thing) — wrong for a root.
        #expect(!CleanupPath.isCovered(CleanupPath.key(item), by: CleanupPath.key(link)))
        #expect(CleanupPath.isCovered(CleanupPath.key(item), by: CleanupPath.directoryKey(link)))
        let overlaps = CleanupPath.overlappingRoots([(.systemCaches, [link.path]), (.userCaches, [real.appendingPathComponent("x").path])])
        #expect(overlaps.count == 1, "a root reached through a symlinked root overlaps it")
    }

    @Test("guard: root-overlap detection sees through /var vs /private/var spellings")
    func overlapUsesResolvedKeys() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try spellings(of: dir)
        let overlaps = CleanupPath.overlappingRoots([(.systemCaches, [s.viaVar.path]), (.userCaches, [s.viaPrivate.path])])
        #expect(overlaps.count == 1)
    }
}


// MARK: - Lucky Draw (H-08, H-09, H-10)

private enum Pixels {
    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Minimal little- or big-endian TIFF with one IFD holding ImageWidth/ImageLength and nothing else —
    /// a *declaration* of a size with no pixel data behind it.
    static func tiffHeader(width: Int, height: Int, bigEndian: Bool = false, type: Int = 4) -> Data {
        func u16(_ v: Int) -> [UInt8] { bigEndian ? [UInt8(v >> 8 & 255), UInt8(v & 255)] : [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        func u32(_ v: Int) -> [UInt8] {
            bigEndian ? [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                      : [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)]
        }
        var b: [UInt8] = bigEndian ? [0x4D, 0x4D, 0, 0x2A] : [0x49, 0x49, 0x2A, 0]
        b += u32(8)                       // IFD at offset 8
        b += u16(2)                       // two entries
        for (tag, value) in [(256, width), (257, height)] {
            b += u16(tag) + u16(type) + u32(1) + (type == 3 ? u16(value) + [0, 0] : u32(value))
        }
        b += u32(0)
        return Data(b)
    }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("halo-hard-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: H-08

@MainActor
@Suite("Lucky Draw fairness, end to end (H-08)")
struct DrawFairnessEndToEndTests {

    private let labels = (0..<12).map { "Person \($0)" }

    /// A store with `labels` on its selected roster — optionally every entry carrying an avatar of some
    /// kind — shown in `mode`.
    private func store(adorned: Bool, mode: AvatarDisplayMode) -> LuckyDrawStore {
        let s = LuckyDrawStore(fileURL: nil, notificationCenter: NotificationCenter(), detectFaces: false)
        s.clearEntries()
        s.addEntries(from: labels.joined(separator: "\n"))
        if adorned {
            for (i, e) in s.selected!.entries.enumerated() {
                switch i % 3 {
                case 0: s.setAvatar(.emoji("🦊"), for: e)
                case 1: s.setAvatar(.photo(fileName: AvatarFileName.make()), for: e)
                default: break                                   // some entries stay un-adorned
                }
            }
        }
        s.setAvatarDisplay(mode)
        return s
    }

    /// One spin made through the real view model, with a seeded generator. Returns the winner's label and
    /// the wheel angle the plan lands on.
    private func spin(seed: UInt64, in store: LuckyDrawStore) throws -> (label: String, angle: Double) {
        var rng = DrawEngineTests.SeededGenerator(seed: seed)
        let vm = LuckyDrawViewModel(store: store, generator: AnyRandomNumberGenerator { rng.next() })
        vm.spin(reduceMotion: true)
        let plan = try #require(vm.plan, "the view model made no plan")
        vm.cancelInFlight()
        let winner = try #require(store.selected?.entries.first { $0.id == plan.winnerID })
        return (winner.label, plan.targetAngle)
    }

    @Test("The same seed names the same winner with and without avatars, in every display mode")
    func avatarsAndModesNeverChangeTheWinner() throws {
        let plain = store(adorned: false, mode: .nameOnly)
        var seen = Set<String>()
        for seed in UInt64(1)...60 {
            let base = try spin(seed: seed, in: plain)
            seen.insert(base.label)
            for mode in AvatarDisplayMode.allCases {
                let adorned = store(adorned: true, mode: mode)
                let got = try spin(seed: seed, in: adorned)
                #expect(got.label == base.label, "seed \(seed), \(mode): \(got.label) vs \(base.label)")
                #expect(got.angle == base.angle, "seed \(seed), \(mode): the landing angle moved")
            }
        }
        #expect(seen.count >= 6, "premise: the seeds do pick a spread of winners (\(seen.count) distinct)")
    }

    @Test("Excluded and retired entries stay off the wheel whatever they look like")
    func eligibilityIsIndependentOfAvatars() throws {
        let s = store(adorned: true, mode: .avatarOnly)
        let out = s.selected!.entries[1]                         // a photo-avatar entry
        s.setExcluded(true, for: out)
        for seed in UInt64(1)...60 {
            let got = try spin(seed: seed, in: s)
            #expect(got.label != out.label)
        }
    }
}

// MARK: H-09

@MainActor
@Suite("Orphan sweep, deterministic (H-09)")
struct OrphanSweepDeterministicTests {

    private final class Offered: @unchecked Sendable { var count = 0 }

    private final class Scratch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-sweep-\(UUID().uuidString)", isDirectory: true)
        var file: URL { dir.appendingPathComponent("luckyDraw.json") }
        init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: dir) }
        let offered = Offered()
        /// Runs the sweep inline and counts how often it was asked to run — no queue, no sleeping.
        @MainActor func store() -> LuckyDrawStore {
            let o = offered
            return LuckyDrawStore(fileURL: file, notificationCenter: NotificationCenter(), detectFaces: false,
                                  sweepScheduler: { work in o.count += 1; work() })
        }
    }

    /// A saved roster with one real photo. Returns where that photo is.
    private func savedRosterWithPhoto(_ s: Scratch) throws -> (roster: UUID, url: URL) {
        let store = s.store()
        let roster = store.selected!.id
        let name = try store.avatarStore!.importPhoto(data: Pixels.png(width: 300, height: 300), rosterID: roster)
        store.setAvatar(.photo(fileName: name), for: store.selected!.entries[0])
        store.flushToDisk()
        return (roster, try #require(store.avatarStore!.url(for: name, rosterID: roster)))
    }

    private func plantPhoto(_ s: Scratch, in roster: UUID = UUID()) throws -> URL {
        let url = s.dir.appendingPathComponent("luckydraw/avatars/\(roster.uuidString)/\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test("A roster file that cannot be read is not 'no references': the sweep is never even offered")
    func unreadableRosterFileSweepsNothing() throws {
        let s = Scratch()
        let photo = try savedRosterWithPhoto(s)
        let stray = try plantPhoto(s)
        try FileManager.default.removeItem(at: s.file)             // the roster file is gone: nothing can be trusted
        s.offered.count = 0

        _ = s.store()
        #expect(s.offered.count == 0, "the orphan sweep was offered to run after a failed read")
        #expect(FileManager.default.fileExists(atPath: photo.url.path), "a referenced photo was deleted")
        #expect(FileManager.default.fileExists(atPath: stray.path), "nothing may be deleted when the roster could not be read")
    }

    @Test("After a clean load the sweep does run, and removes exactly the true orphans")
    func cleanLoadRemovesTrueOrphans() throws {
        let s = Scratch()
        let photo = try savedRosterWithPhoto(s)
        let strayInLiveRoster = try plantPhoto(s, in: photo.roster)
        let strayRoster = try plantPhoto(s)
        s.offered.count = 0

        _ = s.store()
        #expect(s.offered.count == 1)
        #expect(!FileManager.default.fileExists(atPath: strayInLiveRoster.path), "an unreferenced photo survived")
        #expect(!FileManager.default.fileExists(atPath: strayRoster.path), "a folder for no roster survived")
        #expect(FileManager.default.fileExists(atPath: photo.url.path), "the referenced photo was removed")
    }
}

// MARK: H-10

@Suite("Avatar bounds (H-10)")
struct AvatarBoundsTests {

    @Test("A file whose size cannot be read is refused, not treated as 0 bytes")
    func unreadableSizeFailsClosed() throws {
        let root = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let src = root.appendingPathComponent("pic.png")
        try Pixels.png(width: 64, height: 64).write(to: src)

        let blind = AvatarStore(rootURL: root.appendingPathComponent("a"), detectFaces: false, fileSizeReader: { _ in nil })
        #expect(throws: AvatarStore.AvatarError.unreadable) { _ = try blind.importPhoto(from: src, rosterID: UUID()) }

        let sighted = AvatarStore(rootURL: root.appendingPathComponent("b"), detectFaces: false)
        #expect(AvatarFileName.isValid(try sighted.importPhoto(from: src, rosterID: UUID())), "control: the same file imports when its size is readable")

        let huge = AvatarStore(rootURL: root.appendingPathComponent("c"), detectFaces: false, fileSizeReader: { _ in AvatarStore.maxFileBytes + 1 })
        #expect(throws: AvatarStore.AvatarError.fileTooLarge) { _ = try huge.importPhoto(from: src, rosterID: UUID()) }
    }

    @Test("PNG dimensions come from the IHDR bytes")
    func pngHeader() {
        let data = Pixels.png(width: 300, height: 120)
        let r = ImageHeaderProbe.probe(read: { o, n in o < data.count ? data.subdata(in: o..<min(data.count, o + n)) : nil })
        #expect(r == .size(width: 300, height: 120))
    }

    @Test("TIFF dimensions come from IFD 0, both byte orders, SHORT and LONG values")
    func tiffHeader() {
        for big in [false, true] {
            let data = Pixels.tiffHeader(width: 40_000, height: 6_000, bigEndian: big)
            let r = ImageHeaderProbe.probe(read: { o, n in o < data.count ? data.subdata(in: o..<min(data.count, o + n)) : nil })
            #expect(r == .size(width: 40_000, height: 6_000), "bigEndian=\(big)")
        }
        let short = Pixels.tiffHeader(width: 1234, height: 567, type: 3)
        #expect(ImageHeaderProbe.probe(read: { o, n in o < short.count ? short.subdata(in: o..<min(short.count, o + n)) : nil }) == .size(width: 1234, height: 567))
    }

    @Test("Something that is neither PNG nor TIFF is left to the ImageIO check; a truncated PNG/TIFF is malformed")
    func probeEdges() {
        func probe(_ d: Data) -> ImageHeaderProbe.Result {
            ImageHeaderProbe.probe(read: { o, n in o < d.count ? d.subdata(in: o..<min(d.count, o + n)) : nil })
        }
        #expect(probe(Data("hello".utf8)) == .notPNGOrTIFF)
        #expect(probe(Data(Pixels.png(width: 8, height: 8).prefix(12))) == .malformed)
        #expect(probe(Data([0x49, 0x49, 0x2A, 0, 0xFF, 0xFF, 0xFF, 0x7F])) == .malformed)     // IFD offset past the end
    }

    @Test("A PNG or TIFF that DECLARES a huge size is refused from its header, with no pixel data behind it")
    func lyingHeaderIsRefused() throws {
        let store = AvatarStore(rootURL: Pixels.tempRoot(), detectFaces: false)       // production limit: 100 MP
        // 20 000 × 20 000 = 400 MP declared by a real PNG's IHDR (the rest of the file is untouched).
        var png = Pixels.png(width: 16, height: 16)
        for (i, byte) in [UInt8(0), 0, 0x4E, 0x20, 0, 0, 0x4E, 0x20].enumerated() { png[16 + i] = byte }
        #expect(throws: AvatarStore.AvatarError.tooManyPixels) { _ = try store.importPhoto(data: png, rosterID: UUID()) }
        #expect(throws: AvatarStore.AvatarError.tooManyPixels) {
            _ = try store.importPhoto(data: Pixels.tiffHeader(width: 40_000, height: 40_000), rosterID: UUID())
        }
        #expect(throws: AvatarStore.AvatarError.decodeFailed, "a TIFF header with no readable size fails closed") {
            _ = try store.importPhoto(data: Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 0, 0]), rosterID: UUID())
        }
    }

    // MARK: file-name case

    @Test("A photo name is one canonical spelling however the roster file wrote it")
    func nameIsNormalised() throws {
        let upper = "\(UUID().uuidString).jpg"
        let lower = upper.lowercased()
        #expect(AvatarFileName.normalized(lower) == upper)
        #expect(AvatarFileName.normalized(upper) == upper)
        #expect(AvatarFileName.normalized("../x.jpg") == nil && AvatarFileName.normalized("\(UUID().uuidString).JPG") == nil)

        let json = Data(#"{"id":"\#(UUID().uuidString)","label":"A","avatar":{"kind":"photo","file":"\#(lower)"}}"#.utf8)
        let entry = try JSONDecoder().decode(DrawEntry.self, from: json)
        #expect(entry.avatar == .photo(fileName: upper), "a lower-case name in a hand-edited roster must decode to the canonical one")
    }

    @Test("A lower-case reference keeps the photo the sweep would otherwise delete; so does a lower-case recovery file")
    func sweepComparesCanonically() throws {
        let root = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let roster = UUID()
        let name = try store.importPhoto(data: Pixels.png(width: 90, height: 90), rosterID: roster)
        let file = try #require(store.url(for: name, rosterID: roster))
        #expect(store.url(for: name.lowercased(), rosterID: roster) == file, "either spelling resolves to the one file")

        store.sweepOrphans(referenced: [roster: [name.lowercased()]])
        #expect(FileManager.default.fileExists(atPath: file.path), "the sweep deleted a photo that was referenced in the other case")
        store.sweepOrphans(referenced: [roster: []])
        #expect(!FileManager.default.fileExists(atPath: file.path), "control: an unreferenced photo still goes")
    }

    @MainActor
    @Test("A recovery file that spells the name in lower case still protects the photo")
    func recoveryFileLowerCase() throws {
        let dir = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let roster = UUID(), name = "\(UUID().uuidString).jpg"
        let backup = #"[{"id":"\#(roster.uuidString)","entries":[{"avatar":{"kind":"photo","file":"\#(name.lowercased())"}}]}]"#
        try Data(backup.utf8).write(to: dir.appendingPathComponent("luckyDraw.corrupt.json"))
        let refs = LuckyDrawStore.recoveryReferences(besides: dir.appendingPathComponent("luckyDraw.json"))
        #expect(refs?[roster] == [name])
    }

    // MARK: cache

    private func wait(timeout: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// `count` distinct valid photo names in one roster folder, copies of one real 256-px JPEG.
    private func roster(of count: Int, in store: AvatarStore) throws -> (UUID, [String]) {
        let id = UUID()
        let first = try store.importPhoto(data: Pixels.png(width: 300, height: 300), rosterID: id)
        let src = try #require(store.url(for: first, rosterID: id))
        var names = [first]
        while names.count < count {
            let n = AvatarFileName.make()
            try FileManager.default.copyItem(at: src, to: try #require(store.url(for: n, rosterID: id)))
            names.append(n)
        }
        return (id, names)
    }

    @Test("A Data slice (non-zero startIndex) is probed from its first byte, not trapped on")
    func dataSliceIsProbedRelativeToItsStart() throws {
        let store = AvatarStore(rootURL: Pixels.tempRoot(), detectFaces: false)
        var png = Pixels.png(width: 16, height: 16)
        for (i, byte) in [UInt8(0), 0, 0x4E, 0x20, 0, 0, 0x4E, 0x20].enumerated() { png[16 + i] = byte }   // 20 000 x 20 000
        let padded = Data(repeating: 0xAA, count: 10) + png
        let slice = padded.dropFirst(10)
        #expect(slice.startIndex == 10)
        #expect(throws: AvatarStore.AvatarError.tooManyPixels) { _ = try store.importPhoto(data: slice, rosterID: UUID()) }
    }

    @Test("A 500-photo roster never holds more than 64 MB of decoded images")
    func cacheStaysUnderTheCap() throws {
        let root = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let (id, names) = try roster(of: 500, in: store)
        let cache = AvatarImageCache(); cache.store = store
        var peak = 0
        for n in names {
            _ = cache.photo(fileName: n, rosterID: id, points: 128)       // 256-px bucket: ~256 KB each, ~125 MB in all
            peak = max(peak, cache.decodedBytes)
        }
        wait { cache.loadAttempts == 500 && cache.inFlightCount == 0 }
        peak = max(peak, cache.decodedBytes)
        #expect(cache.loadAttempts == 500, "premise: every photo was asked for")
        #expect(peak <= AvatarImageCache.defaultByteCapacity, "decoded images peaked at \(peak / 1_048_576) MB")
        #expect(cache.decodedBytes > AvatarImageCache.defaultByteCapacity / 2, "premise: the cache is actually being used")
        #expect(cache.decodedCount < 500)
    }

    @Test("Eviction is least-recently-USED: a photo the wheel keeps drawing outlives one it stopped drawing")
    func cacheEvictsLeastRecentlyUsed() throws {
        let root = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let (id, names) = try roster(of: 4, in: store)
        let (a, b, c, d) = (names[0], names[1], names[2], names[3])
        // What one decoded 128-px photo actually costs, measured rather than assumed.
        let probe = AvatarImageCache(); probe.store = store
        _ = probe.photo(fileName: a, rosterID: id, points: 64)
        wait { probe.decodedCount == 1 }
        let one = probe.decodedBytes
        #expect(one > 0)
        let cache = AvatarImageCache(byteCapacity: one * 3 + one / 2); cache.store = store   // room for three
        func load(_ n: String) {
            _ = cache.photo(fileName: n, rosterID: id, points: 64)
            wait { cache.isCached(fileName: n, rosterID: id, points: 64) }
        }
        load(a); load(b); load(c)
        _ = cache.photo(fileName: a, rosterID: id, points: 64)              // `a` is drawn again: most recent
        load(d)                                                              // over the cap: the oldest USE goes
        #expect(cache.isCached(fileName: a, rosterID: id, points: 64), "the most recently used photo was evicted (FIFO, not LRU)")
        #expect(!cache.isCached(fileName: b, rosterID: id, points: 64), "the least recently used photo was kept")
        #expect(cache.isCached(fileName: c, rosterID: id, points: 64) && cache.isCached(fileName: d, rosterID: id, points: 128))
        #expect(cache.decodedBytes <= one * 3 + one / 2)
    }
}


// MARK: - Wire contract (H-20a) and live line changes (H-21a)

/// The committed fixture of nodes the Android app really writes. The Kotlin side of the same file is H-20b.
private struct PhoneFixture {
    let root: [String: Any]
    let crypto: CryptoService

    /// Deriving the key is 100 000 PBKDF2 rounds — ~10 s in a Debug build — so it is done once for the
    /// whole run, not once per test.
    nonisolated(unsafe) private static var cached: PhoneFixture?

    static func load() throws -> PhoneFixture {
        if let cached { return cached }
        // `#filePath` is HaloTests/DesktopHardeningTests.swift: the repo root is one level up.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/specs/wire-contract/phone-nodes.v1.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(json as? [String: Any])
        let c = try #require(root["crypto"] as? [String: Any])
        let saltText = try #require(c["saltBase64"] as? String)
        let salt = try #require(Data(base64Encoded: saltText))
        let passphrase = try #require(c["passphrase"] as? String)
        let iterations = try #require(c["iterations"] as? Int)
        let crypto = try CryptoService(passphrase: passphrase, salt: salt, iterations: iterations)
        let loaded = PhoneFixture(root: root, crypto: crypto)
        cached = loaded
        return loaded
    }

    func entries(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
    var deviceId: String { root["deviceId"] as! String }
}

@MainActor
@Suite("Phone wire contract — Swift side (H-20a)")
struct WireContractTests {

    @Test("The fixture is the version this suite understands and carries every node type")
    func fixtureShape() throws {
        let f = try PhoneFixture.load()
        #expect(f.root["contract"] as? String == "halo-phone-nodes" && f.root["version"] as? Int == 1)
        #expect(f.entries("lines").count >= 2 && f.entries("messages").count >= 2 && f.entries("sent").count >= 1 && f.entries("clipboard").count >= 3)
    }

    @Test("Every phone-written device node decodes as the desktop reads it")
    func device() throws {
        let f = try PhoneFixture.load()
        let d = try #require(f.root["device"] as? [String: Any])
        let want = try #require(d["expect"] as? [String: Any])
        let got = SMSWire.device(id: f.deviceId, value: d["node"])
        #expect(got.id == want["id"] as? String && got.name == want["name"] as? String && got.platform == want["platform"] as? String)
    }

    @Test("Every phone-written line node decodes — label, carrier, decrypted own number, sync flag")
    func lines() throws {
        let f = try PhoneFixture.load()
        for entry in f.entries("lines") {
            let key = try #require(entry["key"] as? String)
            let want = try #require(entry["expect"] as? [String: Any])
            let line = SMSWire.line(deviceId: f.deviceId, subIdStr: key, value: entry["node"], crypto: f.crypto)
            #expect(line.subscriptionId == want["subscriptionId"] as? Int, "line \(key)")
            #expect(line.label == want["label"] as? String, "line \(key)")
            #expect(line.carrier == want["carrier"] as? String, "line \(key)")
            #expect(line.ownNumber == want["ownNumber"] as? String, "line \(key)")
            #expect(line.syncEnabled == want["syncEnabled"] as? Bool, "line \(key)")
            #expect(line.id == "\(f.deviceId)-\(line.subscriptionId)")
        }
    }

    @Test("Every phone-written message node decodes — address and body decrypted, date, SIM, read flag")
    func messages() throws {
        let f = try PhoneFixture.load()
        for entry in f.entries("messages") {
            let key = try #require(entry["key"] as? String)
            let want = try #require(entry["expect"] as? [String: Any])
            let m = try #require(SMSWire.message(deviceId: f.deviceId, msgId: key, value: entry["node"], crypto: f.crypto), "message \(key) did not decode")
            #expect(m.contactNumber == want["address"] as? String, "message \(key)")
            #expect(m.body == want["body"] as? String, "message \(key)")
            #expect(m.date == Date(timeIntervalSince1970: Double(want["dateMs"] as! Int) / 1000), "message \(key)")
            #expect(m.lineId == "\(f.deviceId)-\(want["subscriptionId"] as! Int)", "message \(key)")
            #expect(m.read == want["read"] as? Bool, "message \(key)")
            #expect(m.id == "\(f.deviceId)/\(key)")
        }
    }

    @Test("Every phone-written SENT node decodes as a sent message - recipient and body decrypted, never classified, never unread")
    func sentMessages() throws {
        let f = try PhoneFixture.load()
        for entry in f.entries("sent") {
            let key = try #require(entry["key"] as? String)
            let want = try #require(entry["expect"] as? [String: Any])
            let m = try #require(SMSWire.message(deviceId: f.deviceId, msgId: key, value: entry["node"], crypto: f.crypto, node: .sent), "sent \(key) did not decode")
            #expect(m.direction == .sent && want["direction"] as? String == "sent")
            #expect(m.contactNumber == want["address"] as? String, "sent \(key)")
            #expect(m.body == want["body"] as? String, "sent \(key)")
            #expect(m.date == Date(timeIntervalSince1970: Double(want["dateMs"] as! Int) / 1000), "sent \(key)")
            #expect(m.lineId == "\(f.deviceId)-\(want["subscriptionId"] as! Int)", "sent \(key)")
            #expect(m.read, "a message the user sent is read by definition")
            #expect(m.category == .uncategorized, "a sent message is never classified (its text reads like a bank alert)")
            #expect(m.id == "\(f.deviceId)/sent/\(key)", "a sent id must never equal a received id")
        }
    }

    @Test("The fixture's sent message lands in the same thread as that contact's received message")
    func sentJoinsTheContactsThread() throws {
        let f = try PhoneFixture.load()
        let sent = try #require(f.entries("sent").first)
        let sentMsg = try #require(SMSWire.message(deviceId: f.deviceId, msgId: "s", value: sent["node"], crypto: f.crypto, node: .sent))
        let received = try #require(f.entries("messages").first { ($0["expect"] as? [String: Any])?["address"] as? String == sentMsg.contactNumber })
        let recvMsg = try #require(SMSWire.message(deviceId: f.deviceId, msgId: "r", value: received["node"], crypto: f.crypto))
        #expect(SMSSyncClient.normalizeContact(sentMsg.contactNumber) == SMSSyncClient.normalizeContact(recvMsg.contactNumber) && sentMsg.lineId == recvMsg.lineId)
        // …and the phone computed the same keyed thread hash for both.
        #expect((sent["node"] as? [String: Any])?["threadKey"] as? String == (received["node"] as? [String: Any])?["threadKey"] as? String)
    }

    @Test("A message encrypted under a different key is skipped, never shown blank")
    func wrongKey() throws {
        let f = try PhoneFixture.load()
        let other = CryptoService(key: SymmetricKey(size: .bits256))        // a different key, without a 10 s derivation
        let entry = try #require(f.entries("messages").first)
        #expect(SMSWire.message(deviceId: f.deviceId, msgId: "x", value: entry["node"], crypto: other) == nil)
    }

    @Test("Every phone-written clipboard node parses and decrypts")
    func clipboard() throws {
        let f = try PhoneFixture.load()
        for entry in f.entries("clipboard") {
            let key = try #require(entry["key"] as? String)
            let want = try #require(entry["expect"] as? [String: Any])
            let env = try #require(ClipboardSyncEnvelope.from(entry["node"]), "clipboard \(key) is structurally invalid to the desktop")
            #expect(env.itemId == key && env.deviceId == f.deviceId)
            #expect(env.kind == want["kind"] as? String, "clipboard \(key)")
            #expect(env.deviceName == want["deviceName"] as? String, "clipboard \(key)")
            #expect(env.language == want["language"] as? String, "clipboard \(key)")
            #expect(env.createdAt == (want["createdAt"] as? NSNumber)?.doubleValue, "clipboard \(key)")
            #expect(try f.crypto.decrypt(env.contentEnc) == want["text"] as? String, "clipboard \(key)")
        }
    }

    @Test("The desktop writes the same clipboard node shape the phone reads back")
    func clipboardRoundTripsFieldNames() throws {
        let f = try PhoneFixture.load()
        let entry = try #require(f.entries("clipboard").first { ($0["expect"] as? [String: Any])?["language"] is String })
        let node = try #require(entry["node"] as? [String: Any])
        let env = try #require(ClipboardSyncEnvelope.from(node))
        #expect(Set(env.node().keys) == Set(node.keys), "the desktop's envelope and the phone's disagree on field names")
    }
}

@MainActor
@Suite("A line changed on the phone reaches a live Mac (H-21a)")
struct LiveLineChangeTests {

    @Test("A line node rewritten with a new label updates the line the console shows")
    func renamedSimUpdatesLine() throws {
        let f = try PhoneFixture.load()
        let client = SMSSyncClient()
        client.installCryptoForTesting(f.crypto)
        let entry = try #require(f.entries("lines").first { $0["key"] as? String == "1" })
        var node = try #require(entry["node"] as? [String: Any])

        client.mergeLine(deviceId: f.deviceId, subIdStr: "1", value: node)
        #expect(client.lines.map(\.label) == ["Personal"])

        node["label"] = "Work phone"                                  // the user renames the SIM on the phone
        node["carrier"] = "Vi"
        client.mergeLine(deviceId: f.deviceId, subIdStr: "1", value: node)
        #expect(client.lines.count == 1, "a changed line must replace its row, not add one")
        #expect(client.lines.first?.label == "Work phone")
        #expect(client.lines.first?.carrier == "Vi")
    }

    @Test("The stream delivers a child again when — and only when — its value changed")
    func deliveryRule() {
        typealias D = FirebaseRTDBClient.ChildDelivery
        var added = D(), changed = D()
        let v1: [String: Any] = ["1": ["label": "Personal", "carrier": "Airtel"]]
        #expect(added.pending(in: v1, includeChanges: false).map(\.key) == ["1"])
        #expect(changed.pending(in: v1, includeChanges: true).map(\.key) == ["1"])

        #expect(changed.pending(in: v1, includeChanges: true).isEmpty, "an identical event re-delivered nothing new")

        let v2: [String: Any] = ["1": ["carrier": "Airtel", "label": "Work phone"]]      // key order differs, value differs
        #expect(added.pending(in: v2, includeChanges: false).isEmpty, "child_added semantics: a delivered child is never reported again")
        let again = changed.pending(in: v2, includeChanges: true)
        #expect(again.map(\.key) == ["1"])
        #expect((again.first?.value as? [String: Any])?["label"] as? String == "Work phone")

        let reordered: [String: Any] = ["1": ["label": "Work phone", "carrier": "Airtel"]]
        #expect(changed.pending(in: reordered, includeChanges: true).isEmpty, "the same content in another key order is not a change")
    }

    @Test("A removed child that comes back is delivered again, in both modes")
    func removedThenBack() {
        typealias D = FirebaseRTDBClient.ChildDelivery
        for includeChanges in [false, true] {
            var d = D()
            let model: [String: Any] = ["1": ["label": "A"]]
            #expect(d.pending(in: model, includeChanges: includeChanges).count == 1)
            #expect(d.pending(in: [:], includeChanges: includeChanges).isEmpty)
            #expect(d.pending(in: model, includeChanges: includeChanges).count == 1, "includeChanges=\(includeChanges)")
        }
    }

    @Test("A child_added observer never re-delivers a changed child and keeps no fingerprints")
    func addedModeIgnoresChanges() {
        var d = FirebaseRTDBClient.ChildDelivery()
        #expect(d.pending(in: ["m1": ["body": "a"]], includeChanges: false).map(\.key) == ["m1"])
        #expect(d.pending(in: ["m1": ["body": "CHANGED"], "m2": ["body": "b"]], includeChanges: false).map(\.key) == ["m2"])
    }

    @Test("Phone fields the desktop does not know about (lineVersion, updatedAt) are ignored, not fatal")
    func futureFieldsAreTolerated() throws {
        let f = try PhoneFixture.load()
        var node = try #require(f.entries("lines").first?["node"] as? [String: Any])
        node["lineVersion"] = 3
        node["updatedAt"] = 1_800_000_000_123
        let line = SMSWire.line(deviceId: f.deviceId, subIdStr: "1", value: node, crypto: f.crypto)
        #expect(line.label == "Personal" && line.ownNumber == "+919876543210")
    }
}


// MARK: - Follow-up to #60's reviews (h05)

// MARK: H-05 — per-volume case policy, firmlinks

/// A real, throwaway volume: a sparse disk image formatted APFS (case-insensitive) or Case-sensitive
/// APFS, attached at a mount point of the test's choosing. `nil` when `hdiutil` cannot make or attach one
/// (not present, sandboxed, no Disk Images service) — the suites that need it are disabled then.
private final class TempVolume: @unchecked Sendable {
    let base: URL
    let mount: URL
    private var attached = false

    init?(caseSensitive: Bool, mountName: String = "mnt") {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("halo-vol-\(UUID().uuidString)")
        mount = base.appendingPathComponent(mountName)
        do { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true) } catch { return nil }
        let image = base.appendingPathComponent("v").path          // hdiutil appends ".sparseimage"
        let made = ShellReader.run("/usr/bin/hdiutil",
                                   ["create", "-size", "8m", "-fs", caseSensitive ? "Case-sensitive APFS" : "APFS",
                                    "-volname", "HaloT", "-type", "SPARSE", image], timeout: 60)
        guard made.succeeded else { try? FileManager.default.removeItem(at: base); return nil }
        let up = ShellReader.run("/usr/bin/hdiutil",
                                 ["attach", "-mountpoint", mount.path, "-nobrowse", "-noverify", "-noautoopen", image + ".sparseimage"],
                                 timeout: 60)
        guard up.succeeded else { try? FileManager.default.removeItem(at: base); return nil }
        attached = true
        CleanupPath.resetKeyCache()
    }

    func detach() {
        if attached { attached = !ShellReader.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60).succeeded }
        // Only when the volume is gone: removing `base` while the image is still mounted would recurse into it.
        if !attached { try? FileManager.default.removeItem(at: base) }
        CleanupPath.resetKeyCache()
    }

    var supportsCaseSensitiveNames: Bool? {
        try? mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
    }

    /// Whether a disk image can be made here at all — decided once, by trying.
    static let available: Bool = {
        guard let v = TempVolume(caseSensitive: false) else { return false }
        v.detach()
        return true
    }()
}

private func scanned(_ url: URL, size: Int64 = 100) -> ScannedItem {
    ScannedItem(id: UUID(), url: url, size: size, creationDate: nil, modifiedDate: nil, kind: .cache)
}

@Suite("Cleanup path keys follow the volume (H-05 follow-up)")
struct CleanupPathVolumeTests {

    @Test("Case-insensitive volume (real APFS disk image): one file, however it is spelled",
          .enabled(if: TempVolume.available))
    func caseInsensitiveVolumeFolds() throws {
        let v = try #require(TempVolume(caseSensitive: false)); defer { v.detach() }
        #expect(v.supportsCaseSensitiveNames == false, "premise: the image is a case-insensitive volume")
        let dir = v.mount.appendingPathComponent("Dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("A.bin"); try Data([1]).write(to: file)
        let lower = v.mount.appendingPathComponent("dir/a.bin")
        #expect(FileManager.default.fileExists(atPath: lower.path), "premise: the filesystem itself treats them as one file")

        #expect(CleanupPath.key(file) == CleanupPath.key(lower))
        // A leaf that no longer exists (a removed item) folds the same way.
        #expect(CleanupPath.key(dir.appendingPathComponent("Gone.BIN")) == CleanupPath.key(v.mount.appendingPathComponent("DIR/gone.bin")))

        // What it means for the lists: a row spelled one way goes when the other spelling is removed ...
        var cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [scanned(file)]
        CleanupReconciler.apply(removedKeys: [CleanupPath.key(lower)], to: &cats)
        #expect(cats[0].items.isEmpty, "a row survived its file being removed under another case spelling (ghost row)")
        // ... and one file listed under two spellings is one file in the total.
        cats = [CleanupCategory(kind: .systemCaches), CleanupCategory(kind: .userCaches)]
        cats[0].items = [scanned(file)]; cats[1].items = [scanned(lower)]
        #expect(CleanupReconciler.distinctBytes(cats) == 100)
    }

    @Test("Case-sensitive volume (real Case-sensitive APFS disk image): A.bin and a.bin are two files",
          .enabled(if: TempVolume.available))
    func caseSensitiveVolumeKeepsCase() throws {
        let v = try #require(TempVolume(caseSensitive: true)); defer { v.detach() }
        #expect(v.supportsCaseSensitiveNames == true, "premise: the image is a case-sensitive volume")
        let upper = v.mount.appendingPathComponent("A.bin"), lower = v.mount.appendingPathComponent("a.bin")
        try Data([1]).write(to: upper); try Data([2, 2]).write(to: lower)
        #expect(try FileManager.default.contentsOfDirectory(atPath: v.mount.path).count == 2, "premise: two distinct files")

        #expect(CleanupPath.key(upper) != CleanupPath.key(lower))
        var cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [scanned(upper), scanned(lower)]
        CleanupReconciler.apply(removedKeys: [CleanupPath.key(lower)], to: &cats)
        #expect(cats[0].items.map(\.name) == ["A.bin"], "removing a.bin dropped (or kept) the wrong row")
        cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [scanned(upper), scanned(lower)]
        #expect(CleanupReconciler.distinctBytes(cats) == 200, "two distinct files were counted as one")
    }

    @Test("A case-sensitive volume mounted inside a case-insensitive one: the mount point's name folds, what is below it does not",
          .enabled(if: TempVolume.available))
    func mixedVolumes() throws {
        let v = try #require(TempVolume(caseSensitive: true, mountName: "MNT")); defer { v.detach() }
        let parentFlag = try v.base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        guard parentFlag == false else { return }        // the temp dir itself is on a case-sensitive volume here: nothing mixed to test
        try FileManager.default.createDirectory(at: v.mount.appendingPathComponent("Dir"), withIntermediateDirectories: true)

        let a = CleanupPath.key(v.base.appendingPathComponent("MNT/Dir/A.bin"))
        let sameMountOtherSpelling = CleanupPath.key(v.base.appendingPathComponent("mnt/Dir/A.bin"))
        let otherFileBelow = CleanupPath.key(v.base.appendingPathComponent("MNT/dir/A.bin"))
        #expect(a == sameMountOtherSpelling, "the mount point's name lives on the case-insensitive parent: one directory")
        #expect(a != otherFileBelow, "below the mount point the volume is case-sensitive: Dir and dir differ")
        #expect(a.hasSuffix("/mnt/Dir/A.bin"), "folded above and including the mount point, verbatim below it: \(a)")
    }

    @Test("Whatever volume the temp folder is on, keys fold case exactly when that volume does")
    func keysAgreeWithTheRealVolumeFlag() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-flag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sensitive = (try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        let same = CleanupPath.key(dir.appendingPathComponent("Sub/A.bin")) == CleanupPath.key(dir.appendingPathComponent("sub/a.bin"))
        #expect(same == !sensitive, "key folds case: \(same), volume case-sensitive: \(sensitive)")
        #expect(CleanupPath.key(dir.appendingPathComponent("A.bin")) != CleanupPath.key(dir.appendingPathComponent("B.bin")))
    }

    @Test("Firmlinks: /System/Volumes/Data/<x> and /<x> are one location",
          .enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data/Users")))
    func firmlinkSpellingsAgree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-firm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: file)
        // C `realpath`, not `resolvingSymlinksInPath()` — Foundation strips the leading "/private" of /private/var.
        func real(_ url: URL) -> String { var buf = [CChar](repeating: 0, count: Int(PATH_MAX)); return realpath(url.path, &buf) != nil ? String(cString: buf) : url.path }
        let viaData = URL(fileURLWithPath: "/System/Volumes/Data" + real(file))
        try #require(FileManager.default.fileExists(atPath: viaData.path), "premise: the Data-volume spelling reaches the same file")

        #expect(CleanupPath.key(file) == CleanupPath.key(viaData))
        #expect(CleanupPath.directoryKey(dir) == CleanupPath.directoryKey(viaData.deletingLastPathComponent()))
        var cats = [CleanupCategory(kind: .userCaches)]
        cats[0].items = [scanned(viaData)]
        CleanupReconciler.apply(removedKeys: [CleanupPath.key(file)], to: &cats)
        #expect(cats[0].items.isEmpty, "a row addressed through /System/Volumes/Data outlived its file")

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let homeViaData = URL(fileURLWithPath: "/System/Volumes/Data" + real(home))
        #expect(CleanupPath.directoryKey(home) == CleanupPath.directoryKey(homeViaData))
    }

    @Test("A drive swapped for a differently-formatted one at the same mount point is not keyed by the old volume's case flag",
          .enabled(if: TempVolume.available))
    @MainActor
    func remountAtTheSamePathIsRescanned() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("halo-remount-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func attach(caseSensitive: Bool, image: String) -> Bool {
            let path = base.appendingPathComponent(image).path
            guard ShellReader.run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", caseSensitive ? "Case-sensitive APFS" : "APFS",
                                                       "-volname", "HaloT", "-type", "SPARSE", path], timeout: 60).succeeded else { return false }
            return ShellReader.run("/usr/bin/hdiutil", ["attach", "-mountpoint", mount.path, "-nobrowse", "-noverify", "-noautoopen",
                                                        path + ".sparseimage"], timeout: 60).succeeded
        }
        func detach() -> Bool { ShellReader.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60).succeeded }
        var attached = false
        defer {
            if attached { attached = !detach() }
            if !attached { try? FileManager.default.removeItem(at: base) }   // never recurse into a volume that is still mounted
            CleanupPath.resetKeyCache()
        }
        // Other tests (and every scan) clear the key cache too, and the swap takes seconds, so the stale
        // entry can be wiped before the scan: establish the premise — the old flag IS still cached —
        // and retry the swap if it was not, rather than let the assertion below pass for the wrong reason.
        var stale = false
        for attempt in 0..<4 where !stale {
            if attempt > 0 {
                attached = !detach(); try #require(!attached)
                for f in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where f.hasSuffix(".sparseimage") {
                    try? FileManager.default.removeItem(at: base.appendingPathComponent(f))
                }
            }
            CleanupPath.resetKeyCache()
            try #require(attach(caseSensitive: false, image: "ci\(attempt)"))
            attached = true
            #expect(CleanupPath.key(mount.appendingPathComponent("A.bin")) == CleanupPath.key(mount.appendingPathComponent("a.bin")))
            attached = !detach()
            try #require(!attached)
            try #require(attach(caseSensitive: true, image: "cs\(attempt)"))
            attached = true
            try? Data(repeating: 1, count: 4096).write(to: mount.appendingPathComponent("A.bin"))
            try? Data(repeating: 2, count: 4096).write(to: mount.appendingPathComponent("a.bin"))
            // Premise: the old volume's flag is still cached for this mount point, although the two files are distinct.
            stale = CleanupPath.key(mount.appendingPathComponent("A.bin")) == CleanupPath.key(mount.appendingPathComponent("a.bin"))
            if !stale, let n = try? FileManager.default.contentsOfDirectory(atPath: mount.path) {
                for f in n where f.lowercased() == "a.bin" { try? FileManager.default.removeItem(at: mount.appendingPathComponent(f)) }
            }
        }
        try #require(stale, "premise: the previous volume's case flag stays cached across the swap (without a reset)")

        let trash = base.appendingPathComponent("trash")
        let root = mount.path
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root] : [] }, trashDirectories: { [trash] }, trash: { _ in })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches])
        await vm.scanAll()
        let items = (vm.category(for: .userCaches)?.items ?? []).filter { $0.name.lowercased() == "a.bin" }
        #expect(items.count == 2, "premise: both files of the case-sensitive volume are listed")
        #expect(Set(items.map(\.key)).count == 2, "two distinct files were given one key — the previous volume's case flag was reused")
    }

    @Test("canonicalFirmlink only rewrites real firmlink roots")
    func canonicalFirmlinkRules() {
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/Data/Users/x") == "/Users/x")
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/Data/private/var/folders") == "/private/var/folders")
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/Data/usr/local/bin") == "/usr/local/bin")
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/Data/nothing-firmlinked-here") == "/System/Volumes/Data/nothing-firmlinked-here")
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/Data") == "/System/Volumes/Data")
        #expect(CleanupPath.canonicalFirmlink("/System/Volumes/DataX/Users/x") == "/System/Volumes/DataX/Users/x")
        #expect(CleanupPath.canonicalFirmlink("/Users/x") == "/Users/x")
    }
}


// MARK: Clean All: feedback while preparing, one at a time

@MainActor
@Suite("Clean All: in-progress feedback and no double-start (review of #60)")
struct CleanAllBusyTests {
    typealias Fixture = CleanupViewModelTests.Fixture

    private func spin(until cond: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test("While the prune runs the model says so, and a second Clean All is ignored — it does not open a second prune")
    func secondBeginIsIgnored() async throws {
        let f = try Fixture()
        for i in 0..<4 { try f.file("f\(i).bin") }
        let rec = Recorder()
        let root = f.root, trash = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] }, trash: { _ in })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches],
                                  existsOnDisk: { _ in rec.note(); Thread.sleep(forTimeInterval: 0.05); return true })
        await vm.scanAll()
        #expect(!vm.isPreparing && !vm.isBusy)

        let first = Task { await vm.beginCleanAll(for: .userCaches) }
        await spin { vm.isPreparing }
        #expect(vm.isPreparing && vm.isBusy, "no in-progress state during the existence check")

        let second = await vm.beginCleanAll(for: .userCaches)       // the double-click
        #expect(second == nil, "a second Clean All opened a second prune")

        let snapshot = await first.value
        #expect(snapshot?.items.count == 4)
        #expect(rec.calls == 4, "the existence check ran \(rec.calls) times for 4 rows: a second prune was started")
        #expect(!vm.isPreparing && !vm.isBusy, "the flag was left set")
    }

    @Test("The whole re-check before the trash counts as busy, not just the trash itself")
    func busyFromTheFirstAwait() async throws {
        let f = try Fixture()
        for i in 0..<3 { try f.file("f\(i).bin") }
        let trashed = Recorder(), checks = Recorder()
        let root = f.root, trash = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] }, trash: { _ in trashed.note() })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches],
                                  existsOnDisk: { _ in checks.note(); Thread.sleep(forTimeInterval: 0.03); return true })
        await vm.scanAll()
        let snapshot = try #require(await vm.beginCleanAll(for: .userCaches))
        let before = checks.calls

        let first = Task { await vm.cleanAll(confirmed: snapshot) }
        await spin { checks.calls > before }                         // inside the existence re-check
        #expect(trashed.calls == 0, "premise: nothing has been trashed yet")
        #expect(vm.isCleaning && vm.isBusy, "isCleaning was only set once the trash started — the re-check window looked idle")
        await first.value
        #expect(!vm.isCleaning)
    }

    @Test("A second 'Move to Trash' while one is running is ignored: nothing is trashed twice and the first banner survives")
    func secondConfirmIsIgnored() async throws {
        let f = try Fixture()
        for i in 0..<3 { try f.file("f\(i).bin") }
        let trashed = Recorder()
        let root = f.root, trash = f.trash
        // A slow trash: the second click lands while the first is mid-way, when every file still exists —
        // so the existence re-check cannot be what saves it.
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] },
                                          trash: { url in
                                              trashed.note()
                                              Thread.sleep(forTimeInterval: 0.06)
                                              try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
                                          })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches])
        await vm.scanAll()
        let snapshot = try #require(await vm.beginCleanAll(for: .userCaches))

        let first = Task { await vm.cleanAll(confirmed: snapshot) }
        await spin { trashed.calls >= 1 }
        await vm.cleanAll(confirmed: snapshot)                       // the double-click
        await first.value

        #expect(trashed.calls == 3, "trashed \(trashed.calls) times for 3 items: the second click ran a second clean")
        #expect(vm.outcome?.moved == 3 && vm.outcome?.failed == 0, "the first operation's banner was replaced")
        #expect(!vm.isCleaning)
    }

    @Test("A cancelled Clean All does not leave the model stuck busy")
    func cancellationReleasesTheFlags() async throws {
        let f = try Fixture()
        for i in 0..<300 { try f.file("f\(i).bin") }
        let root = f.root, trash = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trash] }, trash: { _ in })
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches],
                                  existsOnDisk: { _ in Thread.sleep(forTimeInterval: 0.002); return true }, pruneDeadline: 30)
        await vm.scanAll()
        let task = Task { await vm.beginCleanAll(for: .userCaches) }
        await spin { vm.isPreparing }
        task.cancel()
        _ = await task.value
        #expect(!vm.isPreparing && !vm.isBusy)
        let again = await vm.beginCleanAll(for: .userCaches)
        #expect(again != nil, "after a cancelled attempt Clean All never worked again")
    }
}


// MARK: H-02 measurement: 20 000 rows must not stall the main actor

/// Measures how long the main thread is blocked. A background thread posts a block to the main queue every
/// few ms and records how late it ran; a synchronous stretch of main-actor work shows up as one late block.
private final class MainThreadHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: TimeInterval = 0
    private var running = false

    func start() {
        lock.lock(); running = true; worst = 0; lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { return }
                let posted = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { [self] in
                    let late = CFAbsoluteTimeGetCurrent() - posted
                    lock.lock(); worst = max(worst, late); lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    /// The longest the main thread was unavailable since `start()`.
    func stop() -> TimeInterval {
        lock.lock(); running = false; let w = worst; lock.unlock()
        return w
    }
}

@MainActor
@Suite("Clean All on a 20 000-row list keeps the main actor free (H-02 measurement)")
struct CleanupMainActorTests {
    typealias Fixture = CleanupViewModelTests.Fixture

    /// The longest main-thread stall allowed while 20 000 rows are checked, trashed and reconciled. Generous
    /// on purpose (a loaded CI box, parallel tests on the main actor): the failure it guards is a stall of
    /// SECONDS, which is what keying/hashing every row on the main actor costs. Measured on this Mac:
    /// 90-130 ms alone (up to ~250 ms with six suites running in parallel); the #60 head, same test: 3.3 s.
    static let allowedStall: TimeInterval = 0.75

    private func run(items: [ScannedItem], fixture f: Fixture, exists: @escaping @Sendable (URL) -> Bool,
                     trash: @escaping @Sendable (URL) throws -> Void) async throws -> (stall: TimeInterval, wall: TimeInterval, vm: CleanupViewModel) {
        let root = f.root, trashDir = f.trash
        let coordinator = ScanCoordinator(roots: { $0 == .userCaches ? [root.path] : [] },
                                          trashDirectories: { [trashDir] }, trash: trash)
        let vm = CleanupViewModel(coordinator: coordinator, kinds: [.userCaches], existsOnDisk: exists, pruneDeadline: 60)
        await vm.scanAll()
        vm.apply(scanned: CleanupCategory(kind: .userCaches, items: items))
        try #require(vm.category(for: .userCaches)?.items.count == items.count, "premise: the list holds every row")

        let beat = MainThreadHeartbeat()
        beat.start()
        let t0 = Date()
        let snapshot = try #require(await vm.beginCleanAll(for: .userCaches))
        await vm.cleanAll(confirmed: snapshot)
        let wall = Date().timeIntervalSince(t0)
        return (beat.stop(), wall, vm)
    }

    @Test("20 000 rows: prune + Clean All + reconcile never block the main thread beyond the threshold")
    func twentyThousandRows() async throws {
        // The heartbeat sees EVERY main-thread stall in the process, including other suites' tests running in
        // parallel, so one noisy run proves nothing. Best of three: a real regression (3.3 s on the #60 head)
        // is slow every time; contention from a loaded run is not.
        var best = TimeInterval.infinity
        for attempt in 1...3 {
            let f = try Fixture()
            // Rows are created the way the scanners create them: key computed at scan time, off the main thread.
            let items = (0..<20_000).map { i -> ScannedItem in
                let url = f.root.appendingPathComponent("group\(i % 40)/file\(i).bin")
                return ScannedItem(id: UUID(), url: url, size: 4096, creationDate: nil, modifiedDate: nil, kind: .cache,
                                   pathKey: CleanupPath.key(url))
            }
            let r = try await run(items: items, fixture: f, exists: { _ in true }, trash: { _ in })
            print("[H-02] 20000 synthetic rows (attempt \(attempt)): wall \(String(format: "%.3f", r.wall)) s, worst main-thread stall \(String(format: "%.0f", r.stall * 1000)) ms")
            #expect(r.vm.category(for: .userCaches)?.items.isEmpty == true, "premise: everything was reconciled away")
            best = min(best, r.stall)
            if best < Self.allowedStall { break }
        }
        #expect(best < Self.allowedStall, "the main thread was blocked for at least \(best) s on every attempt")
    }

    /// The heavy variant: 20 000 REAL files on disk, real `lstat`s, real moves into a temp "trash". Seconds of
    /// setup, so opt-in: `HALO_MEASURE_CLEANUP=1`.
    @Test("20 000 real files (opt-in: HALO_MEASURE_CLEANUP=1)",
          .enabled(if: ProcessInfo.processInfo.environment["HALO_MEASURE_CLEANUP"] != nil))
    func twentyThousandRealFiles() async throws {
        let f = try Fixture()
        let fm = FileManager.default
        for g in 0..<40 { try fm.createDirectory(at: f.root.appendingPathComponent("group\(g)"), withIntermediateDirectories: true) }
        for i in 0..<20_000 { fm.createFile(atPath: f.root.appendingPathComponent("group\(i % 40)/file\(i).bin").path, contents: Data([1])) }
        let items = (0..<20_000).map { i -> ScannedItem in
            let url = f.root.appendingPathComponent("group\(i % 40)/file\(i).bin")
            return ScannedItem(id: UUID(), url: url, size: 1, creationDate: nil, modifiedDate: nil, kind: .cache,
                               pathKey: CleanupPath.key(url))
        }
        let trash = f.trash
        let r = try await run(items: items, fixture: f, exists: CleanupPath.existsOnDisk,
                              trash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString)) })
        print("[H-02] 20000 REAL files: wall \(String(format: "%.3f", r.wall)) s, worst main-thread stall \(String(format: "%.0f", r.stall * 1000)) ms")
        #expect(r.vm.outcome?.moved == 20_000)
        #expect(r.stall < Self.allowedStall, "the main thread was blocked for \(r.stall) s")
    }

    @Test("A scanned row carries its key, so the list is never re-keyed on the main actor")
    func scannersAttachTheKey() async throws {
        let f = try Fixture()
        try f.file("a.bin")
        try f.file("b.bin")
        let vm = f.vm()
        await vm.scanAll()
        let items = (vm.category(for: .userCaches)?.items ?? []) + (vm.category(for: .trash)?.items ?? [])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.pathKey != nil && $0.pathKey == CleanupPath.key($0.url) })
    }
}


// MARK: Avatars: BigTIFF, working set larger than the cache

@Suite("Avatar header probe and cache working set (review of #60)")
struct AvatarFollowUpTests {
    private func probe(_ d: Data) -> ImageHeaderProbe.Result {
        ImageHeaderProbe.probe(read: { o, n in o < d.count ? d.subdata(in: o..<min(d.count, o + n)) : nil })
    }

    @Test("A BigTIFF is refused (fail closed), in both byte orders — as the probe's own doc says — instead of falling through unchecked")
    func bigTIFFIsMalformed() {
        // "II" 2B 00 and "MM" 00 2B, then the BigTIFF offset size (8) / constant (0) / first-IFD offset.
        let little = Data([0x49, 0x49, 0x2B, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0])
        let big = Data([0x4D, 0x4D, 0x00, 0x2B, 0x00, 0x08, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0x10])
        #expect(probe(little) == .malformed)
        #expect(probe(big) == .malformed)
        // Neighbours stay as they were: classic TIFF reads, a random 8 bytes is left to ImageIO.
        #expect(probe(Pixels.tiffHeader(width: 10, height: 20)) == .size(width: 10, height: 20))
        #expect(probe(Data([0x49, 0x49, 0x2C, 0x00, 0, 0, 0, 0])) == .notPNGOrTIFF)
    }

    @Test("A BigTIFF is refused at import, never decoded")
    func bigTIFFRefusedAtImport() {
        let store = AvatarStore(rootURL: Pixels.tempRoot(), detectFaces: false)
        let bigTIFF = Data([0x49, 0x49, 0x2B, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 64))
        #expect(throws: (any Error).self) { _ = try store.importPhoto(data: bigTIFF, rosterID: UUID()) }
    }

    private func wait(timeout: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    @Test("A roster larger than the cache holds at 256 px steps down to 128 px and then stays decoded: a full extra pass re-decodes nothing")
    func largeRosterDoesNotThrash() throws {
        let root = Pixels.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let id = UUID()
        let first = try store.importPhoto(data: Pixels.png(width: 300, height: 300), rosterID: id)
        let src = try #require(store.url(for: first, rosterID: id))
        var names = [first]
        while names.count < 12 {
            let n = AvatarFileName.make()
            try FileManager.default.copyItem(at: src, to: try #require(store.url(for: n, rosterID: id)))
            names.append(n)
        }
        // Room for 5 photos at 256 px, so 12 do not fit there — but 12 fit comfortably at 128 px.
        let cap = AvatarImageCache.estimatedCost(bucket: 256) * 5 + 1024
        let cache = AvatarImageCache(byteCapacity: cap); cache.store = store
        func pass() {
            for n in names { _ = cache.photo(fileName: n, rosterID: id, points: 128) }       // asks for the 256-px bucket
            wait { cache.inFlightCount == 0 }
        }
        pass()                       // fills: the first photos at 256 px, then the working set outgrows the cap
        pass()                       // settles every photo at the 128-px bucket
        let settled = cache.loadAttempts
        pass(); pass()
        #expect(cache.loadAttempts == settled, "\(cache.loadAttempts - settled) photos were decoded again after the cache had settled (LRU thrash)")
        #expect(names.allSatisfy { cache.isCached(fileName: $0, rosterID: id, points: 128) }, "not every photo of the roster stays decoded")
        #expect(cache.decodedBytes <= cap)
    }

    @Test("A roster that fits keeps its 256-px photos — the step-down only starts when the working set cannot fit")
    func smallRosterKeepsFullSize() {
        #expect(AvatarImageCache.servedBucket(requested: 256, photoCount: 200, byteCapacity: AvatarImageCache.defaultByteCapacity) == 256)
        #expect(AvatarImageCache.servedBucket(requested: 256, photoCount: 256, byteCapacity: AvatarImageCache.defaultByteCapacity) == 256)
        #expect(AvatarImageCache.servedBucket(requested: 256, photoCount: 257, byteCapacity: AvatarImageCache.defaultByteCapacity) == 128)
        #expect(AvatarImageCache.servedBucket(requested: 128, photoCount: 5_000, byteCapacity: AvatarImageCache.defaultByteCapacity) == 128)
        #expect(AvatarImageCache.servedBucket(requested: 64, photoCount: 5_000, byteCapacity: AvatarImageCache.defaultByteCapacity) == 64)
    }
}


// MARK: - Sent-message sync (F-044 D23's deferred half)

/// What the Mac shows and — more importantly — must NOT do once the phone syncs the messages the user sends.
@MainActor
@Suite("Sent messages on the console (sent-sync)")
struct SentSyncTests {

    // MARK: building blocks

    private func node(_ crypto: CryptoService, address: String, body: String, dateMs: Double, sub: Int = 1,
                       type: Int?, read: Bool = true) throws -> [String: Any] {
        var n: [String: Any] = ["addressEnc": try crypto.encrypt(address), "bodyEnc": try crypto.encrypt(body),
                                "threadKey": "k", "threadId": 1, "subscriptionId": sub, "date": dateMs,
                                "read": read, "seen": true, "syncedAt": dateMs, "schema": 1]
        if let type { n["type"] = type }
        return n
    }

    private func client() throws -> (SMSSyncClient, CryptoService) {
        let c = SMSSyncClient()
        let crypto = try PhoneFixture.load().crypto
        c.installCryptoForTesting(crypto)
        return (c, crypto)
    }

    private func msg(_ id: String, _ dir: SMSDirection, _ body: String = "Rs 500 debited from a/c XX1234", date: Date = Date(),
                     cat: SMSCategory = .transactional, read: Bool = false) -> SMSMessage {
        SMSMessage(id: id, lineId: "L", contactNumber: "VK-HDFCBK-T", body: body, date: date, category: cat, read: read, direction: dir)
    }

    // MARK: decoding — an old phone's rows, and rows that must never be rendered as received

    @Test("A messages row with no type (every phone before sent-sync) or type 1 is a received message")
    func oldPhoneRowsStayReceived() throws {
        let (_, crypto) = try client()
        for type in [nil, 1] as [Int?] {
            let m = SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: type), crypto: crypto)
            #expect(m?.direction == .received, "type \(String(describing: type))")
        }
    }

    @Test("A type-2 row inside messages is a SENT message, and any other type there is dropped, never rendered as received")
    func typeIsHonoured() throws {
        let (_, crypto) = try client()
        let two = SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: 2), crypto: crypto)
        #expect(two?.direction == .sent)
        for type in [0, 3, 4, 5, 6, 99] {       // draft, outbox, failed, queued, junk
            #expect(SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: type), crypto: crypto) == nil, "type \(type) must not be shown as received")
        }
        var stringly = try node(crypto, address: "X", body: "b", dateMs: 1_000, type: nil); stringly["type"] = "2"
        #expect(SMSWire.message(deviceId: "d", msgId: "1_1", value: stringly, crypto: crypto) == nil, "a malformed type is rejected, not guessed")
    }

    @Test("A row under sent/ is sent whatever its fields say, and a row there claiming another type is rejected")
    func sentNodeKind() throws {
        let (_, crypto) = try client()
        #expect(SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: 2), crypto: crypto, node: .sent)?.direction == .sent)
        #expect(SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: nil), crypto: crypto, node: .sent)?.direction == .sent)
        #expect(SMSWire.message(deviceId: "d", msgId: "1_1", value: try node(crypto, address: "X", body: "b", dateMs: 1_000, type: 1), crypto: crypto, node: .sent) == nil)
    }

    // MARK: threads — unread, category, search

    @Test("Sent messages are never unread, whatever their read flag says, and never colour the thread")
    func unreadAndCategory() throws {
        let (c, crypto) = try client()
        let t = 1_800_000_000_000.0
        c.mergeMessage(deviceId: "d", msgId: "in", value: try node(crypto, address: "+919876543210", body: "Rs 500 debited from a/c XX1234", dateMs: t, type: 1, read: false))
        c.mergeMessage(deviceId: "d", msgId: "out", value: try node(crypto, address: "+919876543210", body: "Paid you Rs 500 via UPI — received?", dateMs: t + 60_000, type: 2, read: false), node: .sent)
        #expect(c.threads.count == 1, "both sides of the conversation are one thread")
        let thread = try #require(c.threads.first)
        #expect(thread.messages.count == 2 && thread.lastMessage?.direction == .sent)
        #expect(thread.unreadCount == 1, "only the received message can be unread")
        #expect(thread.category == .personal, "the sent message is not classified; the thread keeps the received one's category")
    }

    @Test("A thread of nothing but sent messages has no unread and no classified category")
    func sentOnlyThread() throws {
        let (c, crypto) = try client()
        c.mergeMessage(deviceId: "d", msgId: "out", value: try node(crypto, address: "56161", body: "STOP", dateMs: 1_800_000_000_000, type: 2, read: false), node: .sent)
        let thread = try #require(c.threads.first)
        #expect(thread.unreadCount == 0 && thread.category == .uncategorized)
    }

    @Test("Search finds a sent message's text and its recipient; the row previews it as 'You: …'")
    func searchCoversBothSides() throws {
        let vm = SMSConsoleViewModel()
        let crypto = try PhoneFixture.load().crypto
        vm.client.installCryptoForTesting(crypto)
        let t = 1_800_000_000_000.0
        vm.client.mergeMessage(deviceId: "d", msgId: "in", value: try node(crypto, address: "+919876543210", body: "see you at seven", dateMs: t, type: 1, read: false))
        vm.client.mergeMessage(deviceId: "d", msgId: "out", value: try node(crypto, address: "+919812300000", body: "parking is behind the cafe", dateMs: t + 1_000, type: 2), node: .sent)

        vm.search = "parking"                                   // only in the sent message
        #expect(vm.filteredThreads.map(\.contactNumber) == ["+919812300000"])
        vm.search = "seven"                                     // only in the received one
        #expect(vm.filteredThreads.map(\.contactNumber) == ["+919876543210"])
        vm.search = "98123"                                     // the recipient of a sent-only thread
        #expect(vm.filteredThreads.count == 1)
        vm.search = ""
        let sentThread = try #require(vm.allThreads.first { $0.contactNumber == "+919812300000" })
        #expect(vm.preview(for: sentThread) == "You: parking is behind the cafe")
        #expect(vm.totalUnread == 1, "the unread badge counts the one received message and not the sent one")
    }

    // MARK: notifications

    @Test("A sent message never raises a notification; a new received one still does")
    func notificationRule() {
        let connected = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        #expect(!SMSSyncClient.shouldNotify(message: msg("s", .sent, date: later), isNew: true, connectedAt: connected, notificationsEnabled: true))
        #expect(SMSSyncClient.shouldNotify(message: msg("r", .received, date: later), isNew: true, connectedAt: connected, notificationsEnabled: true))
        // the pre-existing rules still hold
        #expect(!SMSSyncClient.shouldNotify(message: msg("r", .received, date: later), isNew: false, connectedAt: connected, notificationsEnabled: true))
        #expect(!SMSSyncClient.shouldNotify(message: msg("r", .received, date: connected.addingTimeInterval(-1)), isNew: true, connectedAt: connected, notificationsEnabled: true))
        #expect(!SMSSyncClient.shouldNotify(message: msg("r", .received, date: later), isNew: true, connectedAt: connected, notificationsEnabled: false))
    }

    // MARK: the expenditure pipeline (F-048/F-056) — a sent message is never a transaction

    @Test("A sent bank-style text produces no transaction, even force-included by an override")
    func sentNeverReachesTheLedger() {
        let pack = PatternPack.indiaDefault
        let text = "Rs.5000 debited from a/c XX1234 via UPI"
        let sent = msg("d/sent/1", .sent, text)
        let received = msg("d/1", .received, text)

        let none = TransactionPipeline.run(messages: [sent], pack: pack, overrides: .init())
        #expect(none.transactions.isEmpty && none.unreadableCount == 0)

        var forced = ExpenditureOverrides(); forced.includedIds = [sent.id]        // D9 "force include" must not open the door
        #expect(TransactionPipeline.run(messages: [sent], pack: pack, overrides: forced).transactions.isEmpty)

        // The same text received IS a transaction — the guard is about direction, not about the text.
        #expect(TransactionPipeline.run(messages: [received], pack: pack, overrides: .init()).transactions.count == 1)
        // Mixed: only the received one is counted, so a sent copy can't even form a near-duplicate pair.
        let mixed = TransactionPipeline.run(messages: [sent, received], pack: pack, overrides: .init())
        #expect(mixed.transactions.count == 1 && mixed.transactions.allSatisfy { !$0.isDuplicate })
    }

    @Test("The expenditure view model feeds the pipeline received messages only")
    func pipelineInputIsReceivedOnly() throws {
        let (c, crypto) = try client()
        let t = 1_800_000_000_000.0
        c.mergeMessage(deviceId: "d", msgId: "in", value: try node(crypto, address: "VK-HDFCBK-T", body: "Rs.100 debited via UPI", dateMs: t, type: 1))
        c.mergeMessage(deviceId: "d", msgId: "out", value: try node(crypto, address: "VK-HDFCBK-T", body: "Rs.100 debited via UPI", dateMs: t + 1_000, type: 2), node: .sent)
        let input = ExpenditureViewModel.pipelineInput(from: c.threads)
        #expect(input.map(\.id) == ["d/in"] && input.allSatisfy { $0.direction == .received })
    }
}
