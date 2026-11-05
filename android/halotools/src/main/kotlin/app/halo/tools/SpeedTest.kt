package app.halo.tools

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * The hosts and sizes are the desktop's `SpeedTestService` (P3-06), unchanged: Cloudflare's public speed endpoint for
 * download/upload and 1.1.1.1 for latency. No new third party is introduced for the phone.
 */
data class SpeedEndpoints(
    val ping: String = "https://1.1.1.1",
    val download: String = "https://speed.cloudflare.com/__down?bytes=25000000",
    val upload: String = "https://speed.cloudflare.com/__up",
)

data class SpeedPlan(
    val pingAttempts: Int = 10,
    val pingGapMs: Long = 150,
    val pingTimeoutMs: Int = 4_000,
    val downloadBytes: Long = 25_000_000,
    val uploadBytes: Int = 5_000_000,
    val requestTimeoutMs: Int = 60_000,
    val chunkBytes: Int = 65_536,
) {
    /** What one run moves over the connection, for the "this uses about N MB" notice (payloads only; TLS/HTTP overhead is small beside it). */
    val estimatedDataBytes: Long get() = downloadBytes + uploadBytes
}

/** The desktop's `SpeedResult`, except that a stage that could not be measured is `null` (the desktop's 0 reads as "0 Mbps"). */
data class SpeedResult(
    val latencyMs: Double?, val downloadMbps: Double?, val uploadMbps: Double?,
    val downloadedBytes: Long, val uploadedBytes: Long,
    val problems: List<String>, val cancelled: Boolean,
)

sealed interface SpeedProgress {
    data class Pinging(val attempt: Int, val of: Int) : SpeedProgress
    data class Downloading(val fraction: Double, val mbps: Double) : SpeedProgress
    data object Uploading : SpeedProgress
    data class Done(val result: SpeedResult) : SpeedProgress
}

/** The three network operations the test needs, so the engine can be tested without a network (and the real one against a local server). */
interface SpeedTransport {
    /** One HEAD request; true if the server answered at all (any status). Throws or returns false on timeout/failure. */
    fun head(url: String, timeoutMs: Int): Boolean
    /** GET [url], reading to the end in [chunkBytes] reads; [onBytes] gets each read's size and returns false to abort. Returns total bytes read. */
    fun download(url: String, chunkBytes: Int, timeoutMs: Int, onBytes: (Int) -> Boolean): Long
    /** POST [bytes] zero bytes and read the response. Returns when the server has answered. */
    fun upload(url: String, bytes: Int, chunkBytes: Int, timeoutMs: Int, cancelled: () -> Boolean)
}

interface SpeedClock { fun nanos(): Long; fun sleepMs(ms: Long) }
object SystemSpeedClock : SpeedClock {
    override fun nanos() = System.nanoTime()
    override fun sleepMs(ms: Long) { try { Thread.sleep(ms) } catch (_: InterruptedException) { Thread.currentThread().interrupt() } }
}

/** Port of the desktop flow: warm-up, N pings -> median, download, upload. Blocking; run it off the main thread. */
class SpeedTestEngine(
    private val transport: SpeedTransport,
    private val endpoints: SpeedEndpoints = SpeedEndpoints(),
    private val plan: SpeedPlan = SpeedPlan(),
    private val clock: SpeedClock = SystemSpeedClock,
) {
    fun run(cancelled: () -> Boolean = { false }, onProgress: (SpeedProgress) -> Unit = {}): SpeedResult {
        val problems = ArrayList<String>()
        fun finish(lat: Double?, down: Double?, up: Double?, dBytes: Long, uBytes: Long, wasCancelled: Boolean) =
            SpeedResult(lat, down, up, dBytes, uBytes, problems, wasCancelled).also { onProgress(SpeedProgress.Done(it)) }

        // 1. Warm-up — a throwaway request so DNS / TCP / TLS setup isn't charged to the first ping. Failure is fine.
        try { transport.head(endpoints.ping, plan.pingTimeoutMs) } catch (_: Exception) {}

        // 2. Latency: N HEADs, gap between, median.
        val rtts = ArrayList<Double>()
        for (i in 1..plan.pingAttempts) {
            if (cancelled()) return finish(median(rtts), null, null, 0, 0, true)
            onProgress(SpeedProgress.Pinging(i, plan.pingAttempts))
            val t0 = clock.nanos()
            val ok = try { transport.head(endpoints.ping, plan.pingTimeoutMs) } catch (_: Exception) { false }
            if (ok) rtts += (clock.nanos() - t0) / 1e6
            if (i < plan.pingAttempts) clock.sleepMs(plan.pingGapMs)
        }
        val latency = median(rtts)
        if (latency == null) problems += "Couldn't reach the latency server."

        // 3. Download.
        if (cancelled()) return finish(latency, null, null, 0, 0, true)
        var downBytes = 0L; var downMbps: Double? = null
        kotlin.run {
            val t0 = clock.nanos()
            var total = 0L
            try {
                transport.download(endpoints.download, plan.chunkBytes, plan.requestTimeoutMs) { n ->
                    total += n
                    val secs = (clock.nanos() - t0) / 1e9
                    if (secs > 0) onProgress(SpeedProgress.Downloading(minOf(total.toDouble() / plan.downloadBytes, 1.0), mbps(total, secs)))
                    !cancelled()
                }
            } catch (e: Exception) { problems += "Download failed: ${describe(e)}" }
            downBytes = total
            val secs = (clock.nanos() - t0) / 1e9
            if (cancelled()) return finish(latency, null, null, downBytes, 0, true)
            if (total > 0 && secs > 0) {
                downMbps = mbps(total, secs)
                if (total < plan.downloadBytes && problems.none { it.startsWith("Download failed") }) problems += "The server sent ${total / 1000} KB of the ${plan.downloadBytes / 1000} KB asked for, so the download figure is from a shorter run."
            }
        }

        // 4. Upload — independent of the download: a failed download still leaves a usable upload figure.
        if (cancelled()) return finish(latency, downMbps, null, downBytes, 0, true)
        var upMbps: Double? = null; var upBytes = 0L
        kotlin.run {
            onProgress(SpeedProgress.Uploading)
            val t0 = clock.nanos()
            try {
                transport.upload(endpoints.upload, plan.uploadBytes, plan.chunkBytes, plan.requestTimeoutMs, cancelled)
                val secs = (clock.nanos() - t0) / 1e9
                if (!cancelled()) { upBytes = plan.uploadBytes.toLong(); if (secs > 0) upMbps = mbps(upBytes, secs) }
            } catch (e: Exception) { if (!cancelled()) problems += "Upload failed: ${describe(e)}" }
        }
        return finish(latency, downMbps, upMbps, downBytes, upBytes, cancelled())
    }

    companion object {
        /** Megabits per second, decimal (1 Mb = 10^6 bits) — the desktop's formula. */
        fun mbps(bytes: Long, seconds: Double): Double = bytes * 8.0 / seconds / 1_000_000.0

        /** Median of the successful samples; the mean of the two middle ones when there is an even number (as the desktop does). Null when there are none. */
        fun median(samples: List<Double>): Double? {
            if (samples.isEmpty()) return null
            val s = samples.sorted(); val mid = s.size / 2
            return if (s.size % 2 == 0) (s[mid - 1] + s[mid]) / 2 else s[mid]
        }

        // Class name + HTTP status only. Exception messages can carry the URL and the resolved address.
        private fun describe(e: Exception): String = when (e) {
            is java.net.SocketTimeoutException -> "timed out"
            is java.net.UnknownHostException -> "couldn't find the server (offline?)"
            is HttpStatusException -> "the server answered ${e.status}"
            is IOException -> "connection problem"
            else -> e.javaClass.simpleName
        }
    }
}

