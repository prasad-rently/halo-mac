package app.halo.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MulticastTest {
    private val me = DeviceInfo(alias = "Pixel", fingerprint = "aaaa", deviceType = "mobile")
    private fun peer(fp: String = "bbbb", alias: String = "Mac", announce: Boolean? = true, port: Int = 53317, protocol: String = "http") =
        DeviceInfo(alias = alias, fingerprint = fp, port = port, protocol = protocol, announce = announce)
    private fun bytes(i: DeviceInfo) = MulticastCodec.encode(i, announce = i.announce ?: true, port = i.port)

    @Test fun `an announcement round-trips and carries the protocol's fields`() {
        val b = MulticastCodec.encode(me, announce = true)
        val text = String(b)
        for (k in listOf("\"alias\":\"Pixel\"", "\"fingerprint\":\"aaaa\"", "\"announce\":true", "\"port\":53317", "\"protocol\":\"http\"", "\"download\":false", "\"version\"")) assertTrue("missing $k in $text", text.contains(k))
        val back = MulticastCodec.decode(b, b.size, ownFingerprint = "zzzz")!!
        assertEquals("aaaa", back.fingerprint); assertEquals(true, back.announce)
        assertEquals(false, HaloJson.decodeFromString(DeviceInfo.serializer(), String(MulticastCodec.encode(me, announce = false))).announce)
    }

    @Test fun `the codec is strict about untrusted datagrams`() {
        fun dec(s: String, own: String = "aaaa") = s.toByteArray().let { MulticastCodec.decode(it, it.size, own) }
        assertNull("our own echo", MulticastCodec.encode(me, true).let { MulticastCodec.decode(it, it.size, "aaaa") })
        assertNull(dec("not json")); assertNull(dec("")); assertNull(dec("{}"))
        assertNull("no fingerprint", dec("""{"alias":"x","fingerprint":""}"""))
        assertNull("bad port", dec("""{"alias":"x","fingerprint":"f","port":70000}"""))
        assertNull("odd protocol", dec("""{"alias":"x","fingerprint":"f","protocol":"ftp"}"""))
        assertNull("blank alias", dec("""{"alias":"  ","fingerprint":"f"}"""))
        val big = ByteArray(MulticastCodec.MAX_DATAGRAM + 1) { ' '.code.toByte() }
        assertNull("oversize", MulticastCodec.decode(big, big.size, "aaaa"))
        val a = dec("""{"alias":"${"x".repeat(500)}\u0007evil","fingerprint":"f"}""")!!
        assertEquals(MulticastCodec.MAX_ALIAS, a.alias.length); assertTrue(a.alias.none { it.isISOControl() })
        assertNotNull("unknown fields are ignored", dec("""{"alias":"x","fingerprint":"f","newField":[1,2]}"""))
    }

    private class Fake(val inbound: ArrayDeque<DatagramTransport.Received>) : DatagramTransport {
        val sent = ArrayList<String>()
        var closed = false
        override fun send(bytes: ByteArray) { sent.add(String(bytes)) }
        override fun receive(timeoutMs: Int) = inbound.removeFirstOrNull()
        override fun close() { closed = true }
    }

    @Test fun `discovery announces, answers an announcement once, reports each peer once, and takes the host from the datagram source`() {
        val b = bytes(peer())
        // the same peer announces twice, and a peer claiming to be on another host in its payload is still located by source
        val t = Fake(ArrayDeque(listOf(DatagramTransport.Received(b, b.size, "192.168.1.9"), DatagramTransport.Received(b, b.size, "192.168.1.9"))))
        var now = 0L
        val found = MulticastDiscovery(me, windowMs = 1000, clock = { now.also { now += 100 } }).run(t)
        assertEquals(1, found.size); assertEquals("192.168.1.9", found[0].host); assertEquals("Mac", found[0].alias)
        assertTrue("announced", t.sent.any { it.contains("\"announce\":true") })
        assertEquals("answered exactly once despite two announcements", 1, t.sent.count { it.contains("\"announce\":false") })
    }

    @Test fun `a reply (announce false) is recorded but never answered, so two devices cannot ping-pong`() {
        val b = bytes(peer(announce = false))
        val t = Fake(ArrayDeque(listOf(DatagramTransport.Received(b, b.size, "10.0.0.5"))))
        var now = 0L
        val found = MulticastDiscovery(me, windowMs = 500, clock = { now.also { now += 50 } }).run(t)
        assertEquals(1, found.size)
        assertTrue(t.sent.none { it.contains("\"announce\":false") })
    }

    @Test fun `the window is bounded and honours cancellation`() {
        var now = 0L; val t = Fake(ArrayDeque())
        MulticastDiscovery(me, windowMs = 2000, clock = { now.also { now += 500 } }).run(t)
        assertTrue("terminates by its own window", now >= 2000)
        var calls = 0; var n2 = 0L
        MulticastDiscovery(me, windowMs = 10_000, clock = { n2.also { n2 += 1 } }).run(Fake(ArrayDeque()), isCancelled = { ++calls > 3 })
        assertTrue(calls <= 5)
    }

    @Test fun `a flood of unique spoofed fingerprints cannot grow the peer list or our replies without bound`() {
        val inbound = ArrayDeque((1..500).map { i -> bytes(peer(fp = "spoof-$i")).let { DatagramTransport.Received(it, it.size, "10.0.0.${i % 250}") } })
        val t = Fake(inbound); var now = 0L
        val found = MulticastDiscovery(me, windowMs = 100_000, clock = { now.also { now += 10 } }).run(t)
        assertEquals(MulticastCodec.MAX_PEERS, found.size)
        assertEquals(MulticastCodec.MAX_ANSWERS, t.sent.count { it.contains("\"announce\":false") })
    }
}
