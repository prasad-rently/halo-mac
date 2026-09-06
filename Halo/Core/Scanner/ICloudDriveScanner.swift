import Foundation

// MARK: - ICloudDriveScanner (F-030)
//
// Local analyzer for `~/Library/Mobile Documents/` — the real, on-disk mirror
// of iCloud Drive that any sandboxed or unsandboxed app can read via
// `FileManager` without special entitlements. This is deliberately NOT a
// full-account iCloud storage report: there is no public API that returns a
// third-party app's total iCloud quota/usage or a category breakdown
// (Drive/Photos/Backups/Mail/etc). See the F-030 section of
// docs/FEATURE_ROADMAP.md for the full feasibility writeup that led to this
// scope.
//
// Sync status per item comes from `URLResourceKey.ubiquitousItemDownloadingStatusKey`
// plus the `isUploading`/`isDownloading` flags — these are genuinely populated
// by the OS for any URL inside a ubiquity container, no entitlement required.

actor ICloudDriveScanner {

    /// Root of the iCloud local sync mirror.
    ///
    /// Non-optional: this only appends path components to
    /// `homeDirectoryForCurrentUser`, which always succeeds, so it could never
    /// be nil. The old doc comment described a nil case that did not exist and
    /// every `guard let root = mobileDocumentsURL` below was dead code.
    /// `isICloudDriveAvailable()` is where the real availability check lives.
    private var mobileDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    // MARK: - Containers

    /// Every top-level ubiquity container under Mobile Documents, with the
    /// user-visible "iCloud Drive" folder (`com~apple~CloudDocs`) sorted first.
    func availableContainers() -> [ICloudContainer] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: mobileDocumentsURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var containers: [ICloudContainer] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let name = entry.lastPathComponent
            containers.append(ICloudContainer(id: name, url: entry, isUserDrive: name == "com~apple~CloudDocs"))
        }
        return containers.sorted { a, b in
            if a.isUserDrive != b.isUserDrive { return a.isUserDrive }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Whether iCloud Drive's local folder exists at all on this Mac.
    func isICloudDriveAvailable() -> Bool {
        let root = mobileDocumentsURL
        let cloudDocs = root.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: cloudDocs.path)
    }

    // MARK: - Scan

    /// Top-level entries of a container, real sizes (directories summed,
    /// bounded — same approach as `SpaceLensViewModel.directorySize`), real
    /// modification dates, and real per-item sync status.
    func scanTopLevel(of container: ICloudContainer) async -> [ICloudDriveItem] {
        await scanDirectory(container.url)
    }

    /// Same as `scanTopLevel(of:)` but for an arbitrary folder inside a
    /// container — used to drill into subfolders (e.g. iCloud Drive/Projects).
    func scanDirectory(_ url: URL) async -> [ICloudDriveItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey],
            options: [])   // evicted placeholders are hidden files; see directorySize
        else { return [] }

        var items: [ICloudDriveItem] = []
        for entry in entries {
            // A container with 20 folders, each capped at 20,000 files, is up to
            // 400,000 stat calls in a single actor call. Without this, navigating
            // away or drilling in could not interrupt it and the next
            // scanDirectory queued behind it.
            if Task.isCancelled { return items.sorted { $0.sizeBytes > $1.sizeBytes } }

            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey])
            let isDir = vals?.isDirectory ?? false

            let localBytes: Int64
            let logicalBytes: Int64
            let truncated: Bool
            if isDir {
                let measured = Self.directorySize(entry)
                localBytes = measured.local
                logicalBytes = measured.logical
                truncated = measured.truncated
            } else {
                let onDisk = Int64(vals?.fileSize ?? 0)
                localBytes = onDisk
                logicalBytes = max(onDisk, Int64(vals?.totalFileSize ?? 0))
                truncated = false
            }

            items.append(ICloudDriveItem(
                id: entry.path, url: entry, name: entry.lastPathComponent,
                sizeBytes: logicalBytes, localBytes: localBytes, isTruncated: truncated,
                isDirectory: isDir, modifiedDate: vals?.contentModificationDate,
                syncStatus: Self.syncStatus(for: entry)
            ))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Recursive byte size of a directory, capped so a huge tree can't hang
    /// the scan (identical bound/rationale as `SpaceLensViewModel`).
    /// Recursive size of a directory, reported two ways.
    ///
    /// `.skipsHiddenFiles` used to be passed here, and that broke the feature's
    /// central purpose. When iCloud Drive evicts a file, its on-disk
    /// representation becomes a hidden placeholder named `.<name>.icloud` — a few
    /// hundred bytes, leading dot. Skipping hidden files skipped exactly those,
    /// so a folder whose contents had been evicted (the normal state under
    /// Optimise Mac Storage, and the single most useful thing an iCloud analyzer
    /// can report) measured ~0 and sorted to the bottom of a list ordered by
    /// size. A 40 GB Documents folder showed as a few megabytes.
    ///
    /// Conflating "bytes on this disk" with "bytes in iCloud" is what caused
    /// that, so the two are now reported separately:
    ///   - `local`   — what the file actually occupies on this Mac.
    ///   - `logical` — the full size, counting evicted files at their real size.
    ///
    /// `truncated` says whether the cap was reached, so a partial total is never
    /// rendered as an exact measurement.
    struct DirectorySize {
        var local: Int64 = 0
        var logical: Int64 = 0
        var truncated = false
    }

    static func directorySize(_ url: URL, cap: Int = 20_000) -> DirectorySize {
        let fm = FileManager.default
        var result = DirectorySize()
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileSizeKey, .isRegularFileKey],
            options: [])   // hidden files included: evicted placeholders are hidden
        else { return result }

        var count = 0
        while let u = en.nextObject() as? URL {
            guard let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { continue }

            let onDisk = Int64(vals.fileSize ?? 0)
            result.local += onDisk

            // For an evicted item the placeholder's `fileSize` is a few hundred
            // bytes while `totalFileSize` carries the real one. Falling back to
            // `onDisk` keeps ordinary files exact.
            result.logical += max(onDisk, Int64(vals.totalFileSize ?? 0))

            count += 1
            if count >= cap {
                result.truncated = true
                break
            }
        }
        return result
    }

    /// Real per-item iCloud sync status via the documented ubiquitous-item
    /// resource keys. No `NSMetadataQuery` run loop needed — these values are
    /// populated by the OS on every `resourceValues(forKeys:)` call for any
    /// URL under a ubiquity container.
    private static func syncStatus(for url: URL) -> ICloudSyncStatus {
        let keys: [URLResourceKey] = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey
        ]
        guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { return .unknown }

        if vals.ubiquitousItemIsUploading == true { return .uploading }
        if vals.ubiquitousItemIsDownloading == true { return .downloading }

        switch vals.ubiquitousItemDownloadingStatus {
        case .some(.current):
            return .local
        case .some(.downloaded):
            return .local
        case .some(.notDownloaded):
            return .evicted
        default:
            // The call succeeded but the OS gave no downloading status. That a
            // locally-present file with no pending cloud state is simply on this
            // Mac is a plausible *inference* — but this feature's whole framing
            // is that inferences are not presented as facts, and returning
            // `.local` rendered a confident "On This Mac" badge off the back of
            // one. `.unknown` is what we actually know, and the badge design
            // already accommodates it.
            return .unknown
        }
    }

    // MARK: - Destructive actions (mandatory: trashItem only, confirmed by caller)

    /// Moves an iCloud Drive item to the Trash. Trashing a file synced to
    /// iCloud Drive removes it from the cloud too — this is standard, expected
    /// Finder behavior, not something Halo needs to special-case.
    func trash(_ item: ICloudDriveItem) -> (success: Bool, errorMessage: String?) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
