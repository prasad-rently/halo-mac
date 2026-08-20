import Testing
import Foundation
@testable import Halo

// MARK: - IndexedFileCategory

@Suite("IndexedFileCategory")
struct IndexedFileCategoryTests {

    @Test("Categorizes by extension, case-insensitively")
    func testCategorization() {
        #expect(IndexedFileCategory.categorize(fileName: "report.PDF") == .documents)
        #expect(IndexedFileCategory.categorize(fileName: "vacation.mov") == .video)
        #expect(IndexedFileCategory.categorize(fileName: "track.mp3") == .audio)
        #expect(IndexedFileCategory.categorize(fileName: "photo.HEIC") == .images)
        #expect(IndexedFileCategory.categorize(fileName: "backup.zip") == .archives)
        #expect(IndexedFileCategory.categorize(fileName: "main.swift") == .code)
        #expect(IndexedFileCategory.categorize(fileName: "no_extension") == .other)
    }
}

// MARK: - DriveVolume identity

@Suite("DriveVolume.driveKey")
struct DriveVolumeIdentityTests {

    @Test("Prefers the volume UUID when available")
    func testUUIDPreferred() {
        let volume = DriveVolume(id: "/Volumes/Test", name: "Test", url: URL(fileURLWithPath: "/Volumes/Test"),
                                  isInternal: false, isRemovable: true,
                                  totalBytes: 100, freeBytes: 50, volumeUUID: "ABCD-1234")
        #expect(volume.driveKey == "ABCD-1234")
    }

    @Test("Falls back to name+capacity when no UUID (exFAT/FAT32)")
    func testFallbackIdentity() {
        let volume = DriveVolume(id: "/Volumes/NoUUID", name: "NoUUID", url: URL(fileURLWithPath: "/Volumes/NoUUID"),
                                  isInternal: false, isRemovable: true,
                                  totalBytes: 64_000_000_000, freeBytes: 1_000_000_000, volumeUUID: nil)
        #expect(volume.driveKey == "NoUUID|64000000000")
    }
}

// MARK: - DriveIndexStore.applyDiff (inode-aware reindex)

@Suite("DriveIndexStore reindex diff")
struct DriveIndexStoreDiffTests {

