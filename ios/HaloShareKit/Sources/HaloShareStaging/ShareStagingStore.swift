import Foundation
import UniformTypeIdentifiers

// MARK: - ShareStagingStore

/// The hand-off between the Share Extension and the app, over the App Group container.
///
/// Layout, under `root`:
///
///     <batch-id>/manifest.json
///     <batch-id>/files/<item-id>/<sanitised name>
///     .building-<batch-id>/…         (a batch still being written — never listed)
///
/// A batch becomes visible by an atomic `rename` of its `.building-` directory **after** the
/// manifest is written, so the app can never read half of one. The app treats everything it
/// reads here as untrusted: ids come from directory names, sizes from the disk, and file
/// paths are re-derived and confined to the batch.
public final class ShareStagingStore: @unchecked Sendable {

    public static let appGroupIdentifier = "group.com.halo.mobile"
    static let buildingPrefix = ".building-"

    public let root: URL
    public let limits: StagingLimits
    /// Directories whose contents may never be *staged* (the App Group container the app keeps its
    /// own state in). A host app can hand the extension any file URL the extension can read; the
    /// extension's reach includes this container, so it is refused as a source.
    public let protectedRoots: [URL]
    private let fm: FileManager
    /// Upper bound for a manifest: 25 items is ~6 KB, so anything near this is not ours.
    static let maxManifestBytes = 1 << 20

    public init(root: URL, limits: StagingLimits = .default, protectedRoots: [URL] = [], fileManager: FileManager = .default) {
        self.root = root
        self.limits = limits
        self.protectedRoots = protectedRoots
        self.fm = fileManager
    }

    /// The store inside the App Group container, or `nil` when the entitlement isn't in effect
    /// (an unsigned build on a device, or a profile without the group).
    public static func appGroup(identifier: String = appGroupIdentifier, limits: StagingLimits = .default) -> ShareStagingStore? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        return ShareStagingStore(root: container.appendingPathComponent("ShareStaging", isDirectory: true), limits: limits,
                                 protectedRoots: [container])
    }

    // MARK: Writing

    public func makeBatchBuilder() throws -> BatchBuilder {
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw StagingRejection.storageUnavailable }
        return try BatchBuilder(store: self, id: UUID().uuidString, fileManager: fm)
    }

    // MARK: Reading

    /// Valid, unexpired batches, newest first. Also tidies: expired batches, abandoned
    /// `.building-` directories (an extension that was killed mid-copy), corrupt manifests and
    /// batches left with no readable file are deleted.
    public func pendingBatches(now: Date = Date()) -> [StagedBatch] {
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var batches: [StagedBatch] = []
        for dir in entries {
            let name = dir.lastPathComponent
            if name.hasPrefix(Self.buildingPrefix) {
                let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: dir) }
                continue
            }
            guard Self.isSafeID(name) else { continue }              // not ours; leave it alone
            guard let batch = load(batchDirectory: dir, id: name, now: now) else { try? fm.removeItem(at: dir); continue }
            if now.timeIntervalSince(batch.createdAt) > limits.batchLifetime { try? fm.removeItem(at: dir); continue }
            batches.append(batch)
        }
        return batches.sorted { $0.createdAt > $1.createdAt }
    }

    /// The on-disk file for an item, confined to its batch. `nil` if it isn't there.
    public func fileURL(for item: StagedItem, in batch: StagedBatch) -> URL? {
        guard Self.isSafeID(batch.id), Self.isSafeID(item.id) else { return nil }
        let name = StagedFileName.sanitize(item.fileName, maxLength: limits.maxNameLength)
        let url = root.appendingPathComponent(batch.id, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(item.id, isDirectory: true)
            .appendingPathComponent(name)
        return isConfinedRegularFile(url, batchID: batch.id) ? url : nil
    }

    /// A *regular file* (not a symlink, not a directory) whose real path is inside its batch
    /// directory. The container is writable by anything signed with the same group, and the send
    /// path later opens whatever this returns — a symlink planted in a batch would otherwise make
    /// the app upload a file from outside staging (its own `Application Support`, say). Following
    /// symlinks was the old behaviour: `fileSizeKey` of a link is the length of its *path*, and
    /// `uploadTask(fromFile:)` reads the target.
    func isConfinedRegularFile(_ url: URL, batchID: String) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              v.isSymbolicLink != true, v.isRegularFile == true else { return false }
        let base = root.resolvingSymlinksInPath().appendingPathComponent(batchID, isDirectory: true).path + "/"
        return url.resolvingSymlinksInPath().path.hasPrefix(base)
    }

    /// True when `url` is, or lies inside, the staging directory or a protected root.
    func isProtectedSource(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath().path
        return ([root] + protectedRoots).contains { r in
            let p = r.resolvingSymlinksInPath().path
            return real == p || real.hasPrefix(p + "/")
        }
    }

    /// Deletes a batch (after a send, or when the user discards it).
    public func remove(batchID: String) {
        guard Self.isSafeID(batchID) else { return }
        try? fm.removeItem(at: root.appendingPathComponent(batchID, isDirectory: true))
    }

    public func removeAll() {
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        entries.forEach { try? fm.removeItem(at: $0) }
    }

    // MARK: Internals

    /// Batch and item ids are UUIDs. Anything else — `..`, a slash, a dot — is refused before
    /// it can become part of a path.
    static func isSafeID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func load(batchDirectory dir: URL, id: String, now: Date) -> StagedBatch? {
        let manifest = dir.appendingPathComponent("manifest.json")
        guard isConfinedRegularFile(manifest, batchID: id),
              let size = (try? manifest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxManifestBytes,
              let data = try? Data(contentsOf: manifest) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var batch = try? decoder.decode(StagedBatch.self, from: data), batch.version == 1 else { return nil }
        // A batch dated in the future would never reach its 24 h expiry.
        guard batch.createdAt <= now.addingTimeInterval(300) else { return nil }
        batch.id = id
        var seen = Set<String>()
        var valid: [StagedItem] = []
        var total: Int64 = 0
        for var item in batch.items.prefix(limits.maxItems) {
            guard seen.insert(item.id).inserted, Self.isSafeID(item.id) else { continue }
            item.fileName = StagedFileName.sanitize(item.fileName, maxLength: limits.maxNameLength)
            guard let url = fileURL(for: item, in: StagedBatch(id: id, createdAt: batch.createdAt, items: [])),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            // The disk is the truth, not the manifest.
            guard Int64(size) <= limits.maxItemBytes, total + Int64(size) <= limits.maxBatchBytes else { continue }
            item.size = Int64(size)
            total += item.size
            valid.append(item)
        }
        guard !valid.isEmpty else { return nil }
        batch.items = valid
        return batch
    }
}

