package app.halo.share

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DeviceInfoWireTest {
    private fun decode(json: String) = HaloJson.decodeFromString(DeviceInfo.serializer(), json)

    @Test fun officialInfoResponseHasNoPortOrProtocolAndStillDecodes() {
        val info = decode("""{"alias":"Nice Orange","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"random string","download":true}""")
        assertEquals(53317, info.port); assertEquals("http", info.protocol); assertEquals(true, info.download)
    }

    @Test fun announcementKeepsPortProtocolAndAnnounce() {
        val info = decode("""{"alias":"Pixel","version":"2.1","deviceModel":null,"deviceType":"mobile","fingerprint":"abc","port":53400,"protocol":"https","download":false,"announce":true}""")
        assertEquals(53400, info.port); assertEquals("https", info.protocol); assertEquals(true, info.announce); assertNull(info.deviceModel)
    }

    @Test fun whatHaloDesktopEncodesDecodesHere() {
        val info = decode("""{"alias":"Mac","version":"2.1","deviceModel":"Mac15,6","deviceType":"desktop","fingerprint":"ff00","port":53317,"protocol":"http","download":false}""")
        assertEquals("Mac", info.alias); assertEquals("desktop", info.deviceType)
    }

    @Test fun unknownFieldsAreIgnored() {
        assertEquals("X", decode("""{"alias":"X","version":"9.9","fingerprint":"f","somethingNew":{"a":1}}""").alias)
    }

    @Test fun identityFieldsAreStillRequired() {
        assertThrows(Exception::class.java) { decode("""{"alias":"x"}""") }
    }

    @Test fun encodingRoundTripsAndEmitsWireKeyNames() {
        val info = DeviceInfo("Phone", deviceModel = "Pixel", deviceType = "mobile", fingerprint = "abc")
        val text = HaloJson.encodeToString(DeviceInfo.serializer(), info)
        assertTrue(text, text.contains("\"protocol\":\"http\"")); assertTrue(text.contains("\"fingerprint\":\"abc\""))
        assertEquals(info, decode(text))
    }
}

class PrepareUploadWireTest {
    @Test fun officialRequestShapeDecodes() {
        val json = """{"info":{"alias":"A","version":"2.0","deviceModel":null,"deviceType":"mobile","fingerprint":"f","port":53317,"protocol":"http","download":false},"files":{"id1":{"id":"id1","fileName":"a.jpg","size":42,"fileType":"image/jpeg","sha256":null,"preview":null,"metadata":{"modified":"2026-01-01T00:00:00Z","accessed":null}}}}"""
        val req = HaloJson.decodeFromString(PrepareUploadRequest.serializer(), json)
        assertEquals("a.jpg", req.files["id1"]?.fileName); assertEquals(42L, req.files["id1"]?.size)
        assertEquals("2026-01-01T00:00:00Z", req.files["id1"]?.metadata?.modified)
    }

    @Test fun missingFileTypeDefaults() {
        assertEquals("application/octet-stream",
            HaloJson.decodeFromString(FileDescriptor.serializer(), """{"id":"1","fileName":"x","size":1}""").fileType)
    }

    @Test fun responseRoundTrips() {
        val r = PrepareUploadResponse("s", mapOf("a" to "t1", "b" to "t2"))
        assertEquals(r, HaloJson.decodeFromString(PrepareUploadResponse.serializer(), HaloJson.encodeToString(PrepareUploadResponse.serializer(), r)))
    }
}

class HttpRequestHeadTest {
    private fun parse(s: String) = HttpRequestHead.parse(s.toByteArray())

    @Test fun methodPathQueryHeaders() {
        val h = parse("POST /api/localsend/v2/upload?sessionId=s%201&fileId=f&token=t HTTP/1.1\r\nHost: x\r\nCONTENT-LENGTH: 42\r\nContent-Type: application/octet-stream")!!
        assertEquals("POST", h.method); assertEquals("/api/localsend/v2/upload", h.path)
        assertEquals(mapOf("sessionId" to "s 1", "fileId" to "f", "token" to "t"), h.query)
        assertEquals(42, h.contentLength)
    }

