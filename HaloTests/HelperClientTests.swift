import Testing
import Foundation
@testable import Halo

// MARK: - HelperClientTests  (F-002)
//
// Tests for HelperClient using a pure-Swift MockHelper.
//
// Key design: MockHelper conforms to HelperProxying (NOT HaloHelperProtocol).
// HaloHelperProtocol is @objc, which forces NSObject inheritance on conformers
// and triggers ObjC completion-handler bridging in async contexts.  That
// bridging dispatches callbacks on the main thread — deadlocking the SPM test
// runner which has no spinning main run loop.
//
// HelperProxying is the identical Swift-only mirror.  MockHelper uses it,
// HelperClient.init(proxy:) accepts it, and NSXPCInterface keeps using
// HaloHelperProtocol for real XPC.

// MARK: - Pure-Swift mock

final class MockHelper: HelperProxying {
    var flushDNSResult         = true
    var purgeRAMResult         = 128.0
    var rebuildSpotlightResult = true
    var clearFontCacheResult   = true
    var versionResult          = "1.2.0-mock"

    var flushDNSCallCount         = 0
    var purgeRAMCallCount         = 0
    var rebuildSpotlightCallCount = 0
    var clearFontCacheCallCount   = 0

    func flushDNS(reply: @escaping (Bool)   -> Void) { flushDNSCallCount += 1;         reply(flushDNSResult) }
    func purgeRAM(reply: @escaping (Double) -> Void) { purgeRAMCallCount += 1;         reply(purgeRAMResult) }
    func rebuildSpotlightIndex(reply: @escaping (Bool)   -> Void) { rebuildSpotlightCallCount += 1; reply(rebuildSpotlightResult) }
    func clearFontCache(reply: @escaping (Bool)   -> Void) { clearFontCacheCallCount += 1; reply(clearFontCacheResult) }
    func helperVersion(reply: @escaping (String) -> Void)  { reply(versionResult) }
}

// MARK: - Suite

@Suite("HelperClient")
struct HelperClientTests {

    // MARK: flushDNS

    @Test("flushDNS returns true on success")
    func testFlushDNSSuccess() async {
        let mock = MockHelper()
        let client = HelperClient(proxy: mock)
        let result = await client.flushDNS()
        #expect(result == true)
        #expect(mock.flushDNSCallCount == 1)
    }

    @Test("flushDNS returns false when helper reports failure")
    func testFlushDNSFailure() async {
        let mock = MockHelper()
        mock.flushDNSResult = false
        let client = HelperClient(proxy: mock)
        let result = await client.flushDNS()
        #expect(result == false)
    }

    // MARK: purgeRAM

    @Test("purgeRAM returns freed MB on success")
    func testPurgeRAMSuccess() async {
        let mock = MockHelper()
        mock.purgeRAMResult = 256.0
        let client = HelperClient(proxy: mock)
        let freed = await client.purgeRAM()
        #expect(freed == 256.0)
        #expect(mock.purgeRAMCallCount == 1)
    }

    @Test("purgeRAM returns 0 when helper could not free any memory")
    func testPurgeRAMZeroFreed() async {
        let mock = MockHelper()
        mock.purgeRAMResult = 0.0   // helper ran but freed nothing
        let client = HelperClient(proxy: mock)
        let freed = await client.purgeRAM()
        #expect(freed == 0.0)
        #expect(mock.purgeRAMCallCount == 1)
    }

    // MARK: rebuildSpotlightIndex

    @Test("rebuildSpotlightIndex returns true on acceptance")
    func testRebuildSpotlight() async {
        let mock = MockHelper()
        let client = HelperClient(proxy: mock)
        let result = await client.rebuildSpotlightIndex()
        #expect(result == true)
        #expect(mock.rebuildSpotlightCallCount == 1)
    }

    @Test("rebuildSpotlightIndex returns false on rejection")
    func testRebuildSpotlightFailure() async {
        let mock = MockHelper()
        mock.rebuildSpotlightResult = false
        let client = HelperClient(proxy: mock)
        let result = await client.rebuildSpotlightIndex()
        #expect(result == false)
    }

    // MARK: clearFontCache

    @Test("clearFontCache returns true on success")
    func testClearFontCache() async {
        let mock = MockHelper()
        let client = HelperClient(proxy: mock)
        let result = await client.clearFontCache()
        #expect(result == true)
        #expect(mock.clearFontCacheCallCount == 1)
    }

    // MARK: helperVersion

    @Test("helperVersion returns version string")
    func testHelperVersion() async {
        let mock = MockHelper()
        let client = HelperClient(proxy: mock)
        let version = await client.helperVersion()
        #expect(version == "1.2.0-mock")
    }

    @Test("helperVersion returns nil when helper unavailable")
    func testHelperVersionUnavailable() async {
        let client = HelperClient(proxy: nil)
        let version = await client.helperVersion()
        #expect(version == nil)
    }

    // MARK: isAvailable

    @Test("isAvailable is true when proxy is set")
    func testIsAvailableWithProxy() {
        let client = HelperClient(proxy: MockHelper())
        #expect(client.isAvailable == true)
    }

    @Test("isAvailable is false when proxy is nil")
    func testIsAvailableWithoutProxy() {
        let client = HelperClient(proxy: nil)
        #expect(client.isAvailable == false)
    }
}
