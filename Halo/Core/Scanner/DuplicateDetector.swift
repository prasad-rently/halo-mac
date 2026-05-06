import Foundation
import CryptoKit

// MARK: - Duplicate Detector Actor
// Three-phase detection: size grouping → partial hash → full hash

actor DuplicateDetector {

    // MARK: - Detection Pipeline

    func detect(in urls: [URL], onProgress: @escaping (Double) -> Void) async throws -> [DuplicateGroup] {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return [] }

        // Phase 1: Group by exact byte size (fast pre-filter, no I/O per file)
        onProgress(0.1)
        let sizeGroups = try groupBySize(files)
        let candidates = sizeGroups.filter { $0.value.count > 1 }.values

        // Phase 2: Partial hash (first 4 KB) to narrow candidates
        onProgress(0.35)
        var partialHashGroups: [[URL]] = []
        for group in candidates {
            try Task.checkCancellation()
            let subGroups = try await groupByPartialHash(Array(group))
            partialHashGroups.append(contentsOf: subGroups.filter { $0.count > 1 })
        }

        // Phase 3: Full SHA-256 hash to confirm exact duplicates
        onProgress(0.65)
        var confirmedGroups: [DuplicateGroup] = []
        let total = Double(partialHashGroups.count)
        for (i, group) in partialHashGroups.enumerated() {
            try Task.checkCancellation()
            let subGroups = try await groupByFullHash(group)
            for confirmed in subGroups where confirmed.count > 1 {
                let items = confirmed.map { url -> DuplicateItem in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    return DuplicateItem(url: url, sizeBytes: size, modifiedDate: modified)
                }
                // Auto-mark oldest copies for deletion (keep newest)
                var sortedItems = items.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
                for i in 1..<sortedItems.count { sortedItems[i].isMarkedForDeletion = true }
                confirmedGroups.append(DuplicateGroup(items: sortedItems))
            }
            onProgress(0.65 + 0.35 * (Double(i + 1) / max(total, 1)))
        }

        return confirmedGroups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    // MARK: - Phase 1: Size Grouping

    private func groupBySize(_ urls: [URL]) throws -> [Int64: [URL]] {
        var groups: [Int64: [URL]] = [:]
        for url in urls {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 4096 else { continue } // skip tiny files
            groups[size, default: []].append(url)
        }
        return groups
    }

    // MARK: - Phase 2: Partial Hash (first 4 KB)

    private func groupByPartialHash(_ urls: [URL]) async throws -> [[URL]] {
        var groups: [Data: [URL]] = [:]
        try await withThrowingTaskGroup(of: (URL, Data)?.self) { group in
            for url in urls {
                group.addTask {
                    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
                    defer { try? fh.close() }
                    guard let data = try fh.read(upToCount: 4096) else { return nil }
                    let hash = Data(SHA256.hash(data: data))
                    return (url, hash)
                }
            }
            for try await result in group {
                if let (url, hash) = result {
                    groups[hash, default: []].append(url)
                }
            }
        }
        return groups.values.filter { $0.count > 1 }.map(Array.init)
    }

    // MARK: - Phase 3: Full Hash

    private func groupByFullHash(_ urls: [URL]) async throws -> [[URL]] {
        var groups: [Data: [URL]] = [:]
        try await withThrowingTaskGroup(of: (URL, Data)?.self) { group in
            for url in urls {
                group.addTask {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    let hash = Data(SHA256.hash(data: data))
                    return (url, hash)
                }
            }
            for try await result in group {
                if let (url, hash) = result {
                    groups[hash, default: []].append(url)
                }
            }
        }
        return groups.values.filter { $0.count > 1 }.map(Array.init)
    }
}
