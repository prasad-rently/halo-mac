package app.halo.cloud

import java.security.MessageDigest
import java.security.SecureRandom
import java.text.BreakIterator
import java.text.Normalizer
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// The Kotlin half of Halo's cloud crypto contract. It must produce and accept exactly what
// Halo/Core/Cloud/CryptoService.swift does — docs/specs/crypto-parity.md is the spec and
// docs/specs/crypto-parity-vectors.v2.json is the executable proof (the Swift suite checks the same
// file against the real CryptoService, so a drift on either side fails a test).
//
//   key    = PBKDF2-HMAC-SHA256(NFC(passphrase) as UTF-8, salt, iterations) -> 32 bytes
//   v1 box = "v1:" + base64( AES-256-GCM(key, plaintext, aad = "halo.cloud.v1") nonce12 || ct || tag16 )
//   v0 box = base64( AES-256-GCM(key, plaintext, no aad) )          -- legacy, READ-ONLY

class CryptoException(val kind: Kind, message: String) : Exception(message) {
    enum class Kind { BAD_CIPHERTEXT, DECRYPTION_FAILED, ENCRYPTION_FAILED, KDF_FAILED, RANDOM_GENERATION_FAILED, INVALID_PARAMETERS }
}

/** The strength floor for a *new* end-to-end passphrase. Mirrors `PassphrasePolicy` in Swift. */
object PassphrasePolicy {
    const val MINIMUM_LENGTH = 12
    const val MINIMUM_DISTINCT_CHARACTERS = 6

    sealed class Verdict {
        object Ok : Verdict()
        data class TooShort(val have: Int) : Verdict()
        object TooRepetitive : Verdict()

        val isAcceptable: Boolean get() = this is Ok

        /** The string form the shared vectors use: "ok", "tooShort:N", "tooRepetitive". */
        val code: String get() = when (this) {
            Ok -> "ok"
            is TooShort -> "tooShort:$have"
            TooRepetitive -> "tooRepetitive"
        }
    }

    /**
     * Characters are counted as user-perceived characters (grapheme clusters) AFTER NFC
     * normalisation, exactly as Swift's `String.count` does. `String.length` counts UTF-16 units
     * and would count "e" + U+0301 as two — the shared vectors include that case on purpose.
     */
    fun evaluate(passphrase: String): Verdict {
        val clusters = graphemes(Normalizer.normalize(passphrase, Normalizer.Form.NFC))
        if (clusters.size < MINIMUM_LENGTH) return Verdict.TooShort(clusters.size)
        if (clusters.toSet().size < MINIMUM_DISTINCT_CHARACTERS) return Verdict.TooRepetitive
        return Verdict.Ok
    }

    internal fun graphemes(s: String): List<String> {
        val it = BreakIterator.getCharacterInstance()
        it.setText(s)
        val out = ArrayList<String>()
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            out.add(s.substring(start, end))
            start = end
            end = it.next()
        }
        return out
    }
}

class CryptoService(private val key: ByteArray) {

    init { require(key.size == 32) { "key must be 32 bytes" } }

    companion object {
        /** OWASP 2023 for PBKDF2-HMAC-SHA256. Stored with the salt and carried in the pairing payload. */
        const val DEFAULT_ITERATIONS = 600_000
        /** What the pre-v2.5 desktop branch used; still accepted so existing keys derive. */
        const val LEGACY_ITERATIONS = 200_000
        const val MINIMUM_ITERATIONS = 100_000
        const val MINIMUM_SALT_BYTES = 16
        const val ENVELOPE_PREFIX = "v1:"
        val ENVELOPE_AAD: ByteArray = "halo.cloud.v1".toByteArray(Charsets.UTF_8)

        private val rng = SecureRandom()

        /** Derive the key from a passphrase + salt and build a service. */
        fun create(passphrase: String, salt: ByteArray, iterations: Int = DEFAULT_ITERATIONS): CryptoService =
            CryptoService(deriveKey(passphrase, salt, iterations))

        /**
         * PBKDF2-HMAC-SHA256 -> 32 bytes. Implemented directly over HmacSHA256 rather than through
         * `SecretKeyFactory`, whose handling of how a passphrase becomes bytes differs between JDK
         * and Android providers — a silent mismatch here is a key nobody can reproduce.
         */
        fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int = DEFAULT_ITERATIONS): ByteArray {
            if (passphrase.isEmpty()) throw CryptoException(CryptoException.Kind.INVALID_PARAMETERS, "the passphrase is empty")
            if (salt.size < MINIMUM_SALT_BYTES) throw CryptoException(CryptoException.Kind.INVALID_PARAMETERS, "the salt is ${salt.size} bytes; need at least $MINIMUM_SALT_BYTES")
            if (iterations < MINIMUM_ITERATIONS) throw CryptoException(CryptoException.Kind.INVALID_PARAMETERS, "$iterations iterations is below the $MINIMUM_ITERATIONS floor")

            val password = Normalizer.normalize(passphrase, Normalizer.Form.NFC).toByteArray(Charsets.UTF_8)
            try {
                val mac = Mac.getInstance("HmacSHA256")
                mac.init(SecretKeySpec(password, "HmacSHA256"))
                // dkLen (32) == hLen (32), so a single block: T1 = U1 xor U2 xor ... xor Uc
                mac.update(salt)
                mac.update(byteArrayOf(0, 0, 0, 1))
                var u = mac.doFinal()
                val t = u.copyOf()
                for (i in 2..iterations) {
                    u = mac.doFinal(u)
                    for (j in t.indices) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
                }
                return t
            } catch (e: CryptoException) {
                throw e
            } catch (e: Exception) {
                throw CryptoException(CryptoException.Kind.KDF_FAILED, "Key derivation failed.")
            } finally {
                password.fill(0)
            }
        }

