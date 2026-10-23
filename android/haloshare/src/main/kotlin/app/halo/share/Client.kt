package app.halo.share

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/** One file to send. [open] is called once per upload, so a `content://` URI can stream from the resolver. */
class OutgoingFile(
    val name: String,
    val size: Long,
    val mimeType: String = "application/octet-stream",
    val id: String = UUID.randomUUID().toString(),
    val open: () -> InputStream,
) {
    val descriptor get() = FileDescriptor(id = id, fileName = name, size = size, fileType = mimeType)

    companion object {
        fun fromFile(file: File, name: String = file.name, mimeType: String = "application/octet-stream") =
            OutgoingFile(name = name, size = file.length(), mimeType = mimeType, open = { file.inputStream() })
    }
}

data class SendProgress(
    val fileId: String, val fileName: String,
    val sent: Long, val total: Long,
    val overallSent: Long, val overallTotal: Long,
)

sealed class SendOutcome {
    object Completed : SendOutcome()
    /** The receiver's user said no (`403`). Not an error to retry. */
    object Declined : SendOutcome()
    /** `204`: nothing needed transferring. */
    object NothingToSend : SendOutcome()
}

/**
 * Cooperative cancellation that can also *interrupt a blocked write*: a receiver that stops
 * reading leaves the sender blocked in `write()`, which a flag alone can never end. Callbacks
 * registered with [onCancel] (the client registers one that closes the connection) run on cancel.
 */
class CancelToken {
    @Volatile var isCancelled = false
        private set
    private val callbacks = CopyOnWriteArrayList<() -> Unit>()

    fun cancel() {
        isCancelled = true
        callbacks.forEach { runCatching { it() } }
    }

    fun onCancel(callback: () -> Unit): AutoCloseable {
        callbacks.add(callback)
        if (isCancelled) runCatching { callback() }
        return AutoCloseable { callbacks.remove(callback) }
    }
}

/**
 * The send side: probe a peer, `prepare-upload`, stream each file from its source with real
 * progress, cancel (which also tells the receiver so it deletes the partial).
 */
class HaloShareClient(private val identity: DeviceIdentity) {

    /** `GET /info`. Returns the peer, or null if nothing (Halo/LocalSend) answered in time. */
    fun probe(host: String, port: Int = HaloShare.DEFAULT_PORT, scheme: String = "http", timeoutMs: Int = 2000): Peer? {
        val conn = open("$scheme://${hostLiteral(host)}:$port${HaloShare.API}/info", "GET", timeoutMs, timeoutMs)
        return try {
            if (conn.responseCode != 200) return null
            val info = HaloJson.decodeFromString(DeviceInfo.serializer(), conn.inputStream.use { String(it.readBytes()) })
                // The responder may omit port/protocol (protocol doc §2); we know how we reached it.
                .copy(port = port, protocol = scheme)
            if (info.fingerprint == identity.fingerprint) null else Peer(info, host)
        } catch (e: Exception) { null } finally { conn.disconnect() }
    }

