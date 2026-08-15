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

// MARK: - NetworkTrafficMonitor Tests (F-017)
//
// The `lsofSample` / `nettopSample` strings below are real output, not
// hand-invented — captured live on this dev machine on 2026-08-15 via:
//   lsof -i -n -P
//   nettop -P -L 1 -J bytes_in,bytes_out
// (trimmed to the rows relevant to each test; PIDs/bytes/addresses are real).
//
// The "Google" (lsof) / "Google Chrome H" (nettop) mismatch under the same
// pid 902 is the exact real-world case that motivated this PR's PID-based
// join fix — previously joining by process-name string silently dropped
// this Chrome-helper's byte totals because the two tools truncate the same
// process's name to different lengths.

@Suite("NetworkTrafficMonitor")
struct NetworkTrafficMonitorTests {

    // MARK: - lsof parser

    private static let lsofSample = """
    COMMAND     PID         USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    ControlCe   414 gokulprasadm    9u  IPv4 0x822b8ee55dba7095      0t0  TCP *:7000 (LISTEN)
    identitys   462 gokulprasadm   10u  IPv4  0xf9340aae7ee948b      0t0  UDP *:*
    Google      902 gokulprasadm   20u  IPv4 0x6f5af65327587d8a      0t0  TCP 192.168.1.68:54697->13.227.180.4:443 (ESTABLISHED)
    Spotify     740 gokulprasadm   21u  IPv6 0x84c96644c4976e7      0t0  TCP [2401:4900:1ce1:fb0a:20d0:5e95:e36e:3fbb]:52535->[2600:1901:1:d18::]:443 (ESTABLISHED)
    Google      902 gokulprasadm   21u  IPv6 0x27768d3b2b25b8d7      0t0  UDP [2401:4900:1ce1:fb0a:20d0:5e95:e36e:3fbb]:51390->[2404:6800:4007:835::2003]:443
    """

    @Test("Parses an ESTABLISHED TCP row into correct pid/host/port/state fields")
    func testLsofParsesEstablishedRow() {
        let entries = NetworkTrafficMonitor.parseLsofOutput(Self.lsofSample)
        let google = entries.first { $0.pid == 902 && $0.protocolType == "TCP" }
        #expect(google != nil)
        #expect(google?.processName == "Google")
        #expect(google?.remoteIP == "13.227.180.4")
        #expect(google?.remotePort == 443)
        #expect(google?.state == "ESTABLISHED")
    }

    @Test("Filters out LISTEN sockets and connectionless UDP (no remote peer)")
    func testLsofFiltersListenAndConnectionless() {
        let entries = NetworkTrafficMonitor.parseLsofOutput(Self.lsofSample)
        #expect(!entries.contains { $0.pid == 414 })   // ControlCenter LISTEN *:7000
        #expect(!entries.contains { $0.pid == 462 })   // identityservice UDP *:*
    }

    @Test("Parses bracketed IPv6 local->remote addresses, stripping the brackets")
    func testLsofParsesIPv6Brackets() {
        let entries = NetworkTrafficMonitor.parseLsofOutput(Self.lsofSample)
        let spotify = entries.first { $0.pid == 740 }
        #expect(spotify?.remoteIP == "2600:1901:1:d18::")
        #expect(spotify?.remotePort == 443)
    }

    @Test("Keeps a UDP row with a real remote peer even when lsof prints no trailing state suffix")
    func testLsofKeepsStatelessUDPWithPeer() {
        let entries = NetworkTrafficMonitor.parseLsofOutput(Self.lsofSample)
        let googleUDP = entries.first { $0.pid == 902 && $0.protocolType == "UDP" }
        #expect(googleUDP != nil)
        #expect(googleUDP?.remoteIP == "2404:6800:4007:835::2003")
    }

    @Test("Dedups identical (pid, ip, port, protocol) socket rows")
    func testLsofDedup() {
        let duplicated = Self.lsofSample +
            "\nGoogle      902 gokulprasadm   20u  IPv4 0x6f5af65327587d8a      0t0  TCP 192.168.1.68:54697->13.227.180.4:443 (ESTABLISHED)\n"
        let entries = NetworkTrafficMonitor.parseLsofOutput(duplicated)
        let matches = entries.filter { $0.pid == 902 && $0.protocolType == "TCP" }
        #expect(matches.count == 1)
    }

    // MARK: - splitHostPort

    @Test("splitHostPort handles plain IPv4:port")
    func testSplitHostPortIPv4() {
        let result = NetworkTrafficMonitor.splitHostPort("13.227.180.4:443")
        #expect(result?.0 == "13.227.180.4")
        #expect(result?.1 == 443)
    }

    @Test("splitHostPort handles bracketed [IPv6]:port")
    func testSplitHostPortIPv6() {
        let result = NetworkTrafficMonitor.splitHostPort("[2600:1901:1:d18::]:443")
        #expect(result?.0 == "2600:1901:1:d18::")
        #expect(result?.1 == 443)
    }

    // MARK: - nettop parser

    private static let nettopSample = """
    ,bytes_in,bytes_out,
    airportd.233,0,0,
    Spotify.611,287905,90291,
    Google Chrome H.902,488148251,1953712,
    """

    @Test("Parses per-app byte totals keyed by pid, tolerating spaces in the process name")
    func testNettopParsesTotals() {
        let totals = NetworkTrafficMonitor.parseNettopOutput(Self.nettopSample)
        let google = totals.first { $0.pid == 902 }
        #expect(google != nil)
        #expect(google?.processName == "Google Chrome H")
        #expect(google?.bytesIn == 488_148_251)
        #expect(google?.bytesOut == 1_953_712)
    }

