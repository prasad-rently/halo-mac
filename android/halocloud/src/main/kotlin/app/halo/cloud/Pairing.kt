package app.halo.cloud

import java.security.MessageDigest
import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// The desktop -> phone pairing QR. Mirrors CloudPairingPayload in Halo/Core/Cloud/CloudModels.swift.
// Carries everything needed to CONNECT (config + auth + salt + KDF cost) but NOT the E2E
// passphrase: a leaked QR exposes only ciphertext.

@Serializable
data class FirebaseConfig(
    val apiKey: String,
    val projectID: String,
    val googleAppID: String,
    val gcmSenderID: String,
    val databaseURL: String,
    val storageBucket: String? = null,
)

@Serializable
data class CloudAuthCredential(val email: String, val password: String)

@Serializable
data class PairingPayload(
    val firebaseConfig: FirebaseConfig,
    val auth: CloudAuthCredential,
    val saltBase64: String,
    /** 1 = original (no iteration count, implicitly 200 000); 2 = carries `iterations`. */
    val schema: Int = 1,
    val iterations: Int = CryptoService.LEGACY_ITERATIONS,
    val checksum: String,
) {
    val salt: ByteArray? get() = try { Base64.getDecoder().decode(saltBase64) } catch (e: IllegalArgumentException) { null }

    /**
     * SHA-256 over the "|"-joined fields. Schema 1 never covered `iterations`, so its formula is
     * frozen to keep validating old payloads; from schema 2 the count is covered, so it cannot be
     * downgraded in transit.
     */
    val isValid: Boolean
        get() = MessageDigest.isEqual(
            checksum.toByteArray(Charsets.UTF_8),
            computeChecksum(firebaseConfig, auth, saltBase64, schema, iterations).toByteArray(Charsets.UTF_8),
        )

    companion object {
        const val CURRENT_SCHEMA = 2
        private val json = Json { ignoreUnknownKeys = true }

        fun computeChecksum(config: FirebaseConfig, auth: CloudAuthCredential, saltBase64: String, schema: Int, iterations: Int): String {
            val fields = mutableListOf(
                config.apiKey, config.projectID, config.googleAppID, config.gcmSenderID,
                config.databaseURL, config.storageBucket ?: "",
                auth.email, auth.password, saltBase64, schema.toString(),
            )
            if (schema >= 2) fields.add(iterations.toString())
            return sha256Hex(fields.joinToString("|"))
        }

        fun create(config: FirebaseConfig, auth: CloudAuthCredential, salt: ByteArray, iterations: Int = CryptoService.DEFAULT_ITERATIONS): PairingPayload {
            val saltB64 = Base64.getEncoder().encodeToString(salt)
            return PairingPayload(config, auth, saltB64, CURRENT_SCHEMA, iterations,
                computeChecksum(config, auth, saltB64, CURRENT_SCHEMA, iterations))
        }

        /** Decode the QR string (base64 of the JSON). Throws on malformed input. */
        fun decode(base64: String): PairingPayload {
            val bytes = try { Base64.getDecoder().decode(base64) } catch (e: IllegalArgumentException) {
                throw CryptoException(CryptoException.Kind.BAD_CIPHERTEXT, "The pairing code is malformed.")
            }
            return try { json.decodeFromString(serializer(), String(bytes, Charsets.UTF_8)) } catch (e: Exception) {
                throw CryptoException(CryptoException.Kind.BAD_CIPHERTEXT, "The pairing code is malformed.")
            }
        }
    }
}

/**
 * H-15: a pairing code is data from outside the phone, and it names the host that the signed-in session's ID token
 * is sent to (`…/path.json?auth=<token>`). A code pointing somewhere that is not a Firebase database is not
 * necessarily hostile (people do run emulators), so this only *warns* — the user decides — but a Firebase Realtime
 * Database always lives under one of the two Google-owned suffixes below.
 */
object FirebaseHosts {
    private val suffixes = listOf(".firebaseio.com", ".firebasedatabase.app")

    /** Matches on a label boundary: `evil-firebaseio.com` and `firebaseio.com.evil.io` do NOT qualify. */
    fun isFirebaseDatabase(databaseURL: String): Boolean {
        val host = runCatching { java.net.URI(databaseURL.trim()).host }.getOrNull()?.lowercase() ?: return false
        return suffixes.any { host.endsWith(it) && host.length > it.length }
    }

    /** Null when the host looks right; otherwise the text to show next to the pairing confirmation. */
    fun warning(databaseURL: String): String? {
        if (isFirebaseDatabase(databaseURL)) return null
        val host = runCatching { java.net.URI(databaseURL.trim()).host }.getOrNull().orEmpty().ifEmpty { "an unrecognised address" }
        return "This pairing code points at $host, which is not a Google Firebase database address (*.firebaseio.com or *.firebasedatabase.app). " +
            "Your sign-in session would be sent there. Continue only if you set that server up yourself; otherwise cancel and generate a new code on your Mac."
    }
}
