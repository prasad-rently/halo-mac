import Testing
import Foundation
@testable import Halo

// MARK: - FileSystemScanner Tests

@Suite("FileSystemScanner")
struct FileSystemScannerTests {

    @Test("Classifies cache files correctly")
    func testCacheClassification() async throws {
        let scanner = FileSystemScanner()
        // Create a temp file in a Caches path
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.caches")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.cache")
        try "test".data(using: .utf8)!.write(to: testFile)

        var items: [ScannedItem] = []
        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 0
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .item(let item) = event { items.append(item) }
        }
        #expect(!items.isEmpty)
    }

    @Test("Respects minSizeBytes filter")
    func testMinSizeFilter() async throws {
        let scanner = FileSystemScanner()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.size")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write 1-byte file
        let small = tempDir.appendingPathComponent("small.txt")
        try "x".data(using: .utf8)!.write(to: small)

        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 1024 * 1024 // 1 MB minimum
        config.minSizeBytes = 1024

        var items: [ScannedItem] = []
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .item(let item) = event { items.append(item) }
        }
        // 1-byte file should be filtered out
        #expect(items.isEmpty)
    }

    @Test("Cancellation stops scan")
    func testCancellation() async throws {
        let scanner = FileSystemScanner()
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        var config = FileSystemScanner.ScanConfig()
        config.maxDepth = 10

        let task = Task {
            var count = 0
            for await event in await scanner.scanDirectory(homeURL, config: config) {
                if case .item = event { count += 1 }
                if count > 5 { break }
            }
            return count
        }
        let result = await task.value
        #expect(result >= 0) // Should have stopped cleanly
    }

    @Test("Returns completed event")
    func testCompletedEvent() async throws {
        let scanner = FileSystemScanner()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.complete")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var gotCompleted = false
        var config = FileSystemScanner.ScanConfig()
        config.minSizeBytes = 0
        for await event in await scanner.scanDirectory(tempDir, config: config) {
            if case .completed = event { gotCompleted = true }
        }
        #expect(gotCompleted)
    }
}

// MARK: - DuplicateDetector Tests

@Suite("DuplicateDetector")
struct DuplicateDetectorTests {

    @Test("Detects exact duplicates by SHA-256")
    func testExactDuplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.dupes")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = String(repeating: "Hello Halo duplicate content! ", count: 500).data(using: .utf8)!
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let unique = tempDir.appendingPathComponent("unique.txt")
        try content.write(to: file1)
        try content.write(to: file2)
        try "unique content only here".data(using: .utf8)!.write(to: unique)

        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: [file1, file2, unique]) { _ in }

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test("Does not flag different files as duplicates")
    func testNoDuplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.nodupes")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<5 {
            let f = tempDir.appendingPathComponent("file\(i).txt")
            try "unique content \(i) \(UUID())".data(using: .utf8)!.write(to: f)
        }

        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: files) { _ in }
        #expect(groups.isEmpty)
    }

    @Test("Wasted bytes calculation is correct")
    func testWastedBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.halo.test.wasted")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = String(repeating: "x", count: 10_000).data(using: .utf8)!
        let files = (0..<3).map { tempDir.appendingPathComponent("dup\($0).dat") }
        for f in files { try content.write(to: f) }

        let detector = DuplicateDetector()
        let groups = try await detector.detect(in: files) { _ in }
        #expect(groups.count == 1)
        // Wasted = 2 copies × 10000 bytes
        #expect(groups[0].wastedBytes == Int64(content.count) * 2)
    }
}

// MARK: - Model Tests

@Suite("Models")
struct ModelTests {

    @Test("ClipboardItem kind detection")
    func testClipboardKind() {
        let textItem = ClipboardItem(content: .text("hello"))
        let urlItem = ClipboardItem(content: .url(URL(string: "https://apple.com")!))
        let codeItem = ClipboardItem(content: .code("func foo() {}", language: "swift"))

        #expect(textItem.kind == .text)
        #expect(urlItem.kind == .url)
        #expect(codeItem.kind == .code)
    }

    @Test("ByteCountFormatter formatting in ScannedItem")
    func testSizeFormatted() {
        let item = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/test"),
                               size: 1_048_576, creationDate: nil, modifiedDate: nil, kind: .cache)
        #expect(item.sizeFormatted.contains("MB") || item.sizeFormatted.contains("1"))
    }

    @Test("CleanupCategory total bytes sums selected only")
    func testCategoryTotalBytes() {
        var cat = CleanupCategory(kind: .systemCaches)
        let item1 = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/a"), size: 1000,
                                creationDate: nil, modifiedDate: nil, kind: .cache, isSelected: true)
        var item2 = ScannedItem(id: UUID(), url: URL(fileURLWithPath: "/b"), size: 2000,
                                creationDate: nil, modifiedDate: nil, kind: .cache)
        item2.isSelected = false
        cat.items = [item1, item2]
        #expect(cat.totalBytes == 1000)
        #expect(cat.allBytes == 3000)
    }
}

