package app.halo.share

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** What the receiver is being asked to accept (protocol doc §7.1). */
data class IncomingOffer(
    val sender: DeviceInfo,
    val senderAddress: String,
    val files: List<FileDescriptor>,
) {
    val totalBytes: Long get() = files.sumOf { it.size }
}

enum class ConsentDecision { ACCEPT, DECLINE }

/**
 * Asked once per `prepare-upload`, on a server thread. Nothing is written and no session exists
 * until it returns [ConsentDecision.ACCEPT]; it may block for as long as the user takes.
 */
fun interface ConsentHandler {
    fun onOffer(offer: IncomingOffer): ConsentDecision
}

/** Callbacks for UI/state. All default to no-ops; called from server threads. */
interface ServerListener {
    fun onOffer(offer: IncomingOffer) {}
    fun onDeclined(senderAlias: String) {}
    fun onProgress(sessionId: String, fileId: String, received: Long, total: Long) {}
    fun onFileReceived(sessionId: String, fileId: String, file: File) {}
    fun onSessionCompleted(sessionId: String) {}
    fun onSessionCancelled(sessionId: String) {}
}

/**
 * The receive side of HaloShare, on plain `java.net` sockets so it runs on the JVM (tests) and on
 * Android unchanged.
 *
 * - **Framing is on bytes** (protocol doc §1): the head is read up to `\r\n\r\n`, then the body by
 *   `Content-Length`, whatever the network does to the packet boundaries.
 * - **Consent first, untrusted names confined, never overwrite, partials don't survive** (§7).
 *   Uploads stream into a hidden `.halopart` and are renamed into place only when complete and,
 *   if the sender supplied a sha256, verified.
 * - A connection that goes quiet for [idleTimeoutMs] is dropped (`SO_TIMEOUT`).
 */