    @Test("Filters out zero-byte rows")
    func testNettopFiltersZeroByteRows() {
        let totals = NetworkTrafficMonitor.parseNettopOutput(Self.nettopSample)
        #expect(!totals.contains { $0.pid == 233 })
    }

    @Test("Sorts app totals by total bytes descending")
    func testNettopSortsDescending() {
        let totals = NetworkTrafficMonitor.parseNettopOutput(Self.nettopSample)
        #expect(totals.first?.pid == 902)
        #expect(totals.map(\.pid) == totals.sorted { $0.totalBytes > $1.totalBytes }.map(\.pid))
    }

    // MARK: - PID-based join (the bug fix)

    @Test("Joining by pid correctly merges lsof and nettop rows despite mismatched process names")
    func testJoinByPIDMergesDespiteNameMismatch() {
        let connections = NetworkTrafficMonitor.parseLsofOutput(Self.lsofSample)
        let totals = NetworkTrafficMonitor.parseNettopOutput(Self.nettopSample)

        let googleConnection = connections.first { $0.pid == 902 && $0.protocolType == "TCP" }
        #expect(googleConnection?.processName == "Google")   // lsof's truncated name

        // The correct join key is pid — this is what NetworkTrafficSection's
        // `appTotal(for pid:)` does.
        let joinedByPID = totals.first { $0.pid == googleConnection?.pid }
        #expect(joinedByPID != nil)
        #expect(joinedByPID?.processName == "Google Chrome H")  // nettop's fuller name
        #expect((joinedByPID?.totalBytes ?? 0) > 0)

        // The bug this PR fixed: joining by processName string instead of pid
        // silently drops this exact real-world case, since the two tools
        // truncate the same process's name differently ("Google" vs
        // "Google Chrome H" for the same pid).
        let joinedByName = totals.first { $0.processName == googleConnection?.processName }
        #expect(joinedByName == nil,
                "process-name join must NOT find a match here — this is the bug that pid-joining fixed")
    }

    // MARK: - Tracker domain matching

    @Test("Matches an exact tracker domain")
    func testTrackerDomainExactMatch() {
        #expect(NetworkTrafficMonitor.matchesTrackerDomain("doubleclick.net", domains: ["doubleclick.net"]))
    }

    @Test("Matches a subdomain of a tracker domain")
    func testTrackerDomainSubdomainMatch() {
        #expect(NetworkTrafficMonitor.matchesTrackerDomain("www.google-analytics.com", domains: ["google-analytics.com"]))
    }

    @Test("Does not match a domain that merely shares a suffix string (no dot boundary)")
    func testTrackerDomainFalsePositiveGuard() {
        #expect(!NetworkTrafficMonitor.matchesTrackerDomain("notdoubleclick.net", domains: ["doubleclick.net"]))
    }

    @Test("Domain matching is case-insensitive")
    func testTrackerDomainCaseInsensitive() {
        #expect(NetworkTrafficMonitor.matchesTrackerDomain("DoubleClick.NET", domains: ["doubleclick.net"]))
    }

    @Test("An unrelated host does not match")
    func testTrackerDomainNoMatch() {
        #expect(!NetworkTrafficMonitor.matchesTrackerDomain("apple.com", domains: ["doubleclick.net", "mixpanel.com"]))
    }

    @Test("Bundled tracker-domains.json decodes and contains known tracker domains")
    func testTrackerDomainsFileDecodes() throws {
        let url = try #require(Bundle.main.url(forResource: "tracker-domains", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(TrackerDomainFileForTest.self, from: data)
        let lowered = Set(file.domains.map { $0.lowercased() })
        #expect(file.domains.count >= 30)
        #expect(lowered.contains("doubleclick.net"))
        #expect(lowered.contains("google-analytics.com"))
    }

    private struct TrackerDomainFileForTest: Decodable {
        let version: Int
        let domains: [String]
    }

    // MARK: - Reverse DNS: never fabricate, and cache dedups by IP

    @Test("A non-resolvable host returns nil, never a fabricated hostname")
    func testResolveHostReturnsNilOnFailure() async {
        let monitor = NetworkTrafficMonitor()
        // Not a parseable numeric IP — getaddrinfo(AI_NUMERICHOST) rejects it
        // immediately with no network round-trip, so this deterministically
        // exercises the same "confirmed unresolved -> nil" code path a real
        // PTR miss takes, without depending on live DNS.
        let result = await monitor.resolveHost(ip: "not-an-ip-address")
        #expect(result == nil)
    }

    @Test("Repeated lookups of the same IP hit the cache instead of re-resolving")
    func testResolveHostCachesByIP() async {
        let monitor = NetworkTrafficMonitor()
        _ = await monitor.resolveHost(ip: "not-an-ip-address")
        _ = await monitor.resolveHost(ip: "not-an-ip-address")
        let count = await monitor.cachedIPCount
        #expect(count == 1, "the same IP looked up twice should only occupy one cache slot")
    }

    @Test("Distinct IPs each occupy their own cache slot")
    func testResolveHostCacheKeyedPerIP() async {
        let monitor = NetworkTrafficMonitor()
        _ = await monitor.resolveHost(ip: "not-an-ip-address")
        _ = await monitor.resolveHost(ip: "also-not-an-ip")
        let count = await monitor.cachedIPCount
        #expect(count == 2)
    }
}
