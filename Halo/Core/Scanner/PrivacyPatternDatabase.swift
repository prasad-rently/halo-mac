import Foundation

// MARK: - PrivacyPatternDatabase (F-018)
//
// Loads sensitive-data detection patterns from the bundled `privacy-patterns.json`.
// Mirrors SignatureDatabase's bundle-first, cached-update-wins loading approach so
// the pattern list can be refreshed via a delta update without an app release —
// though unlike SignatureDatabase, `checkForUpdate()` here is never called during a
// scan (scans are 100% offline; an update check is a separate, explicit action).
//
// All pattern matching AND redaction happen inside this actor so the full matched
// secret value never has to leave it — callers only ever receive a `PrivacyPatternHit`
// carrying an already-redacted preview string.
//
// Usage:
//   await PrivacyPatternDatabase.shared.load()                    // bundle + cache
//   let hits = await PrivacyPatternDatabase.shared.evaluate(text: fileContents)

actor PrivacyPatternDatabase {

    // MARK: - Singleton
    static let shared = PrivacyPatternDatabase()

    // MARK: - Codable models (JSON wire format)

    private struct PatternFile: Decodable {
        let version: Int
        let updated: String
        let patterns: [PatternEntry]
    }

    private struct PatternEntry: Decodable {
        let id: String
        let category: String
        let matchType: String   // "exact" | "regex" | "luhnCandidate"
        let value: String
        let risk: String
        let label: String
    }

    // MARK: - Compiled representation

    private enum CompiledMatch {
        case exact(String)
        case regex(NSRegularExpression)
        /// Regex finds *candidate* digit runs; each candidate is Luhn-validated
        /// before being treated as a real credit-card-number match.
        case luhnCandidate(NSRegularExpression)
    }

    private struct CompiledPattern {
        let category: PrivacyExposureCategory
        let risk: PrivacyExposureRiskLevel
        let match: CompiledMatch
    }

    // MARK: - State

    private var table: [String: CompiledPattern] = [:]
    private var loadedVersion: Int = 0
    private(set) var updatedString: String = ""
    private(set) var isLoaded = false

    /// Remote endpoint for delta updates (responds with the same JSON schema). Never
    /// contacted during a scan — only via the explicit `checkForUpdate()` call.
    private let updateURL = URL(string: "https://api.halo.mac/privacy-patterns/latest.json")!

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.halo.mac/privacy-patterns.json")
    }

    private init() {}

    // MARK: - Load

    /// Loads patterns. Priority: cached update > bundle. Always falls back to the
    /// bundle so a scan is never left with zero patterns.
    func load() async {
        if let cached = loadFromDisk(url: cacheURL) {
            applyFile(cached)
        }
        if let bundled = loadFromBundle() {
            if bundled.version > loadedVersion {
                applyFile(bundled)
            } else if table.isEmpty {
                applyFile(bundled)
            }
        }
        isLoaded = true
    }

    // MARK: - Delta Update (never called mid-scan)

    func checkForUpdate() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: updateURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let file = try JSONDecoder().decode(PatternFile.self, from: data)
            guard file.version > loadedVersion else { return }
            persistToDisk(data: data)
            applyFile(file)
        } catch {
            // Network unavailable / bad JSON — swallow and continue with what's loaded.
        }
    }

    // MARK: - Query

    var patternCount: Int { table.count }

    /// Evaluates `text` (the full contents of one already-size/binary-filtered file)
    /// against every loaded pattern. Returns fully-redacted hits only — the raw
    /// matched substring never survives past this function's local scope.
    func evaluate(text: String) -> [PrivacyPatternHit] {
        guard !text.isEmpty else { return [] }
        var hits: [PrivacyPatternHit] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in table.values {
            // Cap matches per pattern per file so one pathological file (e.g. a huge
            // CSV of card-shaped numbers) can't blow up memory or flood the UI.
            var matchesForPattern = 0
            let maxMatchesPerPattern = 20

            switch pattern.match {
            case .exact(let needle):
                if text.contains(needle) {
                    hits.append(PrivacyPatternHit(category: pattern.category, risk: pattern.risk,
                                                   redactedPreview: needle))
                }

            case .regex(let regex):
                regex.enumerateMatches(in: text, range: fullRange) { match, _, stop in
                    guard matchesForPattern < maxMatchesPerPattern,
                          let match, let range = Range(match.range, in: text) else {
                        stop.pointee = true
                        return
                    }
                    let raw = String(text[range])
                    hits.append(PrivacyPatternHit(category: pattern.category, risk: pattern.risk,
                                                   redactedPreview: Self.redact(raw, category: pattern.category)))
                    matchesForPattern += 1
                }

            case .luhnCandidate(let regex):
                regex.enumerateMatches(in: text, range: fullRange) { match, _, stop in
                    guard matchesForPattern < maxMatchesPerPattern,
                          let match, let range = Range(match.range, in: text) else {
                        stop.pointee = true
                        return
                    }
                    let raw = String(text[range])
                    let digits = raw.filter(\.isNumber)
                    guard digits.count >= 13, digits.count <= 19, Self.isLuhnValid(digits) else { return }
                    hits.append(PrivacyPatternHit(category: pattern.category, risk: pattern.risk,
                                                   redactedPreview: Self.redact(digits, category: pattern.category)))
                    matchesForPattern += 1
                }
            }
        }
        return hits
    }

    // MARK: - Luhn validation
    //
    // A raw "16 digits in a row" regex has a huge false-positive rate against
    // order numbers, phone numbers, tracking IDs, etc. The Luhn checksum is the
    // same algorithm card networks use to catch mistyped numbers, so requiring it
    // to pass cuts false positives dramatically without needing brand-specific
    // prefix tables.
    private static func isLuhnValid(_ digits: String) -> Bool {
        let values = digits.reversed().compactMap { $0.wholeNumberValue }
        guard values.count == digits.count, !values.isEmpty else { return false }
        var sum = 0
        for (index, digit) in values.enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Redaction
    //
    // Never returns the full matched value. Only enough of it to help the user
    // recognize *which* secret this is (prefix and/or last 4 characters).
    private static func redact(_ raw: String, category: PrivacyExposureCategory) -> String {
        switch category {
        case .creditCard:
            let last4 = String(raw.suffix(4))
            return "•••• •••• •••• \(last4)"
        case .awsKey:
            let last4 = String(raw.suffix(4))
            return "AKIA••••••••\(last4)"
        case .githubToken:
            let prefix = String(raw.prefix(4))
            let last4 = String(raw.suffix(4))
            return "\(prefix)••••••••\(last4)"
        case .stripeKey:
            let prefix = raw.hasPrefix("pk_live_") ? "pk_live_" : "sk_live_"
            let last4 = String(raw.suffix(4))
            return "\(prefix)••••••••\(last4)"
        case .ssn:
            let last4 = String(raw.suffix(4))
            return "•••-••-\(last4)"
        case .sshPrivateKey:
            // The PEM header itself is a public marker, not a secret — the key
            // material that follows it is never read or matched against.
            return raw
        }
    }

    // MARK: - Private helpers

    private func loadFromBundle() -> PatternFile? {
        guard let url = Bundle.main.url(forResource: "privacy-patterns", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PatternFile.self, from: data)
    }

    private func loadFromDisk(url: URL) -> PatternFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PatternFile.self, from: data)
    }

    private func persistToDisk(data: Data) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func applyFile(_ file: PatternFile) {
        var newTable: [String: CompiledPattern] = [:]
        for entry in file.patterns {
            guard let category = PrivacyExposureCategory(rawEntry: entry.category),
                  let risk = PrivacyExposureRiskLevel(rawEntry: entry.risk),
                  let match = Self.compile(matchType: entry.matchType, value: entry.value) else { continue }
            newTable[entry.id] = CompiledPattern(category: category, risk: risk, match: match)
        }
        for (k, v) in newTable { table[k] = v }
        if file.version >= loadedVersion { updatedString = file.updated }
        loadedVersion = max(loadedVersion, file.version)
    }

    private static func compile(matchType: String, value: String) -> CompiledMatch? {
        switch matchType {
        case "exact":
            return .exact(value)
        case "regex":
            guard let regex = try? NSRegularExpression(pattern: value) else { return nil }
            return .regex(regex)
        case "luhnCandidate":
            guard let regex = try? NSRegularExpression(pattern: value) else { return nil }
            return .luhnCandidate(regex)
        default:
            return nil
        }
    }

    /// The `updated` field ("yyyy-MM-dd") from the active pattern file, parsed to a Date.
    var lastUpdatedDate: Date? {
        guard !updatedString.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: updatedString)
    }
}

/// A single redacted match returned by `PrivacyPatternDatabase.evaluate(text:)`.
/// Contains no raw secret data — safe to hold in `@Published` UI state.
struct PrivacyPatternHit: Sendable {
    let category: PrivacyExposureCategory
    let risk: PrivacyExposureRiskLevel
    let redactedPreview: String
}

// MARK: - JSON string → enum parsing

private extension PrivacyExposureCategory {
    init?(rawEntry: String) {
        switch rawEntry {
        case "creditCard":     self = .creditCard
        case "awsKey":         self = .awsKey
        case "githubToken":    self = .githubToken
        case "stripeKey":      self = .stripeKey
        case "sshPrivateKey":  self = .sshPrivateKey
        case "ssn":            self = .ssn
        default: return nil
        }
    }
}

private extension PrivacyExposureRiskLevel {
    init?(rawEntry: String) {
        switch rawEntry.lowercased() {
        case "critical": self = .critical
        case "warning":  self = .warning
        case "info":     self = .info
        default: return nil
        }
    }
}
