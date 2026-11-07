package app.halo.mobile.cloud

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import app.halo.cloud.KeyAccess
import app.halo.cloud.KeyPolicy
import app.halo.cloud.Keystore
import app.halo.cloud.SealKeyUnusableException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Seals the Firebase credential and the data key at rest under a key that lives in the Android Keystore
 * (hardware-backed where the device has it) and never leaves it. The file on disk is ciphertext; pulling
 * it off the phone yields nothing without the Keystore key. (F-049 D4: "Secure storage (Keystore/Keychain)".)
 *
 * Key creation policy (see [KeyPolicy]): [seal] and [open] NEVER create a key. They used to generate a fresh one
 * whenever `getKey` returned null, which orphaned everything sealed under the old key and made it look "corrupt"
 * (replaceable). Now a missing or permanently unusable key surfaces as [SealKeyUnusableException] and the user is told;
 * a key is created only by [ensureKey], called when pairing and when the user explicitly resets.
 */
object SecretBox : app.halo.cloud.Sealer {
    private const val ALIAS = "halo.cloud.secrets.v1"
    private const val PROVIDER = "AndroidKeyStore"
    private const val IV_BYTES = 12

    private fun keystore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private val policy = KeyPolicy(object : KeyAccess<SecretKey> {
        override fun get(): SecretKey? = keystore().getKey(ALIAS, null) as? SecretKey
        override fun generate(): SecretKey {
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
            gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            return gen.generateKey()
        }
        override fun delete() { keystore().deleteEntry(ALIAS) }
    })

    /** Create the key if there is none (or the old one is permanently unusable). Pairing and an explicit reset only. */
    fun ensureKey() { policy.ensure() }

    /** `iv(12) || ciphertext || tag(16)`. */
    override fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, policy.use())
        return c.iv + c.doFinal(plain)
    }

    /**
     * Only an authentication failure (or an impossible blob) is a [app.halo.cloud.SealCorruptException]; a missing or
     * permanently invalidated key is a [SealKeyUnusableException]; any other Keystore or provider error propagates as
     * itself, which [app.halo.cloud.SealedFile] treats as "try again later — keep the file".
     */
    override fun open(blob: ByteArray): ByteArray {
        if (blob.size <= IV_BYTES) throw app.halo.cloud.SealCorruptException("sealed blob too short")
        val key = policy.use()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        try { c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, IV_BYTES)) }
        catch (e: Exception) { if (Keystore.isPermanentKeyFailure(e)) throw SealKeyUnusableException("the secure key is permanently unusable", e) else throw e }
        return try { c.doFinal(blob, IV_BYTES, blob.size - IV_BYTES) }
        catch (e: javax.crypto.AEADBadTagException) { throw app.halo.cloud.SealCorruptException("authentication failed", e) }
    }

    fun destroy() { runCatching { keystore().deleteEntry(ALIAS) } }
}