    /** Sends [files] to [peer]. Throws [HaloShareException] on failure; [HaloShareException.Cancelled] on cancel. */
    fun send(files: List<OutgoingFile>, peer: Peer, cancel: CancelToken = CancelToken(),
             progress: (SendProgress) -> Unit = {}): SendOutcome {
        if (files.isEmpty()) return SendOutcome.NothingToSend

        val request = PrepareUploadRequest(identity.deviceInfo(), files.associate { it.id to it.descriptor })
        val body = HaloJson.encodeToString(PrepareUploadRequest.serializer(), request).toByteArray()

        // The receiver is waiting on a *person*; don't give up after a default 30 s.
        val conn = open("${peer.baseUrl}${HaloShare.API}/prepare-upload", "POST", 5_000, 10 * 60_000)
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setFixedLengthStreamingMode(body.size)
        val registration = cancel.onCancel { conn.disconnect() }
        val accepted: PrepareUploadResponse
        try {
            conn.outputStream.use { it.write(body) }
            when (val status = conn.responseCode) {
                200 -> accepted = HaloJson.decodeFromString(PrepareUploadResponse.serializer(), conn.inputStream.use { String(it.readBytes()) })
                204 -> return SendOutcome.NothingToSend
                403 -> return SendOutcome.Declined
                409, 429 -> throw HaloShareException.Busy()
                else -> throw HaloShareException.Http(status)
            }
        } catch (e: HaloShareException) { throw e
        } catch (e: IOException) {
            if (cancel.isCancelled) throw HaloShareException.Cancelled()
            throw HaloShareException.Unreachable(e.message ?: "connection failed")
        } catch (e: Exception) { throw HaloShareException.InvalidResponse()
        } finally { registration.close(); conn.disconnect() }

        val overallTotal = files.sumOf { it.size }
        var completed = 0L
        try {
            for (file in files) {
                if (cancel.isCancelled) throw HaloShareException.Cancelled()
                val token = accepted.files[file.id] ?: throw HaloShareException.InvalidResponse()
                val base = completed
                upload(file, token, accepted.sessionId, peer, cancel) { sent ->
                    progress(SendProgress(file.id, file.name, sent, file.size, base + sent, overallTotal))
                }
                completed += file.size
            }
        } catch (e: Exception) {
            // Whatever went wrong — cancel included — tell the receiver, so it drops the session
            // and its partial file rather than waiting for an idle timeout.
            cancelSession(accepted.sessionId, peer)
            throw if (e is HaloShareException) e else HaloShareException.Unreachable(e.message ?: "transfer failed")
        }
        return SendOutcome.Completed
    }

    private fun upload(file: OutgoingFile, token: String, sessionId: String, peer: Peer, cancel: CancelToken,
                       progress: (Long) -> Unit) {
        fun q(s: String) = URLEncoder.encode(s, "UTF-8")
        val conn = open("${peer.baseUrl}${HaloShare.API}/upload?sessionId=${q(sessionId)}&fileId=${q(file.id)}&token=${q(token)}",
            "POST", 5_000, 2 * 60_000)
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/octet-stream")
        conn.setFixedLengthStreamingMode(file.size)
        val registration = cancel.onCancel { conn.disconnect() }
        try {
            val input = try { file.open() } catch (e: IOException) { throw HaloShareException.FileUnreadable(file.name) }
            input.use { src ->
                conn.outputStream.use { out ->
                    val buf = ByteArray(64 * 1024)
                    var sent = 0L
                    var lastReport = 0L
                    while (true) {
                        if (cancel.isCancelled) throw HaloShareException.Cancelled()
                        val n = src.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        sent += n
                        if (sent - lastReport >= 256 * 1024) { lastReport = sent; progress(sent) }
                    }
                    progress(sent)
                }
            }
            when (val status = conn.responseCode) {
                200 -> return
                409, 429 -> throw HaloShareException.Busy()
                422 -> throw HaloShareException.ChecksumMismatch()
                else -> throw HaloShareException.Http(status)
            }
        } catch (e: HaloShareException) { throw e
        } catch (e: IOException) {
            if (cancel.isCancelled) throw HaloShareException.Cancelled()
            throw HaloShareException.Unreachable(e.message ?: "connection lost")
        } finally { registration.close(); conn.disconnect() }
    }

    /** Best-effort: tells the receiver to discard the session and its partial files. */
    fun cancelSession(sessionId: String, peer: Peer) {
        val conn = open("${peer.baseUrl}${HaloShare.API}/cancel?sessionId=${URLEncoder.encode(sessionId, "UTF-8")}", "POST", 3_000, 5_000)
        try {
            conn.doOutput = true
            conn.setFixedLengthStreamingMode(0)
            conn.outputStream.close()
            conn.responseCode
        } catch (_: Exception) {
        } finally { conn.disconnect() }
    }

    private fun open(url: String, method: String, connectMs: Int, readMs: Int): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = connectMs
            readTimeout = readMs
            useCaches = false
            setRequestProperty("Connection", "close")
        }

    private fun hostLiteral(host: String) = if (host.contains(':')) "[$host]" else host
}