class HttpStatusException(val status: Int) : IOException("HTTP $status")

/**
 * The real transport, on java.net.HttpURLConnection (available on Android and the JVM alike). HTTPS only unless
 * [allowCleartext] — which exists for the loopback server in the tests and is never set by the app.
 */
class HttpSpeedTransport(private val allowCleartext: Boolean = false, private val userAgent: String = "Halo-Mobile/1.0") : SpeedTransport {
    private companion object { const val MAX_DOWNLOAD_BYTES = 40_000_000L }

    private fun open(url: String, timeoutMs: Int): HttpURLConnection {
        require(url.startsWith("https://") || (allowCleartext && url.startsWith("http://"))) { "speed test endpoints must be https" }
        return (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = timeoutMs; readTimeout = timeoutMs; useCaches = false
            setRequestProperty("User-Agent", userAgent); setRequestProperty("Cache-Control", "no-cache")
            // Without this Android's HttpURLConnection silently asks for gzip and inflates the body, so a compressible response
            // would be counted at its inflated size and the figure would be wrong. Cloudflare's __down is incompressible today; this keeps it true.
            setRequestProperty("Accept-Encoding", "identity")
        }
    }

    override fun head(url: String, timeoutMs: Int): Boolean {
        val c = open(url, timeoutMs)
        try {
            c.requestMethod = "HEAD"
            c.instanceFollowRedirects = false          // a 3xx is a complete round trip; following it would time two hosts
            c.responseCode
            return true
        } finally { runCatching { c.inputStream.close() }; runCatching { c.errorStream?.close() } }   // not disconnect(): keeping the socket pooled is what makes the warm-up useful
    }

    override fun download(url: String, chunkBytes: Int, timeoutMs: Int, onBytes: (Int) -> Boolean): Long {
        val maxBytes = MAX_DOWNLOAD_BYTES
        val c = open(url, timeoutMs)
        try {
            c.requestMethod = "GET"
            val code = c.responseCode
            if (code !in 200..299) throw HttpStatusException(code)
            val buf = ByteArray(chunkBytes); var total = 0L
            c.inputStream.use { s ->
                while (true) {
                    val n = s.read(buf); if (n < 0) break
                    total += n
                    if (!onBytes(n)) break
                    if (total > maxBytes) break          // the host is hard-coded, but never read an unbounded body on someone's data plan
                }
            }
            return total
        } finally { c.disconnect() }
    }

    override fun upload(url: String, bytes: Int, chunkBytes: Int, timeoutMs: Int, cancelled: () -> Boolean) {
        val c = open(url, timeoutMs)
        try {
            c.requestMethod = "POST"; c.doOutput = true
            c.setRequestProperty("Content-Type", "application/octet-stream")
            c.setFixedLengthStreamingMode(bytes)         // streamed, not buffered: 5 MB never sits in memory
            val zeros = ByteArray(minOf(chunkBytes, bytes))
            c.outputStream.use { o ->
                var left = bytes
                while (left > 0) { if (cancelled()) return; val n = minOf(left, zeros.size); o.write(zeros, 0, n); left -= n }
            }
            val code = c.responseCode
            runCatching { c.inputStream.use { s -> val b = ByteArray(4096); while (s.read(b) >= 0) { /* drain */ } } }
            if (code !in 200..299) throw HttpStatusException(code)
        } finally { c.disconnect() }
    }
}
