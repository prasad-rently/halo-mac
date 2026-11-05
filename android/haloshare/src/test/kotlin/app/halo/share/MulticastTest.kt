package app.halo.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        // the same peer announces twice (the host-in-payload case has its own test below)
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

    @Test fun `a payload that names some other host is ignored - the peer is located by the datagram source`() {
        // DeviceInfo has no host field, so an attacker can only try extra JSON fields (or an address stuffed into a real one).
        val sneaky = """{"alias":"Mac","fingerprint":"bbbb","port":53317,"protocol":"http","announce":true,"ip":"6.6.6.6","host":"6.6.6.6","address":"6.6.6.6","hostname":"6.6.6.6"}""".toByteArray()
        val t = Fake(ArrayDeque(listOf(DatagramTransport.Received(sneaky, sneaky.size, "192.168.1.9"))))
        var now = 0L
        val found = MulticastDiscovery(me, windowMs = 500, clock = { now.also { now += 50 } }).run(t)
        assertEquals(1, found.size)
        assertEquals("host is the source address", "192.168.1.9", found[0].host)
        assertEquals("http://192.168.1.9:53317", found[0].baseUrl)
        assertTrue("nothing in the decoded device mentions the injected address", !found[0].info.toString().contains("6.6.6.6"))
        assertTrue("and our replies go to the group, not to it", t.sent.none { it.contains("6.6.6.6") })
    }

    // ── interface pinning (follow-up item 4) ────────────────────────────────────────────────────

    private fun nic(name: String, up: Boolean = true, loopback: Boolean = false, multicast: Boolean = true, ipv4: Boolean = true) = IfaceCandidate(name, up, loopback, multicast, ipv4)

    @Test fun `the Wi-Fi interface the OS names is chosen when it is usable`() {
        val all = listOf(nic("lo", loopback = true), nic("rmnet0"), nic("wlan0"), nic("tun0"))
        assertEquals("wlan0", MulticastInterfaces.choose(all, "wlan0"))
    }

    @Test fun `no usable preferred interface means no pin - discovery falls back to the default behaviour`() {
        val all = listOf(nic("lo", loopback = true), nic("wlan0", up = false), nic("rmnet0", multicast = false), nic("p2p0", ipv4 = false))
        assertNull("no preference", MulticastInterfaces.choose(all, null))
        assertNull("blank preference", MulticastInterfaces.choose(all, " "))
        assertNull("not present", MulticastInterfaces.choose(all, "wlan9"))
        assertNull("down", MulticastInterfaces.choose(all, "wlan0"))
        assertNull("no multicast", MulticastInterfaces.choose(all, "rmnet0"))
        assertNull("no IPv4", MulticastInterfaces.choose(all, "p2p0"))
        assertNull("never the loopback", MulticastInterfaces.choose(all, "lo"))
    }

    @Test fun `the real transport is pinned to a usable interface and falls back quietly for an unknown one`() {
        UdpMulticastTransport(port = 0, preferredInterface = "no-such-interface0").use { assertNull("fell back", it.pinnedInterface) }
        UdpMulticastTransport(port = 0).use { assertNull("no preference, no pin", it.pinnedInterface) }
        val usable = MulticastInterfaces.systemCandidates().map { it.first }.firstOrNull { it.up && !it.loopback && it.multicast && it.hasIpv4 }
        org.junit.Assume.assumeTrue("needs a multicast-capable interface on this machine", usable != null)
        UdpMulticastTransport(port = 0, preferredInterface = usable!!.name).use {
            // pinning can legitimately be refused by the OS for a given NIC; what must hold is that it never throws and never pins to something else
            assertTrue(it.pinnedInterface == null || it.pinnedInterface == usable.name)
        }
    }

    // ── lock scope + periodic re-announce (follow-up item 10) ───────────────────────────────────

    private class FakeLock : MulticastLockHandle {
        val log = ArrayList<String>(); override var isHeld = false
        override fun acquire() { log.add("acquire"); isHeld = true }
        override fun release() { log.add("release"); isHeld = false }
    }

    @Test fun `the lock is held for the window only and released even when the transport blows up`() {
        val lock = FakeLock(); val t = Fake(ArrayDeque())
        val seenHeldDuring = java.util.concurrent.atomic.AtomicBoolean(false)
        MulticastWindow.run(me, 500, lock, { seenHeldDuring.set(lock.isHeld); t })   // clock is real; a 500 ms window with no traffic
        assertTrue("held while the transport was opened", seenHeldDuring.get())
        assertEquals(listOf("acquire", "release"), lock.log); assertFalse(lock.isHeld); assertTrue(t.closed)

        val lock2 = FakeLock()
        val r = MulticastWindow.run(me, 500, lock2, { throw java.io.IOException("no multicast on this network") })
        assertTrue("an unavailable network gives an empty result, not a crash", r.isEmpty())
        assertEquals(listOf("acquire", "release"), lock2.log)

        val lock3 = object : MulticastLockHandle { override fun acquire() { throw SecurityException("refused") }; override fun release() {}; override val isHeld = false }
        assertTrue(MulticastWindow.run(me, 500, lock3, { Fake(ArrayDeque()) }).isEmpty())
    }

    @Test fun `re-announce runs a bounded window each interval while idle, never while busy, and the lock is free between windows`() {
        val lock = FakeLock(); val idle = java.util.concurrent.atomic.AtomicBoolean(true)
        val maxHeld = java.util.concurrent.atomic.AtomicInteger(); val running = java.util.concurrent.atomic.AtomicInteger()
        val a = PeriodicAnnouncer(intervalMs = 40, isIdle = { idle.get() }, announce = {
            running.incrementAndGet().let { n -> if (n > maxHeld.get()) maxHeld.set(n) }
            MulticastWindow.run(me, 20, lock, { Fake(ArrayDeque()) })
            running.decrementAndGet()
        })
        a.start()
        assertTrue("windows run while idle", waitUntil(3000) { a.windowsRun >= 3 })
        idle.set(false)
        Thread.sleep(150)                                           // let a window that was already in flight finish
        val frozen = a.windowsRun
        Thread.sleep(300)
        assertEquals("no windows while a transfer / consent prompt is active", frozen, a.windowsRun)
        idle.set(true)
        assertTrue("resumes when idle again", waitUntil(3000) { a.windowsRun > frozen })
        a.stop()
        val afterStop = a.windowsRun
        Thread.sleep(200)
        assertEquals("nothing runs after stop", afterStop, a.windowsRun)
        assertEquals("windows never overlap", 1, maxHeld.get())
        assertFalse("the lock is not held between windows or after stop", lock.isHeld)
        assertEquals("every acquire was matched by a release", lock.log.count { it == "acquire" }, lock.log.count { it == "release" })
    }

    @Test fun `an extra window on a network change is rate limited and respects idle and stop`() {
        var now = 0L; val ran = java.util.concurrent.atomic.AtomicInteger(); val idle = java.util.concurrent.atomic.AtomicBoolean(true)
        val a = PeriodicAnnouncer(intervalMs = 3_600_000, isIdle = { idle.get() }, announce = { ran.incrementAndGet() }, minGapMs = 10_000, clock = { now })
        a.start()
        assertTrue(a.tick(requireGap = true)); assertFalse("inside the gap", a.tick(requireGap = true))
        now += 10_001
        idle.set(false); assertFalse("busy", a.tick(requireGap = true)); idle.set(true)
        assertTrue("after the gap", a.tick(requireGap = true))
        a.stop(); assertFalse("stopped", a.tick(requireGap = true))
        assertEquals(2, ran.get())
    }
}
