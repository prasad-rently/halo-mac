package app.halo.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.SecureRandom

/** H-13: the clipboard history file is ciphertext at rest, and an existing plaintext file is migrated. */
class SealedFileTest {
    @get:Rule val tmp = TemporaryFolder()

    /** The same construction the app's Keystore SecretBox uses (AES-256-GCM, iv‖ct‖tag), with an in-memory key. */
    private class AesSealer(val keyBytes: ByteArray = ByteArray(32) { (it * 7 + 1).toByte() }) : Sealer {
        override fun seal(plain: ByteArray): ByteArray {
            val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, iv))
            return iv + c.doFinal(plain)
        }
        override fun open(blob: ByteArray): ByteArray {
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, blob, 0, 12))
            return c.doFinal(blob, 12, blob.size - 12)
        }
    }

    private val secret = """[{"id":"a","text":"hunter2 is my bank PIN","kind":"text"}]"""

    @Test fun `what is written is ciphertext, and reads back`() {
        val f = File(tmp.root, "clipboard-history.json")
        val sf = SealedFile(f, AesSealer())
        sf.write(secret)
        val onDisk = f.readBytes()
        assertFalse("plaintext must not appear on disk", String(onDisk, Charsets.ISO_8859_1).contains("hunter2"))
        assertFalse(String(onDisk, Charsets.ISO_8859_1).contains("bank PIN"))
        assertArrayEquals(SealedFile.MAGIC, onDisk.copyOfRange(0, 4))
        assertEquals(secret, SealedFile(f, AesSealer()).read())
    }

    @Test fun `an existing plaintext file is read once and sealed in place`() {
        val f = File(tmp.root, "clipboard-history.json"); f.writeText(secret)         // what v2.5 wrote
        val sf = SealedFile(f, AesSealer())
        val r = sf.readResult() as SealedRead.Text
        assertEquals(secret, r.text)
        assertTrue(r.migrated)
        assertFalse("plaintext must be gone after migration", String(f.readBytes(), Charsets.ISO_8859_1).contains("hunter2"))
        assertEquals(secret, SealedFile(f, AesSealer()).read())       // and still readable afterwards
    }

    @Test fun `a sealed file whose key is gone reads as empty, never as garbage, and is not mistaken for plaintext`() {
        val f = File(tmp.root, "clipboard-history.json")
        SealedFile(f, AesSealer()).write(secret)
        val other = SealedFile(f, AesSealer(ByteArray(32) { 9 }))     // Keystore reset ⇒ a different key
        assertNull(other.read())
        assertEquals(SealedRead.Corrupt, other.readResult())
    }

    @Test fun `a tampered sealed file reads as empty`() {
        val f = File(tmp.root, "clipboard-history.json")
        SealedFile(f, AesSealer()).write(secret)
        val b = f.readBytes(); b[b.size - 3] = (b[b.size - 3].toInt() xor 1).toByte(); f.writeBytes(b)
        assertNull(SealedFile(f, AesSealer()).read())
    }

    @Test fun `missing and empty files read as null, delete removes the file`() {
        val f = File(tmp.root, "x.json"); val sf = SealedFile(f, AesSealer())
        assertNull(sf.read()); f.writeBytes(ByteArray(0)); assertNull(sf.read())
        sf.write("[]"); assertTrue(f.exists()); sf.delete(); assertFalse(f.exists())
    }
}
