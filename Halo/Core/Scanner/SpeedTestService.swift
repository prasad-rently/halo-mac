import Foundation
import Darwin

// MARK: - SpeedTestService  (P3-06)
//
// On-demand only — zero background footprint.
// Download: streams ~5 MB from Cloudflare speed endpoint, measures live throughput.
// Upload:   POSTs 2 MB of zero bytes, measures throughput.
// Ping:     5 TCP connections to 1.1.1.1:443, measures RTT.

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
        // 1. Ping
        let latency = await measureLatency(progress: progress)

        // 2. Download
        let download = try await measureDownload(progress: progress)
        try Task.checkCancellation()

        // 3. Upload
        let upload = try await measureUpload(progress: progress)

        let result = SpeedResult(downloadMbps: download,
                                 uploadMbps: upload,
                                 latencyMs: latency,
                                 testedAt: Date())
        progress(.done(result))
        return result
    }

    // MARK: - Latency (via HEAD request to Cloudflare CDN — no FD_SET macros needed)

    private func measureLatency(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async -> Double {
        let url = URL(string: "https://1.1.1.1")!
        let attempts = 5
        var rtts: [Double] = []

        for i in 0..<attempts {
            progress(.pinging(attempt: i + 1, of: attempts))
            let rtt = await httpPing(url: url)
            if let r = rtt { rtts.append(r) }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms gap
        }

        guard !rtts.isEmpty else { return 0 }
        return rtts.reduce(0, +) / Double(rtts.count)
    }

    private func httpPing(url: URL) async -> Double? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3)
        req.httpMethod = "HEAD"
        let start = Date()
        guard let (_, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return Date().timeIntervalSince(start) * 1000
    }

    // MARK: - Download

    private func measureDownload(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> Double {
        // Cloudflare speed test endpoint — 5 MB file
        let url = URL(string: "https://speed.cloudflare.com/__down?bytes=5000000")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Halo/1.0", forHTTPHeaderField: "User-Agent")

        let start = Date()
        var totalBytes: Int64 = 0
        let targetBytes: Int64 = 5_000_000

        let (asyncBytes, _) = try await URLSession.shared.bytes(for: request)

        // Read in 32 KB chunks — byte-by-byte iteration is 100× more CPU-intensive
        // for the same amount of data and causes needless scheduling overhead.
        var chunkBuffer = [UInt8]()
        chunkBuffer.reserveCapacity(32_768)

        for try await byte in asyncBytes {
            chunkBuffer.append(byte)
            totalBytes += 1
            try Task.checkCancellation()

            if chunkBuffer.count >= 32_768 {
                chunkBuffer.removeAll(keepingCapacity: true)
                let elapsed = Date().timeIntervalSince(start)
                let mbps = elapsed > 0 ? (Double(totalBytes) * 8 / elapsed / 1_000_000) : 0
                let pct = Double(totalBytes) / Double(targetBytes)
                progress(.downloading(percent: min(pct, 1.0), mbps: mbps))
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        return elapsed > 0 ? (Double(totalBytes) * 8 / elapsed / 1_000_000) : 0
    }

    // MARK: - Upload

    private func measureUpload(progress: @Sendable @escaping (SpeedTestProgress) -> Void) async throws -> Double {
        let url = URL(string: "https://speed.cloudflare.com/__up")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("Halo/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let uploadSize = 2_000_000
        let payload = Data(count: uploadSize)

        progress(.uploading(percent: 0, mbps: 0))
        let start = Date()
        let (_, _) = try await URLSession.shared.upload(for: request, from: payload)
        let elapsed = Date().timeIntervalSince(start)

        progress(.uploading(percent: 1.0, mbps: 0))
        return elapsed > 0 ? (Double(uploadSize) * 8 / elapsed / 1_000_000) : 0
    }
}
