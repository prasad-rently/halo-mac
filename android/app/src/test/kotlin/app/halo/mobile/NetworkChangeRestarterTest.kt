package app.halo.mobile

import app.halo.mobile.background.NetworkChangeRestarter
import app.halo.mobile.background.NetworkEvents
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkChangeRestarterTest {
    private class Events(var current: String?) : NetworkEvents {
        var listener: NetworkEvents.Listener? = null; var registers = 0; var unregisters = 0
        override fun currentNetworkId() = current
        override fun register(listener: NetworkEvents.Listener): () -> Unit { registers++; this.listener = listener; return { unregisters++; this.listener = null } }
    }

    private fun rig(initial: String? = "wifi-1", minGap: Long = 3_000): Triple<Events, NetworkChangeRestarter, IntArray> {
        val e = Events(initial); val n = intArrayOf(0); var now = 0L
        val r = NetworkChangeRestarter(e, { n[0]++ }, minGapMs = minGap, clock = { now })
        clockHolder[r] = { delta -> now += delta }
        return Triple(e, r, n)
    }
    private val clockHolder = HashMap<NetworkChangeRestarter, (Long) -> Unit>()
    private fun NetworkChangeRestarter.advance(ms: Long) = clockHolder[this]!!(ms)

    @Test fun `the callback is registered only while started and unregistered on stop`() {
        val (e, r, _) = rig()
        assertEquals(0, e.registers); assertFalse(r.registered)
        r.start(); assertEquals(1, e.registers); assertTrue(r.registered); assertNotNull(e.listener)
        r.start(); assertEquals("start is idempotent", 1, e.registers)
        r.stop(); assertEquals(1, e.unregisters); assertNull(e.listener); assertFalse(r.registered)
        r.stop(); assertEquals("stop is idempotent", 1, e.unregisters)
    }

    @Test fun `after stop a late event does nothing`() {
        val (e, r, n) = rig(); r.start(); val l = e.listener!!; r.stop()
        r.advance(10_000); l.onAvailable("cell-1")
        assertEquals(0, n[0])
    }

    @Test fun `the callback Android fires at registration for the network we are already on is not a change`() {
        val (e, r, n) = rig("wifi-1"); r.start()
        e.listener!!.onAvailable("wifi-1")
        assertEquals(0, n[0])
    }

    @Test fun `moving to a different network restarts once, and a burst of events for one switch collapses`() {
        val (e, r, n) = rig("wifi-1"); r.start(); val l = e.listener!!
        r.advance(10_000)
        l.onAvailable("cell-1"); assertEquals(1, n[0])
        l.onAvailable("cell-1"); assertEquals("same network again is nothing", 1, n[0])
        r.advance(500); l.onAvailable("wifi-2"); assertEquals("inside the gap: collapsed", 1, n[0])
        r.advance(5_000); l.onAvailable("wifi-3"); assertEquals(2, n[0])
    }

    @Test fun `the same network coming back after a loss is a change`() {
        val (e, r, n) = rig("wifi-1"); r.start(); val l = e.listener!!; r.advance(10_000)
        l.onLost("wifi-1"); assertEquals("losing a network alone restarts nothing", 0, n[0])
        r.advance(10_000); l.onAvailable("wifi-1"); assertEquals(1, n[0])
    }

    @Test fun `starting offline makes the first network to appear a change`() {
        val (e, r, n) = rig(null); r.start(); r.advance(10_000)
        e.listener!!.onAvailable("wifi-1"); assertEquals(1, n[0])
    }

    @Test fun `losing some other network is ignored`() {
        val (e, r, n) = rig("wifi-1"); r.start(); val l = e.listener!!; r.advance(10_000)
        l.onLost("cell-9"); l.onAvailable("wifi-1")
        assertEquals(0, n[0])
    }
}