    @Test fun missingOrGarbageContentLengthIsZero() {
        assertEquals(0, parse("GET /a HTTP/1.1\r\nHost: x")!!.contentLength)
        assertEquals(0, parse("POST /a HTTP/1.1\r\nContent-Length: banana")!!.contentLength)
    }

    @Test fun chunkedAndExpectContinueAreRecognised() {
        assertTrue(parse("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked")!!.isChunked)
        assertTrue(parse("POST /a HTTP/1.1\r\nExpect: 100-continue")!!.expectsContinue)
    }

    @Test fun malformedRequestLinesAreRejected() {
        assertNull(parse("")); assertNull(parse("GET")); assertNull(parse("GET nopath HTTP/1.1"))
    }

    @Test fun strayHighByteInAHeaderDoesNotInvalidateTheRequest() {
        val bytes = "GET /api/localsend/v2/info HTTP/1.1\r\nX-Weird: ".toByteArray() + byteArrayOf(0xFF.toByte())
        assertEquals("/api/localsend/v2/info", HttpRequestHead.parse(bytes)?.path)
    }

    @Test fun percentDecodingHandlesEdgesAndUtf8() {
        assertEquals("a b", HttpRequestHead.percentDecode("a%20b"))
        assertEquals("100%", HttpRequestHead.percentDecode("100%"))
        assertEquals("%zz", HttpRequestHead.percentDecode("%zz"))
        assertEquals("é", HttpRequestHead.percentDecode("%C3%A9"))
        assertEquals("a+b", HttpRequestHead.percentDecode("a+b"))
    }
}

class SafeFileNameTest {
    private fun tempDir() = Files.createTempDirectory("hsk-name").toFile()

    @Test fun goodNamesAndSubFoldersAreKeptBackslashesAreSeparators() {
        assertEquals("photo.jpg", SafeFileName.relativePath("photo.jpg"))
        assertEquals("trip/2026/a.jpg", SafeFileName.relativePath("trip/2026/a.jpg"))
        assertEquals("Win/Style/a.txt", SafeFileName.relativePath("Win\\Style\\a.txt"))
    }

    @Test fun traversalIsNeutralised() {
        assertEquals(".zshrc", SafeFileName.relativePath("../../.zshrc"))
        assertEquals("etc/passwd", SafeFileName.relativePath("/etc/passwd"))
        assertEquals("a/b", SafeFileName.relativePath("a/../../b"))
        assertNull(SafeFileName.relativePath("..")); assertNull(SafeFileName.relativePath("")); assertNull(SafeFileName.relativePath("a\u0000b"))
    }

    @Test fun everyHostileNameResolvesInsideTheDestination() {
        val base = tempDir()
        for (h in listOf("../../escape", "/tmp/escape", "a/../../../escape", "..", "", "....//x", "\\\\server\\share\\x")) {
            val f = SafeFileName.uniqueDestination(h, base)
            assertTrue("\"$h\" -> ${f.path}", f.path.startsWith(base.path + "/"))
        }
    }

    @Test fun existingFilesAreNeverOverwritten() {
        val base = tempDir()
        File(base, "r.pdf").writeText("a"); File(base, "r (1).pdf").writeText("b")
        assertEquals("r (2).pdf", SafeFileName.uniqueDestination("r.pdf", base).name)
        File(base, "README").writeText("c")
        assertEquals("README (1)", SafeFileName.uniqueDestination("README", base).name)
    }