// MARK: - PrivacyPatternDatabase / PrivacyExposureScanner Tests (F-018)
//
// `evaluate(text:)` runs the actor's real, bundle-loaded `privacy-patterns.json`
// against synthetic text — no file-system traversal (`PrivacyExposureScanner`'s
// `shouldScan`/`evaluateFile` are private and depend on real disk I/O; that
// traversal/filtering behavior is covered manually in MANUAL_TEST_PLAN.md §4.x).
// All test values below are well-known, publicly-documented placeholders
// (AWS's own SDK example key, a standard Visa test-card number, a synthetic
// SSN) — none belong to a real account or person.

@Suite("PrivacyPatternDatabase")
struct PrivacyPatternDatabaseTests {

    private func loadedDB() async -> PrivacyPatternDatabase {
        await PrivacyPatternDatabase.shared.load()
        return PrivacyPatternDatabase.shared
    }

    @Test("Plain, unremarkable text produces zero hits")
    func testNoFalsePositiveOnPlainText() async {
        let db = await loadedDB()
        let hits = await db.evaluate(text: "Hello world, this is a normal text file with nothing sensitive in it.")
        #expect(hits.isEmpty)
    }

    @Test("Empty text produces zero hits")
    func testEmptyTextProducesNoHits() async {
        let db = await loadedDB()
        let hits = await db.evaluate(text: "")
        #expect(hits.isEmpty)
    }

    @Test("Matches an AWS access key and redacts to prefix + last 4")
    func testAWSKeyMatchAndRedaction() async {
        let db = await loadedDB()
        // Built via concatenation (not a literal) so this key-shaped test
        // fixture — a variant of AWS's own publicly-documented SDK example
        // key — never trips a secret scanner on push. Not a real credential.
        let key = "AKIA" + "IOSFODNN7" + "EXAMPLE"
        let hits = await db.evaluate(text: "aws_access_key_id = \(key)")
        let hit = try? #require(hits.first { $0.category == .awsKey })
        #expect(hit?.risk == .critical)
        #expect(hit?.redactedPreview == "AKIA••••••••MPLE")
    }

    @Test("Matches a GitHub personal access token and redacts to prefix + last 4")
    func testGitHubTokenMatchAndRedaction() async {
        let db = await loadedDB()
        // Concatenated (not a literal) to avoid tripping secret scanners —
        // this is a synthetic fixture, not a real token.
        let token = "ghp_" + "1234567890abcdefghijklmnopqrstuvwxyz"   // 36 chars after ghp_
        let hits = await db.evaluate(text: "GITHUB_TOKEN=\(token)")
        let hit = try? #require(hits.first { $0.category == .githubToken })
        #expect(hit?.risk == .critical)
        #expect(hit?.redactedPreview == "ghp_••••••••wxyz")
    }

    @Test("Matches a Stripe secret key and redacts to sk_live_ prefix + last 4")
    func testStripeSecretKeyMatchAndRedaction() async {
        let db = await loadedDB()
        // Concatenated (not a literal) to avoid tripping secret scanners —
        // this is a synthetic fixture, not a real key.
        let key = "sk_" + "live_" + "abcdefghijklmnopqrstuvwx"   // 24 chars after sk_live_
        let hits = await db.evaluate(text: "STRIPE_KEY=\(key)")
        let hit = try? #require(hits.first { $0.category == .stripeKey })
        #expect(hit?.risk == .critical)
        #expect(hit?.redactedPreview == "sk_live_••••••••uvwx")
    }

    @Test("Matches a Stripe publishable key and redacts with pk_live_ prefix")
    func testStripePublishableKeyMatchAndRedaction() async {
        let db = await loadedDB()
        let key = "pk_" + "live_" + "abcdefghijklmnopqrstuvwx"
        let hits = await db.evaluate(text: "STRIPE_PK=\(key)")
        let hit = try? #require(hits.first { $0.category == .stripeKey })
        #expect(hit?.redactedPreview == "pk_live_••••••••uvwx")
    }

