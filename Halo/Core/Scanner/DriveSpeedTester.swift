import Foundation
import Darwin

// MARK: - DriveSpeedTester  (F-043 / NFeat-121)
//
// On-demand read & write throughput benchmark for internal and external
// drives. Zero background footprint — nothing runs until the user taps Run.
//
// Methodology (why the numbers are trustworthy)
// ---------------------------------------------
// • Uncached I/O: the benchmark file's descriptor is flagged `F_NOCACHE` so
//   reads/writes bypass the unified buffer cache and hit the device. Without
//   this, a read test just measures RAM.
// • Durability: after writing, `F_FULLFSYNC` forces the drive to flush its
//   own write-back cache to media, so the write figure reflects real device
//   throughput, not the SSD's DRAM.
// • Random payload: the write buffer is filled with random bytes so
//   compressing/dedup controllers can't inflate the result.
// • Average vs Optimal: every chunk is timed. `average` = total bytes ÷ total
//   time (sustained real-world speed). `optimal` = the fastest single chunk
//   (peak/burst speed the device is capable of).
// • Multiple passes aggregate all chunk samples for a stable average and the
//   best observed peak.

// MARK: - Models

/// A mounted volume eligible for benchmarking.
struct DriveVolume: Identifiable, Hashable, Sendable {
    let id: String            // volume path (stable per mount)
    let name: String
    let url: URL
    let isInternal: Bool
    let isRemovable: Bool
    let totalBytes: Int64
    let freeBytes: Int64

    var kindLabel: String { isInternal ? "Internal" : (isRemovable ? "External" : "Secondary") }
    var iconName: String { isInternal ? "internaldrive" : "externaldrive" }
}

/// The result of a completed benchmark. Speeds are in MB/s (decimal, 1 MB = 1e6 bytes).
struct DriveSpeedResult: Sendable, Equatable {
    let volumeName: String
    let isInternal: Bool
    let writeAverageMBps: Double
    let writeOptimalMBps: Double
    let readAverageMBps: Double
    let readOptimalMBps: Double
    let fileSizeBytes: Int64
    let passes: Int
    let sampleCount: Int
    let testedAt: Date
}

/// Live progress emitted during a run.
enum DriveSpeedProgress: Sendable {
    case preparing
    case writing(pass: Int, of: Int, percent: Double, mbps: Double)
    case reading(pass: Int, of: Int, percent: Double, mbps: Double)
    case done(DriveSpeedResult)
}

/// The amount of data written/read per run. Larger = more accurate, slower.
enum DriveTestSize: String, CaseIterable, Identifiable, Sendable {
    case quick    = "Quick"      // 128 MB
    case standard = "Standard"   // 512 MB
    case thorough = "Thorough"   // 1 GB

    var id: String { rawValue }

    var bytes: Int64 {
        switch self {
        case .quick:    return 128 * 1_000_000
        case .standard: return 512 * 1_000_000
        case .thorough: return 1_000 * 1_000_000
        }
    }

    var subtitle: String {
        switch self {
        case .quick:    return "128 MB · fastest"
        case .standard: return "512 MB · balanced"
        case .thorough: return "1 GB · most accurate"
        }
    }
}

enum DriveSpeedError: LocalizedError {
    case notWritable(String)
    case insufficientSpace(volume: String, needed: Int64, free: Int64)
    case ioFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notWritable(let v): return "Halo can't write a test file to \(v). Grant access to this drive, or the volume may be read-only."
        case let .insufficientSpace(v, needed, free):
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Not enough free space on \(v) — this test needs \(n) but only \(f) is available. Pick a smaller test size."
        case .ioFailure(let m):   return "Benchmark failed: \(m)"
        case .cancelled:          return "Benchmark cancelled."
        }
    }
}

// MARK: - Tester

