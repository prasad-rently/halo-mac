package app.halo.tools

import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Engine logic runs against a scripted transport + fake clock (exact arithmetic); the real [HttpSpeedTransport] runs against
 * a loopback HTTP server. NOTHING here touches the internet — the Mbps a real connection gives is NOT verified by these tests.
 */
class SpeedTestTest {
    // ── fake transport / clock ─────────────────────────────────────────────────────────────────

    private class FakeClock : SpeedClock {
        var now = 0L; val sleeps = mutableListOf<Long>()
        override fun nanos() = now
        override fun sleepMs(ms: Long) { sleeps += ms; now += ms * 1_000_000 }
        fun advanceMs(ms: Long) { now += ms * 1_000_000 }
    }

    private class Scripted(val clock: FakeClock) : SpeedTransport {
        val calls = mutableListOf<String>()
        var pingMs: MutableList<Long?> = mutableListOf()          // null = failure; consumed in order (first one is the warm-up)
        var downloadMs = 2_000L; var downloadBytes = 25_000_000L; var downloadError: Exception? = null; var chunks = 10
        var uploadMs = 1_000L; var uploadError: Exception? = null
        override fun head(url: String, timeoutMs: Int): Boolean {
            calls += "head"
            val next = if (pingMs.isEmpty()) 10L else pingMs.removeAt(0)
            if (next == null) throw java.io.IOException("x")
            clock.advanceMs(next); return true
        }
        override fun download(url: String, chunkBytes: Int, timeoutMs: Int, onBytes: (Int) -> Boolean): Long {
            calls += "download"
            downloadError?.let { throw it }
            var sent = 0L
            for (i in 1..chunks) {
                clock.advanceMs(downloadMs / chunks)
                val n = (downloadBytes / chunks).toInt(); sent += n
                if (!onBytes(n)) break
            }
            return sent
        }
        override fun upload(url: String, bytes: Int, chunkBytes: Int, timeoutMs: Int, cancelled: () -> Boolean) {
            calls += "upload"; uploadError?.let { throw it }; clock.advanceMs(uploadMs)
        }
    }

    private fun engine(t: Scripted, c: FakeClock, plan: SpeedPlan = SpeedPlan()) = SpeedTestEngine(t, SpeedEndpoints(), plan, c)

    // ── the desktop's numbers ──────────────────────────────────────────────────────────────────

    @Test fun defaultsAreTheDesktopsHostsAndSizes() {
        assertEquals("https://speed.cloudflare.com/__down?bytes=25000000", SpeedEndpoints().download)
        assertEquals("https://speed.cloudflare.com/__up", SpeedEndpoints().upload)
        assertEquals("https://1.1.1.1", SpeedEndpoints().ping)
        val p = SpeedPlan()
        assertEquals(25_000_000L, p.downloadBytes); assertEquals(5_000_000, p.uploadBytes); assertEquals(10, p.pingAttempts)
        assertEquals(150L, p.pingGapMs); assertEquals(65_536, p.chunkBytes); assertEquals(30_000_000L, p.estimatedDataBytes)
    }

    @Test fun throughputIsDecimalMegabitsOverWallClock() {
        val c = FakeClock(); val t = Scripted(c)       // 25 MB in 2 s = 100 Mbps; 5 MB in 1 s = 40 Mbps
        val r = engine(t, c).run()
        assertEquals(100.0, r.downloadMbps!!, 1e-9); assertEquals(40.0, r.uploadMbps!!, 1e-9)
        assertEquals(25_000_000L, r.downloadedBytes); assertEquals(5_000_000L, r.uploadedBytes); assertTrue(r.problems.isEmpty()); assertFalse(r.cancelled)
    }

    @Test fun warmUpThenTenPingsThenDownloadThenUpload_withGapsBetweenPingsOnly() {
        val c = FakeClock(); val t = Scripted(c)
        engine(t, c).run()
        assertEquals(List(11) { "head" } + listOf("download", "upload"), t.calls)    // 1 warm-up + 10 timed
        assertEquals(List(9) { 150L }, c.sleeps)
    }

    @Test fun latencyIsTheMedianOfSuccessfulPings_warmUpExcluded() {
        val c = FakeClock(); val t = Scripted(c)
        // warm-up 5000 (must not count), then 10 samples with two outliers and one failure
        t.pingMs = mutableListOf(5000, 10, 12, 900, 11, null, 13, 10, 11, 700, 12)
        assertEquals(12.0, engine(t, c).run().latencyMs!!, 1e-9)          // sorted 10,10,11,11,12,12,13,700,900 -> 12
    }

