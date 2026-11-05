import Testing
import Foundation
import UniformTypeIdentifiers
@testable import HaloShareStaging

private func tempDir(_ tag: String = "stage") -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeFile(_ name: String, bytes: Int, in dir: URL? = nil) throws -> URL {
    let d = dir ?? tempDir("src")
    let url = d.appendingPathComponent(name)
    try Data(repeating: 0x5A, count: bytes).write(to: url)
    return url
}

private func store(_ limits: StagingLimits = .default) -> ShareStagingStore {
    ShareStagingStore(root: tempDir("root"), limits: limits)
}

@Suite("StagedFileName")
struct StagedFileNameTests {
    @Test("Paths, traversal, control characters and hidden-file dots are neutralised")
    func hostile() {
        #expect(StagedFileName.sanitize("../../etc/passwd") == "passwd")
        #expect(StagedFileName.sanitize("a\\b\\c.txt") == "c.txt")
        #expect(StagedFileName.sanitize("..") == "file")
        #expect(StagedFileName.sanitize(".hidden") == "hidden")
        #expect(StagedFileName.sanitize("bad\u{0}name\u{7}.txt") == "badname.txt")
        #expect(StagedFileName.sanitize("a:b*c?.txt") == "abc.txt")
        #expect(StagedFileName.sanitize("   ") == "file")
        #expect(StagedFileName.sanitize(nil) == "file")
        #expect(StagedFileName.sanitize("") == "file")
    }

    @Test("Bidi overrides, zero-width and BOM characters cannot disguise an extension")
    func bidi() {
        #expect(StagedFileName.sanitize("invoice-\u{202E}gpj.exe") == "invoice-gpj.exe")
        #expect(StagedFileName.sanitize("a\u{200B}b\u{2066}c\u{FEFF}.txt") == "abc.txt")
    }

    @Test("Long names are shortened but keep their extension")
    func long() {
        let n = StagedFileName.sanitize(String(repeating: "x", count: 400) + ".jpeg", maxLength: 50)
        #expect(n.count <= 50)
        #expect(n.hasSuffix(".jpeg"))
    }
}

@Suite("SecurityScopedAccess")
struct SecurityScopedAccessTests {
    final class Log: @unchecked Sendable {
        let lock = NSLock(); var stopped: [URL] = []
        func add(_ u: URL) { lock.withLock { stopped.append(u) } }
    }

    @Test("Only URLs whose access was granted are released, and each exactly once")
    func balanced() {
        let granted = URL(fileURLWithPath: "/a/granted.txt"), refused = URL(fileURLWithPath: "/a/refused.txt")
        let log = Log()
        let access = SecurityScopedAccess(start: { $0 == granted }, stop: { log.add($0) })
        access.begin([granted, refused])
        #expect(access.heldCount == 1)
        access.end()
        access.end()                       // idempotent
        #expect(log.stopped == [granted])
    }

    @Test("Releasing happens on deinit too, so an abandoned selection cannot leak access")
    func deinitReleases() {
        let u = URL(fileURLWithPath: "/a/b.txt"); let log = Log()
        var access: SecurityScopedAccess? = SecurityScopedAccess(start: { _ in true }, stop: { log.add($0) })
        access?.begin([u])
        access = nil
        #expect(log.stopped == [u])
    }
}

@Suite("ShareStagingStore")
struct StagingStoreTests {