class HaloShareServer(
    private val identity: DeviceIdentity,
    private val receiveDirectory: File,
    private val consent: ConsentHandler,
    private val listener: ServerListener = object : ServerListener {},
    private val idleTimeoutMs: Int = 60_000,
    private val maxConcurrentSessions: Int = 4,
) {
    private class Session(
        val id: String,
        val sender: DeviceInfo,
        val files: Map<String, FileDescriptor>,
        val tokens: Map<String, String>,
    ) {
        val received = HashSet<String>()
        val inFlight = HashMap<String, File>()
    }

    private val sessions = ConcurrentHashMap<String, Session>()
    private val lock = Any()
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "haloshare-conn").apply { isDaemon = true } }
    private var serverSocket: ServerSocket? = null
    private val running = AtomicBoolean(false)

    /** The bound port, or 0 before [start]. */
    val port: Int get() = serverSocket?.localPort ?: 0

    /** Starts listening. Pass `0` for an ephemeral port (tests). Returns the bound port. */
    fun start(port: Int = HaloShare.DEFAULT_PORT): Int {
        check(running.compareAndSet(false, true)) { "already started" }
        val socket = ServerSocket()
        socket.reuseAddress = true
        try {
            socket.bind(java.net.InetSocketAddress(port))
        } catch (e: IOException) {
            running.set(false)
            throw e
        }
        serverSocket = socket
        Thread({ acceptLoop(socket) }, "haloshare-accept").apply { isDaemon = true }.start()
        return socket.localPort
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { serverSocket?.close() }
        serverSocket = null
        synchronized(lock) {
            sessions.values.forEach { discardPartials(it) }
            sessions.clear()
        }
        pool.shutdownNow()
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (running.get()) {
            val client = try { socket.accept() } catch (e: SocketException) { return } catch (e: IOException) { return }
            try { pool.execute { serve(client) } } catch (e: Exception) { runCatching { client.close() } }
        }
    }

    // ── Connection ────────────────────────────────────────────────────────────────────────────

    private fun serve(socket: Socket) {
        socket.use { s ->
            s.soTimeout = idleTimeoutMs
            val input = s.getInputStream()
            val output = s.getOutputStream()
            fun respond(bytes: ByteArray) { runCatching { output.write(bytes); output.flush() } }

            val (head, prefix) = readHead(input) ?: run { respond(HttpResponse.error(400, "Bad Request")); return }
            if (head.isChunked) { respond(HttpResponse.error(411, "Content-Length required")); return }
            if (head.expectsContinue) runCatching { output.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray()); output.flush() }

            val address = (s.remoteSocketAddress as? java.net.InetSocketAddress)?.address?.hostAddress ?: "unknown"
            try {
                when {
                    head.method == "GET" && head.path == "${HaloShare.API}/info" ->
                        respond(HttpResponse.bytes(200, HaloJson.encodeToString(DeviceInfo.serializer(), identity.deviceInfo(port))))

                    head.method == "POST" && head.path == "${HaloShare.API}/register" -> {
                        val body = readBody(input, head, prefix)
                        val ok = body != null && runCatching { HaloJson.decodeFromString(DeviceInfo.serializer(), String(body)) }.isSuccess
                        if (!ok) respond(HttpResponse.error(400, "Invalid body"))
                        else respond(HttpResponse.bytes(200, HaloJson.encodeToString(DeviceInfo.serializer(), identity.deviceInfo(port))))
                    }

                    head.method == "POST" && head.path == "${HaloShare.API}/prepare-upload" -> {
                        val body = readBody(input, head, prefix)
                        val request = body?.let { runCatching { HaloJson.decodeFromString(PrepareUploadRequest.serializer(), String(it)) }.getOrNull() }
                        if (request == null) respond(HttpResponse.error(400, "Invalid body"))
                        else respond(prepareUpload(request, address))
                    }

                    head.method == "POST" && head.path == "${HaloShare.API}/upload" -> respond(upload(input, head, prefix))

                    head.method == "POST" && head.path == "${HaloShare.API}/cancel" -> respond(cancel(head.query["sessionId"] ?: ""))

                    else -> respond(HttpResponse.error(404, "Not Found"))
                }
            } catch (e: SocketTimeoutException) {
                // idle: drop silently
            } catch (e: IOException) {
                // peer went away
            }
        }
    }

    // ── Routes ────────────────────────────────────────────────────────────────────────────────

    private fun prepareUpload(request: PrepareUploadRequest, address: String): ByteArray {
        if (request.files.isEmpty()) return HttpResponse.error(400, "No files")
        if (sessions.size >= maxConcurrentSessions) return HttpResponse.error(429, "Too many sessions")

        val offer = IncomingOffer(request.info, address, request.files.values.sortedBy { it.fileName })
        listener.onOffer(offer)
        if (consent.onOffer(offer) != ConsentDecision.ACCEPT) {
            listener.onDeclined(request.info.alias)
            return HttpResponse.error(403, "Rejected")        // declined ⇒ 403, no session, nothing on disk
        }

        val id = UUID.randomUUID().toString()
        val tokens = request.files.keys.associateWith { randomToken() }
        sessions[id] = Session(id, request.info, request.files, tokens)
        return HttpResponse.bytes(200, HaloJson.encodeToString(PrepareUploadResponse.serializer(), PrepareUploadResponse(id, tokens)))
    }

    private fun upload(input: InputStream, head: HttpRequestHead, prefix: ByteArray): ByteArray {
        val sessionId = head.query["sessionId"]; val fileId = head.query["fileId"]; val token = head.query["token"]
        if (sessionId == null || fileId == null || token == null) return HttpResponse.error(400, "Missing params")
        val session = sessions[sessionId] ?: return HttpResponse.error(404, "Session not found")
        val expected = session.tokens[fileId]
        if (expected == null || !MessageDigest.isEqual(expected.toByteArray(), token.toByteArray())) return HttpResponse.error(403, "Invalid token")
        val descriptor = session.files[fileId] ?: return HttpResponse.error(404, "File not found")

        val partial: File
        synchronized(lock) {
            if (fileId in session.received || fileId in session.inFlight) return HttpResponse.error(409, "Already uploaded")
            val destination = SafeFileName.uniqueDestination(descriptor.fileName, receiveDirectory)
            if (!(destination.parentFile!!.mkdirs() || destination.parentFile!!.isDirectory)) return HttpResponse.error(500, "Cannot create folder")
            partial = File(destination.parentFile, ".${destination.name}.${UUID.randomUUID().toString().take(8)}.halopart")
            session.inFlight[fileId] = partial
        }

        val expectedSize = if (head.contentLength > 0) head.contentLength.toLong() else descriptor.size
        val digest = descriptor.sha256?.let { MessageDigest.getInstance("SHA-256") }
        val ok = try {
            stream(input, prefix, partial, expectedSize, digest) { received ->
                listener.onProgress(sessionId, fileId, received, expectedSize)
            }
        } catch (e: IOException) { false }

        synchronized(lock) {
            session.inFlight.remove(fileId)
            // A cancel may have removed the session while we were streaming.
            if (sessions[sessionId] == null) { partial.delete(); return HttpResponse.error(404, "Session cancelled") }
            if (!ok) { partial.delete(); return HttpResponse.error(400, "Incomplete upload") }
            if (digest != null) {
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                if (!actual.equals(descriptor.sha256, ignoreCase = true)) { partial.delete(); return HttpResponse.error(422, "Checksum mismatch") }
            }
            // Re-resolve now so a name taken while this file streamed isn't overwritten.
            val final = SafeFileName.uniqueDestination(descriptor.fileName, receiveDirectory)
            try { Files.move(partial.toPath(), final.toPath(), StandardCopyOption.ATOMIC_MOVE) }
            catch (e: IOException) { partial.delete(); return HttpResponse.error(500, "Cannot store file") }

            session.received.add(fileId)
            val done = session.received.size == session.files.size
            if (done) sessions.remove(sessionId)
            listener.onFileReceived(sessionId, fileId, final)
            if (done) listener.onSessionCompleted(sessionId)
            return HttpResponse.bytes(200, "{\"message\":\"OK\"}")
        }
    }

    private fun cancel(sessionId: String): ByteArray {
        synchronized(lock) {
            sessions.remove(sessionId)?.let { discardPartials(it); listener.onSessionCancelled(sessionId) }
        }
        return HttpResponse.bytes(200, "{\"message\":\"OK\"}")
    }

    private fun discardPartials(s: Session) { s.inFlight.values.forEach { it.delete() } }

    // ── Streaming / wire helpers ──────────────────────────────────────────────────────────────

    private fun stream(input: InputStream, prefix: ByteArray, file: File, expected: Long, digest: MessageDigest?,
                       progress: (Long) -> Unit): Boolean {
        var received = 0L
        file.outputStream().buffered(256 * 1024).use { out ->
            val first = minOf(prefix.size.toLong(), expected).toInt()
            if (first > 0) { out.write(prefix, 0, first); digest?.update(prefix, 0, first); received += first }

            val buf = ByteArray(256 * 1024)
            var lastReport = 0L
            while (received < expected) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), expected - received).toInt())
                if (n < 0) return false                     // peer closed early
                out.write(buf, 0, n); digest?.update(buf, 0, n); received += n
                if (received - lastReport >= 512 * 1024) { lastReport = received; progress(received) }
            }
        }
        progress(received)
        return true
    }

    private fun readHead(input: InputStream): Pair<HttpRequestHead, ByteArray>? {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (buffer.size() <= MAX_HEAD_BYTES) {
            val n = input.read(chunk)
            if (n < 0) return null
            buffer.write(chunk, 0, n)
            val bytes = buffer.toByteArray()
            val end = indexOfTerminator(bytes)
            if (end >= 0) {
                val head = HttpRequestHead.parse(bytes.copyOfRange(0, end)) ?: return null
                return head to bytes.copyOfRange(end + 4, bytes.size)
            }
        }
        return null
    }

    private fun readBody(input: InputStream, head: HttpRequestHead, prefix: ByteArray): ByteArray? {
        val length = head.contentLength
        if (length <= 0 || length > MAX_JSON_BODY) return null
        val body = java.io.ByteArrayOutputStream(length)
        body.write(prefix, 0, minOf(prefix.size, length))
        val buf = ByteArray(16 * 1024)
        while (body.size() < length) {
            val n = input.read(buf, 0, minOf(buf.size, length - body.size()))
            if (n < 0) return null
            body.write(buf, 0, n)
        }
        return body.toByteArray()
    }

    private fun indexOfTerminator(b: ByteArray): Int {
        for (i in 0..b.size - 4) {
            if (b[i] == '\r'.code.toByte() && b[i + 1] == '\n'.code.toByte() && b[i + 2] == '\r'.code.toByte() && b[i + 3] == '\n'.code.toByte()) return i
        }
        return -1
    }

    private fun randomToken(): String {
        val bytes = ByteArray(24).also { SecureRandom().nextBytes(it) }
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    companion object {
        const val MAX_HEAD_BYTES = 32 * 1024
        const val MAX_JSON_BODY = 4 * 1024 * 1024
    }
}
