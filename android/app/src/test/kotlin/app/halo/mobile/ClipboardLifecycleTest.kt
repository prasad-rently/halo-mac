package app.halo.mobile

import app.halo.mobile.cloud.ClipboardBackend
import app.halo.mobile.cloud.ClipboardLifecycle
import app.halo.mobile.cloud.ClipboardOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The foreground service may stop only the clipboard stream it started. The stream is shared with the accessibility service and gated on the user's own switch. */
class ClipboardLifecycleTest {
    private class Fake : ClipboardBackend {
        var streamOpen = false; var listening = false; var starts = 0; var stops = 0
        override fun startStream() { streamOpen = true; starts++ }
        override fun stopStream() { streamOpen = false; stops++ }
        override fun startListening() { listening = true }
        override fun stopListening() { listening = false }
    }

    @Test fun `a stream the service started alone stops when the service lets go`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.acquire(ClipboardOwner.SERVICE); assertTrue(f.streamOpen && f.listening)
        l.release(ClipboardOwner.SERVICE)
        assertFalse(f.streamOpen); assertFalse(f.listening); assertFalse(l.isRunning)
    }

    @Test fun `a stream the user's switch started keeps running when the service is destroyed`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.acquire(ClipboardOwner.USER)
        l.acquire(ClipboardOwner.SERVICE)                                   // the service also asked; it did not start it
        val stopsBefore = f.stops
        l.release(ClipboardOwner.SERVICE)
        assertTrue("still streaming for the user", f.streamOpen && f.listening && l.isRunning)
        assertEquals("the service never called stop", stopsBefore, f.stops)
    }

    @Test fun `a stream the accessibility service started keeps running when the foreground service is destroyed`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.acquire(ClipboardOwner.ACCESSIBILITY); l.acquire(ClipboardOwner.SERVICE)
        l.release(ClipboardOwner.SERVICE)
        assertTrue(f.streamOpen && l.isRunning); assertEquals(setOf(ClipboardOwner.ACCESSIBILITY), l.owners())
    }

    @Test fun `the service started it first, then the user joined - the service going away must not take the user's stream with it`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.acquire(ClipboardOwner.SERVICE); l.acquire(ClipboardOwner.USER)
        l.release(ClipboardOwner.SERVICE)
        assertTrue(f.streamOpen)
        l.release(ClipboardOwner.USER)
        assertFalse("last owner out closes it", f.streamOpen)
    }

    @Test fun `releasing a claim never made does nothing`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.release(ClipboardOwner.SERVICE)
        l.acquire(ClipboardOwner.USER); val stops = f.stops
        l.release(ClipboardOwner.SERVICE)
        assertEquals(stops, f.stops); assertTrue(f.streamOpen)
    }

    @Test fun `the user's setting turning off stops it for everyone`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.acquire(ClipboardOwner.USER); l.acquire(ClipboardOwner.SERVICE); l.acquire(ClipboardOwner.ACCESSIBILITY)
        l.stopAll()
        assertFalse(f.streamOpen); assertFalse(f.listening); assertFalse(l.isRunning); assertTrue(l.owners().isEmpty())
    }

    @Test fun `refresh re-opens the stream for current owners and does nothing when nobody holds it`() {
        val f = Fake(); val l = ClipboardLifecycle(f)
        l.refresh(); assertEquals(0, f.starts)
        l.acquire(ClipboardOwner.SERVICE); val s0 = f.starts
        l.refresh(); assertEquals(s0 + 1, f.starts)
        l.release(ClipboardOwner.SERVICE); val s1 = f.starts
        l.refresh(); assertEquals("released: a network change must not reopen it", s1, f.starts)
    }
}