    @Test("A file is copied in, listed, and its bytes are intact")
    func roundTrip() throws {
        let s = store()
        let src = try makeFile("photo.jpg", bytes: 3000)
        let b = try s.makeBatchBuilder()
        try b.addFile(copying: src)
        let batch = try #require(try b.commit())

        let pending = s.pendingBatches()
        #expect(pending.count == 1)
        #expect(pending[0].id == batch.id)
        #expect(pending[0].items[0].fileName == "photo.jpg")
        #expect(pending[0].items[0].size == 3000)
        let url = try #require(s.fileURL(for: pending[0].items[0], in: pending[0]))
        #expect(try Data(contentsOf: url) == Data(repeating: 0x5A, count: 3000))
        // The original is untouched.
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test("A batch is invisible until committed — the app never reads a half-written one")
    func atomic() throws {
        let s = store()
        let b = try s.makeBatchBuilder()
        try b.addFile(copying: makeFile("a.bin", bytes: 10))
        #expect(s.pendingBatches().isEmpty)
        try b.commit()
        #expect(s.pendingBatches().count == 1)
    }

    @Test("Nothing staged ⇒ nothing committed and nothing left on disk")
    func emptyCommit() throws {
        let s = store()
        let b = try s.makeBatchBuilder()
        #expect(try b.commit() == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: s.root.path))?.isEmpty == true)
    }

    @Test("Item count is capped")
    func countCap() throws {
        let s = store(StagingLimits(maxItems: 2))
        let b = try s.makeBatchBuilder()
        try b.addFile(copying: makeFile("1", bytes: 1)); try b.addFile(copying: makeFile("2", bytes: 1))
        #expect(throws: StagingRejection.tooManyItems(max: 2)) { try b.addFile(copying: makeFile("3", bytes: 1)) }
        #expect(b.count == 2)
    }

    @Test("A file over the per-item cap is refused before anything is copied")
    func itemCap() throws {
        let s = store(StagingLimits(maxItemBytes: 100))
        let b = try s.makeBatchBuilder()
        #expect(throws: StagingRejection.itemTooLarge(name: "big.bin", maxBytes: 100)) {
            try b.addFile(copying: makeFile("big.bin", bytes: 101))
        }
        try b.addFile(copying: makeFile("ok.bin", bytes: 100))      // the boundary is inclusive
        let files = try FileManager.default.contentsOfDirectory(atPath: s.root.appendingPathComponent(".building-\(b.id)/files").path)
        #expect(files.count == 1, "the refused file left no directory behind")
    }

    @Test("The whole batch is capped too, and a refused item does not use up the budget")
    func batchCap() throws {
        let s = store(StagingLimits(maxItemBytes: 100, maxBatchBytes: 150))
        let b = try s.makeBatchBuilder()
        try b.addFile(copying: makeFile("a", bytes: 100))
        #expect(throws: StagingRejection.batchTooLarge(maxBytes: 150)) { try b.addFile(copying: makeFile("b", bytes: 60)) }
        try b.addFile(copying: makeFile("c", bytes: 50))            // still fits: the refusal released nothing it never took
        #expect(b.count == 2)
    }

    @Test("A folder is refused")
    func folder() throws {
        let b = try store().makeBatchBuilder()
        #expect(throws: StagingRejection.folder(name: "Trip")) { try b.addFile(copying: tempDir("Trip"), suggestedName: "Trip") }
    }

