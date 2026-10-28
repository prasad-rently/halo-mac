import Foundation

// MARK: - Avatar storage accounting (F-053 / v2.6 C-3)
//
// Read-only helpers for the "how much space do my photos use, and where" readout. A separate
// file (extension) so `AvatarStore` itself stays untouched; deletion still goes through
// `AvatarStore.deleteAll(rosterID:)`, which owns the containment checks.

extension AvatarStore {

    /// Bytes of photo files in one roster's folder. A symlinked roster folder, and any symlink
    /// inside it, is not followed — a planted link must not make Halo report (or imply it owns)
    /// bytes that live elsewhere. Zero when the folder doesn't exist.
    func bytes(forRoster rosterID: UUID) -> Int64 {
        let dir = directory(for: rosterID)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        guard (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        else { return 0 }
        var sum: Int64 = 0
        for item in items {
            guard let v = try? item.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            sum += Int64(v.fileSize ?? 0)
        }
        return sum
    }
}

/// One roster's line in the storage readout.
struct AvatarRosterUsage: Equatable, Identifiable {
    let rosterID: UUID
    let name: String
    let bytes: Int64
    var id: UUID { rosterID }
}

/// Everything the readout shows.
struct AvatarStorageUsage: Equatable {
    /// Whole avatars folder (includes any stray files, so it can exceed the sum of `rosters`).
    var totalBytes: Int64
    /// Rosters that currently hold photo bytes, largest first.
    var rosters: [AvatarRosterUsage]

    static let empty = AvatarStorageUsage(totalBytes: 0, rosters: [])

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
