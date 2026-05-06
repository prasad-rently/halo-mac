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

        var items: [ScannedItem] = []

        for pathString in kind.targetPaths {
            let url = URL(fileURLWithPath: pathString)
            guard FileManager.default.fileExists(atPath: pathString) else { continue }

            var config = FileSystemScanner.ScanConfig()
            config.maxDepth = kind == .xcodeData ? 3 : 4
            config.minSizeBytes = 1024 // ignore files under 1KB
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
}
