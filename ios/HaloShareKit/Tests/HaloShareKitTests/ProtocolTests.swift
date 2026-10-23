import Testing
import Foundation
@testable import HaloShareKit

@Suite("DeviceInfo wire format")
struct DeviceInfoWireTests {

    @Test("An official /info response — no port, no protocol — decodes with sensible defaults")
    func officialInfo() throws {
        let json = #"{"alias":"Nice Orange","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"random string","download":true}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(info.port == 53317)
        #expect(info.protocol == .http)
        #expect(info.download == true)
    }

    @Test("A multicast announcement keeps port, protocol and announce")
    func announcement() throws {
        let json = #"{"alias":"Pixel","version":"2.1","deviceModel":null,"deviceType":"mobile","fingerprint":"abc","port":53400,"protocol":"https","download":false,"announce":true}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(info.port == 53400)
        #expect(info.protocol == .https)
        #expect(info.announce == true)
        #expect(info.deviceModel == nil)
    }

    @Test("What Halo desktop encodes today decodes here")
    func desktopShape() throws {
        // Shape produced by desktop's DeviceInfoDTO (announce omitted when nil).
        let json = #"{"alias":"Mac","version":"2.1","deviceModel":"Mac15,6","deviceType":"desktop","fingerprint":"ff00","port":53317,"protocol":"http","download":false}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(info.alias == "Mac")
        #expect(info.deviceType == "desktop")
    }

    @Test("Unknown protocol values and unknown fields do not break decoding")
    func tolerant() throws {
        let json = #"{"alias":"X","version":"9.9","fingerprint":"f","protocol":"quic","somethingNew":{"a":1}}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(info.protocol == .http)
    }

    @Test("Identity fields are still required")
    func requiredFields() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"alias":"x"}"#.utf8)) }
    }

    @Test("Encoding round-trips and emits the wire key names")
    func roundTrip() throws {
        let info = DeviceInfo(alias: "Phone", deviceModel: "iPhone", deviceType: "mobile", fingerprint: "abc", port: 53317, protocol: .http)
        let data = try JSONEncoder().encode(info)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"protocol\":\"http\""))
        #expect(text.contains("\"fingerprint\":\"abc\""))
        #expect(try JSONDecoder().decode(DeviceInfo.self, from: data) == info)
    }
}

@Suite("prepare-upload messages")
struct PrepareUploadWireTests {

    @Test("A prepare-upload request in the official shape decodes")
    func request() throws {
        let json = #"{"info":{"alias":"A","version":"2.0","deviceModel":null,"deviceType":"mobile","fingerprint":"f","port":53317,"protocol":"http","download":false},"files":{"id1":{"id":"id1","fileName":"a.jpg","size":42,"fileType":"image/jpeg","sha256":null,"preview":null,"metadata":{"modified":"2026-01-01T00:00:00Z","accessed":null}}}}"#
        let req = try JSONDecoder().decode(PrepareUploadRequest.self, from: Data(json.utf8))
        #expect(req.files["id1"]?.fileName == "a.jpg")
        #expect(req.files["id1"]?.size == 42)
        #expect(req.files["id1"]?.metadata?.modified == "2026-01-01T00:00:00Z")
    }

