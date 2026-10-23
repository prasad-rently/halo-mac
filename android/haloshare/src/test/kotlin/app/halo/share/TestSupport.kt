package app.halo.share

import java.io.File
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Collects server callbacks so a test can wait for them. */
class EventLog : ServerListener {
    val offers = CopyOnWriteArrayList<IncomingOffer>()
    val received = CopyOnWriteArrayList<File>()
    val progress = CopyOnWriteArrayList<Long>()
    val completed = AtomicInteger()
    val cancelled = AtomicInteger()
    val declined = AtomicInteger()
    override fun onOffer(offer: IncomingOffer) { offers.add(offer) }
    override fun onDeclined(senderAlias: String) { declined.incrementAndGet() }
    override fun onProgress(sessionId: String, fileId: String, received: Long, total: Long) { progress.add(received) }
    override fun onFileReceived(sessionId: String, fileId: String, file: File) { received.add(file) }
    override fun onSessionCompleted(sessionId: String) { completed.incrementAndGet() }
    override fun onSessionCancelled(sessionId: String) { cancelled.incrementAndGet() }
}

fun waitUntil(timeoutMs: Long = 10_000, condition: () -> Boolean): Boolean {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) { if (condition()) return true; Thread.sleep(25) }
    return condition()
}

/** A running receiver plus a client that already found it. */
class Rig(
    decision: ConsentDecision = ConsentDecision.ACCEPT,
    idleTimeoutMs: Int = 30_000,
    maxSessions: Int = 4,
) : AutoCloseable {
    val dir: File = Files.createTempDirectory("hsk-rx").toFile()
    val log = EventLog()
    val server = HaloShareServer(
        DeviceIdentity("Receiver", DeviceIdentity.randomFingerprint(), deviceType = "desktop"),
        dir, { decision }, log, idleTimeoutMs, maxSessions,
    )
    val port: Int = server.start(0)
    val client = HaloShareClient(DeviceIdentity("Sender", DeviceIdentity.randomFingerprint()))
    val peer: Peer = client.probe("127.0.0.1", port, timeoutMs = 5000) ?: error("the server did not answer /info")

    /** Regular files actually on disk (recursive, relative) — a leftover `.halopart` shows up. */
    fun filesOnDisk(): List<String> =
        dir.walkTopDown().filter { it.isFile }.map { it.relativeTo(dir).path }.sorted().toList()

    override fun close() { server.stop(); dir.deleteRecursively() }
}

fun makeFile(name: String, bytes: Long, dir: File = Files.createTempDirectory("hsk-src").toFile()): File {
    dir.mkdirs()
    val f = File(dir, name)
    f.outputStream().buffered(1 shl 20).use { out ->
        val chunk = ByteArray(1 shl 20)
        var written = 0L
        while (written < bytes) {
            val n = minOf(chunk.size.toLong(), bytes - written).toInt()
            for (i in 0 until n) chunk[i] = ((written + i) * 31 + 129).toByte()   // high bytes: not valid UTF-8
            out.write(chunk, 0, n); written += n
        }
    }
    return f
}

fun sha256(f: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    f.inputStream().use { s -> val b = ByteArray(1 shl 20); while (true) { val n = s.read(b); if (n < 0) break; md.update(b, 0, n) } }
    return md.digest().joinToString("") { "%02x".format(it) }
}

fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

fun prepareBody(vararg files: FileDescriptor, alias: String = "RawSender"): ByteArray =
    HaloJson.encodeToString(PrepareUploadRequest.serializer(),
        PrepareUploadRequest(DeviceInfo(alias = alias, fingerprint = "raw-${java.util.UUID.randomUUID()}"), files.associateBy { it.id })).toByteArray()

fun parseResponse(raw: String): PrepareUploadResponse =
    HaloJson.decodeFromString(PrepareUploadResponse.serializer(), raw.substringAfter("\r\n\r\n"))

// ── Raw HTTP: an independent client — one write, our own framing, no HttpURLConnection ─────────

object Raw {
    class Reply(val status: Int, val text: String)

    /** [splitAfterHead] writes head and body separately; otherwise it is ONE write (curl/OkHttp/Dart shape). */
    fun post(port: Int, path: String, body: ByteArray, contentType: String = "application/octet-stream",
             declaredLength: Int? = null, splitAfterHead: Boolean = false, extraHeaders: String = ""): Reply {
        Socket().use { s ->
            s.soTimeout = 10_000
            s.connect(InetSocketAddress("127.0.0.1", port), 5000)
            val head = "POST $path HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: $contentType\r\nContent-Length: ${declaredLength ?: body.size}\r\n${extraHeaders}Connection: close\r\n\r\n".toByteArray()
            val out = s.getOutputStream()
            if (splitAfterHead) { out.write(head); out.flush(); Thread.sleep(150); out.write(body); out.flush() }
            else { out.write(head + body); out.flush() }
            if (declaredLength != null && declaredLength > body.size) s.shutdownOutput()     // a peer that dies mid-upload

            val reply = try { s.getInputStream().readBytes() } catch (e: java.net.SocketTimeoutException) { ByteArray(0) }
            val text = String(reply)
            val status = text.split(' ').getOrNull(1)?.toIntOrNull() ?: -1
            return Reply(status, text)
        }
    }
}

