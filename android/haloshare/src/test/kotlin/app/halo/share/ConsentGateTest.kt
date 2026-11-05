package app.halo.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class ConsentGateTest {
    private fun offer(addr: String = "10.0.0.2") =
        IncomingOffer(DeviceInfo(alias = "Mac", fingerprint = "f-$addr"), addr, listOf(FileDescriptor("1", "secret-name.pdf", 10, "application/pdf")))

    private class Probe {
        val pending = AtomicReference<IncomingOffer?>(null); val shown = CopyOnWriteArrayList<Long>(); val cleared = AtomicInteger()
        val everPending = AtomicInteger()
    }

    private fun ConsentGate.askAsync(o: IncomingOffer, p: Probe, visible: () -> Boolean, out: AtomicReference<ConsentDecision?>, done: CountDownLatch) =
        Thread {
            out.set(ask(o, visible, { x -> p.pending.set(x); if (x != null) p.everPending.incrementAndGet() }, { id -> p.shown.add(id) }, { p.cleared.incrementAndGet() }))
            done.countDown()
        }.apply { isDaemon = true; start() }

    @Test fun `concurrent offers - exactly one prompt opens, the rest are declined at once and nobody is left blocked`() {
        val gate = ConsentGate(backgroundTimeoutMs = 60_000, pollMs = 20)
        val p = Probe(); val n = 12
        val start = CountDownLatch(1); val finished = CountDownLatch(n)
        val results = CopyOnWriteArrayList<ConsentDecision>()
        val pool = Executors.newFixedThreadPool(n)
        repeat(n) { i -> pool.execute { start.await(); results.add(gate.ask(offer("10.0.0.$i"), { true }, { x -> p.pending.set(x); if (x != null) p.everPending.incrementAndGet() }, {}, {})); finished.countDown() } }
        start.countDown()
        // 11 of the 12 return without anyone answering
        assertTrue(waitUntil(5_000) { results.size == n - 1 })
        assertEquals("only one prompt was ever opened", 1, p.everPending.get())
        assertNotNull(p.pending.get())
        assertTrue(gate.resolve(ConsentDecision.ACCEPT))
        assertTrue("the opener returns", finished.await(5, TimeUnit.SECONDS))
        assertEquals(1, results.count { it == ConsentDecision.ACCEPT }); assertEquals(n - 1, results.count { it == ConsentDecision.DECLINE })
        assertNull(p.pending.get()); assertFalse(gate.isPending)
        pool.shutdownNow()
    }

    @Test fun `unanswered in the background is declined after the timeout, the notification raised once and taken down`() {
        val gate = ConsentGate(backgroundTimeoutMs = 250, pollMs = 20); val p = Probe()
        val out = AtomicReference<ConsentDecision?>(null); val done = CountDownLatch(1)
        gate.askAsync(offer(), p, { false }, out, done)
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertEquals(ConsentDecision.DECLINE, out.get())
        assertEquals(1, p.shown.size); assertTrue(p.cleared.get() >= 1); assertNull(p.pending.get()); assertFalse(gate.isPending)
    }

    @Test fun `on screen it waits as long as the person takes - the background clock does not run`() {
        val gate = ConsentGate(backgroundTimeoutMs = 100, pollMs = 20); val p = Probe()
        val out = AtomicReference<ConsentDecision?>(null); val done = CountDownLatch(1)
        gate.askAsync(offer(), p, { true }, out, done)
        Thread.sleep(500)
        assertEquals("still waiting", 1L, done.count); assertTrue(p.shown.isEmpty())
        gate.resolve(ConsentDecision.ACCEPT)
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertEquals(ConsentDecision.ACCEPT, out.get())
    }

    @Test fun `a prompt left open when the app goes away starts the background clock then, instead of blocking every later offer`() {
        val visible = java.util.concurrent.atomic.AtomicBoolean(true)
        val gate = ConsentGate(backgroundTimeoutMs = 250, pollMs = 20); val p = Probe()
        val out = AtomicReference<ConsentDecision?>(null); val done = CountDownLatch(1)
        gate.askAsync(offer(), p, { visible.get() }, out, done)
        Thread.sleep(300); assertEquals("not timed out while visible", 1L, done.count)
        visible.set(false)
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertEquals(ConsentDecision.DECLINE, out.get())
        assertEquals("the notification was raised when the app left", 1, p.shown.size)
    }

    @Test fun `a declined or unanswered sender is cooled off - a LAN flood does not re-raise the prompt`() {
        var now = 0L
        val gate = ConsentGate(backgroundTimeoutMs = 60_000, coolOffMs = 30_000, pollMs = 10, clock = { now })
        val p = Probe(); val out = AtomicReference<ConsentDecision?>(null); val done = CountDownLatch(1)
        gate.askAsync(offer("10.0.0.9"), p, { true }, out, done)
        assertTrue(waitUntil { gate.isPending }); gate.resolve(ConsentDecision.DECLINE)
        assertTrue(done.await(5, TimeUnit.SECONDS))
        val before = p.everPending.get()
        assertEquals(ConsentDecision.DECLINE, gate.ask(offer("10.0.0.9"), { true }, { if (it != null) p.everPending.incrementAndGet() }, {}, {}))
        assertEquals("no prompt for the cooled-off sender", before, p.everPending.get())
        now += 31_000                                                // the cool-off expires
        val out2 = AtomicReference<ConsentDecision?>(null); val done2 = CountDownLatch(1)
        gate.askAsync(offer("10.0.0.9"), p, { true }, out2, done2)
        assertTrue("prompts again after the cool-off", waitUntil { gate.isPending }); gate.resolve(ConsentDecision.ACCEPT)
        assertTrue(done2.await(5, TimeUnit.SECONDS)); assertEquals(ConsentDecision.ACCEPT, out2.get())
        // an accepted sender is not penalised: asking again right away prompts
        val out3 = AtomicReference<ConsentDecision?>(null); val done3 = CountDownLatch(1)
        gate.askAsync(offer("10.0.0.9"), p, { true }, out3, done3)
        assertTrue(waitUntil { gate.isPending }); gate.resolve(ConsentDecision.DECLINE); assertTrue(done3.await(5, TimeUnit.SECONDS))
    }

    @Test fun `a stale notification tap cannot answer a newer offer`() {
        val gate = ConsentGate(backgroundTimeoutMs = 60_000, pollMs = 10, coolOffMs = 0)
        val p = Probe(); val o1 = AtomicReference<ConsentDecision?>(null); val d1 = CountDownLatch(1)
        gate.askAsync(offer("10.0.0.1"), p, { false }, o1, d1)
        assertTrue(waitUntil { p.shown.size == 1 }); val firstId = p.shown[0]
        gate.resolve(ConsentDecision.DECLINE); assertTrue(d1.await(5, TimeUnit.SECONDS))
        val o2 = AtomicReference<ConsentDecision?>(null); val d2 = CountDownLatch(1)
        gate.askAsync(offer("10.0.0.2"), p, { false }, o2, d2)
        assertTrue(waitUntil { p.shown.size == 2 }); val secondId = p.shown[1]
        assertTrue("ids differ", firstId != secondId)
        assertFalse("the old notification's Accept does nothing", gate.resolve(ConsentDecision.ACCEPT, firstId))
        assertEquals(1L, d2.count)
        assertTrue(gate.resolve(ConsentDecision.ACCEPT, secondId)); assertTrue(d2.await(5, TimeUnit.SECONDS)); assertEquals(ConsentDecision.ACCEPT, o2.get())
        assertFalse("nothing pending: a late tap is a no-op", gate.resolve(ConsentDecision.ACCEPT, secondId))
    }

    // ── a tap that arrives as the prompt times out (follow-up item 5) ───────────────────────────

    @Test fun `an Accept that lands as the background timeout fires is never reported applied while the decision is DECLINE`() {
        // Deterministic version of the window: the tap lands inside the very clock read that decides the timeout.
        repeat(2) { variant ->
            val gateRef = AtomicReference<ConsentGate>(); val shownId = AtomicReference<Long?>(null)
            val applied = AtomicReference<Boolean?>(null)
            var now = 0L
            val clock = { val t = now; now += 100
                if (t >= 300 && applied.get() == null && shownId.get() != null) applied.set(gateRef.get().resolve(ConsentDecision.ACCEPT, shownId.get()))   // the tap, mid-decision
                t }
            val gate = ConsentGate(backgroundTimeoutMs = 300, coolOffMs = 0, pollMs = 5, clock = clock); gateRef.set(gate)
            val decision = gate.ask(offer("10.1.1.$variant"), { false }, { }, { id -> shownId.set(id) }, { })
            assertTrue("the tap was delivered", applied.get() != null)
            assertEquals("resolve() and the returned decision must agree (applied=${applied.get()}, decision=$decision)", applied.get() == true, decision == ConsentDecision.ACCEPT)
        }
    }

    @Test fun `an Accept after the prompt has already timed out reports expired, not applied`() {
        val shown = AtomicReference<Long?>(null)
        val gate = ConsentGate(backgroundTimeoutMs = 120, coolOffMs = 0, pollMs = 10)
        assertEquals(ConsentDecision.DECLINE, gate.ask(offer(), { false }, { }, { id -> shown.set(id) }, { }))
        assertFalse("the late Accept is expired", gate.resolve(ConsentDecision.ACCEPT, shown.get()))
        assertFalse("with or without the id", gate.resolve(ConsentDecision.ACCEPT))
        assertFalse(gate.isPending)
    }

    @Test fun `a prompt answered in time still returns exactly what was tapped`() {
        val gate = ConsentGate(backgroundTimeoutMs = 60_000, coolOffMs = 0, pollMs = 10); val p = Probe()
        for (d in ConsentDecision.values()) {
            val out = AtomicReference<ConsentDecision?>(null); val done = CountDownLatch(1)
            gate.askAsync(offer(), p, { true }, out, done)
            assertTrue(waitUntil { gate.isPending })
            assertTrue("applied", gate.resolve(d)); assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(d, out.get())
        }
    }
}