        fun randomBytes(count: Int): ByteArray = try {
            ByteArray(count).also { rng.nextBytes(it) }
        } catch (e: Exception) {
            throw CryptoException(CryptoException.Kind.RANDOM_GENERATION_FAILED, "The system couldn't produce secure random bytes.")
        }

        fun generateSalt(count: Int = MINIMUM_SALT_BYTES): ByteArray = randomBytes(count)
    }

    /**
     * A keyed hash for grouping without exposing the value (the SMS `threadKey`): HMAC-SHA256 under a
     * sub-key derived from the data key, hex-encoded. A plain SHA-256 of a phone number would be
     * reversible by trying every number; keying it with the secret makes it useless without the key.
     */
    fun keyedHash(context: String, data: String): String {
        val outer = Mac.getInstance("HmacSHA256")
        outer.init(SecretKeySpec(key, "HmacSHA256"))
        val subKey = outer.doFinal(context.toByteArray(Charsets.UTF_8))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(subKey, "HmacSHA256"))
        return mac.doFinal(data.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    /** The raw key, for a caller that must persist it (device keystore) instead of the passphrase. */
    fun exportKey(): ByteArray = key.copyOf()

    /** Seal a UTF-8 string -> `"v1:" + base64(nonce12 || ct || tag16)`. */
    fun encrypt(plaintext: String): String {
        try {
            val nonce = randomBytes(12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(ENVELOPE_AAD)
            val sealed = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
            return ENVELOPE_PREFIX + Base64.getEncoder().encodeToString(nonce + sealed)
        } catch (e: CryptoException) {
            throw e
        } catch (e: Exception) {
            throw CryptoException(CryptoException.Kind.ENCRYPTION_FAILED, "Couldn't encrypt the payload.")
        }
    }

    /** Open a `v1:` envelope, or a legacy unprefixed (v0) box. Throws on wrong key / tamper. */
    fun decrypt(ciphertext: String): String {
        val isV1 = ciphertext.startsWith(ENVELOPE_PREFIX)
        val body = if (isV1) ciphertext.substring(ENVELOPE_PREFIX.length) else ciphertext

        val combined = try {
            Base64.getDecoder().decode(body)
        } catch (e: IllegalArgumentException) {
            throw CryptoException(CryptoException.Kind.BAD_CIPHERTEXT, "The encrypted payload is malformed.")
        }
        // nonce12 + tag16 is the shortest possible box (an empty plaintext).
        if (combined.size < 28) throw CryptoException(CryptoException.Kind.BAD_CIPHERTEXT, "The encrypted payload is malformed.")

        val opened = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
            // v1 binds the AAD; v0 never had one. The prefix is authenticated, so it cannot be
            // stripped or forged to downgrade a message.
            if (isV1) cipher.updateAAD(ENVELOPE_AAD)
            cipher.doFinal(combined, 12, combined.size - 12)
        } catch (e: Exception) {
            throw CryptoException(CryptoException.Kind.DECRYPTION_FAILED, "Couldn't decrypt — wrong key or corrupted data.")
        }
        return try {
            Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(opened)).toString()
        } catch (e: Exception) {
            throw CryptoException(CryptoException.Kind.DECRYPTION_FAILED, "Couldn't decrypt — wrong key or corrupted data.")
        }
    }
}

internal fun sha256Hex(s: String): String =
    MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
