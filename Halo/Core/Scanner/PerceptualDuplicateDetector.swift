import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Photos

// MARK: - Perceptual Duplicate Detector (F-025 · Duplicate Photos Finder)
//
// Unlike `DuplicateDetector` (bit-exact SHA-256 matching), this actor finds
// *visually* similar images — the same photo re-saved at a different
// compression level, cropped, or resized still "looks" the same but hashes
// completely differently under SHA-256.
//
// Algorithm (standard DCT-based pHash, mirrors the well-known pHash.org
// approach so results are comparable with other tools):
//   1. Decode a small thumbnail of the image via ImageIO (fast — hardware
//      accelerated, no need to materialize the full-resolution bitmap).
//   2. Render that thumbnail into a 32×32 8-bit grayscale bitmap.
//   3. Run a 2-D DCT-II over the 32×32 grid.
//   4. Keep the top-left 8×8 block of DCT coefficients (the lowest, most
//      perceptually significant frequencies — high frequencies encode fine
//      detail/noise that differs even between "the same" photo at two
//      compression levels).
//   5. Threshold each of the 64 coefficients against their median to produce
//      a 64-bit fingerprint (1 bit per coefficient).
//   6. Two images are "near-duplicates" when the Hamming distance between
//      their fingerprints is small (default: ≤ 8 of 64 bits differ).
//
// This mirrors `DuplicateDetector`'s actor + progress-callback structure so
// the two scanners feel like the same family of code.

