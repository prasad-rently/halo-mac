import Foundation

// MARK: - Scan Coordinator
// Runs all cleanup scan tasks in parallel and aggregates results

/// Outcome of trashing a batch — per item, so callers can update their lists truthfully.
struct CleanupResult: Sendable {
    struct Failure: Sendable { let name: String; let message: String }
    /// Items that were moved to the Trash by this call.
    var removed: [URL] = []
    /// Items that were already gone before we got to them — also removed from the lists, but
    /// not counted as freed and never an error.
    var alreadyGone: [URL] = []
    var freed: Int64 = 0
    var failures: [Failure] = []

    /// Everything that should leave the on-screen lists.
    var gone: [URL] { removed + alreadyGone }
}

actor ScanCoordinator {

    private let scanner = FileSystemScanner()
    /// Where each category scans. Injectable so tests can point two categories at one temp folder.
    private let roots: @Sendable (CleanupKind) -> [String]
    private let trashDirectories: @Sendable () -> [URL]
    /// How one item is trashed. The default is `FileManager.trashItem` — the project's
    /// mandatory rule; tests substitute a closure that moves into a temp "trash".
    private let trash: @Sendable (URL) throws -> Void
    /// Awaited after a category has been read from disk and before it is returned. A no-op in
    /// production; tests use it to make one scan finish after a newer one (BUG-001 R8).
    private let afterScan: @Sendable (CleanupKind) async -> Void

    init(roots: @escaping @Sendable (CleanupKind) -> [String] = { $0.targetPaths },
         trashDirectories: @escaping @Sendable () -> [URL] = {
             FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
         },
         trash: @escaping @Sendable (URL) throws -> Void = { url in
             var resulting: NSURL?
             try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
         },
         afterScan: @escaping @Sendable (CleanupKind) async -> Void = { _ in }) {
        self.afterScan = afterScan
        self.roots = roots
        self.trashDirectories = trashDirectories
        self.trash = trash
    }

    // MARK: - Full Smart Scan

    func runFullScan() async -> SmartScanResult {
        await withTaskGroup(of: CleanupCategory?.self) { group in

            for kind in [CleanupKind.systemCaches, .logFiles, .trash, .xcodeData] {
                group.addTask {
                    await self.scanCategory(kind)
                }
            }

            var categories: [CleanupCategory] = []
            for await result in group {
                if let cat = result { categories.append(cat) }
            }

            return SmartScanResult(
                date: Date(),
                categoryResults: categories.sorted { $0.allBytes > $1.allBytes },
                threatsFound: 0,
                loginItemsFound: 3
            )
        }
    }

    // MARK: - Scan a Single Category

    func scanCategory(_ kind: CleanupKind) async -> CleanupCategory {
        let category = await readCategory(kind)
        await afterScan(kind)
        return category
    }

    private func readCategory(_ kind: CleanupKind) async -> CleanupCategory {
        var category = CleanupCategory(kind: kind)
        category.isScanning = true

        // Xcode DerivedData: enumerate build-project directories as single items
        if kind == .xcodeData {
            category.items = await scanDerivedDataDirectories()
            category.isScanning = false
            return category
        }

        // Trash: enumerate immediate top-level items (files & folders) in Trash
        if kind == .trash {
            category.items = await scanTrashItems()
            category.isScanning = false
            return category
        }

        var items: [ScannedItem] = []

        for pathString in roots(kind) {
            let url = URL(fileURLWithPath: pathString)
            guard FileManager.default.fileExists(atPath: pathString) else { continue }

            var config = FileSystemScanner.ScanConfig()
            config.maxDepth = 4
            config.minSizeBytes = 1024  // 1 KB minimum for file-level scan categories
            if let days = kind.ageThresholdDays {
                config.olderThanDays = days
            }

            for await event in await scanner.scanDirectory(url, config: config) {
                if case .item(let item) = event {
                    items.append(item)
                }
            }
        }

        category.items = items.sorted { $0.size > $1.size }
        category.isScanning = false
        return category
    }

    // MARK: - Trash: enumerate top-level items with real sizes

    private func scanTrashItems() async -> [ScannedItem] {
        var items: [ScannedItem] = []
        let fm = FileManager.default

        // Use the proper FileManager API — covers all mounted volumes' trash dirs
        let trashURLs = trashDirectories()

        for trashURL in trashURLs {
            guard fm.fileExists(atPath: trashURL.path) else { continue }

            let children = (try? fm.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey,
                                             .contentModificationDateKey, .creationDateKey],
                options: []   // include hidden files — Trash can contain .hidden items
            )) ?? []

            for child in children {
                let resVals = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey,
                    .contentModificationDateKey, .creationDateKey
                ])
                let isDir = resVals?.isDirectory ?? false

                // For directories in Trash, calculate their total recursive size
                let size: Int64 = isDir
                    ? await scanner.calculateSize(of: child)
                    : Int64(resVals?.fileSize ?? 0)

                let item = ScannedItem(
                    id: UUID(),
                    url: child,
                    size: size,
                    creationDate: resVals?.creationDate,
                    modifiedDate: resVals?.contentModificationDate,
                    kind: .other
                )
                items.append(item)
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Execute Cleanup

    /// Trashes the given items one by one and reports what actually happened to each.
    ///
    /// Before BUG-001 this went through `FileSystemScanner.deleteItems`, which swallows every
    /// error — so a failed trash was indistinguishable from a successful one, `error` was never
    /// set, and the caller then dropped every row. Now each outcome is explicit.
    func executeCleanup(items: [ScannedItem]) async -> CleanupResult {
        var result = CleanupResult()
        let trashKeys = trashDirectories().map(CleanupPath.key)
        for item in items {
            if Task.isCancelled { break }
            // `trashItem` on something already in the Trash "succeeds" without moving it, which
            // would be reported as moved, dropped from the list, and still occupy the disk.
            // Halo never deletes permanently, so say what the user has to do instead.
            let key = CleanupPath.key(item.url)
            if trashKeys.contains(where: { CleanupPath.isCovered(key, by: $0) }) {
                result.failures.append(.init(name: item.name,
                    message: "already in the Trash — empty the Trash in Finder to free the space"))
                continue
            }
            do {
                try trash(item.url)
                result.removed.append(item.url)
                result.freed += item.size
            } catch {
                let ns = error as NSError
                let alreadyGone = ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
                    || !CleanupPath.existsOnDisk(item.url)
                if alreadyGone {
                    result.alreadyGone.append(item.url)
                } else {
                    result.failures.append(.init(name: item.name, message: error.localizedDescription))
                }
            }
        }
        return result
    }

    // MARK: - DerivedData: enumerate project build folders as single deletable units

    /// Scans DerivedData and CoreSimulator/Caches by enumerating the immediate
    /// subdirectories (one per Xcode project build) and calculating each folder's
    /// total size. Trashing these directory-level items is what actually frees disk
    /// space — scanning individual files inside them only finds a tiny fraction of
    /// the total and leaves the directory skeleton behind.
    private func scanDerivedDataDirectories() async -> [ScannedItem] {
        let home = NSHomeDirectory()
        let roots = [
            URL(fileURLWithPath: "\(home)/Library/Developer/Xcode/DerivedData"),
            URL(fileURLWithPath: "\(home)/Library/Developer/CoreSimulator/Caches")
        ]
        let fm = FileManager.default
        var items: [ScannedItem] = []

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }

            let children = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // Process each project folder concurrently to calculate sizes fast
            await withTaskGroup(of: ScannedItem?.self) { group in
                for child in children {
                    group.addTask {
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: child.path, isDirectory: &isDir),
                              isDir.boolValue else { return nil }

                        let resVals = try? child.resourceValues(
                            forKeys: [.contentModificationDateKey, .creationDateKey]
                        )
                        let size = await self.scanner.calculateSize(of: child)
                        guard size > 0 else { return nil }   // skip empty placeholder dirs

                        return ScannedItem(
                            id: UUID(),
                            url: child,
                            size: size,
                            creationDate: resVals?.creationDate,
                            modifiedDate: resVals?.contentModificationDate,
                            kind: .derived
                        )
                    }
                }
                for await result in group {
                    if let item = result { items.append(item) }
                }
            }
        }
        return items.sorted { $0.size > $1.size }
    }
}
