package app.halo.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.file.Files

class ServerLifecycleTest {
    private fun server() = HaloShareServer(DeviceIdentity("R", DeviceIdentity.randomFingerprint(), deviceType = "desktop"), Files.createTempDirectory("hsk-lc").toFile(), { ConsentDecision.DECLINE })
    private fun reachable(port: Int) = try { Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500); true } } catch (e: java.io.IOException) { false }

    @Test fun `stop closes the port, and a stopped server can never be started again`() {
        val s = server(); val port = s.start(0)
        assertTrue(waitUntil(2000) { reachable(port) })
        s.stop()
        assertTrue("port closed after stop", waitUntil(2000) { !reachable(port) })
        assertThrows(IllegalStateException::class.java) { s.start(0) }       // a start() that loses a race with stop() must not reopen the port
        s.stop()                                                            // idempotent
    }

    @Test fun `stop before start wins - nothing listens afterwards`() {
        val s = server(); s.stop()
        assertThrows(IllegalStateException::class.java) { s.start(0) }
        assertEquals(0, s.port)
    }

    @Test fun `start racing stop never leaves a listener behind`() {
        repeat(40) {
            val s = server()
            val probe = java.net.ServerSocket(0).use { it.localPort }        // a free port we can test afterwards
            val t = Thread { runCatching { s.start(probe) } }
            t.start(); s.stop(); t.join(5000)
            // Whatever the interleaving, once stop() has returned and start() has finished, the port must be closed.
            assertTrue("iteration $it left $probe open", waitUntil(2000) { !reachable(probe) })
        }
    }

    // ── restart race with the old socket's release (follow-up item 7) ─────────────────────────

    @Test fun `a restart whose bind arrives before the old socket is released waits for it instead of failing`() {
        val holder = java.net.ServerSocket(0); val port = holder.localPort          // stands in for the old listener, still holding the port
        val s = server()
        val result = java.util.concurrent.atomic.AtomicReference<Any?>()
        val t = Thread { result.set(try { s.start(port, bindRetryMs = 5_000) } catch (e: Throwable) { e }) }
        t.start()
        Thread.sleep(300)                                                           // the new bind is now failing and retrying
        assertTrue("still waiting, not failed", result.get() == null)
        holder.close()                                                              // the old socket finally goes away
        t.join(5_000)
        assertEquals("bound once the port was free", port, result.get())
        assertTrue(waitUntil(2000) { reachable(port) })
        s.stop()
    }

    @Test fun `without a retry window a held port still fails at once, and the failure leaves the server startable`() {
        val holder = java.net.ServerSocket(0); val port = holder.localPort
        val s = server()
        val t0 = System.nanoTime()
        assertThrows(java.net.BindException::class.java) { s.start(port) }
        assertTrue("failed immediately", (System.nanoTime() - t0) < 1_000_000_000L)
        holder.close()
        assertEquals(port, s.start(port))                                           // running flag was reset: a later attempt works
        s.stop()
    }

    @Test fun `the retry gives up after its window and reports the bind failure`() {
        val holder = java.net.ServerSocket(0); val port = holder.localPort
        val s = server()
        val t0 = System.nanoTime()
        assertThrows(java.net.BindException::class.java) { s.start(port, bindRetryMs = 300) }
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("waited about the window, was $ms ms", ms in 250..3000)
        holder.close(); s.stop()
    }

    @Test fun `stop during the retry wait ends it at once and opens nothing`() {
        val holder = java.net.ServerSocket(0); val port = holder.localPort
        val s = server()
        val failed = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val t = Thread { try { s.start(port, bindRetryMs = 30_000) } catch (e: Throwable) { failed.set(e) } }
        t.start(); Thread.sleep(150)
        s.stop(); t.join(3_000)
        assertTrue("start returned promptly after stop", !t.isAlive)
        assertTrue(failed.get() != null)
        holder.close()
        assertTrue("nothing is listening on the freed port", waitUntil(1000) { !reachable(port) })
    }

    @Test fun `repeated stop-then-start restarts on the same fixed port always end up listening`() {
        val port = java.net.ServerSocket(0).use { it.localPort }
        var s = server(); s.start(port, bindRetryMs = 3_000)
        repeat(15) {
            s.stop()
            s = server(); s.start(port, bindRetryMs = 3_000)
            assertTrue("restart $it is listening", waitUntil(2000) { reachable(port) })
        }
        s.stop()
    }
}