    /// A fresh, fully isolated store per test — never touches the real
    /// on-disk index (see `DriveIndexStore.init(directoryOverride:)`).
    private func makeStore() throws -> DriveIndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloTests-DriveIndex-\(UUID().uuidString)", isDirectory: true)
        return try DriveIndexStore(directoryOverride: dir)
    }

    @Test("A brand new inode is inserted")
    func testInsert() async throws {
        let store = try makeStore()
        let row = WalkedFileRow(relativePath: "/a.txt", fileName: "a.txt", size: 10,
                                 createdDate: nil, modifiedDate: Date(), inode: 1, category: .documents)
        let summary = try await store.applyDiff(driveKey: "d1", walked: [row])
        #expect(summary.inserted == 1)
        #expect(summary.moved == 0)
        #expect(summary.modified == 0)
        #expect(summary.removed == 0)

        let results = try await store.search(query: "a.txt")
        #expect(results.count == 1)
        #expect(results.first?.inode == 1)
    }

    @Test("Same inode, unchanged content and path — no-op")
    func testUnchanged() async throws {
        let store = try makeStore()
        let date = Date()
        let row = WalkedFileRow(relativePath: "/a.txt", fileName: "a.txt", size: 10,
                                 createdDate: nil, modifiedDate: date, inode: 1, category: .documents)
        _ = try await store.applyDiff(driveKey: "d1", walked: [row])
        let summary = try await store.applyDiff(driveKey: "d1", walked: [row])
        #expect(summary.unchanged == 1)
        #expect(summary.inserted == 0)
    }

    @Test("Same inode, new path — classified as moved, not delete+insert")
    func testMoveDetection() async throws {
        let store = try makeStore()
        let date = Date()
        let original = WalkedFileRow(relativePath: "/old/a.txt", fileName: "a.txt", size: 10,
                                      createdDate: nil, modifiedDate: date, inode: 1, category: .documents)
        _ = try await store.applyDiff(driveKey: "d1", walked: [original])

        let moved = WalkedFileRow(relativePath: "/new/a.txt", fileName: "a.txt", size: 10,
                                   createdDate: nil, modifiedDate: date, inode: 1, category: .documents)
        let summary = try await store.applyDiff(driveKey: "d1", walked: [moved])
        #expect(summary.moved == 1)
        #expect(summary.inserted == 0)
        #expect(summary.removed == 0)

        let results = try await store.search(query: "a.txt")
        #expect(results.count == 1)
        #expect(results.first?.relativePath == "/new/a.txt")
    }

    @Test("Same inode, changed size — modified, and cached hashes are invalidated")
    func testModifiedInvalidatesHash() async throws {
        let store = try makeStore()
        let date = Date()
        let original = WalkedFileRow(relativePath: "/a.txt", fileName: "a.txt", size: 10,
                                      createdDate: nil, modifiedDate: date, inode: 1, category: .documents)
        _ = try await store.applyDiff(driveKey: "d1", walked: [original])
        let firstRow = try await store.search(query: "a.txt").first
        try await store.setHash(fileID: firstRow!.id, partialHash: "abc", fullHash: "abcdef")

        let changed = WalkedFileRow(relativePath: "/a.txt", fileName: "a.txt", size: 999,
                                     createdDate: nil, modifiedDate: date.addingTimeInterval(60),
                                     inode: 1, category: .documents)
        let summary = try await store.applyDiff(driveKey: "d1", walked: [changed])
        #expect(summary.modified == 1)

        let updated = try await store.search(query: "a.txt").first
        #expect(updated?.size == 999)
        #expect(updated?.fullHash == nil)
        #expect(updated?.partialHash == nil)
    }

    @Test("A file missing from the walk is removed")
    func testRemoval() async throws {
        let store = try makeStore()
        let row = WalkedFileRow(relativePath: "/a.txt", fileName: "a.txt", size: 10,
                                 createdDate: nil, modifiedDate: Date(), inode: 1, category: .documents)
        _ = try await store.applyDiff(driveKey: "d1", walked: [row])

        let summary = try await store.applyDiff(driveKey: "d1", walked: [])
        #expect(summary.removed == 1)
        let results = try await store.search(query: "a.txt")
        #expect(results.isEmpty)
    }

    @Test("Duplicate-candidate sizes only surface at or above the threshold, across drives")
    func testCandidateDuplicateSizes() async throws {
        let store = try makeStore()
        let sharedSize: Int64 = 500
        let rowA = WalkedFileRow(relativePath: "/x.bin", fileName: "x.bin", size: sharedSize,
                                  createdDate: nil, modifiedDate: Date(), inode: 1, category: .other)
        let rowB = WalkedFileRow(relativePath: "/y.bin", fileName: "y.bin", size: sharedSize,
                                  createdDate: nil, modifiedDate: Date(), inode: 2, category: .other)
        let unique = WalkedFileRow(relativePath: "/z.bin", fileName: "z.bin", size: 1,
                                    createdDate: nil, modifiedDate: Date(), inode: 3, category: .other)
        _ = try await store.applyDiff(driveKey: "d1", walked: [rowA, unique])
        _ = try await store.applyDiff(driveKey: "d2", walked: [rowB])

        let candidates = try await store.candidateDuplicateSizes(minSize: 100)
        #expect(candidates == [sharedSize])

        let tooHigh = try await store.candidateDuplicateSizes(minSize: 1_000)
        #expect(tooHigh.isEmpty)

        let filesAtSize = try await store.filesOfSize(sharedSize)
        #expect(filesAtSize.count == 2)
        #expect(Set(filesAtSize.map(\.driveKey)) == ["d1", "d2"])
    }
}