    @Test fun medianOfEvenCountIsTheMeanOfTheMiddleTwo() {
        assertEquals(15.0, SpeedTestEngine.median(listOf(10.0, 20.0, 30.0, 5.0))!!, 1e-9)
        assertEquals(20.0, SpeedTestEngine.median(listOf(30.0, 10.0, 20.0))!!, 1e-9)
        assertNull(SpeedTestEngine.median(emptyList()))
    }

    @Test fun allPingsFailingGivesNullLatencyNotZero_andTheRestStillRuns() {
        val c = FakeClock(); val t = Scripted(c); t.pingMs = MutableList(11) { null }
        val r = engine(t, c).run()
        assertNull(r.latencyMs); assertNotNull(r.downloadMbps); assertTrue(r.problems.any { it.contains("latency") })
    }

    @Test fun failedDownloadDoesNotThrowAndUploadStillMeasured() {
        val c = FakeClock(); val t = Scripted(c); t.downloadError = HttpStatusException(503)
        val r = engine(t, c).run()
        assertNull(r.downloadMbps); assertNotNull(r.uploadMbps); assertNotNull(r.latencyMs)
        assertEquals(listOf("Download failed: the server answered 503"), r.problems)
    }

    @Test fun failedUploadKeepsTheDownloadFigure() {
        val c = FakeClock(); val t = Scripted(c); t.uploadError = java.net.SocketTimeoutException("secret.example:443")
        val r = engine(t, c).run()
        assertNotNull(r.downloadMbps); assertNull(r.uploadMbps); assertEquals(listOf("Upload failed: timed out"), r.problems)
        assertFalse("problem text must not carry hostnames from exception messages", r.problems.any { it.contains("secret.example") })
    }

    @Test fun shortDownloadIsMeasuredFromWhatArrivedAndSaidSo() {
        val c = FakeClock(); val t = Scripted(c); t.downloadBytes = 10_000_000; t.downloadMs = 1_000
        val r = engine(t, c).run()
        assertEquals(80.0, r.downloadMbps!!, 1e-9); assertTrue(r.problems.single().contains("shorter run"))
    }

    @Test fun zeroBytesIsNullNotInfinity() {
        val c = FakeClock(); val t = Scripted(c); t.downloadBytes = 0
        assertNull(engine(t, c).run().downloadMbps)
    }

    @Test fun cancelDuringDownloadStopsEverythingAfterIt() {
        val c = FakeClock(); val t = Scripted(c); var polls = 0
        val r = engine(t, c).run(cancelled = { ++polls > 14 })        // trips part-way through the download chunks
        assertTrue(r.cancelled); assertNull(r.uploadMbps); assertFalse("upload must not start after cancel", t.calls.contains("upload"))
        assertNull(r.downloadMbps)
    }

    @Test fun cancelBeforeStartDoesNoNetwork() {
        val c = FakeClock(); val t = Scripted(c)
        val r = engine(t, c).run(cancelled = { true })
        assertTrue(r.cancelled); assertEquals(listOf("head"), t.calls)    // only the (harmless) warm-up
    }

    @Test fun progressIsReportedInOrderAndEndsWithDone() {
        val c = FakeClock(); val t = Scripted(c); val seen = mutableListOf<SpeedProgress>()
        val r = engine(t, c).run(onProgress = { seen += it })
        assertEquals(10, seen.filterIsInstance<SpeedProgress.Pinging>().size)
        val dl = seen.filterIsInstance<SpeedProgress.Downloading>()
        assertTrue(dl.isNotEmpty() && dl.zipWithNext().all { (a, b) -> b.fraction >= a.fraction } && dl.last().fraction == 1.0)
        assertEquals(SpeedProgress.Done(r), seen.last()); assertTrue(seen.contains(SpeedProgress.Uploading))
    }

    // ── the real transport against a loopback server ───────────────────────────────────────────

    private lateinit var server: HttpServer
    private val uploaded = AtomicLong(); private val nonZeroUpload = AtomicBoolean(false); private val headSeen = AtomicLong()
    private var base = ""