    @Test("A missing source is refused, not crashed on")
    func missing() throws {
        let b = try store().makeBatchBuilder()
        #expect(throws: StagingRejection.unreadable("nope.txt")) {
            try b.addFile(copying: URL(fileURLWithPath: "/nonexistent/nope.txt"))
        }
    }

    @Test("A hostile suggested name stays inside the item folder")
    func hostileName() throws {
        let s = store()
        let b = try s.makeBatchBuilder()
        let item = try b.addFile(copying: makeFile("x.bin", bytes: 4), suggestedName: "../../../../escape.txt")
        #expect(item.fileName == "escape.txt")
        let batch = try #require(try b.commit())
        let url = try #require(s.fileURL(for: batch.items[0], in: batch))
        #expect(url.path.hasPrefix(s.root.path))
        #expect(!FileManager.default.fileExists(atPath: s.root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    }

    @Test("Text is staged as a .txt file; blank and oversized text is refused")
    func text() throws {
        let s = store(StagingLimits(maxTextBytes: 10))
        let b = try s.makeBatchBuilder()
        let item = try b.addText("hello")
        #expect(item.kind == .text && item.size == 5 && item.mimeType == "text/plain")
        #expect(throws: StagingRejection.emptyText) { try b.addText("  \n ") }
        #expect(throws: StagingRejection.textTooLong(maxBytes: 10)) { try b.addText(String(repeating: "x", count: 11)) }
    }

    @Test("Only plain web links are staged")
    func links() throws {
        let b = try store().makeBatchBuilder()
        let item = try b.addLink(URL(string: "https://example.com/a?b=c")!)
        #expect(item.kind == .link && item.fileName == "Link example.com.txt")
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "halo://x", "https://user:pw@example.com/", "mailto:a@b.c"] {
            #expect(throws: StagingRejection.self, "\(bad)") { try b.addLink(URL(string: bad)!) }
        }
    }

    @Test("Expired batches are deleted on the next look; fresh ones survive")
    func expiry() throws {
        let s = store(StagingLimits(batchLifetime: 100))
        let old = try s.makeBatchBuilder(); try old.addText("old"); try old.commit(now: Date(timeIntervalSinceNow: -500))
        let fresh = try s.makeBatchBuilder(); try fresh.addText("fresh"); try fresh.commit()
        let pending = s.pendingBatches()
        #expect(pending.count == 1)
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent(old.id).path), "expired directory is gone from disk")
    }

    @Test("remove(batchID:) deletes the whole batch — the cleanup after a send or discard")
    func cleanup() throws {
        let s = store()
        let b = try s.makeBatchBuilder(); try b.addFile(copying: makeFile("a", bytes: 5))
        let batch = try #require(try b.commit())
        s.remove(batchID: batch.id)
        #expect(s.pendingBatches().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent(batch.id).path))
    }

    @Test("remove(batchID:) refuses an id that is a path")
    func removeTraversal() throws {
        let s = store()
        let canary = s.root.deletingLastPathComponent().appendingPathComponent("canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        s.remove(batchID: "../" + canary.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: canary.path))
    }

    @Test("A tampered manifest cannot widen the limits or point outside the batch")
    func tamperedManifest() throws {
        let s = store(StagingLimits(maxItems: 1, maxItemBytes: 100))
        let b = try s.makeBatchBuilder(); try b.addFile(copying: makeFile("ok.bin", bytes: 10))
        let batch = try #require(try b.commit())
        // Rewrite the manifest: lie about size, add a traversal id and a second item.
        var evil = batch
        evil.items[0].size = 1
        evil.items.append(StagedItem(id: "../..", fileName: "x", size: 1, mimeType: "a/b", kind: .file))
        evil.items.append(StagedItem(id: UUID().uuidString, fileName: "ghost", size: 1, mimeType: "a/b", kind: .file))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(evil).write(to: s.root.appendingPathComponent("\(batch.id)/manifest.json"))

        let pending = s.pendingBatches()
        #expect(pending.count == 1)
        #expect(pending[0].items.count == 1, "capped at maxItems; ghost and traversal items dropped")
        #expect(pending[0].items[0].size == 10, "size comes from the disk, not the manifest")
    }

    // The test above only *looks* like it exercises id/size validation: its extra items sit behind
    // `maxItems: 1`, so the cap alone drops them. These run with a cap that lets every tampered item
    // reach the per-item checks.
    @Test("Tampered items are rejected by validation, not just by the item cap")
    func tamperedManifestPerItem() throws {
        let s = store()                                              // default limits: 25 items
        let b = try s.makeBatchBuilder(); try b.addFile(copying: makeFile("ok.bin", bytes: 10))
        let batch = try #require(try b.commit())
        var evil = batch
        evil.items.append(StagedItem(id: "../..", fileName: "x", size: 1, mimeType: "a/b", kind: .file))
        evil.items.append(StagedItem(id: UUID().uuidString, fileName: "ghost", size: 1, mimeType: "a/b", kind: .file))
        evil.items.append(StagedItem(id: batch.items[0].id, fileName: "dup", size: 1, mimeType: "a/b", kind: .file))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(evil).write(to: s.root.appendingPathComponent("\(batch.id)/manifest.json"))
        let pending = s.pendingBatches()
        #expect(pending.first?.items.count == 1, "traversal id, missing file and duplicate id are all dropped")
    }

    @Test("The disk, not the manifest, decides what exceeds the item and batch caps")
    func tamperedSizesVersusCaps() throws {
        let s = store(StagingLimits(maxItems: 5, maxItemBytes: 100, maxBatchBytes: 150))
        let big = try makeFile("a.bin", bytes: 90), big2 = try makeFile("b.bin", bytes: 90)
        // Stage under generous limits, then re-open under strict ones with a manifest that lies small.
        let loose = ShareStagingStore(root: s.root, limits: StagingLimits(maxItems: 5, maxItemBytes: 1000, maxBatchBytes: 1000))
        let b = try loose.makeBatchBuilder()
        try b.addFile(copying: big); try b.addFile(copying: big2)
        var batch = try #require(try b.commit())
        for i in batch.items.indices { batch.items[i].size = 1 }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(batch).write(to: s.root.appendingPathComponent("\(batch.id)/manifest.json"))
        let pending = s.pendingBatches()
        #expect(pending.first?.items.count == 1, "90 + 90 > 150: the second is refused although the manifest claims 1 byte each")
        #expect(pending.first?.totalBytes == 90)
    }

    @Test("A symlink planted in a batch is never offered for sending")
    func plantedSymlink() throws {
        let fm = FileManager.default
        let s = store()
        let secret = try makeFile("secret.db", bytes: 5000)
        let b = try s.makeBatchBuilder()
        try b.addFile(copying: makeFile("keep.txt", bytes: 10))
        let victim = try b.addFile(copying: makeFile("victim.txt", bytes: 10))
        let batch = try #require(try b.commit())
        let planted = s.root.appendingPathComponent("\(batch.id)/files/\(victim.id)/\(victim.fileName)")
        try fm.removeItem(at: planted)
        try fm.createSymbolicLink(at: planted, withDestinationURL: secret)

        let pending = try #require(s.pendingBatches().first)
        #expect(pending.items.count == 1, "only the genuine file survives")
        #expect(pending.items.allSatisfy { $0.fileName == "keep.txt" })
        #expect(s.fileURL(for: victim, in: batch) == nil)
    }

    @Test("A symlinked item directory or batch directory cannot lead outside the batch")
    func symlinkedDirectories() throws {
        let fm = FileManager.default
        let s = store()
        let outside = tempDir("outside")
        try Data(repeating: 1, count: 20).write(to: outside.appendingPathComponent("x.txt"))
        let b = try s.makeBatchBuilder()
        let item = try b.addFile(copying: makeFile("x.txt", bytes: 10))
        let batch = try #require(try b.commit())
        // item directory -> a directory outside containing a same-named file
        let itemDir = s.root.appendingPathComponent("\(batch.id)/files/\(item.id)")
        try fm.removeItem(at: itemDir)
        try fm.createSymbolicLink(at: itemDir, withDestinationURL: outside)
        #expect(s.fileURL(for: item, in: batch) == nil)
        #expect(s.pendingBatches().isEmpty)

        // a whole batch directory that is a symlink to a directory holding a valid batch
        let alt = ShareStagingStore(root: outside)
        let b3 = try alt.makeBatchBuilder(); try b3.addText("hi")
        let altBatch = try #require(try b3.commit())
        try fm.createSymbolicLink(at: s.root.appendingPathComponent(UUID().uuidString),
                                  withDestinationURL: outside.appendingPathComponent(altBatch.id))
        #expect(s.pendingBatches().isEmpty, "a symlinked batch directory is not a batch")
    }

    @Test("A source symlink and the staging area itself are refused as sources")
    func refusedSources() throws {
        let fm = FileManager.default
        let s = store()
        let target = try makeFile("t.bin", bytes: 10)
        let link = target.deletingLastPathComponent().appendingPathComponent("l.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let b = try s.makeBatchBuilder()
        #expect(throws: StagingRejection.self) { try b.addFile(copying: link) }

        // stage something, then try to stage a file *from inside* the staging root
        let b1 = try s.makeBatchBuilder(); let it = try b1.addFile(copying: target)
        let committed = try #require(try b1.commit())
        let inside = try #require(s.fileURL(for: it, in: committed))
        let b2 = try s.makeBatchBuilder()
        #expect(throws: StagingRejection.self) { try b2.addFile(copying: inside) }

        // a protected root (the app group container) is refused too
        let container = tempDir("container")
        let guarded = ShareStagingStore(root: container.appendingPathComponent("ShareStaging"), protectedRoots: [container])
        let priv = try makeFile("private.db", bytes: 10, in: container)
        let b3 = try guarded.makeBatchBuilder()
        #expect(throws: StagingRejection.self) { try b3.addFile(copying: priv) }
    }

    @Test("A manifest dated in the future, or absurdly large, is not kept alive")
    func futureAndOversizedManifest() throws {
        let s = store()
        let b = try s.makeBatchBuilder(); try b.addText("x")
        let batch = try #require(try b.commit())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var future = batch; future.createdAt = Date(timeIntervalSinceNow: 10 * 365 * 86400)
        try enc.encode(future).write(to: s.root.appendingPathComponent("\(batch.id)/manifest.json"))
        #expect(s.pendingBatches(now: Date(timeIntervalSinceNow: 30 * 86400)).isEmpty, "never expiring is not an option")

        let b2 = try s.makeBatchBuilder(); try b2.addText("y")
        let batch2 = try #require(try b2.commit())
        let huge = Data(repeating: 0x20, count: ShareStagingStore.maxManifestBytes + 10)
        try (try enc.encode(batch2) + huge).write(to: s.root.appendingPathComponent("\(batch2.id)/manifest.json"))
        #expect(s.pendingBatches().isEmpty)
    }

    @Test("A corrupt manifest is cleaned up rather than listed")
    func corrupt() throws {
        let s = store()
        let b = try s.makeBatchBuilder(); try b.addText("x")
        let batch = try #require(try b.commit())
        try Data("not json".utf8).write(to: s.root.appendingPathComponent("\(batch.id)/manifest.json"))
        #expect(s.pendingBatches().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent(batch.id).path))
    }

    @Test("Abandoned .building directories are swept once old")
    func abandoned() throws {
        let s = store()
        let b = try s.makeBatchBuilder(); try b.addText("x")           // never committed
        let dir = s.root.appendingPathComponent(".building-\(b.id)")
        #expect(s.pendingBatches().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path), "a recent one may still be in progress")
        #expect(s.pendingBatches(now: Date(timeIntervalSinceNow: 7200)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite("ShareIngest (NSItemProvider → staged batch)")
struct IngestTests {

    @Test("A file provider (Photos / Files shape) is staged with its bytes and name")
    func file() async throws {
        let s = store()
        let src = try makeFile("report.pdf", bytes: 2048)
        let provider = try #require(NSItemProvider(contentsOf: src))
        let r = await ShareIngest.stage(providers: [provider], into: s)
        #expect(r.rejections.isEmpty)
        let batch = try #require(r.batch)
        #expect(batch.items.count == 1)
        #expect(batch.items[0].fileName == "report.pdf")
        #expect(batch.items[0].size == 2048)
        #expect(batch.items[0].mimeType == "application/pdf")
        #expect(s.pendingBatches().count == 1)
    }

    @Test("A web link provider becomes a link file; a file: URL provider is treated as a file, never a link")
    func links() async throws {
        let s = store()
        let web = NSItemProvider(item: URL(string: "https://example.org/x")! as NSURL, typeIdentifier: UTType.url.identifier)
        let r = await ShareIngest.stage(providers: [web], into: s)
        #expect(r.batch?.items.first?.kind == .link)

        let src = try makeFile("note.txt", bytes: 7)
        let fileURL = NSItemProvider(item: src as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let r2 = await ShareIngest.stage(providers: [fileURL], into: s)
        #expect(r2.batch?.items.first?.kind == .file)
        #expect(r2.batch?.items.first?.fileName == "note.txt")
    }

    @Test("A javascript: link is rejected and stages nothing")
    func badLink() async throws {
        let p = NSItemProvider(item: URL(string: "javascript:alert(1)")! as NSURL, typeIdentifier: UTType.url.identifier)
        let s = store()
        let r = await ShareIngest.stage(providers: [p], into: s)
        #expect(r.batch == nil)
        #expect(r.rejections.count == 1)
        #expect(s.pendingBatches().isEmpty)
    }

    @Test("Plain text is staged as a text file")
    func text() async throws {
        let p = NSItemProvider(item: "hello from another app" as NSString, typeIdentifier: UTType.plainText.identifier)
        let r = await ShareIngest.stage(providers: [p], into: store())
        #expect(r.batch?.items.first?.kind == .text)
    }

    @Test("Over the item cap: the first ones are kept, the rest are reported — not silently dropped")
    func overCap() async throws {
        let s = store(StagingLimits(maxItems: 2))
        var providers: [NSItemProvider] = []
        for i in 0..<4 { providers.append(try #require(NSItemProvider(contentsOf: try makeFile("f\(i).bin", bytes: 4)))) }
        let r = await ShareIngest.stage(providers: providers, into: s)
        #expect(r.staged == 2)
        #expect(r.rejections == [.tooManyItems(max: 2), .tooManyItems(max: 2)])
    }

    @Test("A folder is rejected with a reason")
    func folder() async throws {
        let dir = tempDir("FolderToShare")
        let p = try #require(NSItemProvider(contentsOf: dir))
        let r = await ShareIngest.stage(providers: [p], into: store())
        #expect(r.batch == nil)
        #expect(!r.rejections.isEmpty)
    }
}
