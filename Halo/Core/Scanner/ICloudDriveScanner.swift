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

    /// Root of the iCloud local sync mirror. `nil` if iCloud Drive has never
    /// been set up on this Mac (the folder itself won't exist).
    private var mobileDocumentsURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    // MARK: - Containers

    /// Every top-level ubiquity container under Mobile Documents, with the
    /// user-visible "iCloud Drive" folder (`com~apple~CloudDocs`) sorted first.
    func availableContainers() -> [ICloudContainer] {
        guard let root = mobileDocumentsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
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
        guard let root = mobileDocumentsURL else { return false }
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
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var items: [ICloudDriveItem] = []
        for entry in entries {
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = vals?.isDirectory ?? false
            let size = isDir ? Self.directorySize(entry) : Int64(vals?.fileSize ?? 0)
            let modified = vals?.contentModificationDate
            let status = Self.syncStatus(for: entry)
            items.append(ICloudDriveItem(
                id: entry.path, url: entry, name: entry.lastPathComponent,
                sizeBytes: size, isDirectory: isDir, modifiedDate: modified,
                syncStatus: status
            ))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Recursive byte size of a directory, capped so a huge tree can't hang
    /// the scan (identical bound/rationale as `SpaceLensViewModel`).
    private static func directorySize(_ url: URL, cap: Int = 20_000) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0, count = 0
        while let u = en.nextObject() as? URL {
            if let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               vals.isRegularFile == true, let s = vals.fileSize {
                total += Int64(s); count += 1
                if count >= cap { break }
            }
        }
        return total
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
            // Not a ubiquitous item resource (or the OS couldn't answer) —
            // for a locally-present file this means "no cloud pending state",
            // i.e. it's simply on this Mac.
            return .local
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