// MARK: - BatchBuilder

/// Accumulates one share into a `.building-` directory. Every `add…` enforces the limits and
/// either stages the item completely or throws a `StagingRejection` and leaves nothing behind.
public final class BatchBuilder: @unchecked Sendable {
    public let id: String
    private let store: ShareStagingStore
    private let fm: FileManager
    private let dir: URL
    private let lock = NSLock()
    private var items: [StagedItem] = []
    private var totalBytes: Int64 = 0
    private var finished = false

    init(store: ShareStagingStore, id: String, fileManager: FileManager) throws {
        self.store = store; self.id = id; self.fm = fileManager
        dir = store.root.appendingPathComponent(ShareStagingStore.buildingPrefix + id, isDirectory: true)
        do { try fm.createDirectory(at: dir.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true) }
        catch { throw StagingRejection.storageUnavailable }
    }

    public var count: Int { lock.withLock { items.count } }

    // MARK: Adding

    /// Copies a file in. The source is only read; a security-scoped or temporary URL is fine.
    @discardableResult
    public func addFile(copying source: URL, suggestedName: String? = nil, mimeType: String? = nil) throws -> StagedItem {
        let displayName = StagedFileName.sanitize(suggestedName ?? source.lastPathComponent, maxLength: store.limits.maxNameLength)
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true { throw StagingRejection.folder(name: displayName) }
        // Never stage the staging area itself or the app's own container, whoever asks.
        if store.isProtectedSource(source) { throw StagingRejection.unreadable(displayName) }
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw StagingRejection.unreadable(displayName) }
        let bytes = Int64(size)

