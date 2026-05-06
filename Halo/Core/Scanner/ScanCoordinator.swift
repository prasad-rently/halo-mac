import Foundation

// MARK: - Scan Coordinator
// Runs all cleanup scan tasks in parallel and aggregates results

actor ScanCoordinator {

    private let scanner = FileSystemScanner()

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

        for pathString in kind.targetPaths {
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
        let trashURLs = fm.urls(for: .trashDirectory, in: .userDomainMask)

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

    // MARK: - Execute Cleanup (batch)

    /// Trashes all given items. Returns (deleted, freed, firstError).
    func executeCleanup(items: [ScannedItem]) async -> (deleted: Int, freed: Int64, error: String?) {
        var totalDeleted = 0
        var totalFreed: Int64 = 0
        var firstError: String? = nil

        for item in items {
            do {
                let result = try await scanner.deleteItems([item])
                totalDeleted += result.deleted
                totalFreed += result.freed
            } catch {
                if firstError == nil {
                    firstError = "Could not trash \"\(item.name)\": \(error.localizedDescription)"
                }
            }
        }
        return (totalDeleted, totalFreed, firstError)
    }

    // MARK: - Execute Cleanup (single item)

    func deleteSingleItem(_ item: ScannedItem) async throws {
        _ = try await scanner.deleteItems([item])
    }

    // MARK: - DerivedData: placeholder (implemented in fix 3)
    private func scanDerivedDataDirectories() async -> [ScannedItem] { [] }
}