    @Test fun aDestinationUnderPrivateKeepsTheRealName() {
        // Regression from the Swift Kit: containment must not depend on what exists on disk.
        val base = File("/private/tmp/hsk-private-${System.nanoTime()}").apply { mkdirs() }
        try {
            assertEquals("hello.txt", SafeFileName.uniqueDestination("hello.txt", base).name)
            assertTrue(SafeFileName.uniqueDestination("a/b/c.txt", base).path.endsWith("/a/b/c.txt"))
            assertEquals("escape.txt", SafeFileName.uniqueDestination("../../escape.txt", base).name)
        } finally { base.deleteRecursively() }
    }
}

class LocalNetworkTest {
    @Test fun slash24YieldsTheOther253Hosts() {
        val hosts = LocalNetwork.candidateHosts("192.168.1.20", 24)
        assertEquals(253, hosts.size); assertFalse("192.168.1.20" in hosts)
        assertFalse("192.168.1.0" in hosts); assertFalse("192.168.1.255" in hosts)
        assertEquals("192.168.1.1", hosts.first()); assertEquals("192.168.1.254", hosts.last())
    }

    @Test fun aWideMaskIsCapped() {
        val hosts = LocalNetwork.candidateHosts("10.1.2.3", 16)
        assertTrue(hosts.size <= 1022); assertTrue("10.1.2.4" in hosts)
    }

    @Test fun nonsenseYieldsNothing() {
        assertTrue(LocalNetwork.candidateHosts("banana", 24).isEmpty())
        assertTrue(LocalNetwork.candidateHosts("10.0.0.1", 0).isEmpty())
        assertTrue(LocalNetwork.candidateHosts("10.0.0.1", 31).isEmpty())
    }

    @Test fun hostPortParsing() {
        assertEquals(53317, LocalNetwork.parseHostPort("192.168.1.5")?.second)
        assertEquals(8080, LocalNetwork.parseHostPort("192.168.1.5:8080")?.second)
        assertEquals("fe80::1", LocalNetwork.parseHostPort("[fe80::1]:9000")?.first)
        assertEquals(53317, LocalNetwork.parseHostPort("[::1]")?.second)
        assertNull(LocalNetwork.parseHostPort("host:99999")); assertNull(LocalNetwork.parseHostPort("host:abc"))
        assertNull(LocalNetwork.parseHostPort("  ")); assertNull(LocalNetwork.parseHostPort(":80"))
    }

    @Test fun netmaskToPrefix() {
        assertEquals(24, LocalNetwork.prefixLength("255.255.255.0")); assertEquals(16, LocalNetwork.prefixLength("255.255.0.0"))
        assertNull(LocalNetwork.prefixLength("255.0.255.0")); assertNull(LocalNetwork.prefixLength("nope"))
    }
}

class IdentityTest {
    @Test fun fingerprintIsGeneratedOnceThenStable() {
        val store = InMemoryStore()
        val a = DeviceIdentityStore.loadOrCreate(store, "Phone")
        val b = DeviceIdentityStore.loadOrCreate(store, "Other name")
        assertEquals(a.fingerprint, b.fingerprint); assertEquals(32, a.fingerprint.length); assertEquals("Phone", b.alias)
    }

    @Test fun twoDevicesDontShareAFingerprint() = assertNotEquals(DeviceIdentity.randomFingerprint(), DeviceIdentity.randomFingerprint())

    @Test fun aliasEditsPersistAreTrimmedAndCappedBlanksIgnored() {
        val store = InMemoryStore()
        DeviceIdentityStore.loadOrCreate(store, "Phone")
        DeviceIdentityStore.setAlias(store, "  Kitchen Tablet  ")
        assertEquals("Kitchen Tablet", DeviceIdentityStore.loadOrCreate(store, "x").alias)
        DeviceIdentityStore.setAlias(store, "   ")
        assertEquals("Kitchen Tablet", DeviceIdentityStore.loadOrCreate(store, "x").alias)
        DeviceIdentityStore.setAlias(store, "z".repeat(100))
        assertEquals(40, DeviceIdentityStore.loadOrCreate(store, "x").alias.length)
    }
}