        let itemID = UUID().uuidString
        try reserve(bytes: bytes, name: displayName)
        let itemDir = dir.appendingPathComponent("files/\(itemID)", isDirectory: true)
        let target = itemDir.appendingPathComponent(displayName)
        do {
            try fm.createDirectory(at: itemDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)             // streamed by the OS, not loaded into memory
        } catch {
            release(bytes: bytes)
            try? fm.removeItem(at: itemDir)
            throw StagingRejection.unreadable(displayName)
        }
        // Re-check what actually landed: a file can grow between the stat and the copy.
        let copied = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if copied > store.limits.maxItemBytes {
            release(bytes: bytes); try? fm.removeItem(at: itemDir)
            throw StagingRejection.itemTooLarge(name: displayName, maxBytes: store.limits.maxItemBytes)
        }
        let item = StagedItem(id: itemID, fileName: displayName, size: copied,
                              mimeType: mimeType ?? Self.mimeType(forName: displayName), kind: .file)
        lock.withLock { items.append(item); totalBytes += (copied - bytes) }
        return item
    }

    @discardableResult
    public func addText(_ text: String, name: String = "Shared text.txt") throws -> StagedItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StagingRejection.emptyText }
        let data = Data(text.utf8)
        guard data.count <= store.limits.maxTextBytes else { throw StagingRejection.textTooLong(maxBytes: store.limits.maxTextBytes) }
        return try addGenerated(data, name: name, kind: .text)
    }

    /// Only plain web links. `file:`, `javascript:`, custom schemes and credentials-in-URL are refused.
    @discardableResult
    public func addLink(_ url: URL) throws -> StagedItem {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw StagingRejection.badLink("only web links (http/https) are supported")
        }
        guard let host = url.host, !host.isEmpty else { throw StagingRejection.badLink("it has no host") }
        guard url.user == nil, url.password == nil else { throw StagingRejection.badLink("it contains a password") }
        let text = url.absoluteString
        guard text.utf8.count <= 4096 else { throw StagingRejection.badLink("it is too long") }
        return try addGenerated(Data((text + "\n").utf8), name: "Link \(host).txt", kind: .link)
    }

    private func addGenerated(_ data: Data, name: String, kind: StagedItemKind) throws -> StagedItem {
        let displayName = StagedFileName.sanitize(name, maxLength: store.limits.maxNameLength)
        let bytes = Int64(data.count)
        try reserve(bytes: bytes, name: displayName)
        let itemID = UUID().uuidString
        let itemDir = dir.appendingPathComponent("files/\(itemID)", isDirectory: true)
        do {
            try fm.createDirectory(at: itemDir, withIntermediateDirectories: true)
            try data.write(to: itemDir.appendingPathComponent(displayName))
        } catch {
            release(bytes: bytes); try? fm.removeItem(at: itemDir)
            throw StagingRejection.storageUnavailable
        }
        let item = StagedItem(id: itemID, fileName: displayName, size: bytes, mimeType: "text/plain", kind: kind)
        lock.withLock { items.append(item) }
        return item
    }

    // MARK: Limits (checked *before* any byte is copied)

    private func reserve(bytes: Int64, name: String) throws {
        try lock.withLock {
            guard !finished else { throw StagingRejection.storageUnavailable }
            guard items.count < store.limits.maxItems else { throw StagingRejection.tooManyItems(max: store.limits.maxItems) }
            guard bytes <= store.limits.maxItemBytes else {
                throw StagingRejection.itemTooLarge(name: name, maxBytes: store.limits.maxItemBytes)
            }
            guard totalBytes + bytes <= store.limits.maxBatchBytes else {
                throw StagingRejection.batchTooLarge(maxBytes: store.limits.maxBatchBytes)
            }
            totalBytes += bytes
        }
    }

    private func release(bytes: Int64) { lock.withLock { totalBytes -= bytes } }

    // MARK: Finishing

    /// Publishes the batch (manifest, then atomic rename). `nil` — and nothing left on disk —
    /// when no item was staged.
    @discardableResult
    public func commit(now: Date = Date()) throws -> StagedBatch? {
        let snapshot: [StagedItem] = lock.withLock { finished = true; return items }
        guard !snapshot.isEmpty else { try? fm.removeItem(at: dir); return nil }
        let batch = StagedBatch(id: id, createdAt: now, items: snapshot)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(batch).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            try fm.moveItem(at: dir, to: store.root.appendingPathComponent(id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: dir)
            throw StagingRejection.storageUnavailable
        }
        return batch
    }

    /// Throws away everything staged so far.
    public func abort() {
        lock.withLock { finished = true; items.removeAll() }
        try? fm.removeItem(at: dir)
    }

    static func mimeType(forName name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