actor PerceptualDuplicateDetector {

    /// Extensions eligible for perceptual hashing. Anything ImageIO can
    /// decode a thumbnail from is fair game; this list covers what actually
    /// shows up in `~/Pictures`, `~/Downloads`, and Desktop screenshots.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"
    ]

    // MARK: - Detection Pipeline

    /// Compute pHash for every image under `urls`, then cluster near-duplicates.
    /// - Parameter hammingThreshold: max bit difference (of 64) to count as a match.
    func detect(
        in urls: [URL],
        hammingThreshold: Int = 8,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [PhotoSimilarGroup] {
        let files = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { return [] }

        onProgress(0.05)

        // Phase 1: compute a hash + metadata for every image concurrently.
        var hashed: [PhotoHashResult] = []
        let total = Double(files.count)
        var completed = 0
        try await withThrowingTaskGroup(of: PhotoHashResult?.self) { group in
            for url in files {
                group.addTask {
                    try Task.checkCancellation()
                    return Self.computeHash(for: url)
                }
            }
            for try await result in group {
                completed += 1
                onProgress(0.05 + 0.65 * (Double(completed) / max(total, 1)))
                if let result { hashed.append(result) }
            }
        }

        try Task.checkCancellation()
        onProgress(0.75)

        // Phase 2: cluster by Hamming distance (union-find over all pairs).
        let clusters = Self.cluster(hashed, threshold: hammingThreshold)
        onProgress(0.9)

        // Phase 3: build groups + auto-select the recommended keep.
        var groups: [PhotoSimilarGroup] = []
        for cluster in clusters where cluster.count > 1 {
            groups.append(Self.makeGroup(from: cluster))
        }

        onProgress(1.0)
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    // MARK: - Hash Result (internal transport struct — cheap, Sendable)

    struct PhotoHashResult: Sendable {
        let url: URL
        let hash: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let sizeBytes: Int64
        let modifiedDate: Date?
    }

    // MARK: - Grouping

    nonisolated private static func makeGroup(from cluster: [PhotoHashResult]) -> PhotoSimilarGroup {
        var items: [PhotoHashItem] = cluster.map {
            PhotoHashItem(
                url: $0.url,
                sizeBytes: $0.sizeBytes,
                modifiedDate: $0.modifiedDate,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                hash: $0.hash
            )
        }
        // Recommended keep: highest resolution wins; ties broken by most recent.
        if let bestIndex = items.indices.max(by: { a, b in
            let pixelsA = items[a].megapixels
            let pixelsB = items[b].megapixels
            if pixelsA != pixelsB { return pixelsA < pixelsB }
            return (items[a].modifiedDate ?? .distantPast) < (items[b].modifiedDate ?? .distantPast)
        }) {
            for i in items.indices {
                items[i].isRecommendedKeep = (i == bestIndex)
                items[i].isMarkedForDeletion = (i != bestIndex)
            }
        }
        return PhotoSimilarGroup(items: items)
    }

    // MARK: - Hash computation (pure, no actor state touched — safe to call from task-group children)

    nonisolated private static func computeHash(for url: URL) -> PhotoHashResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Pixel dimensions come straight from metadata — no decode needed —
        // so this stays fast even for very large originals.
        var pixelWidth = 0
        var pixelHeight = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            pixelHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }

        // A small thumbnail is all the DCT step needs — ImageIO generates it
        // efficiently without decoding the full-resolution bitmap.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
              let grid = grayscale32x32(thumbnail) else { return nil }

        let hash = perceptualHash(from: grid)

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        return PhotoHashResult(
            url: url, hash: hash,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            sizeBytes: size, modifiedDate: modified
        )
    }

    /// Render `cgImage` into a 32×32 8-bit grayscale grid.
    nonisolated private static func grayscale32x32(_ cgImage: CGImage) -> [[Double]]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        guard let context = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var grid = [[Double]](repeating: [Double](repeating: 0, count: side), count: side)
        for y in 0..<side {
            for x in 0..<side {
                grid[y][x] = Double(pixels[y * side + x])
            }
        }
        return grid
    }

    /// 32×32 grayscale grid → 64-bit pHash (top-left 8×8 DCT coefficients,
    /// thresholded against their median).
    nonisolated private static func perceptualHash(from grid: [[Double]]) -> UInt64 {
        let dct = dct2D(grid)

        var lowFrequency: [Double] = []
        lowFrequency.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                lowFrequency.append(dct[y][x])
            }
        }

        // Exclude the DC term ([0][0], overall average brightness) when
        // computing the median — it's a huge outlier that would otherwise
        // skew every other bit toward "below median".
        let acCoefficients = Array(lowFrequency.dropFirst())
        let median = acCoefficients.sorted()[acCoefficients.count / 2]

        var hash: UInt64 = 0
        for (i, value) in lowFrequency.enumerated() {
            if value > median {
                hash |= (1 << UInt64(63 - i))
            }
        }
        return hash
    }

    /// Naive separable 2-D DCT-II. O(N^3) but N is fixed at 32, so this is a
    /// few thousand multiply-adds per image — negligible next to image decode.
    nonisolated private static func dct2D(_ input: [[Double]]) -> [[Double]] {
        let n = input.count
        var cosTable = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for x in 0..<n {
            for u in 0..<n {
                cosTable[x][u] = cos(Double.pi / Double(n) * (Double(x) + 0.5) * Double(u))
            }
        }

        // Pass 1: DCT along rows.
        var rowsTransformed = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for y in 0..<n {
            for u in 0..<n {
                var sum = 0.0
                for x in 0..<n { sum += input[y][x] * cosTable[x][u] }
                rowsTransformed[y][u] = sum
            }
        }

        // Pass 2: DCT along columns, with orthonormal scaling factors applied.
        var output = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for u in 0..<n {
            let cu = u == 0 ? 1.0 / 2.0.squareRoot() : 1.0
            for v in 0..<n {
                let cv = v == 0 ? 1.0 / 2.0.squareRoot() : 1.0
                var sum = 0.0
                for y in 0..<n { sum += rowsTransformed[y][u] * cosTable[y][v] }
                output[v][u] = 0.25 * cu * cv * sum
            }
        }
        return output
    }

    // MARK: - Clustering (union-find over Hamming distance)

    nonisolated static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    nonisolated private static func cluster(
        _ items: [PhotoHashResult], threshold: Int
    ) -> [[PhotoHashResult]] {
        clusterByHash(items, hash: { $0.hash }, threshold: threshold)
    }

    /// Generic union-find clustering by Hamming distance — shared by the
    /// loose-file path (`PhotoHashResult`) and the Photos Library path
    /// (`PhotoAssetHashResult`) below.
    nonisolated private static func clusterByHash<T>(
        _ items: [T], hash: (T) -> UInt64, threshold: Int
    ) -> [[T]] {
        guard !items.isEmpty else { return [] }
        var parent = Array(0..<items.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                if hammingDistance(hash(items[i]), hash(items[j])) <= threshold {
                    union(i, j)
                }
            }
        }
        var groups: [Int: [T]] = [:]
        for i in 0..<items.count {
            groups[find(i), default: []].append(items[i])
        }
        return Array(groups.values)
    }
}

