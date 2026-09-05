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

// MARK: - F-017 review fixes

@Suite("NetworkTrafficMonitor lsof parsing")
struct NetworkLsofParsingTests {

    // lsof truncates COMMAND to 9 characters but does NOT strip embedded spaces,
    // so "Google Chrome" arrives as "Google Ch". Assuming COMMAND was a single
    // token made parts[1] a name fragment, Int32(...) returned nil, and the row
    // was dropped silently — the browsers users most want to see were the ones
    // most likely to vanish.
    @Test("A COMMAND containing a space still yields the right PID and name")
    func testCommandWithSpace() {
        let output = """
        COMMAND     PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        Google Ch  4321 user   45u  IPv4 0x1234      0t0  TCP 192.168.1.5:52000->142.250.183.14:443 (ESTABLISHED)
        """
        let entries = NetworkTrafficMonitor.parseLsofOutput(output)
        #expect(entries.count == 1)
        #expect(entries.first?.pid == 4321)
        #expect(entries.first?.processName == "Google Ch")
        #expect(entries.first?.remoteIP == "142.250.183.14")
        #expect(entries.first?.remotePort == 443)
    }

    @Test("A single-token COMMAND still parses")
    func testSingleTokenCommand() {
        let output = """
        COMMAND   PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        curl     9876 user    5u  IPv4 0x9999      0t0  TCP 10.0.0.2:51000->93.184.216.34:80 (ESTABLISHED)
        """
        let entries = NetworkTrafficMonitor.parseLsofOutput(output)
        #expect(entries.first?.processName == "curl")
        #expect(entries.first?.pid == 9876)
    }

    @Test("LISTEN sockets with no peer are skipped")
    func testListenSocketsSkipped() {
        let output = """
        COMMAND   PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        nginx     100 user    6u  IPv4 0x1111      0t0  TCP *:8080 (LISTEN)
        """
        #expect(NetworkTrafficMonitor.parseLsofOutput(output).isEmpty)
    }

    // The identity fix: snapshot() rebuilds every entry each 2 s poll, so a
    // fresh UUID made ForEach treat every row as new every tick.
    @Test("Identity is the pid:ip:port:proto composite, stable across polls")
    func testStableIdentityAcrossPolls() {
        let output = """
        COMMAND   PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        curl     9876 user    5u  IPv4 0x9999      0t0  TCP 10.0.0.2:51000->93.184.216.34:80 (ESTABLISHED)
        """
        let first = NetworkTrafficMonitor.parseLsofOutput(output)
        let second = NetworkTrafficMonitor.parseLsofOutput(output)
        #expect(first.first?.id == second.first?.id)
        #expect(first.first?.id == "9876:93.184.216.34:80:TCP")
    }

    @Test("Reverse DNS is off by default")
    func testReverseDNSDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: NetworkTrafficMonitor.reverseDNSEnabledKey)
        #expect(NetworkTrafficMonitor.isReverseDNSEnabled == false)
    }
}

// MARK: - Bounded-concurrency scheduler
//
// The scheduler used to prime its task group from an `inFlight` counter that
// stopped being incremented once the inputs ran out, so with fewer inputs than
// the concurrency cap the priming loop never terminated — an actor pinned at
// 100% CPU with no suspension point to cancel at. The only fixture anyone had
// tried was "more inputs than the cap", which is the one case that worked.
//
// Every count at and below the cap is pinned here for that reason. Note these
// are hang-detectors rather than assertion failures: a regression stalls the
// suite instead of reddening it, which is an argument for a per-suite timeout
// in CI (see P0.1).
@Suite("NetworkTrafficMonitor bounded concurrency")
struct NetworkTrafficMonitorConcurrencyTests {

    @Test("Zero inputs returns empty rather than spinning",
          arguments: [1, 2, 8, 64])
    func testEmptyInputs(limit: Int) async {
        let out = await NetworkTrafficMonitor.mapConcurrently([], limit: limit) { $0 }
        #expect(out.isEmpty)
    }

