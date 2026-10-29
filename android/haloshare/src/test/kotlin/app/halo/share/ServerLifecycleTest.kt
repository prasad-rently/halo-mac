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
}