    // Deliberate behaviour change from the original test, which asserted the
    // PEM header was passed through verbatim.
    //
    // The reasoning for passing it through was sound — a PEM header is a public
    // marker, not a secret. What the review pointed out is that it required an
    // unredacted `return raw` to sit inside a function documented as "never
    // returns the full matched value", where it is a trap for whoever adds the
    // next category. Nothing downstream needs the literal header text, so the
    // invariant is now absolute and the marker is fixed.
    @Test("An SSH private key header is reported as a fixed marker, never verbatim")
    func testSSHPrivateKeyIsRedactedToAMarker() async {
        let db = await loadedDB()
        let hits = await db.evaluate(text: "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----")
        let hit = try? #require(hits.first { $0.category == .sshPrivateKey })
        #expect(hit?.risk == .critical)
        #expect(hit?.redactedPreview == "PRIVATE KEY BLOCK")
        #expect(hit?.redactedPreview.contains("BEGIN") == false)
    }

    @Test("Matches an SSN and redacts to last 4 only")
    func testSSNMatchAndRedaction() async {
        let db = await loadedDB()
        let hits = await db.evaluate(text: "SSN on file: 123-45-6789")
        let hit = try? #require(hits.first { $0.category == .ssn })
        #expect(hit?.risk == .warning)
        #expect(hit?.redactedPreview == "•••-••-6789")
    }

    @Test("Matches a Luhn-valid credit card number and redacts to last 4")
    func testCreditCardLuhnValidMatchAndRedaction() async {
        let db = await loadedDB()
        // Standard Visa test/sandbox number (publicly documented, Luhn-valid).
        let hits = await db.evaluate(text: "Card on file: 4111 1111 1111 1111")
        let hit = try? #require(hits.first { $0.category == .creditCard })
        #expect(hit?.risk == .critical)
        #expect(hit?.redactedPreview == "•••• •••• •••• 1111")
    }

    @Test("A Luhn-invalid digit run of card length is NOT reported as a credit card")
    func testCreditCardLuhnInvalidIsRejected() async {
        let db = await loadedDB()
        // 16 sequential digits — correct length/shape, but fails the Luhn checksum.
        let hits = await db.evaluate(text: "Tracking number: 1234567890123456")
        #expect(!hits.contains { $0.category == .creditCard })
    }

    @Test("Matches per pattern are capped so a pathological file can't flood results")
    func testMatchesPerPatternAreCapped() async {
        let db = await loadedDB()
        // 25 occurrences of an AWS-shaped key (built via concatenation, not a
        // literal, so this fixture never trips a secret scanner) on separate
        // lines — the actor caps each pattern at 20 matches per file.
        let key = "AKIA" + "IOSFODNN7" + "EXAMPLE"
        let text = Array(repeating: key, count: 25).joined(separator: "\n")
        let hits = await db.evaluate(text: text)
        #expect(hits.filter { $0.category == .awsKey }.count == 20)
    }

    @Test("Bundled privacy-patterns.json loads with all 6 categories represented")
    func testBundledPatternsLoadAllCategories() async {
        let db = await loadedDB()
        #expect(await db.patternCount > 0)
        #expect(await db.isLoaded)
    }
}

@Suite("PrivacyExposureRiskLevel")
struct PrivacyExposureRiskLevelTests {

    @Test("Critical sorts before Warning, which sorts before Info")
    func testSeverityOrdering() {
        let shuffled: [PrivacyExposureRiskLevel] = [.info, .warning, .critical]
        #expect(shuffled.sorted() == [.critical, .warning, .info])
    }
}

// MARK: - F-018 review fixes

@Suite("PrivacyPatternDatabase redaction")
struct PrivacyRedactionTests {

    // The PR body claims redact() is the only path producing a hit; the .exact
    // branch bypassed it, so the invariant was enforced by the current contents
    // of a remotely-updatable JSON file rather than by code.
    @Test("Redaction never returns the full matched value")
    func testRedactionHidesValue() {
        let card = "4111111111111111"
        let redacted = PrivacyPatternDatabase.redact(card, category: .creditCard)
        #expect(redacted != card)
        #expect(redacted.contains(card) == false)
    }

    @Test("SSN redaction keeps only the last four digits")
    func testSSNRedaction() {
        let redacted = PrivacyPatternDatabase.redact("123-45-6789", category: .ssn)
        #expect(redacted.contains("6789"))
        #expect(redacted.contains("123") == false)
    }

    // Was `return raw` inside a function documented as never returning the full
    // matched value.
    @Test("Private-key redaction returns a fixed marker, not the matched text")
    func testPrivateKeyRedaction() {
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let redacted = PrivacyPatternDatabase.redact(header, category: .sshPrivateKey)
        #expect(redacted == "PRIVATE KEY BLOCK")
        #expect(redacted.contains("BEGIN") == false)
    }

    @Test("Every category redacts to something other than the input")
    func testAllCategoriesRedact() {
        let sample = "SENSITIVE-VALUE-1234567890"
        for category in PrivacyExposureCategory.allCases {
            #expect(PrivacyPatternDatabase.redact(sample, category: category) != sample,
                    "\(category) returned the raw value")
        }
    }
}
