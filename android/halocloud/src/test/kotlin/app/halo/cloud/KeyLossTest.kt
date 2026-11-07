package app.halo.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.KeyStoreException
import java.security.SecureRandom
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * H-13 / #61 leftovers: the Keystore key can be transiently unavailable, permanently lost, or absent. Each is a different
 * state with a different consequence for the data sealed under it, and none of them may end in a silent overwrite.
 */
class KeyLossTest {
    @get:Rule val tmp = TemporaryFolder()

    /** A fake Keystore entry. */
    private class FakeKeys : KeyAccess<SecretKeySpec> {
        var key: SecretKeySpec? = SecretKeySpec(ByteArray(32) { (it * 7 + 1).toByte() }, "AES")
        var getFailure: Exception? = null
        var generated = 0; var deleted = 0
        override fun get(): SecretKeySpec? { getFailure?.let { throw it }; return key }
        override fun generate(): SecretKeySpec { generated++; return SecretKeySpec(ByteArray(32).also { SecureRandom().nextBytes(it) }, "AES").also { key = it } }
        override fun delete() { deleted++; key = null; getFailure = null }
    }

    /** A Sealer over the policy, as SecretBox is on Android. */
    private class PolicySealer(val policy: KeyPolicy<SecretKeySpec>) : Sealer {
        override fun seal(plain: ByteArray): ByteArray {
            val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, policy.use(), GCMParameterSpec(128, iv))
            return iv + c.doFinal(plain)
        }
        override fun open(blob: ByteArray): ByteArray {
            if (blob.size <= 12) throw SealCorruptException("short")
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, policy.use(), GCMParameterSpec(128, blob, 0, 12))
            return try { c.doFinal(blob, 12, blob.size - 12) } catch (e: javax.crypto.AEADBadTagException) { throw SealCorruptException("auth", e) }
        }
    }

    private fun rig() = FakeKeys().let { it to PolicySealer(KeyPolicy(it)) }

    // ── the policy: who may create a key ────────────────────────────────────────────────────────

    @Test fun `opening and sealing never create a key - a missing key is KeyUnusable, not a fresh start`() {
        val (keys, sealer) = rig()
        val blob = sealer.seal("secret".toByteArray())
        keys.key = null                                                   // the Keystore lost the entry
        assertThrows(SealKeyUnusableException::class.java) { sealer.open(blob) }
        assertThrows(SealKeyUnusableException::class.java) { sealer.seal("more".toByteArray()) }
        assertEquals("nothing silently regenerated the key", 0, keys.generated)
        assertNull(keys.key)
    }

    @Test fun `a permanent key failure is KeyUnusable, a transient one is rethrown as itself`() {
        val (keys, sealer) = rig()
        val blob = sealer.seal("x".toByteArray())
        keys.getFailure = UnrecoverableKeyException("invalidated")
        assertThrows(SealKeyUnusableException::class.java) { sealer.open(blob) }
        keys.getFailure = RuntimeException("wrapped", UnrecoverableKeyException("inner"))
        assertThrows(SealKeyUnusableException::class.java) { sealer.open(blob) }
        keys.getFailure = KeyStoreException("keystore daemon busy")
        assertThrows(KeyStoreException::class.java) { sealer.open(blob) }          // transient: stays itself, so the file layer calls it Unavailable
        assertEquals(0, keys.generated); assertEquals(0, keys.deleted)
    }

    @Test fun `ensure creates a key only when there is none or the old one is permanently unusable`() {
        val (keys, _) = rig(); val policy = KeyPolicy(keys)
        val before = keys.key; policy.ensure(); assertEquals("existing key kept", 0, keys.generated); assertTrue(before === keys.key)
        keys.key = null; policy.ensure(); assertEquals(1, keys.generated)
        keys.getFailure = UnrecoverableKeyException("x"); policy.ensure()
        assertEquals("the unusable entry was removed then replaced", 1, keys.deleted); assertEquals(2, keys.generated)
        keys.getFailure = KeyStoreException("busy")
        assertThrows(KeyStoreException::class.java) { policy.ensure() }
        assertEquals("a transient failure is never answered with a new key", 2, keys.generated); assertEquals(1, keys.deleted)
    }

    @Test fun `permanent-failure detection looks through causes and matches Android's invalidation by name`() {
        assertTrue(Keystore.isPermanentKeyFailure(UnrecoverableKeyException()))
        assertTrue(Keystore.isPermanentKeyFailure(IllegalStateException("a", IllegalArgumentException("b", UnrecoverableKeyException()))))
        assertFalse(Keystore.isPermanentKeyFailure(KeyStoreException()))
        assertFalse(Keystore.isPermanentKeyFailure(java.io.IOException()))
    }

    // ── a lost key under SealedFile / SealedStore (the clipboard history) ───────────────────────

    @Test fun `a lost key reads as KeyUnusable - never Corrupt - and the file is not touched`() {
        val (keys, sealer) = rig(); val f = File(tmp.root, "h.bin"); val sf = SealedFile(f, sealer)
        sf.write("history"); val onDisk = f.readBytes()
        keys.key = null
        assertEquals(SealedRead.KeyUnusable, sf.readResult())
        keys.getFailure = UnrecoverableKeyException("x"); keys.key = SecretKeySpec(ByteArray(32), "AES")
        assertEquals(SealedRead.KeyUnusable, sf.readResult())
        keys.getFailure = KeyStoreException("busy")
        assertTrue("transient is Unavailable, a different state", sf.readResult() is SealedRead.Unavailable)
        assertArrayEquals(onDisk, f.readBytes())
    }

    @Test fun `with the key lost the store surfaces an actionable state and keeps the file, instead of silently holding clips in memory`() {
        val (keys, sealer) = rig(); val f = File(tmp.root, "h.bin"); val sf = SealedFile(f, sealer)
        sf.write("[old]"); val onDisk = f.readBytes()
        keys.key = null
        val store = SealedStore(sf)
        assertNull(store.load())
        assertTrue(store.keyLost); assertTrue(store.blocked)
        assertTrue("says what happened and what to do", store.warning!!.contains("secure key was lost") && store.warning!!.contains("reset"))
        assertFalse("not the 'will be retried' wording that can never come true", store.warning!!.contains("will be retried"))
        assertEquals(SealedStore.Outcome.Deferred, store.save { "[new]" })
        assertArrayEquals("the old file is untouched", onDisk, f.readBytes())
        assertEquals(0, keys.generated)
        // The user resets: the file goes, a key is created explicitly, and saving works again.
        store.delete(); KeyPolicy(keys).ensure()
        assertFalse(store.keyLost); assertNull(store.warning)
        assertEquals(SealedStore.Outcome.Saved, store.save { "[new]" })
        assertEquals("[new]", SealedFile(f, sealer).read())
    }

    @Test fun `if the key comes back, the next save re-reads and merges - nothing is lost`() {
        val (keys, sealer) = rig(); val f = File(tmp.root, "h.bin"); val sf = SealedFile(f, sealer)
        sf.write("[disk]"); val saved = keys.key
        keys.key = null
        val store = SealedStore(sf); store.load()
        assertEquals(SealedStore.Outcome.Deferred, store.save { "[mem]" })
        keys.key = saved                                                  // e.g. the Keystore finished restoring
        var seen: String? = "unset"
        assertEquals(SealedStore.Outcome.Saved, store.save { disk -> seen = disk; "$disk+[mem]" })
        assertEquals("[disk]", seen); assertFalse(store.keyLost); assertEquals("[disk]+[mem]", sf.read())
    }

    // ── the pairing profile (CloudStore.load) ───────────────────────────────────────────────────

    private fun blob(name: String = "p.bin") = File(tmp.root, name)

    @Test fun `profile load distinguishes loaded, missing, corrupt, unavailable and key-lost`() {
        val (keys, sealer) = rig(); val f = blob(); val b = SealedBlobFile(f, sealer)
        assertEquals(ProfileLoad.Missing, b.load { it })
        b.write("""{"ok":1}""")
        assertEquals(ProfileLoad.Loaded("""{"ok":1}"""), b.load { it })
        assertEquals("unparsable content after a good open is Corrupt", ProfileLoad.Corrupt, b.load { error("bad json") })
        val bytes = f.readBytes(); f.writeBytes(bytes.also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() })
        assertEquals("tampered ⇒ authentication failure ⇒ Corrupt", ProfileLoad.Corrupt, b.load { it })
        f.writeBytes(byteArrayOf(1, 2, 3)); assertEquals(ProfileLoad.Corrupt, b.load { it })
        f.writeBytes(ByteArray(0)); assertEquals(ProfileLoad.Missing, b.load { it })
        b.write("again")
        keys.getFailure = KeyStoreException("busy")
        assertTrue(b.load { it } is ProfileLoad.Unavailable)
        keys.getFailure = UnrecoverableKeyException("gone")
        assertEquals(ProfileLoad.KeyLost, b.load { it })
        keys.getFailure = null; keys.key = null
        assertEquals("a missing key with a file present is KeyLost, not 'not paired'", ProfileLoad.KeyLost, b.load { it })
    }

    @Test fun `a transient Keystore failure is NOT 'not paired' and never costs the profile`() {
        val (keys, sealer) = rig(); val f = blob(); val b = SealedBlobFile(f, sealer)
        b.write("profile"); val onDisk = f.readBytes()
        keys.getFailure = KeyStoreException("after OTA the keystore daemon was not ready")
        val r = b.load { it }
        assertTrue(r is ProfileLoad.Unavailable); assertFalse(r == ProfileLoad.Missing || r == ProfileLoad.Corrupt)
        assertArrayEquals("file untouched", onDisk, f.readBytes())
        keys.getFailure = null
        assertEquals("a retry after recovery reads it", ProfileLoad.Loaded("profile"), b.load { it })
    }

    @Test fun `a successful write leaves no temp file, and a write that cannot be completed leaves the old file intact and no temp behind`() {
        val (_, sealer) = rig(); val f = blob(); val b = SealedBlobFile(f, sealer)
        b.write("v1"); assertFalse(File(f.parentFile, f.name + ".tmp").exists())
        val v1 = f.readBytes()
        // Something that is not a regular file sits where the temp file must go: the write cannot even begin.
        val tmpPath = File(f.parentFile, f.name + ".tmp"); tmpPath.mkdir()
        assertThrows(Exception::class.java) { b.write("v2") }
        assertArrayEquals("the old profile is untouched (no truncating fallback write)", v1, f.readBytes())
        tmpPath.delete()
        b.write("v3"); assertEquals(ProfileLoad.Loaded("v3"), b.load { it })
        val sf = SealedFile(blob("h.bin"), sealer); sf.write("a"); sf.write("b")
        assertEquals("b", sf.read()); assertFalse(File(tmp.root, "h.bin.tmp").exists())
    }

    @Test fun `an unreadable profile file is Unavailable, and a failing sealer on write leaves the old file intact`() {
        val (keys, sealer) = rig(); val f = blob(); val b = SealedBlobFile(f, sealer)
        b.write("v1"); val v1 = f.readBytes()
        keys.getFailure = KeyStoreException("busy")
        assertThrows(KeyStoreException::class.java) { b.write("v2") }
        keys.getFailure = null
        assertArrayEquals("a write whose sealing failed touched nothing", v1, f.readBytes())
        assertFalse(File(f.parentFile, f.name + ".tmp").exists())
        val dir = blob("asdir"); dir.mkdir()
        assertTrue("a directory where the file should be is unavailable, not 'not paired'", SealedBlobFile(dir, sealer).load { it } is ProfileLoad.Unavailable)
    }
}
