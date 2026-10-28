package app.halo.cloud

import java.io.File

/** Something that can seal and open bytes under a key the file system never sees (on Android: the Keystore). */
interface Sealer {
    fun seal(plain: ByteArray): ByteArray
    /** Throws if the blob was not produced by this sealer's current key (tampered, or the key was reset). */
    fun open(blob: ByteArray): ByteArray
}

/**
 * A small text file that is ciphertext on disk (H-13). Kept in the pure-JVM module so the property that
 * matters — "the bytes at rest are not the plaintext" — is unit-tested without Android; the app supplies a
 * Keystore-backed [Sealer].
 *
 * Layout: [MAGIC] ‖ sealed blob. The magic is what lets a *legacy plaintext* file (written before H-13) be told
 * apart from a sealed one without guessing: `[`/`{` JSON can never start with it.
 *
 *  - [read] of a sealed file returns its text; of a legacy plaintext file returns that text AND immediately
 *    re-writes it sealed (the migration); of a sealed file that can no longer be opened (Keystore reset) returns
 *    null — "empty", never garbage — the same policy the pairing profile uses.
 *  - [write] goes via a temp file + rename so a crash cannot leave a half-written (undecryptable) file.
 */
class SealedFile(private val file: File, private val sealer: Sealer) {
    /** True when [read] found a legacy plaintext file and sealed it. Exposed for tests and diagnostics. */
    @Volatile var lastReadMigrated: Boolean = false; private set

    fun read(): String? {
        lastReadMigrated = false
        val bytes = try { if (file.exists()) file.readBytes() else return null } catch (e: Exception) { return null }
        if (bytes.isEmpty()) return null
        if (!hasMagic(bytes)) {
            // Legacy plaintext: keep the data, but do not leave it readable on disk.
            val text = bytes.toString(Charsets.UTF_8)
            if (runCatching { write(text) }.isSuccess) lastReadMigrated = true
            return text
        }
        return try { sealer.open(bytes.copyOfRange(MAGIC.size, bytes.size)).toString(Charsets.UTF_8) } catch (e: Exception) { null }
    }

    fun write(text: String) {
        val out = MAGIC + sealer.seal(text.toByteArray(Charsets.UTF_8))
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(file)) { file.writeBytes(out); tmp.delete() }
    }

    fun delete() { file.delete(); File(file.parentFile, file.name + ".tmp").delete() }

    private fun hasMagic(b: ByteArray) = b.size >= MAGIC.size && MAGIC.indices.all { b[it] == MAGIC[it] }

    companion object { val MAGIC = byteArrayOf(0x48, 0x53, 0x46, 0x31) }   // "HSF1"
}