    @Before fun startServer() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = Executors.newCachedThreadPool()
        server.createContext("/ping") { ex -> headSeen.incrementAndGet(); ex.sendResponseHeaders(204, -1); ex.close() }
        server.createContext("/redirect") { ex -> ex.responseHeaders.add("Location", "http://unreachable.invalid/"); ex.sendResponseHeaders(301, -1); ex.close() }
        server.createContext("/down") { ex ->
            val n = Regex("bytes=(\\d+)").find(ex.requestURI.query.orEmpty())!!.groupValues[1].toLong()
            ex.sendResponseHeaders(200, n)
            val chunk = ByteArray(8192); var left = n
            ex.responseBody.use { o -> while (left > 0) { val k = minOf(left, chunk.size.toLong()).toInt(); o.write(chunk, 0, k); left -= k } }
        }
        server.createContext("/slow") { ex ->
            ex.sendResponseHeaders(200, 200_000); val chunk = ByteArray(10_000)
            ex.responseBody.use { o -> repeat(20) { Thread.sleep(40); o.write(chunk); o.flush() } }       // ~800 ms for 200 KB
        }
        server.createContext("/up") { ex ->
            val buf = ByteArray(8192); var total = 0L
            ex.requestBody.use { s -> while (true) { val n = s.read(buf); if (n < 0) break; total += n; for (i in 0 until n) if (buf[i] != 0.toByte()) nonZeroUpload.set(true) } }
            uploaded.addAndGet(total); ex.sendResponseHeaders(200, -1); ex.close()
        }
        server.createContext("/fail") { ex -> ex.sendResponseHeaders(500, -1); ex.close() }
        server.start(); base = "http://127.0.0.1:${server.address.port}"
    }
    @After fun stopServer() { server.stop(0) }

    private val transport get() = HttpSpeedTransport(allowCleartext = true)
    private val small = SpeedPlan(pingAttempts = 3, pingGapMs = 1, downloadBytes = 1_000_000, uploadBytes = 300_000)

    @Test fun realTransportEndToEndAgainstLoopback() {
        val e = SpeedEndpoints("$base/ping", "$base/down?bytes=1000000", "$base/up")
        val r = SpeedTestEngine(transport, e, small).run()
        assertEquals(1_000_000L, r.downloadedBytes); assertEquals(300_000L, uploaded.get()); assertFalse("upload payload is zero bytes, as on the desktop", nonZeroUpload.get())
        assertTrue(r.problems.toString(), r.problems.isEmpty()); assertTrue(r.downloadMbps!! > 0 && r.uploadMbps!! > 0 && r.latencyMs!! >= 0)
        assertEquals("1 warm-up + 3 timed HEADs", 4L, headSeen.get())
    }

    @Test fun measuredRateReflectsServerTime() {
        val e = SpeedEndpoints("$base/ping", "$base/slow", "$base/up")
        val r = SpeedTestEngine(transport, e, small.copy(downloadBytes = 200_000)).run()
        // 200 KB took >= ~800 ms on the server side, so it cannot have been faster than 2 Mbps; a broken clock or byte count would blow past that.
        assertTrue("got ${r.downloadMbps}", r.downloadMbps!! in 0.5..2.2)
    }

    @Test fun serverErrorsBecomeProblemsNotCrashes() {
        val e = SpeedEndpoints("$base/ping", "$base/fail", "$base/fail")
        val r = SpeedTestEngine(transport, e, small).run()
        assertNull(r.downloadMbps); assertNull(r.uploadMbps); assertNotNull(r.latencyMs)
        assertEquals(listOf("Download failed: the server answered 500", "Upload failed: the server answered 500"), r.problems)
    }

    @Test fun headDoesNotFollowRedirects() {
        assertTrue(transport.head("$base/redirect", 2000))       // would throw UnknownHost / hang if it followed the 301
    }

    @Test fun cleartextIsRefusedUnlessExplicitlyAllowed() {
        val real = HttpSpeedTransport()
        val e = SpeedEndpoints("$base/ping", "$base/down?bytes=10", "$base/up")
        val r = SpeedTestEngine(real, e, small).run()
        assertNull(r.latencyMs); assertNull(r.downloadMbps); assertNull(r.uploadMbps)
        assertEquals("nothing may be sent over cleartext", 0L, headSeen.get() + uploaded.get())
    }

    @Test fun cancelAbortsARealDownloadPromptly() {
        val e = SpeedEndpoints("$base/ping", "$base/slow", "$base/up")
        val stop = AtomicBoolean(false)
        val t0 = System.nanoTime()
        val r = SpeedTestEngine(transport, e, small.copy(downloadBytes = 200_000)).run(cancelled = { stop.get() }, onProgress = { if (it is SpeedProgress.Downloading) stop.set(true) })
        assertTrue(r.cancelled); assertEquals("no upload after cancel", 0L, uploaded.get())
        assertTrue("took ${(System.nanoTime() - t0) / 1_000_000} ms", (System.nanoTime() - t0) / 1_000_000 < 600)
    }
}
