import Foundation
import SQLite3

// MARK: - DriveIndexStore  (F-051)
//
// Persistent, cross-launch, cross-disconnect index of every file Halo has
// seen on an approved drive. Backed by raw SQLite3 (libsqlite3.tbd — no SPM
// dependency) rather than JSON-in-UserDefaults: search must work with the
// drive disconnected without loading every path into memory, and a
// reindex diff needs indexed lookups, not a full deserialize.
//
// One actor, one connection — SQLite serializes naturally under the
// actor's own serialization, so no additional locking is needed.

/// One file discovered by a directory walk, before it's reconciled against
/// the store. `DriveIndexCoordinator` produces these; `applyDiff` consumes
/// them.
struct WalkedFileRow: Sendable {
    let relativePath: String
    let fileName: String
    let size: Int64
    let createdDate: Date?
    let modifiedDate: Date?
    let inode: UInt64
    let category: IndexedFileCategory
}

/// What a reindex actually did, for logging/UI ("changed 12 files").
struct DriveDiffSummary: Sendable, Equatable {
    var inserted = 0
    var moved = 0
    var modified = 0
    var removed = 0
    var unchanged = 0
}

enum DriveIndexStoreError: Error {
    case openFailed(String)
    case sqlError(String)
}

actor DriveIndexStore {

    private var db: OpaquePointer?

    /// Opens (creating if needed) the store at
    /// `~/Library/Application Support/Halo/drive-index.sqlite3`, or under
    /// `directoryOverride` when provided — used by `HaloTests` to get a
    /// fully isolated, disposable store per test rather than touching the
    /// real on-disk index.
    init(directoryOverride: URL? = nil) throws {
        let dir = try directoryOverride ?? DriveIndexStore.storeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("drive-index.sqlite3").path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw DriveIndexStoreError.openFailed(message)
        }
        db = handle
        try execute("PRAGMA journal_mode=WAL;")
        try createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// UI tests pass `-uiTestingSeedDriveIndex` to get deterministic sample
    /// data (see `DriveIndexCoordinator.seedForUITesting()`) — routing the
    /// whole store to a temp directory in that mode keeps test runs from
    /// ever touching a developer's real drive index, mirroring
    /// `HaloTestFixtures`'s sandboxed-temp-dir philosophy.
    nonisolated static func storeDirectory() throws -> URL {
        if ProcessInfo.processInfo.arguments.contains("-uiTestingSeedDriveIndex") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("HaloUITestDriveIndex", isDirectory: true)
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent("Halo", isDirectory: true)
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS drives (
            driveKey TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            indexingState TEXT NOT NULL,
            lastIndexedDate REAL,
            fileCount INTEGER NOT NULL DEFAULT 0,
            totalBytes INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            driveKey TEXT NOT NULL,
            relativePath TEXT NOT NULL,
            fileName TEXT NOT NULL,
            size INTEGER NOT NULL,
            createdDate REAL,
            modifiedDate REAL,
            inode INTEGER NOT NULL,
            category TEXT NOT NULL,
            partialHash TEXT,
            fullHash TEXT,
            lastSeenDate REAL NOT NULL,
            UNIQUE(driveKey, inode)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_files_name ON files(driveKey, fileName);")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_path ON files(driveKey, relativePath);")
    }

    // MARK: - Drives

    func upsertKnownDrive(_ drive: KnownDrive) throws {
        let stmt = try prepare("""
            INSERT INTO drives (driveKey, name, indexingState, lastIndexedDate, fileCount, totalBytes)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(driveKey) DO UPDATE SET
                name = excluded.name,
                indexingState = excluded.indexingState,
                lastIndexedDate = excluded.lastIndexedDate,
                fileCount = excluded.fileCount,
                totalBytes = excluded.totalBytes;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, drive.driveKey)
        bindText(stmt, 2, drive.name)
        bindText(stmt, 3, drive.indexingState.rawValue)
        bindDouble(stmt, 4, drive.lastIndexedDate?.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 5, Int64(drive.fileCount))
        sqlite3_bind_int64(stmt, 6, drive.totalBytes)
        try step(stmt)
    }

    func knownDrive(driveKey: String) throws -> KnownDrive? {
        let stmt = try prepare("SELECT driveKey, name, indexingState, lastIndexedDate, fileCount, totalBytes FROM drives WHERE driveKey = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, driveKey)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readKnownDrive(stmt)
    }

    func allKnownDrives() throws -> [KnownDrive] {
        let stmt = try prepare("SELECT driveKey, name, indexingState, lastIndexedDate, fileCount, totalBytes FROM drives ORDER BY name;")
        defer { sqlite3_finalize(stmt) }
        var results: [KnownDrive] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readKnownDrive(stmt))
        }
        return results
    }

    /// Removes a drive's index rows and its `drives` row. Never touches
    /// files on the physical drive — this only forgets Halo's own index.
    func forgetDrive(driveKey: String) throws {
        try withTransaction {
            let deleteFiles = try prepare("DELETE FROM files WHERE driveKey = ?;")
            defer { sqlite3_finalize(deleteFiles) }
            bindText(deleteFiles, 1, driveKey)
            try step(deleteFiles)

            let deleteDrive = try prepare("DELETE FROM drives WHERE driveKey = ?;")
            defer { sqlite3_finalize(deleteDrive) }
            bindText(deleteDrive, 1, driveKey)
            try step(deleteDrive)
        }
    }

    private func readKnownDrive(_ stmt: OpaquePointer?) -> KnownDrive {
        KnownDrive(
            driveKey: columnText(stmt, 0),
            name: columnText(stmt, 1),
            indexingState: DriveIndexingState(rawValue: columnText(stmt, 2)) ?? .notIndexed,
            lastIndexedDate: columnDouble(stmt, 3).map(Date.init(timeIntervalSince1970:)),
            fileCount: Int(sqlite3_column_int64(stmt, 4)),
            totalBytes: sqlite3_column_int64(stmt, 5)
        )
    }

    // MARK: - Reindex diff (Phase 3 — inode-aware new/moved/modified/removed)

    /// Reconciles a fresh walk against the stored rows for `driveKey`,
    /// matched by inode (not path) so renames/moves update in place without
    /// invalidating a previously computed hash. Everything commits in a
    /// single transaction.
    @discardableResult
    func applyDiff(driveKey: String, walked: [WalkedFileRow], now: Date = Date()) throws -> DriveDiffSummary {
        var summary = DriveDiffSummary()
        let nowTimestamp = now.timeIntervalSince1970

        try withTransaction {
            // Existing rows for this drive, keyed by inode.
            struct ExistingRow { let id: Int64; let relativePath: String; let size: Int64; let modifiedDate: Double? }
            var existingByInode: [UInt64: ExistingRow] = [:]
            let selectStmt = try prepare("SELECT id, inode, relativePath, size, modifiedDate FROM files WHERE driveKey = ?;")
            defer { sqlite3_finalize(selectStmt) }
            bindText(selectStmt, 1, driveKey)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let inode = UInt64(bitPattern: sqlite3_column_int64(selectStmt, 1))
                existingByInode[inode] = ExistingRow(
                    id: sqlite3_column_int64(selectStmt, 0),
                    relativePath: columnText(selectStmt, 2),
                    size: sqlite3_column_int64(selectStmt, 3),
                    modifiedDate: columnDouble(selectStmt, 4)
                )
            }

            var seenInodes = Set<UInt64>()

            let insertStmt = try prepare("""
                INSERT INTO files (driveKey, relativePath, fileName, size, createdDate, modifiedDate, inode, category, lastSeenDate)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(insertStmt) }

            let updatePathStmt = try prepare("UPDATE files SET relativePath = ?, fileName = ?, lastSeenDate = ? WHERE id = ?;")
            defer { sqlite3_finalize(updatePathStmt) }

            let updateModifiedStmt = try prepare("""
                UPDATE files SET size = ?, createdDate = ?, modifiedDate = ?, category = ?,
                    partialHash = NULL, fullHash = NULL, lastSeenDate = ? WHERE id = ?;
                """)
            defer { sqlite3_finalize(updateModifiedStmt) }

            let touchSeenStmt = try prepare("UPDATE files SET lastSeenDate = ? WHERE id = ?;")
            defer { sqlite3_finalize(touchSeenStmt) }

            for row in walked {
                seenInodes.insert(row.inode)

                guard let existing = existingByInode[row.inode] else {
                    // New inode → insert.
                    sqlite3_reset(insertStmt)
                    bindText(insertStmt, 1, driveKey)
                    bindText(insertStmt, 2, row.relativePath)
                    bindText(insertStmt, 3, row.fileName)
                    sqlite3_bind_int64(insertStmt, 4, row.size)
                    bindDouble(insertStmt, 5, row.createdDate?.timeIntervalSince1970)
                    bindDouble(insertStmt, 6, row.modifiedDate?.timeIntervalSince1970)
                    sqlite3_bind_int64(insertStmt, 7, Int64(bitPattern: row.inode))
                    bindText(insertStmt, 8, row.category.rawValue)
                    sqlite3_bind_double(insertStmt, 9, nowTimestamp)
                    try step(insertStmt)
                    summary.inserted += 1
                    continue
                }

                let modifiedChanged = existing.modifiedDate != row.modifiedDate?.timeIntervalSince1970
                let sizeChanged = existing.size != row.size

                if sizeChanged || modifiedChanged {
                    // Same inode, content changed → update metadata, invalidate hashes.
                    sqlite3_reset(updateModifiedStmt)
                    sqlite3_bind_int64(updateModifiedStmt, 1, row.size)
                    bindDouble(updateModifiedStmt, 2, row.createdDate?.timeIntervalSince1970)
                    bindDouble(updateModifiedStmt, 3, row.modifiedDate?.timeIntervalSince1970)
                    bindText(updateModifiedStmt, 4, row.category.rawValue)
                    sqlite3_bind_double(updateModifiedStmt, 5, nowTimestamp)
                    sqlite3_bind_int64(updateModifiedStmt, 6, existing.id)
                    try step(updateModifiedStmt)
                    summary.modified += 1
                } else if existing.relativePath != row.relativePath {
                    // Same inode, same content, different path → moved/renamed.
                    sqlite3_reset(updatePathStmt)
                    bindText(updatePathStmt, 1, row.relativePath)
                    bindText(updatePathStmt, 2, row.fileName)
                    sqlite3_bind_double(updatePathStmt, 3, nowTimestamp)
                    sqlite3_bind_int64(updatePathStmt, 4, existing.id)
                    try step(updatePathStmt)
                    summary.moved += 1
                } else {
                    sqlite3_reset(touchSeenStmt)
                    sqlite3_bind_double(touchSeenStmt, 1, nowTimestamp)
                    sqlite3_bind_int64(touchSeenStmt, 2, existing.id)
                    try step(touchSeenStmt)
                    summary.unchanged += 1
                }
            }

            // Anything stored but not seen in this walk is gone.
            let staleIDs = existingByInode.compactMap { inode, row in
                seenInodes.contains(inode) ? nil : row.id
            }
            if !staleIDs.isEmpty {
                let deleteStmt = try prepare("DELETE FROM files WHERE id = ?;")
                defer { sqlite3_finalize(deleteStmt) }
                for id in staleIDs {
                    sqlite3_reset(deleteStmt)
                    sqlite3_bind_int64(deleteStmt, 1, id)
                    try step(deleteStmt)
                }
                summary.removed = staleIDs.count
            }
        }

        return summary
    }

    // MARK: - Search

    func search(query: String, limit: Int = 100) throws -> [IndexedFileEntry] {
        let stmt = try prepare("""
            SELECT id, driveKey, relativePath, fileName, size, createdDate, modifiedDate, inode, category, partialHash, fullHash, lastSeenDate
            FROM files WHERE fileName LIKE ? ORDER BY fileName LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, "%\(query)%")
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var results: [IndexedFileEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileEntry(stmt))
        }
        return results
    }

    /// Sizes with two or more files at or above `minSize`, across all drives.
    func candidateDuplicateSizes(minSize: Int64) throws -> [Int64] {
        let stmt = try prepare("SELECT size FROM files WHERE size >= ? GROUP BY size HAVING COUNT(*) > 1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, minSize)
        var sizes: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            sizes.append(sqlite3_column_int64(stmt, 0))
        }
        return sizes
    }

    func filesOfSize(_ size: Int64) throws -> [IndexedFileEntry] {
        let stmt = try prepare("""
            SELECT id, driveKey, relativePath, fileName, size, createdDate, modifiedDate, inode, category, partialHash, fullHash, lastSeenDate
            FROM files WHERE size = ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, size)
        var results: [IndexedFileEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileEntry(stmt))
        }
        return results
    }

    func setHash(fileID: Int64, partialHash: String?, fullHash: String?) throws {
        let stmt = try prepare("UPDATE files SET partialHash = ?, fullHash = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, partialHash)
        bindText(stmt, 2, fullHash)
        sqlite3_bind_int64(stmt, 3, fileID)
        try step(stmt)
    }

    private func readFileEntry(_ stmt: OpaquePointer?) -> IndexedFileEntry {
        IndexedFileEntry(
            id: sqlite3_column_int64(stmt, 0),
            driveKey: columnText(stmt, 1),
            relativePath: columnText(stmt, 2),
            fileName: columnText(stmt, 3),
            size: sqlite3_column_int64(stmt, 4),
            createdDate: columnDouble(stmt, 5).map(Date.init(timeIntervalSince1970:)),
            modifiedDate: columnDouble(stmt, 6).map(Date.init(timeIntervalSince1970:)),
            inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 7)),
            category: IndexedFileCategory(rawValue: columnText(stmt, 8)) ?? .other,
            partialHash: columnTextOrNil(stmt, 9),
            fullHash: columnTextOrNil(stmt, 10),
            lastSeenDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        )
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw DriveIndexStoreError.sqlError(lastErrorMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DriveIndexStoreError.sqlError(lastErrorMessage())
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DriveIndexStoreError.sqlError(lastErrorMessage())
        }
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(stmt, index); return }
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        guard let value else { sqlite3_bind_null(stmt, index); return }
        sqlite3_bind_double(stmt, index, value)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func columnTextOrNil(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}