    @Test("A file without fileType still decodes — it is optional in practice")
    func missingFileType() throws {
        let f = try JSONDecoder().decode(FileDescriptor.self, from: Data(#"{"id":"1","fileName":"x","size":1}"#.utf8))
        #expect(f.fileType == "application/octet-stream")
    }

    @Test("The response round-trips")
    func response() throws {
        let r = PrepareUploadResponse(sessionId: "s", files: ["a": "t1", "b": "t2"])
        #expect(try JSONDecoder().decode(PrepareUploadResponse.self, from: JSONEncoder().encode(r)) == r)
    }
}

@Suite("HTTPRequestHead")
struct HTTPRequestHeadTests {
    private func parse(_ s: String) -> HTTPRequestHead? { HTTPRequestHead.parse(Data(s.utf8)) }

    @Test("Method, path, query and headers; header names are case-insensitive")
    func basics() throws {
        let h = try #require(parse("POST /api/localsend/v2/upload?sessionId=s%201&fileId=f&token=t HTTP/1.1\r\nHost: x\r\nCONTENT-LENGTH: 42\r\nContent-Type: application/octet-stream"))
        #expect(h.method == "POST")
        #expect(h.path == "/api/localsend/v2/upload")
        #expect(h.query == ["sessionId": "s 1", "fileId": "f", "token": "t"])
        #expect(h.contentLength == 42)
    }

    @Test("Missing or garbage Content-Length is 0")
    func lengthEdges() throws {
        #expect(try #require(parse("GET /a HTTP/1.1\r\nHost: x")).contentLength == 0)
        #expect(try #require(parse("POST /a HTTP/1.1\r\nContent-Length: banana")).contentLength == 0)
    }

    @Test("Chunked and Expect: 100-continue are recognised")
    func flags() throws {
        #expect(try #require(parse("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked")).isChunked)
        #expect(try #require(parse("POST /a HTTP/1.1\r\nExpect: 100-continue")).expectsContinue)
    }

    @Test("Malformed request lines are rejected")
    func malformed() {
        #expect(parse("") == nil)
        #expect(parse("GET") == nil)
        #expect(parse("GET nopath HTTP/1.1") == nil)
    }

    @Test("A stray high byte in a header does not invalidate the request")
    func lossy() {
        var d = Data("GET /api/localsend/v2/info HTTP/1.1\r\nX-Weird: ".utf8)
        d.append(0xFF)
        #expect(HTTPRequestHead.parse(d)?.path == "/api/localsend/v2/info")
    }
}

@Suite("SafeFileName")
struct SafeFileNameTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hsk-name-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("Good names and sub-folders are kept; backslashes are separators")
    func keeps() {
        #expect(SafeFileName.relativePath("photo.jpg") == "photo.jpg")
        #expect(SafeFileName.relativePath("trip/2026/a.jpg") == "trip/2026/a.jpg")
        #expect(SafeFileName.relativePath("Win\\Style\\a.txt") == "Win/Style/a.txt")
    }

    @Test("Traversal is neutralised")
    func neutralises() {
        #expect(SafeFileName.relativePath("../../.zshrc") == ".zshrc")
        #expect(SafeFileName.relativePath("/etc/passwd") == "etc/passwd")
        #expect(SafeFileName.relativePath("a/../../b") == "a/b")
        #expect(SafeFileName.relativePath("..") == nil)
        #expect(SafeFileName.relativePath("") == nil)
        #expect(SafeFileName.relativePath("a\0b") == nil)
    }

    @Test("Every hostile name resolves inside the destination")
    func inside() throws {
        let base = try tempDir()
        let root = base.standardizedFileURL.path
        for h in ["../../escape", "/tmp/escape", "a/../../../escape", "..", "", "....//x", "\\\\server\\share\\x"] {
            #expect(SafeFileName.uniqueDestination(for: h, in: base).standardizedFileURL.path.hasPrefix(root + "/"), "\"\(h)\"")
        }
    }

    @Test("A destination under /private/… keeps the real file name (regression: it became \"file\")")
    func privatePrefixedDestination() throws {
        // standardizedFileURL strips "/private" only for paths that EXIST. The destination
        // directory exists; the not-yet-written candidate file does not — so the two used to
        // normalise differently, the containment check wrongly failed, and every received
        // file was saved as "file". Reproduced with `halosharecli receive --dir /private/tmp/…`.
        let base = URL(fileURLWithPath: "/private/tmp/hsk-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(SafeFileName.uniqueDestination(for: "hello.txt", in: base).lastPathComponent == "hello.txt")
        #expect(SafeFileName.uniqueDestination(for: "a/b/c.txt", in: base).path.hasSuffix("/a/b/c.txt"))
        // …and confinement must still hold under the same prefix.
        let hostile = SafeFileName.uniqueDestination(for: "../../escape.txt", in: base)
        #expect(hostile.path.hasPrefix(base.path + "/"), "\(hostile.path)")
        #expect(hostile.lastPathComponent == "escape.txt")
    }

    @Test("Existing files are never overwritten")
    func unique() throws {
        let base = try tempDir()
        try Data("a".utf8).write(to: base.appendingPathComponent("r.pdf"))
        try Data("b".utf8).write(to: base.appendingPathComponent("r (1).pdf"))
        #expect(SafeFileName.uniqueDestination(for: "r.pdf", in: base).lastPathComponent == "r (2).pdf")
        try Data("c".utf8).write(to: base.appendingPathComponent("README"))
        #expect(SafeFileName.uniqueDestination(for: "README", in: base).lastPathComponent == "README (1)")
    }
}

@Suite("LocalNetwork")
struct LocalNetworkTests {

    @Test("A /24 yields 253 other hosts, not including ourselves, network or broadcast")
    func slash24() {
        let hosts = LocalNetwork.candidateHosts(address: "192.168.1.20", netmask: "255.255.255.0")
        #expect(hosts.count == 253)
        #expect(!hosts.contains("192.168.1.20"))
        #expect(!hosts.contains("192.168.1.0") && !hosts.contains("192.168.1.255"))
        #expect(hosts.first == "192.168.1.1" && hosts.last == "192.168.1.254")
    }

    @Test("A wide mask is capped rather than producing a flood of probes")
    func capped() {
        let hosts = LocalNetwork.candidateHosts(address: "10.1.2.3", netmask: "255.255.0.0", maxHosts: 1022)
        #expect(hosts.count <= 1022)
        #expect(hosts.contains("10.1.2.4"))
    }

    @Test("Nonsense addresses yield nothing")
    func nonsense() {
        #expect(LocalNetwork.candidateHosts(address: "banana", netmask: "255.255.255.0").isEmpty)
        #expect(LocalNetwork.candidateHosts(address: "10.0.0.1", netmask: "0.0.0.0").isEmpty)
    }

    @Test("host[:port] parsing")
    func hostPort() {
        #expect(LocalNetwork.parseHostPort("192.168.1.5")?.port == 53317)
        #expect(LocalNetwork.parseHostPort("192.168.1.5:8080")?.port == 8080)
        #expect(LocalNetwork.parseHostPort("[fe80::1]:9000")?.host == "fe80::1")
        #expect(LocalNetwork.parseHostPort("[::1]")?.port == 53317)
        #expect(LocalNetwork.parseHostPort("host:99999") == nil)
        #expect(LocalNetwork.parseHostPort("host:abc") == nil)
        #expect(LocalNetwork.parseHostPort("  ") == nil)
        #expect(LocalNetwork.parseHostPort(":80") == nil)
    }
}

@Suite("DeviceIdentity")
struct IdentityTests {
    @Test("The fingerprint is generated once and then stable")
    func stable() {
        let store = InMemoryIdentityStore()
        let a = DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "Phone")
        let b = DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "Other name")
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint.count == 32)
        #expect(b.alias == "Phone", "the persisted alias wins over a later default")
    }

    @Test("Two devices don't share a fingerprint")
    func distinct() {
        #expect(DeviceIdentity.randomFingerprint() != DeviceIdentity.randomFingerprint())
    }

    @Test("Alias edits persist, are trimmed and capped; blanks are ignored")
    func alias() {
        let store = InMemoryIdentityStore()
        _ = DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "Phone")
        DeviceIdentityStore.setAlias("  Kitchen iPad  ", in: store)
        #expect(DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "x").alias == "Kitchen iPad")
        DeviceIdentityStore.setAlias("   ", in: store)
        #expect(DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "x").alias == "Kitchen iPad")
        DeviceIdentityStore.setAlias(String(repeating: "z", count: 100), in: store)
        #expect(DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: "x").alias.count == 40)
    }
}