/** `curl` — a third-party HTTP stack, the strongest independent check we have. Returns (status, body). */
fun curl(vararg args: String): Pair<Int, String> {
    val p = ProcessBuilder(listOf("/usr/bin/curl", "-s", "-o", "/dev/stdout", "-w", "\n%{http_code}", "--max-time", "30") + args)
        .redirectErrorStream(false).start()
    val out = p.inputStream.readBytes()
    p.waitFor(60, TimeUnit.SECONDS)
    val text = String(out)
    val idx = text.lastIndexOf('\n')
    return (text.substring(idx + 1).trim().toIntOrNull() ?: -1) to text.substring(0, maxOf(idx, 0))
}

val curlAvailable: Boolean get() = File("/usr/bin/curl").canExecute()

// ── StallingReceiver: accepts an offer, then stops reading the upload ──────────────────────────

/**
 * A minimal receiver that accepts an offer and then **stops reading the upload**, so a client upload
 * blocks on TCP backpressure — the deterministic way to hold a transfer mid-flight (loopback is far
 * too fast to cancel a real one reliably). Counts `/cancel` requests.
 */
class StallingReceiver : AutoCloseable {
    @Volatile var uploadStarted = false
    val cancelRequests = AtomicInteger()
    private val server = ServerSocket(0, 16, java.net.InetAddress.getByName("127.0.0.1"))
    private val open = CopyOnWriteArrayList<Socket>()
    val port: Int = server.localPort

    init { Thread({ acceptLoop() }, "stall-accept").apply { isDaemon = true }.start() }

    private fun acceptLoop() {
        while (!server.isClosed) {
            val s = try { server.accept() } catch (e: Exception) { return }
            open.add(s)
            Thread({ handle(s) }, "stall-conn").apply { isDaemon = true }.start()
        }
    }

    private fun handle(s: Socket) {
        try {
            val input = s.getInputStream(); val out = s.getOutputStream()
            val buf = java.io.ByteArrayOutputStream(); val chunk = ByteArray(8192)
            var end: Int
            while (true) {
                val n = input.read(chunk); if (n < 0) return
                buf.write(chunk, 0, n)
                val b = buf.toByteArray()
                end = (0..b.size - 4).firstOrNull { b[it] == 13.toByte() && b[it + 1] == 10.toByte() && b[it + 2] == 13.toByte() && b[it + 3] == 10.toByte() } ?: -1
                if (end >= 0) break
            }
            val all = buf.toByteArray()
            val head = HttpRequestHead.parse(all.copyOfRange(0, end)) ?: return
            var body = all.copyOfRange(end + 4, all.size)
            fun reply(status: Int, json: String) { out.write(HttpResponse.bytes(status, json)); out.flush(); s.close() }
            when (head.path) {
                "${HaloShare.API}/info" ->
                    reply(200, HaloJson.encodeToString(DeviceInfo.serializer(), DeviceInfo(alias = "Stalled", fingerprint = "stalled-${java.util.UUID.randomUUID()}", port = port)))
                "${HaloShare.API}/prepare-upload" -> {
                    val bodyOut = java.io.ByteArrayOutputStream().also { it.write(body) }
                    while (bodyOut.size() < head.contentLength) { val n = input.read(chunk, 0, minOf(chunk.size, head.contentLength - bodyOut.size())); if (n < 0) return; bodyOut.write(chunk, 0, n) }
                    val req = HaloJson.decodeFromString(PrepareUploadRequest.serializer(), String(bodyOut.toByteArray()))
                    reply(200, HaloJson.encodeToString(PrepareUploadResponse.serializer(), PrepareUploadResponse("stalled-session", req.files.keys.associateWith { "tok-$it" })))
                }
                "${HaloShare.API}/upload" -> { uploadStarted = true; while (!s.isClosed) Thread.sleep(200) }   // never read the body
                "${HaloShare.API}/cancel" -> { cancelRequests.incrementAndGet(); reply(200, "{\"message\":\"OK\"}") }
                else -> reply(404, "{}")
            }
        } catch (_: Exception) {}
    }

    override fun close() { open.forEach { runCatching { it.close() } }; runCatching { server.close() } }
}