// MARK: - Photos Library path (F-025 stretch goal)
//
// This half of the feature is real, idiomatic PhotoKit code — not a stub —
// but it has NOT been exercised at runtime this session: doing so requires
// launching the app and clicking through the system permission prompt, which
// is explicitly out of scope for this pass (see PR description). Everything
// needed for it to work is wired up: the `NSPhotoLibraryUsageDescription`
// Info.plist key and the `com.apple.security.personal-information.photos-library`
// entitlement (both entitlement files). Treat this as "needs a real
// permission-grant test pass," not "known broken."
extension PerceptualDuplicateDetector {

    enum PhotosLibraryError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Halo doesn't have permission to access your Photos Library yet."
            }
        }
    }

    /// Current PhotoKit authorization state for read/write access (read/write
    /// is required, not just read, because deleting near-duplicates needs
    /// `PHAssetChangeRequest.deleteAssets`).
    nonisolated static var photosLibraryAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Prompts the system permission dialog if not already determined.
    static func requestPhotosLibraryAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Perceptual-hash scan of the user's Photos Library, mirroring `detect(in:)`
    /// but sourcing images via `PHImageManager` instead of `FileManager`.
    func detectInPhotosLibrary(
        hammingThreshold: Int = 8,
        assetCap: Int = 3000,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [PhotoAssetSimilarGroup] {
        let status = Self.photosLibraryAuthorizationStatus
        guard status == .authorized || status == .limited else {
            throw PhotosLibraryError.notAuthorized
        }

        onProgress(0.02)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = assetCap
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return [] }

        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .fastFormat   // single callback — safe with a checked continuation
        requestOptions.isSynchronous = false
        requestOptions.isNetworkAccessAllowed = true // allow iCloud-only originals to download a preview

        var results: [PhotoAssetHashResult] = []
        let total = Double(assets.count)
        for (i, asset) in assets.enumerated() {
            try Task.checkCancellation()
            if let hash = await Self.requestHash(for: asset, imageManager: imageManager, options: requestOptions) {
                results.append(PhotoAssetHashResult(
                    localIdentifier: asset.localIdentifier, hash: hash,
                    pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                ))
            }
            onProgress(0.02 + 0.9 * (Double(i + 1) / total))
        }

        let clusters = Self.clusterByHash(results, hash: { $0.hash }, threshold: hammingThreshold)
        onProgress(1.0)
        return clusters.filter { $0.count > 1 }.map(Self.makeAssetGroup)
    }

    /// Moves the given assets to Photos' "Recently Deleted" — the PhotoKit
    /// equivalent of `trashItem` (recoverable, not a permanent delete).
    func deletePhotosLibraryAssets(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private struct PhotoAssetHashResult: Sendable {
        let localIdentifier: String
        let hash: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let creationDate: Date?
    }

    nonisolated private static func makeAssetGroup(from cluster: [PhotoAssetHashResult]) -> PhotoAssetSimilarGroup {
        var items: [PhotoAssetHashItem] = cluster.map {
            PhotoAssetHashItem(
                localIdentifier: $0.localIdentifier, hash: $0.hash,
                pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                creationDate: $0.creationDate
            )
        }
        if let bestIndex = items.indices.max(by: { a, b in
            let pixelsA = items[a].megapixels
            let pixelsB = items[b].megapixels
            if pixelsA != pixelsB { return pixelsA < pixelsB }
            return (items[a].creationDate ?? .distantPast) < (items[b].creationDate ?? .distantPast)
        }) {
            for i in items.indices {
                items[i].isRecommendedKeep = (i == bestIndex)
                items[i].isMarkedForDeletion = (i != bestIndex)
            }
        }
        return PhotoAssetSimilarGroup(items: items)
    }

    /// `.fastFormat` delivery calls its result handler exactly once, so a
    /// checked continuation is safe here (no double-resume risk).
    nonisolated private static func requestHash(
        for asset: PHAsset, imageManager: PHImageManager, options: PHImageRequestOptions
    ) async -> UInt64? {
        await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset, targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFit, options: options
            ) { image, _ in
                // NSImage (unlike UIImage) has no `.cgImage` property — it must be
                // rendered via `cgImage(forProposedRect:context:hints:)`.
                guard let image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let grid = grayscale32x32(cgImage) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: perceptualHash(from: grid))
            }
        }
    }
}
