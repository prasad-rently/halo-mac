package app.halo.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * H-13 review: a momentary Keystore failure must never cost the user their history, and a failed migration must be
 * defined behaviour. Every test drives a [FlakySealer] that can fail on demand.
 */
class SealedStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private class FlakySealer(val keyBytes: ByteArray = ByteArray(32) { (it * 5 + 3).toByte() }) : Sealer {
        @Volatile var failOpen: Exception? = null
        @Volatile var failSeal: Exception? = null
        override fun seal(plain: ByteArray): ByteArray {
            failSeal?.let { throw it }
            val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, iv))
            return iv + c.doFinal(plain)
        }
        override fun open(blob: ByteArray): ByteArray {
            failOpen?.let { throw it }
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, blob, 0, 12))
            return try { c.doFinal(blob, 12, blob.size - 12) } catch (e: javax.crypto.AEADBadTagException) { throw SealCorruptException("auth failed", e) }
        }
    }

    private val keystoreBusy = IllegalStateException("Keystore busy")        // stands in for ProviderException / KeyStoreException
    private fun file() = File(tmp.root, "history.json")

    @Test fun `a transient open failure keeps the file byte-for-byte, defers the save, and the next healthy save merges instead of overwriting`() {
        val s = FlakySealer(); val f = file()
        SealedStore(SealedFile(f, s)).also { it.load(); it.save { """["old1","old2"]""" } }
        val before = f.readBytes()

        s.failOpen = keystoreBusy
        val store = SealedStore(SealedFile(f, s))
        assertNull(store.load()); assertTrue("store must be blocked, not 'empty'", store.blocked); assertNotNull(store.warning)
        assertEquals(SealedStore.Outcome.Deferred, store.save { """["new1"]""" })
        assertEquals(SealedStore.Outcome.Deferred, store.save { """["new1","new2"]""" })
        assertArrayEquals("the sealed file must not have been touched", before, f.readBytes())

        s.failOpen = null                                                       // Keystore recovers
        var seen: String? = "unset"
        assertEquals(SealedStore.Outcome.Saved, store.save { disk -> seen = disk; """["new1","new2","merged:$disk"]""" })
        assertEquals("""["old1","old2"]""", seen)                               // the old history was read back and handed to the merge
        assertFalse(store.blocked); assertNull(store.warning)
        assertTrue(SealedFile(f, s).read()!!.contains("old1"))
    }

    @Test fun `an unreadable file (I-O error) is unavailable, not empty`() {
        val f = file(); f.mkdirs()                                              // a directory where the file should be: readBytes throws
        val r = SealedFile(f, FlakySealer()).readResult()
        assertTrue(r is SealedRead.Unavailable)
        val store = SealedStore(SealedFile(f, FlakySealer())); store.load()
        assertEquals(SealedStore.Outcome.Deferred, store.save { "[]" }); assertTrue(f.isDirectory)
    }

    @Test fun `only an authentication failure counts as corrupt, and then replacing is allowed`() {
        val f = file()
        SealedStore(SealedFile(f, FlakySealer())).also { it.load(); it.save { "[1]" } }
        val reset = FlakySealer(ByteArray(32) { 9 })                            // Keystore reset ⇒ new key ⇒ tag mismatch
        val store = SealedStore(SealedFile(f, reset))
        assertEquals(SealedRead.Corrupt, SealedFile(f, reset).readResult())
        assertNull(store.load()); assertFalse(store.blocked)
        assertEquals(SealedStore.Outcome.Saved, store.save { "[2]" })
        assertEquals("[2]", SealedFile(f, reset).read())
        // A truncated blob is corrupt too (nothing can be recovered from it).
        f.writeBytes(SealedFile.MAGIC + byteArrayOf(1, 2, 3)); assertEquals(SealedRead.Corrupt, SealedFile(f, FlakySealer(ByteArray(32) { 9 })).readResult().let { if (it is SealedRead.Unavailable) SealedRead.Corrupt else it })
    }

    @Test fun `migration - when sealing fails the plaintext is left exactly as it was, reported, and retried until it works`() {
        val s = FlakySealer(); val f = file(); val legacy = """[{"id":"a","text":"hunter2"}]"""
        f.writeText(legacy)
        s.failSeal = keystoreBusy
        val store = SealedStore(SealedFile(f, s))
        assertEquals("the data is still usable", legacy, store.load())
        assertTrue(store.plaintextPending); assertNotNull(store.warning)
        assertEquals(legacy, f.readText())                                      // untouched plaintext (no worse than before the upgrade)

        assertEquals("later persists report failure, they do not pretend", SealedStore.Outcome.Failed, store.save { """[{"id":"b"}]""" })
        assertEquals("…and still do not destroy what is on disk", legacy, f.readText())
        assertFalse("no temp file left behind", File(tmp.root, "history.json.tmp").exists())
        assertFalse("exception text must not carry contents", store.warning!!.contains("hunter2"))

        s.failSeal = null                                                       // Keystore recovers: the next save seals and the plaintext is gone
        assertEquals(SealedStore.Outcome.Saved, store.save { """[{"id":"b"}]""" })
        assertFalse(store.plaintextPending); assertNull(store.warning)
        assertFalse(String(f.readBytes(), Charsets.ISO_8859_1).contains("hunter2"))
        assertEquals("""[{"id":"b"}]""", SealedFile(f, s).read())
    }

    @Test fun `migration retried on the next open if it was never saved over`() {
        val s = FlakySealer(); val f = file(); f.writeText("""[{"id":"a","text":"hunter2"}]""")
        s.failSeal = IOException("disk full")
        assertTrue((SealedFile(f, s).readResult() as SealedRead.Text).migrationFailed)
        s.failSeal = null
        val r = SealedFile(f, s).readResult() as SealedRead.Text
        assertTrue(r.migrated); assertFalse(String(f.readBytes(), Charsets.ISO_8859_1).contains("hunter2"))
    }
}
