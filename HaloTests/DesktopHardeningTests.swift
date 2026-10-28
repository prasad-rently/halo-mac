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
        // What one decoded 256-px photo actually costs, measured rather than assumed.
        let probe = AvatarImageCache(); probe.store = store
        _ = probe.photo(fileName: a, rosterID: id, points: 128)
        wait { probe.decodedCount == 1 }
        let one = probe.decodedBytes
        #expect(one > 0)
        let cache = AvatarImageCache(byteCapacity: one * 3 + one / 2); cache.store = store   // room for three
        func load(_ n: String) {
            _ = cache.photo(fileName: n, rosterID: id, points: 128)
            wait { cache.isCached(fileName: n, rosterID: id, points: 128) }
        }
        load(a); load(b); load(c)
        _ = cache.photo(fileName: a, rosterID: id, points: 128)              // `a` is drawn again: most recent
        load(d)                                                              // over the cap: the oldest USE goes
        #expect(cache.isCached(fileName: a, rosterID: id, points: 128), "the most recently used photo was evicted (FIFO, not LRU)")
        #expect(!cache.isCached(fileName: b, rosterID: id, points: 128), "the least recently used photo was kept")
        #expect(cache.isCached(fileName: c, rosterID: id, points: 128) && cache.isCached(fileName: d, rosterID: id, points: 128))
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
        #expect(f.entries("lines").count >= 2 && f.entries("messages").count >= 2 && f.entries("clipboard").count >= 3)
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
