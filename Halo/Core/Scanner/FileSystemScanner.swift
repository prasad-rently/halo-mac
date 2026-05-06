import Foundation

// MARK: - File System Scanner Actor
// Concurrent directory traversal using TaskGroup
// Supports cancellation, progress streaming, and kind classification

actor FileSystemScanner {

    // MARK: - Scan Events

    enum ScanEvent: Sendable {
        case progress(scanned: Int, found: Int, currentPath: String)
        case item(ScannedItem)
        case completed(itemCount: Int, totalBytes: Int64)
        case error(String)
    }

    // MARK: - Configuration

    struct ScanConfig: Sendable {
        var maxDepth: Int = 5
        var maxConcurrency: Int = 8
        var excludePaths: Set<String> = []
        var fileKindFilter: Set<FileKind>? = nil
        var minSizeBytes: Int64 = 0
        var olderThanDays: Int? = nil
        var followSymlinks: Bool = false
    }

    // MARK: - Main Scan Entry Point

    func scanDirectory(
        _ rootURL: URL,
        config: ScanConfig = ScanConfig()
    ) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    var scanned = 0
                    var found = 0
                    var totalBytes: Int64 = 0

                    let items = try await self.traverse(
                        url: rootURL,
                        depth: 0,
                        config: config,
                        onProgress: { path in
                            scanned += 1
                            continuation.yield(.progress(
                                scanned: scanned,
                                found: found,
                                currentPath: path
                            ))
                        }
                    )

                    for item in items {
                        found += 1
                        totalBytes += item.size
                        continuation.yield(.item(item))
                    }

                    continuation.yield(.completed(itemCount: found, totalBytes: totalBytes))
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Recursive Traversal

    private func traverse(
        url: URL,
        depth: Int,
        config: ScanConfig,
        onProgress: @escaping (String) -> Void
    ) async throws -> [ScannedItem] {
        try Task.checkCancellation()

        guard depth <= config.maxDepth else { return [] }
        guard !config.excludePaths.contains(url.path) else { return [] }

        var results: [ScannedItem] = []
        let fm = FileManager.default

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey,
                                       .contentModificationDateKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var childURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            onProgress(fileURL.lastPathComponent)
            try Task.checkCancellation()

            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }

            let isDirectory = resourceValues.isDirectory ?? false
            let isSymlink = resourceValues.isSymbolicLink ?? false

            if isSymlink && !config.followSymlinks { continue }

            if !isDirectory {
                let sizeBytes = Int64(resourceValues.fileSize ?? 0)
                if sizeBytes < config.minSizeBytes { continue }

                let created = resourceValues.creationDate
                let modified = resourceValues.contentModificationDate

                // Age filter
                if let days = config.olderThanDays, let mod = modified {
                    let ageInDays = -mod.timeIntervalSinceNow / 86400
                    if ageInDays < Double(days) { continue }
                }

                let kind = classifyFile(fileURL)

                // Kind filter
                if let filter = config.fileKindFilter, !filter.contains(kind) { continue }

                let item = ScannedItem(
                    id: UUID(),
                    url: fileURL,
                    size: sizeBytes,
                    creationDate: created,
                    modifiedDate: modified,
                    kind: kind
                )
                results.append(item)
            } else {
                childURLs.append(fileURL)
                enumerator.skipDescendants()
            }
        }

        // Process child directories concurrently
        if !childURLs.isEmpty {
            let childResults = try await withThrowingTaskGroup(
                of: [ScannedItem].self,
                returning: [ScannedItem].self
            ) { group in
                var pending = 0
                for childURL in childURLs {
                    if pending >= config.maxConcurrency {
                        if let result = try await group.next() {
                            results.append(contentsOf: result)
                        }
                        pending -= 1
                    }
                    group.addTask {
                        try await self.traverse(
                            url: childURL,
                            depth: depth + 1,
                            config: config,
                            onProgress: onProgress
                        )
                    }
                    pending += 1
                }
                var allResults: [ScannedItem] = []
                for try await result in group {
                    allResults.append(contentsOf: result)
                }
                return allResults
            }
            results.append(contentsOf: childResults)
        }

        return results
    }

    // MARK: - File Classification

    private func classifyFile(_ url: URL) -> FileKind {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        // Cache patterns
        if path.contains("/Library/Caches") { return .cache }
        if path.contains("/var/folders") { return .cache }

        // Log patterns
        if ext == "log" || ext == "asl" || path.contains("/Library/Logs") { return .log }

        // Temp patterns
        if path.contains("/tmp") || path.contains("/Temp") { return .temp }
        if ext == "tmp" { return .temp }

        // Derived / Xcode
        if path.contains("DerivedData") { return .derived }
        if path.contains("CoreSimulator/Caches") { return .derived }

        // iOS Backups
        if path.contains("MobileSync/Backup") { return .iosBackup }

        // Language packs
        if ext == "lproj" { return .languagePack }

        // App Support
        if path.contains("/Library/Application Support") { return .appSupport }
        if path.contains("/Library/Containers") { return .appSupport }

        // Downloads heuristic
        if path.contains("/Downloads") { return .download }

        return .other
    }

    // MARK: - Safe Deletion

    func deleteItem(_ item: ScannedItem) throws {
        var resultURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultURL)
    }

    func deleteItems(_ items: [ScannedItem]) async throws -> (deleted: Int, freed: Int64) {
        var deletedCount = 0
        var freedBytes: Int64 = 0

        for item in items {
            try Task.checkCancellation()
            do {
                try deleteItem(item)
                deletedCount += 1
                freedBytes += item.size
            } catch {
                // Log but continue — best-effort deletion
                print("[Halo] Could not delete \(item.url.path): \(error)")
            }
        }
        return (deletedCount, freedBytes)
    }

    // MARK: - Quick Size Calculation

    func calculateSize(of url: URL) async -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }
}
