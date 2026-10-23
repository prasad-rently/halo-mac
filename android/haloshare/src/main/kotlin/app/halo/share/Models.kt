package app.halo.share

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Constants of the HaloShare (LocalSend v2) protocol. Contract: docs/HALOSHARE_PROTOCOL.md. */
object HaloShare {
    const val DEFAULT_PORT = 53317
    const val PROTOCOL_VERSION = "2.1"
    const val MULTICAST_GROUP = "224.0.0.167"
    const val API = "/api/localsend/v2"
}

/**
 * Lenient on decode, as the protocol doc §2 requires: the `info` and `register` *responses* of the
 * official apps carry no `port` or `protocol`, so those default instead of failing; unknown
 * fields are ignored; nullable fields may be absent.
 */
val HaloJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

/** A peer's identity: multicast announcement, `register` request, `info` of prepare-upload. */
@Serializable
data class DeviceInfo(
    val alias: String,
    val version: String = HaloShare.PROTOCOL_VERSION,
    val deviceModel: String? = null,
    /** `mobile | desktop | web | headless | server` — a string so a newer value can't break decoding. */
    val deviceType: String? = null,
    val fingerprint: String,
    val port: Int = HaloShare.DEFAULT_PORT,
    val protocol: String = "http",
    val download: Boolean? = null,
    val announce: Boolean? = null,
)

@Serializable
data class FileTimestamps(val modified: String? = null, val accessed: String? = null)

/** The protocol's `FileMetadata`: one entry of a prepare-upload request. */
@Serializable
data class FileDescriptor(
    val id: String,
    val fileName: String,
    val size: Long,
    val fileType: String = "application/octet-stream",
    val sha256: String? = null,
    val preview: String? = null,
    val metadata: FileTimestamps? = null,
)

@Serializable
data class PrepareUploadRequest(val info: DeviceInfo, val files: Map<String, FileDescriptor>)

/** `files` maps file id → token. */
@Serializable
data class PrepareUploadResponse(val sessionId: String, val files: Map<String, String>)

/** A device found on the network and where we reached it. */
data class Peer(val info: DeviceInfo, val host: String) {
    val id: String get() = info.fingerprint
    val alias: String get() = info.alias
    val port: Int get() = info.port
    val scheme: String get() = info.protocol
    val baseUrl: String get() = "$scheme://${if (host.contains(':')) "[$host]" else host}:$port"
}

sealed class HaloShareException(message: String) : Exception(message) {
    class Http(val status: Int) : HaloShareException("The other device answered with an error (HTTP $status).")
    class Busy : HaloShareException("The other device is busy with another transfer. Try again in a moment.")
    class ChecksumMismatch : HaloShareException("The file arrived damaged (checksum mismatch).")
    class Unreachable(why: String) : HaloShareException("Couldn't reach the other device: $why")
    class InvalidResponse : HaloShareException("The other device sent a reply HaloShare couldn't understand.")
    class FileUnreadable(name: String) : HaloShareException("Couldn't read $name.")
    class Cancelled : HaloShareException("Cancelled.")
}

/** Persisted identity: alias + a random fingerprint generated once (protocol doc §6). */
data class DeviceIdentity(
    val alias: String,
    val fingerprint: String,
    val deviceModel: String? = null,
    val deviceType: String = "mobile",
) {
    fun deviceInfo(port: Int = HaloShare.DEFAULT_PORT) = DeviceInfo(
        alias = alias, deviceModel = deviceModel, deviceType = deviceType,
        fingerprint = fingerprint, port = port, protocol = "http", download = false,
    )

    companion object {
        fun randomFingerprint(): String {
            val bytes = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}

interface KeyValueStore {
    fun get(key: String): String?
    fun put(key: String, value: String)
}

class InMemoryStore : KeyValueStore {
    private val map = HashMap<String, String>()
    override fun get(key: String) = map[key]
    override fun put(key: String, value: String) { map[key] = value }
}

object DeviceIdentityStore {
    private const val ALIAS = "haloshare.alias"
    private const val FINGERPRINT = "haloshare.fingerprint"

    fun loadOrCreate(store: KeyValueStore, defaultAlias: String, deviceModel: String? = null,
                     deviceType: String = "mobile"): DeviceIdentity {
        val alias = store.get(ALIAS) ?: defaultAlias.also { store.put(ALIAS, it) }
        val fingerprint = store.get(FINGERPRINT)?.takeIf { it.isNotEmpty() }
            ?: DeviceIdentity.randomFingerprint().also { store.put(FINGERPRINT, it) }
        return DeviceIdentity(alias, fingerprint, deviceModel, deviceType)
    }

    fun setAlias(store: KeyValueStore, alias: String) {
        val trimmed = alias.trim()
        if (trimmed.isNotEmpty()) store.put(ALIAS, trimmed.take(40))
    }
}
