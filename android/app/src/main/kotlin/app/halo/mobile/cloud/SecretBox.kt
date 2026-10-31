package app.halo.mobile.cloud

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Seals the Firebase credential and the data key at rest under a key that lives in the Android Keystore
 * (hardware-backed where the device has it) and never leaves it. The file on disk is ciphertext; pulling
 * it off the phone yields nothing without the Keystore key. (F-049 D4: "Secure storage (Keystore/Keychain)".)
 */
object SecretBox : app.halo.cloud.Sealer {
    private const val ALIAS = "halo.cloud.secrets.v1"
    private const val PROVIDER = "AndroidKeyStore"
    private const val IV_BYTES = 12

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return gen.generateKey()
    }

    /** `iv(12) || ciphertext || tag(16)`. */
    override fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(plain)
    }

    /**
     * Only an authentication failure (or an impossible blob) is a [app.halo.cloud.SealCorruptException]; a Keystore or
     * provider error propagates as itself, which [app.halo.cloud.SealedFile] treats as "try again later — keep the file".
     */
    override fun open(blob: ByteArray): ByteArray {
        if (blob.size <= IV_BYTES) throw app.halo.cloud.SealCorruptException("sealed blob too short")
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_BYTES))
        return try { c.doFinal(blob, IV_BYTES, blob.size - IV_BYTES) }
        catch (e: javax.crypto.AEADBadTagException) { throw app.halo.cloud.SealCorruptException("authentication failed", e) }
    }

    fun destroy() { runCatching { KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS) } }
}