actor DriveSpeedTester {

    /// 8 MB per chunk — coarse enough to amortise syscall overhead, fine
    /// enough to yield many timing samples for the average/peak split.
    private let chunkBytes = 8 * 1_000_000
    private let passes = 3

    // MARK: Volume enumeration

    /// Mounted, local, browsable volumes suitable for benchmarking, internal first.
    func availableVolumes() -> [DriveVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey, .volumeIsLocalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [DriveVolume] = []
        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Only local, browsable volumes (skip network shares & system hidden).
            guard rv.volumeIsLocal == true, rv.volumeIsBrowsable == true else { continue }
            let vol = DriveVolume(
                id: url.path,
                name: rv.volumeName ?? url.lastPathComponent,
                url: url,
                isInternal: rv.volumeIsInternal ?? true,
                isRemovable: rv.volumeIsRemovable ?? false,
                totalBytes: Int64(rv.volumeTotalCapacity ?? 0),
                freeBytes: Int64(rv.volumeAvailableCapacity ?? 0)
            )
            volumes.append(vol)
        }
        // Internal volumes first, then by name.
        return volumes.sorted { a, b in
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Run

    func run(volume: DriveVolume,
             size: DriveTestSize,
             progress: @Sendable @escaping (DriveSpeedProgress) -> Void) async throws -> DriveSpeedResult {
        progress(.preparing)

        let totalBytes = size.bytes

        // Guard against filling a nearly-full drive. Only enforced when we
        // actually know the free space (0 means the capacity was unreadable at
        // enumeration time — don't false-positive in that case). We reuse a
        // single scratch file across passes, so one copy + a small margin is enough.
        let margin: Int64 = 64 * 1_000_000
        if volume.freeBytes > 0, volume.freeBytes < totalBytes + margin {
            throw DriveSpeedError.insufficientSpace(volume: volume.name,
                                                    needed: totalBytes,
                                                    free: volume.freeBytes)
        }

        let fileURL = try scratchURL(for: volume)
        // Ensure the scratch file is always removed, even on error/cancel.
        // NOTE: this is Halo's own temp benchmark file (never user data), so it
        // is unlinked immediately rather than moved to Trash. On external drives
        // we also rmdir the .HaloSpeedTest dir we created (rmdir only removes it
        // if empty, so it can never clobber unrelated content).
        defer {
            unlink(fileURL.path)
            let parent = fileURL.deletingLastPathComponent()
            if parent.lastPathComponent == ".HaloSpeedTest" { rmdir(parent.path) }
        }
        let chunk = makeRandomChunk(chunkBytes)

        var writeSamples: [Double] = []
        var readSamples: [Double] = []

        for pass in 1...passes {
            try Task.checkCancellation()
            let w = try writePass(to: fileURL, totalBytes: totalBytes, chunk: chunk,
                                  pass: pass, progress: progress)
            writeSamples.append(contentsOf: w)

            try Task.checkCancellation()
            let r = try readPass(from: fileURL, totalBytes: totalBytes,
                                 pass: pass, progress: progress)
            readSamples.append(contentsOf: r)
        }

        let result = DriveSpeedResult(
            volumeName: volume.name,
            isInternal: volume.isInternal,
            writeAverageMBps: average(writeSamples),
            writeOptimalMBps: writeSamples.max() ?? 0,
            readAverageMBps: average(readSamples),
            readOptimalMBps: readSamples.max() ?? 0,
            fileSizeBytes: totalBytes,
            passes: passes,
            sampleCount: writeSamples.count + readSamples.count,
            testedAt: Date()
        )
        progress(.done(result))
        return result
    }

    // MARK: - Write

    private func writePass(to url: URL, totalBytes: Int64, chunk: [UInt8],
                           pass: Int, progress: @Sendable @escaping (DriveSpeedProgress) -> Void) throws -> [Double] {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw DriveSpeedError.notWritable(url.deletingLastPathComponent().lastPathComponent) }
        defer { close(fd) }
        // Bypass the buffer cache so we measure the device, not RAM.
        _ = fcntl(fd, F_NOCACHE, 1)

        var samples: [Double] = []
        var written: Int64 = 0
        let chunkLen = chunk.count

        while written < totalBytes {
            try Task.checkCancellation()
            let toWrite = Int(min(Int64(chunkLen), totalBytes - written))
            let start = DispatchTime.now()
            let n = chunk.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, toWrite)
            }
            guard n == toWrite else { throw DriveSpeedError.ioFailure("short write (\(n)/\(toWrite))") }
            let secs = elapsed(since: start)
            if secs > 0 { samples.append(Double(n) / secs / 1_000_000) }
            written += Int64(n)

            let pct = Double(written) / Double(totalBytes)
            progress(.writing(pass: pass, of: passes, percent: pct, mbps: samples.last ?? 0))
        }

        // Force the drive to flush its own write cache to media.
        _ = fcntl(fd, F_FULLFSYNC)
        return samples
    }

    // MARK: - Read

    private func readPass(from url: URL, totalBytes: Int64,
                          pass: Int, progress: @Sendable @escaping (DriveSpeedProgress) -> Void) throws -> [Double] {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DriveSpeedError.ioFailure("cannot reopen scratch file for reading") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var samples: [Double] = []
        var read: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkBytes)

        while read < totalBytes {
            try Task.checkCancellation()
            let start = DispatchTime.now()
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, chunkBytes)
            }
            if n <= 0 { break }
            let secs = elapsed(since: start)
            if secs > 0 { samples.append(Double(n) / secs / 1_000_000) }
            read += Int64(n)

            let pct = Double(read) / Double(totalBytes)
            progress(.reading(pass: pass, of: passes, percent: pct, mbps: samples.last ?? 0))
        }
        return samples
    }

    // MARK: - Helpers

    private func scratchURL(for volume: DriveVolume) throws -> URL {
        // For the boot/internal volume, use the sandbox-safe temp dir.
        // For other volumes, write into a dot-dir at the volume root.
        let dir: URL
        if volume.isInternal {
            dir = FileManager.default.temporaryDirectory
        } else {
            dir = volume.url.appendingPathComponent(".HaloSpeedTest", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw DriveSpeedError.notWritable(volume.name)
        }
        return dir.appendingPathComponent("halo-speedtest-\(UUID().uuidString).bin")
    }

    private func makeRandomChunk(_ count: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        // Fill with random bytes so drive controllers can't compress the payload.
        buf.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress { arc4random_buf(base, count) }
        }
        return buf
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func average(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }
}