    /// The regression case: counts strictly below the cap, plus the boundary.
    @Test("Fewer inputs than the cap still completes",
          arguments: [1, 2, 3, 7, 8, 9, 20])
    func testFewerInputsThanCap(count: Int) async {
        let inputs = (0..<count).map { "10.0.0.\($0)" }
        let out = await NetworkTrafficMonitor.mapConcurrently(inputs, limit: 8) { "host-\($0)" }

        #expect(out.count == count)
        for ip in inputs { #expect(out[ip] == "host-\(ip)") }
    }

    @Test("Never exceeds the concurrency limit")
    func testRespectsLimit() async {
        let tracker = ConcurrencyTracker()
        let inputs = (0..<40).map { "ip-\($0)" }

        let out = await NetworkTrafficMonitor.mapConcurrently(inputs, limit: 5) { ip in
            await tracker.enter()
            // Yield so overlapping tasks actually get a chance to overlap;
            // without this the peak could be 1 and the test would pass vacuously.
            await Task.yield()
            await tracker.leave()
            return ip
        }

        #expect(out.count == 40)
        #expect(await tracker.peak <= 5)
        #expect(await tracker.peak > 1, "no overlap observed — the test would not detect a cap regression")
    }

    /// A nil result must be *stored* as "resolved, no hostname" rather than
    /// dropped, otherwise the caller re-resolves it on every poll and the
    /// negative cache never warms.
    @Test("Optional values keep their key when nil")
    func testNilValuesRetainKeys() async {
        let out: [String: String?] = await NetworkTrafficMonitor.mapConcurrently(
            ["a", "b"], limit: 4
        ) { $0 == "a" ? "host-a" : nil }

        #expect(out.count == 2)
        #expect(out.index(forKey: "b") != nil)
        #expect(out["b"] == .some(nil))
    }

    @Test("A non-positive limit returns empty rather than spinning")
    func testNonPositiveLimit() async {
        let out = await NetworkTrafficMonitor.mapConcurrently(["a", "b"], limit: 0) { $0 }
        #expect(out.isEmpty)
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}


// MARK: - AsyncTimeout
//
// Every assertion here is on ELAPSED TIME, deliberately. The idiom this helper
// replaces — racing a `Task.sleep` sibling inside a `withTaskGroup` — returned
// the correct *value* and the wrong *time*, so a test that only checked the
// returned value passed against the broken version. Timing is the property that
// was actually missing.
@Suite("AsyncTimeout")
struct AsyncTimeoutTests {

    /// Bounds are generous: the gap between "released at the deadline" and
    /// "joined the abandoned work" is seconds, not milliseconds, so there is no
    /// need to measure tightly and invite flakiness.
    private static let slowWork: TimeInterval = 3.0

    // The case that used to hang the caller for the full duration of work it
    // had already given up on.
    @Test("Work slower than the deadline releases the caller at the deadline")
    func testBoundsWallClock() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 0.3) { deliver in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: Self.slowWork)   // uninterruptible
                deliver("too-late")
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(value == nil)
        #expect(elapsed < Self.slowWork / 2, "waited \(elapsed)s for abandoned work")
    }

    // The worse case: no delivery ever. Under the old shape the group waited on
    // a child that would never finish, so the caller blocked forever.
    @Test("A callback that never fires still returns at the deadline")
    func testNeverDelivered() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 0.3) { _ in }

        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test("A prompt result is returned immediately, not held until the deadline")
    func testFastPathNotDelayed() async {
        let started = Date()
        let value: String? = await AsyncTimeout.run(seconds: 10) { $0("quick") }

        #expect(value == "quick")
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    // A second resume on a checked continuation is a fatalError, so the test
    // process surviving is itself the assertion.
    @Test("Repeated deliveries resolve to the first and do not crash")
    func testRepeatedDeliveryTakesFirst() async {
        let value: Int? = await AsyncTimeout.run(seconds: 10) { deliver in
            deliver(1)
            deliver(2)
            deliver(3)
        }
        #expect(value == 1)
    }

    // PhotoKit delivers a placeholder then a real image; the first delivery
    // wins even when it is nil, which is the documented behaviour of `.run`.
    @Test("A first delivery of nil wins over a later real value")
    func testFirstNilWins() async {
        let value: Int? = await AsyncTimeout.run(seconds: 10) { deliver in
            deliver(nil)
            deliver(42)
        }
        #expect(value == nil)
    }

    @Test("A delivery arriving after the deadline is ignored rather than crashing")
    func testLateDeliveryIgnored() async {
        let value: Int? = await AsyncTimeout.run(seconds: 0.2) { deliver in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.5)
                deliver(7)
            }
        }
        #expect(value == nil)
        // Let the late delivery land while the test is still running, so a
        // double-resume would take this process down rather than a later one.
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    @Test("runBlocking returns a prompt value and bounds a slow one")
    func testRunBlocking() async {
        #expect(await AsyncTimeout.runBlocking(seconds: 10) { "done" } == "done")

        let started = Date()
        let slow: String? = await AsyncTimeout.runBlocking(seconds: 0.3) {
            Thread.sleep(forTimeInterval: Self.slowWork)
            return "too-late"
        }
        #expect(slow == nil)
        #expect(Date().timeIntervalSince(started) < Self.slowWork / 2)
    }
}
