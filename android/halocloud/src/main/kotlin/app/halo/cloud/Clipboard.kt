package app.halo.cloud

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.security.MessageDigest
import java.util.UUID

// F-045 on the phone. Wire format = Halo/Features/ClipboardSync/ClipboardSyncModels.swift:
// `clipboard/{uid}/items/{itemId}` -> {itemId, deviceId, deviceName, kind, contentEnc, createdAt, schema}.

data class ClipboardEnvelope(
    val itemId: String,
    val deviceId: String,
    val deviceName: String,
    val kind: String,          // "text" | "url" | "code"
    val contentEnc: String,
    val language: String?,
    val createdAtMs: Double,
) {
    fun node(): JsonObject {
        val m = linkedMapOf<String, JsonElement>(
            "itemId" to JsonPrimitive(itemId), "deviceId" to JsonPrimitive(deviceId), "deviceName" to JsonPrimitive(deviceName),
            "kind" to JsonPrimitive(kind), "contentEnc" to JsonPrimitive(contentEnc), "createdAt" to JsonPrimitive(createdAtMs.toLong()),
            "schema" to JsonPrimitive(1),
        )
        language?.let { m["language"] = JsonPrimitive(it) }
        return JsonObject(m)
    }

    companion object {
        /** Null when structurally invalid, exactly as the desktop's parser. */
        fun from(value: JsonElement?): ClipboardEnvelope? {
            val d = value as? JsonObject ?: return null
            fun str(k: String) = (d[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            return ClipboardEnvelope(
                itemId = str("itemId") ?: return null,
                deviceId = str("deviceId") ?: return null,
                deviceName = str("deviceName") ?: "Unknown device",
                kind = str("kind") ?: return null,
                contentEnc = str("contentEnc") ?: return null,
                language = str("language"),
                createdAtMs = (d["createdAt"] as? JsonPrimitive)?.doubleOrNull ?: 0.0,
            )
        }
    }
}

/** A remote copy, decrypted, ready for the local history (never the live clipboard — D9). */
data class RemoteClip(val itemId: String, val text: String, val kind: String, val deviceName: String, val createdAtMs: Long)

/** Opt-in secret filter (D5: available but OFF by default). Mirrors `ClipboardSensitiveFilter` rule for rule. */
object ClipboardSensitiveFilter {
    private val keywords = listOf("password", "passwd", "secret", "api_key", "apikey", "access_token", "bearer ", "private key", "-----begin")
    private val tokenShapes = listOf(
        Regex("^AKIA[0-9A-Z]{16}$"),                                   // AWS access key id
        Regex("^gh[pousr]_[A-Za-z0-9]{20,}$"),                         // GitHub token
        Regex("^xox[baprs]-[A-Za-z0-9-]{10,}$"),                       // Slack token
        Regex("^eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$"), // JWT
        Regex("^sk-[A-Za-z0-9]{20,}$"),                                // OpenAI-style key
        // 64+ hex = a 256-bit key or SHA-256 digest. Shorter hex (MD5, git SHAs) is not a secret.
        Regex("^[A-Fa-f0-9]{64,}$"),
    )

    fun isSensitive(text: String): Boolean {
        val t = text.trim()
        if (t.isEmpty()) return false
        val lower = t.lowercase()
        if (keywords.any { lower.contains(it) }) return true
        if (t.none { it == ' ' || it == '\n' }) return tokenShapes.any { it.containsMatchIn(t) }
        return false
    }
}

class ClipboardSyncEngine(
    private val rtdb: Rtdb,
    private val crypto: CryptoService,
    private val deviceId: String,
    private val deviceName: String,
    private val filterSensitive: () -> Boolean = { false },
    private val clock: () -> Long = System::currentTimeMillis,
) {
    sealed interface Publish {
        object Sent : Publish
        object Duplicate : Publish
        object Empty : Publish
        object Excluded : Publish
        data class Failed(val why: String) : Publish
    }

    private val seenItemIds = HashSet<String>()
    private var lastHash: String? = null
    private var lastSweepMs = 0L
    @Volatile var excludedCount = 0; private set

    /** A remote clip the user explicitly copied locally: its echo must not be published back. */
    fun suppressEcho(text: String) { synchronized(this) { lastHash = sha256(text) } }

    /** Publish a local copy: dedup (D8), optional secret filter (D5), encrypt (D2), put, then cap-sweep (D4). */
    fun publish(text: String): Publish {
        if (text.isBlank()) return Publish.Empty
        synchronized(this) {
            val h = sha256(text)
            if (h == lastHash) return Publish.Duplicate
            lastHash = h
        }
        if (filterSensitive() && ClipboardSensitiveFilter.isSensitive(text)) { excludedCount++; return Publish.Excluded }
        return try {
            val uid = rtdb.uid
            val id = UUID.randomUUID().toString().uppercase()
            synchronized(this) { seenItemIds.add(id) }
            val env = ClipboardEnvelope(id, deviceId, deviceName, kindOf(text), crypto.encrypt(text), null, clock().toDouble())
            rtdb.put("clipboard/$uid/items/$id", env.node())
            sweepCap(uid)
            Publish.Sent
        } catch (e: Exception) {
            synchronized(this) { lastHash = null }            // let the same text be retried
            Publish.Failed(e.message ?: "upload failed")
        }
    }

    /** Receive: existing items first, then new ones. Our own copies and re-deliveries are dropped (D3, D8). */
    fun observe(onRemote: (RemoteClip) -> Unit): AutoCloseable =
        rtdb.observeChildAdded("clipboard/${rtdb.uid}/items") { _, value ->
            val env = ClipboardEnvelope.from(value) ?: return@observeChildAdded
            if (env.deviceId == deviceId) return@observeChildAdded
            if (!synchronized(this) { seenItemIds.add(env.itemId) }) return@observeChildAdded
            val text = try { crypto.decrypt(env.contentEnc) } catch (e: CryptoException) { return@observeChildAdded }
            onRemote(RemoteClip(env.itemId, text, env.kind, env.deviceName, env.createdAtMs.toLong()))
        }

    /** The primary privacy control (D10): remove every synced item from the cloud. */
    fun purge() {
        rtdb.delete("clipboard/${rtdb.uid}/items")
        synchronized(this) { seenItemIds.clear() }
    }

    private fun sweepCap(uid: String) {
        if (clock() - lastSweepMs < SWEEP_INTERVAL_MS) return
        lastSweepMs = clock()
        val raw = rtdb.get("clipboard/$uid/items") as? JsonObject ?: return
        if (raw.size <= CAP) return
        val oldest = raw.entries.map { (k, v) -> k to (((v as? JsonObject)?.get("createdAt") as? JsonPrimitive)?.doubleOrNull ?: 0.0) }.sortedBy { it.second }
        for ((k, _) in oldest.take(raw.size - CAP)) runCatching { rtdb.delete("clipboard/$uid/items/$k") }
    }

    companion object {
        const val CAP = 500
        private const val SWEEP_INTERVAL_MS = 30_000L

        /** `url` for a single-line http(s) address, else `text`. (Code detection is a desktop nicety.) */
        fun kindOf(text: String): String {
            val t = text.trim()
            return if (!t.contains('\n') && !t.contains(' ') && (t.startsWith("http://") || t.startsWith("https://")) &&
                runCatching { java.net.URI(t).host != null }.getOrDefault(false)) "url" else "text"
        }

        fun sha256(s: String): String = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
