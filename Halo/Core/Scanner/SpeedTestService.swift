import Foundation
import Darwin

// MARK: - SpeedTestService  (P3-06)
//
// On-demand only — zero background footprint.
// Download: streams 25 MB from Cloudflare speed endpoint, measures live throughput.
// Upload:   POSTs 5 MB of zero bytes, measures throughput.
// Ping:     10 HEAD requests to 1.1.1.1, uses median RTT (eliminates outliers).

actor SpeedTestService {

    // MARK: - Public model

    struct SpeedResult: Sendable {
        let downloadMbps: Double
        let uploadMbps: Double
        let latencyMs: Double
        let testedAt: Date
    }

    enum SpeedTestProgress: Sendable {
        case pinging(attempt: Int, of: Int)
        case downloading(percent: Double, mbps: Double)
        case uploading(percent: Double, mbps: Double)
        case done(SpeedResult)
    }

    // MARK: - Run

    func runTest(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> SpeedResult {
        // 1. Warm-up — one throwaway request so TCP slow-start doesn't skew latency
        _ = try? await URLSession.shared.data(from: URL(string: "https://1.1.1.1")!)

        // 2. Ping (10 samples, median)
        let latency = await measureLatency(progress: progress)

        // 3. Download
        let download = try await measureDownload(progress: progress)
        try Task.checkCancellation()

        // 4. Upload
        let upload = try await measureUpload(progress: progress)

        let result = SpeedResult(downloadMbps: download,
                                 uploadMbps: upload,
                                 latencyMs: latency,
                                 testedAt: Date())
        progress(.done(result))
        return result
    }

    // MARK: - Latency
    // 10 pings, 150 ms apart — use median to dismiss outliers caused by
    // packet loss, scheduling jitter, or brief congestion.

    private func measureLatency(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async -> Double {
        let url = URL(string: "https://1.1.1.1")!
        let attempts = 10
        var rtts: [Double] = []

        for i in 0..<attempts {
            progress(.pinging(attempt: i + 1, of: attempts))
            if let rtt = await httpPing(url: url) { rtts.append(rtt) }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms gap
        }

        guard !rtts.isEmpty else { return 0 }
        // Median eliminates single-packet outliers
        let sorted = rtts.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private func httpPing(url: URL) async -> Double? {
        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 4)
        req.httpMethod = "HEAD"
        let start = Date()
        guard (try? await URLSession.shared.data(for: req)) != nil else { return nil }
        return Date().timeIntervalSince(start) * 1000
    }

    // MARK: - Download
    // 25 MB from Cloudflare; measures live Mbps in 64 KB chunks.
    // Avoids byte-by-byte iteration which saturates the CPU and
    // artificially limits the measured throughput on fast connections.

    private func measureDownload(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> Double {
        let url = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.setValue("Halo/2.0", forHTTPHeaderField: "User-Agent")

        let start = Date()
        var totalBytes: Int64 = 0
        let targetBytes: Int64 = 25_000_000

        let (asyncBytes, _) = try await URLSession.shared.bytes(for: request)

        // 64 KB chunk buffer — coarser granularity, far less CPU overhead
        var chunkBuffer = [UInt8]()
        chunkBuffer.reserveCapacity(65_536)

        for try await byte in asyncBytes {
            chunkBuffer.append(byte)
            totalBytes += 1
            try Task.checkCancellation()

            if chunkBuffer.count >= 65_536 {
                chunkBuffer.removeAll(keepingCapacity: true)
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > 0 {
                    let mbps = Double(totalBytes) * 8 / elapsed / 1_000_000
                    let pct  = Double(totalBytes) / Double(targetBytes)
                    progress(.downloading(percent: min(pct, 1.0), mbps: mbps))
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(totalBytes) * 8 / elapsed / 1_000_000
    }

    // MARK: - Upload
    // 5 MB POST to Cloudflare __up endpoint.
    // Measures wall-clock time for the complete upload so the result
    // isn't contaminated by TCP slow-start on tiny payloads.

    private func measureUpload(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> Double {
        let url = URL(string: "https://speed.cloudflare.com/__up")!
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Halo/2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let uploadSize = 5_000_000
        let payload = Data(count: uploadSize)

        progress(.uploading(percent: 0, mbps: 0))
        let start = Date()
        let (_, _) = try await URLSession.shared.upload(for: request, from: payload)
        let elapsed = Date().timeIntervalSince(start)

        progress(.uploading(percent: 1.0, mbps: 0))
        guard elapsed > 0 else { return 0 }
        return Double(uploadSize) * 8 / elapsed / 1_000_000
    }
}
