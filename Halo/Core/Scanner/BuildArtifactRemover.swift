import Foundation

// MARK: - F-054 removal
//
// Two operations, and only two:
//   1. `moveToTrash`   — `FileManager.trashItem`, the project's mandatory rule. Recoverable.
//   2. `trashAndEmpty` — FR-U5b / D4b, owner-accepted, scoped by D-02. Calls `trashItem` first, then
//      permanently removes ONLY the URLs that `trashItem(at:resultingItemURL:)` returned in this
//      operation, each verified to sit inside a Trash directory and not be a symlink.
//
// Never enumerates a Trash, never calls any "empty trash" API, never rebuilds a Trash path from a
// name (the Trash renames on collision). The single `removeItem` in the whole feature is in
// `permanentlyRemoveTrashed(_:trashDirectories:)` below.
//
// INTENDED CLAUDE.md EDIT (not applied here — a later docs merge does it): "File deletion —
// mandatory rule" gains a second sanctioned exception beside Drive Speed's `unlink`: F-054's
// "Trash and empty", limited to URLs returned by this operation's own `trashItem` calls, for
// Safe + git-verified items only (D-02).

enum BuildArtifactRemover {

    typealias TrashFunction = @Sendable (URL) throws -> URL?

    struct Failure: Sendable, Equatable {
        let id: String
        let name: String
        let message: String
    }

    struct Outcome: Sendable, Equatable {
        /// Ids that left their original location (trashed, whether or not then emptied).
        var moved: [String] = []
        var movedBytes: Int64 = 0
        /// Ids permanently removed — a subset of `moved`.
        var permanentlyRemoved: [String] = []
        /// Moved to Trash but not removed from it (no resulting URL, failed verification, error).
        var leftInTrash: [Failure] = []
        /// Never moved.
        var failed: [Failure] = []
        /// Ineligible for the requested action (D-02) — nothing was done to them.
        var refused: [Failure] = []
    }

    /// The real `trashItem`.
    static let systemTrash: TrashFunction = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: Move to Trash (default action)

    static func moveToTrash(_ items: [BuildArtifactItem],
                            trash: TrashFunction = systemTrash,
                            home: String = NSHomeDirectory()) -> Outcome {
        var out = Outcome()
        for item in items {
            if let why = preflight(item, home: home) {
                out.failed.append(.init(id: item.id, name: item.artifactURL.lastPathComponent, message: why)); continue
            }
            do {
                _ = try trash(item.artifactURL)
                out.moved.append(item.id); out.movedBytes += item.size
            } catch {
                out.failed.append(.init(id: item.id, name: item.artifactURL.lastPathComponent,
                                        message: error.localizedDescription))
            }
        }
        return out
    }

    // MARK: Move to Trash and empty those items (FR-U5b, D-02)

    static func trashAndEmpty(_ items: [BuildArtifactItem],
                              trash: TrashFunction = systemTrash,
                              trashDirectories: [URL] = defaultTrashDirectories(),
                              home: String = NSHomeDirectory()) -> Outcome {
        var out = Outcome()
        for item in items {
            // D-02: Safe + git-verified only. Everything else is refused, untouched.
            guard item.permanentRemovalEligible else {
                out.refused.append(.init(id: item.id, name: item.artifactURL.lastPathComponent,
                                         message: "Only Safe, git-verified items can be removed permanently."))
                continue
            }
            if let why = preflight(item, home: home) {
                out.failed.append(.init(id: item.id, name: item.artifactURL.lastPathComponent, message: why)); continue
            }
            let resulting: URL?
            do { resulting = try trash(item.artifactURL) } catch {
                // trashItem failed: the item is still where it was — not removed, reported.
                out.failed.append(.init(id: item.id, name: item.artifactURL.lastPathComponent,
                                        message: error.localizedDescription))
                continue
            }
            out.moved.append(item.id); out.movedBytes += item.size
            guard let trashed = resulting else {
                out.leftInTrash.append(.init(id: item.id, name: item.artifactURL.lastPathComponent,
                                             message: "Moved to Trash, but the system did not report where — left there."))
                continue
            }
            if let why = permanentlyRemoveTrashed(trashed, trashDirectories: trashDirectories) {
                out.leftInTrash.append(.init(id: item.id, name: item.artifactURL.lastPathComponent, message: why))
            } else {
                out.permanentlyRemoved.append(item.id)
            }
        }
        return out
    }

    // MARK: Pieces

    /// `~/.Trash` and each volume's `.Trashes/<uid>`. Paths only — nothing inside them is read.
    static func defaultTrashDirectories() -> [URL] {
        var dirs = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
        let uid = getuid()
        for vol in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [] {
            dirs.append(vol.appendingPathComponent(".Trashes/\(uid)"))
        }
        return dirs
    }

    /// True when `url` lies strictly inside one of `trashDirectories`, after resolving symlinks in
    /// its PARENT chain, and `url` itself is not a symlink.
    static func isInsideTrash(_ url: URL, trashDirectories: [URL]) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let leaf = parent + "/" + url.lastPathComponent
        for t in trashDirectories {
            let root = t.resolvingSymlinksInPath().path
            if leaf.hasPrefix(root.hasSuffix("/") ? root : root + "/") && leaf != root {
                var st = stat()
                guard lstat(url.path, &st) == 0 else { return false }
                return (st.st_mode & S_IFMT) != S_IFLNK
            }
        }
        return false
    }

    /// THE ONLY `removeItem` IN F-054. Permanently deletes `trashed` — a URL returned by this
    /// operation's own `trashItem` call — after verifying it is inside a Trash directory and not a
    /// symlink. Returns nil on success, otherwise a reason (the item stays in the Trash).
    /// Do not widen: no enumeration of a Trash, no wildcard, no reconstructed path.
    private static func permanentlyRemoveTrashed(_ trashed: URL, trashDirectories: [URL]) -> String? {
        guard isInsideTrash(trashed, trashDirectories: trashDirectories) else {
            return "Moved to Trash, but its location could not be verified as inside the Trash — left there."
        }
        do {
            try FileManager.default.removeItem(at: trashed)   // sanctioned exception, see file header
            return nil
        } catch {
            return "Moved to Trash, but could not be removed from it: \(error.localizedDescription)"
        }
    }

    /// Re-checked immediately before acting: still a real directory (not swapped for a symlink),
    /// still not a forbidden path.
    private static func preflight(_ item: BuildArtifactItem, home: String) -> String? {
        let url = item.artifactURL
        if BuildArtifactSafety.isNeverTouch(url.path, home: home) { return "This folder is protected and is never removed." }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "Already gone." }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "It is now a symlink — refusing to touch it." }
        if (st.st_mode & S_IFMT) != S_IFDIR { return "It is no longer a folder — refusing to touch it." }
        return nil
    }
}
