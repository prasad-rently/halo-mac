import Foundation

// MARK: - SignatureDatabase (F-004)
//
// Loads malware keyword signatures from the bundled `signatures.json`.
// Also supports a lightweight HTTPS delta-update so the list stays fresh
// without a full app update.
//
// Usage:
//   await SignatureDatabase.shared.load()           // call once at app start
//   await SignatureDatabase.shared.checkForUpdate() // optional — fires in background
//   if let hit = await SignatureDatabase.shared.matches(keyword: "genieo") { … }

actor SignatureDatabase {

    // MARK: - Singleton
    static let shared = SignatureDatabase()

    // MARK: - Codable models (JSON wire format)

    private struct SignatureFile: Decodable {
        let version: Int
        let updated: String
        let signatures: [SignatureEntry]
    }

    private struct SignatureEntry: Decodable {
        let keyword: String
        let kind: String
        let risk: String
    }

    // MARK: - State

    /// Flat dictionary for O(1) keyword lookup: keyword → (kind, risk)
    private var table: [String: (kind: ThreatKind, risk: ThreatRisk)] = [:]
    private var loadedVersion: Int = 0
    private(set) var isLoaded = false

    // Remote endpoint for delta updates (responds with the same JSON schema)
    private let updateURL = URL(string: "https://api.halo.mac/signatures/latest.json")!

    // Cache path in the app's Caches directory
    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.halo.mac/signatures.json")
    }

    // MARK: - Init
    private init() {}

    // MARK: - Load

    /// Loads signatures. Priority: cached update > bundle.
    /// Always falls back to bundle so the app is never left with 0 signatures.
    func load() async {
        // 1. Try cached update first (newer version)
        if let cached = loadFromDisk(url: cacheURL) {
            applyFile(cached)
        }

        // 2. Always load bundle baseline (merge: bundle fills any gaps)
        if let bundled = loadFromBundle() {
            if bundled.version > loadedVersion {
                applyFile(bundled)          // cached was missing / older
            } else if table.isEmpty {
                applyFile(bundled)          // safety fallback
            }
        }

        isLoaded = true
    }

    // MARK: - Delta Update

    /// Fetches the latest signature list from the remote endpoint.
    /// Silently does nothing on network failure (the bundled list remains active).
    func checkForUpdate() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: updateURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let file = try JSONDecoder().decode(SignatureFile.self, from: data)

            guard file.version > loadedVersion else { return }   // nothing newer

            // Persist to cache so the update survives app restarts
            persistToDisk(data: data)
            applyFile(file)
        } catch {
            // Network unavailable / bad JSON — swallow and continue
        }
    }

    // MARK: - Query

    /// Returns threat metadata if `keyword` matches any loaded signature (case-insensitive substring).
    func matches(keyword: String) -> (kind: ThreatKind, risk: ThreatRisk)? {
        let lower = keyword.lowercased()
        for (sig, info) in table where lower.contains(sig) {
            return info
        }
        return nil
    }

    /// Returns all loaded signature keywords (useful for diagnostics/testing).
    var signatureCount: Int { table.count }

    // MARK: - Private helpers

    private func loadFromBundle() -> SignatureFile? {
        guard let url = Bundle.main.url(forResource: "signatures", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SignatureFile.self, from: data)
    }

    private func loadFromDisk(url: URL) -> SignatureFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SignatureFile.self, from: data)
    }

    private func persistToDisk(data: Data) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func applyFile(_ file: SignatureFile) {
        var newTable: [String: (kind: ThreatKind, risk: ThreatRisk)] = [:]
        for entry in file.signatures {
            guard let kind = ThreatKind(rawEntry: entry.kind),
                  let risk = ThreatRisk(rawEntry: entry.risk) else { continue }
            newTable[entry.keyword.lowercased()] = (kind, risk)
        }
        // Merge: new entries win; existing entries kept if not overwritten
        for (k, v) in newTable { table[k] = v }
        loadedVersion = max(loadedVersion, file.version)
    }
}

// MARK: - ThreatKind / ThreatRisk JSON parsing extensions

private extension ThreatKind {
    init?(rawEntry: String) {
        switch rawEntry.lowercased() {
        case "adware":    self = .adware
        case "pup":       self = .pup
        case "hijacker":  self = .hijacker
        case "keylogger": self = .keylogger
        case "ransomware":self = .ransomware
        default: return nil
        }
    }
}

private extension ThreatRisk {
    init?(rawEntry: String) {
        switch rawEntry.lowercased() {
        case "low":    self = .low
        case "medium": self = .medium
        case "high":   self = .high
        default: return nil
        }
    }
}
