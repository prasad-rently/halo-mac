package app.halo.cloud

import java.io.File
import javax.crypto.AEADBadTagException

/** Something that can seal and open bytes under a key the file system never sees (on Android: the Keystore). */
interface Sealer {
    /** May throw anything (a Keystore that is momentarily unavailable): the caller must not lose data to that. */
    fun seal(plain: ByteArray): ByteArray
    /**
     * Throws [SealCorruptException] (or `AEADBadTagException`) ONLY when the blob cannot be authenticated by a healthy
     * key — tampered, truncated, or written under a key that has since been reset. EVERY OTHER throwable means "could not
     * try right now" (Keystore/provider hiccup, I/O) and is treated as retryable: the file is kept, never replaced.
     */
    fun open(blob: ByteArray): ByteArray
}

/** The blob is not authentic under the current key: its contents are unrecoverable, so replacing it loses nothing. */
class SealCorruptException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** What reading a [SealedFile] found. The distinction between [Corrupt] and [Unavailable] is the data-safety rule (H-13 review). */
sealed interface SealedRead {
    /** [migrated]: a legacy plaintext file was found and has been sealed. [migrationFailed]: it was found but could not be sealed (yet) — it is still on disk as plaintext and sealing is retried on the next write/read. */
    data class Text(val text: String, val migrated: Boolean = false, val migrationFailed: Boolean = false) : SealedRead
    /** No file, or an empty one. */
    object Missing : SealedRead
    /** Authentication failed: unrecoverable by anyone, safe to overwrite. */
    object Corrupt : SealedRead
    /** Could not read or open right now. The file is intact — **do not overwrite it.** */
    data class Unavailable(val reason: String) : SealedRead
}

/**
 * A small text file that is ciphertext on disk (H-13). Kept in the pure-JVM module so the property that
 * matters — "the bytes at rest are not the plaintext" — is unit-tested without Android; the app supplies a
 * Keystore-backed [Sealer].
 *
 * Layout: [MAGIC] ‖ sealed blob. The magic is what lets a *legacy plaintext* file (written before H-13) be told
 * apart from a sealed one without guessing: `[`/`{` JSON can never start with it.
 *
 *  - [readResult] of a sealed file returns its text; of a legacy plaintext file returns that text AND tries to seal it
 *    in place; a failed seal leaves the plaintext untouched and says so ([SealedRead.Text.migrationFailed]).
 *  - Only an authentication failure is [SealedRead.Corrupt]. A thrown I/O or provider error is [SealedRead.Unavailable],
 *    and callers (see [SealedStore]) must then leave the file alone.
 *  - [write] goes via a temp file + rename, and seals BEFORE touching any file, so a failing sealer can never truncate
 *    or replace what is on disk. Nothing here logs; exception messages carry no file contents.
 */
class SealedFile(private val file: File, private val sealer: Sealer) {
    fun readResult(): SealedRead {
        val bytes = try { if (file.exists()) file.readBytes() else return SealedRead.Missing } catch (e: Exception) { return SealedRead.Unavailable("read failed: ${e.javaClass.simpleName}") }
        if (bytes.isEmpty()) return SealedRead.Missing
        if (!hasMagic(bytes)) {
            val text = bytes.toString(Charsets.UTF_8)
            val sealed = runCatching { write(text) }.isSuccess        // seal failed ⇒ plaintext stays exactly as it was
            return SealedRead.Text(text, migrated = sealed, migrationFailed = !sealed)
        }
        return try { SealedRead.Text(sealer.open(bytes.copyOfRange(MAGIC.size, bytes.size)).toString(Charsets.UTF_8)) }
        catch (e: SealCorruptException) { SealedRead.Corrupt }
        catch (e: AEADBadTagException) { SealedRead.Corrupt }
        catch (e: Exception) { SealedRead.Unavailable("open failed: ${e.javaClass.simpleName}") }
    }

    /** Text only when readable; null for missing, corrupt AND unavailable — use [readResult] when the difference matters. */
    fun read(): String? = (readResult() as? SealedRead.Text)?.text

    fun write(text: String) {
        val out = MAGIC + sealer.seal(text.toByteArray(Charsets.UTF_8))     // may throw: nothing has been touched yet
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(file)) { file.writeBytes(out); tmp.delete() }
    }

    fun delete() { file.delete(); File(file.parentFile, file.name + ".tmp").delete() }

    private fun hasMagic(b: ByteArray) = b.size >= MAGIC.size && MAGIC.indices.all { b[it] == MAGIC[it] }

    companion object { val MAGIC = byteArrayOf(0x48, 0x53, 0x46, 0x31) }   // "HSF1"
}

/**
 * The persistence policy around a [SealedFile] (H-13 review). Holds the one rule that matters: **never replace a file
 * whose current contents could not be read.**
 *
 *  - [load] is the initial read. If it was [SealedRead.Unavailable] the store is *blocked*: later [save]s re-read
 *    first, merge what is on disk with what is in memory (via the caller's `produce`), and only then write. While
 *    still unreadable, [save] returns [Outcome.Deferred] and writes nothing — the data stays in memory and on disk.
 *  - A legacy plaintext file that could not be sealed stays "pending": every [save] retries sealing it, reported as
 *    [Outcome.Failed] until it works. The plaintext is therefore exactly as exposed as it was before the upgrade, never more.
 */
class SealedStore(private val file: SealedFile) {
    enum class Outcome { Saved, Deferred, Failed }

    @Volatile var blocked = false; private set
    @Volatile var plaintextPending = false; private set
    /** Human-readable, content-free status for the UI; null when everything is fine. */
    @Volatile var warning: String? = null; private set

    fun load(): String? = absorb(file.readResult())

    private fun absorb(r: SealedRead): String? = when (r) {
        is SealedRead.Text -> { blocked = false; plaintextPending = r.migrationFailed; update(); r.text }
        SealedRead.Missing, SealedRead.Corrupt -> { blocked = false; plaintextPending = false; update(); null }
        is SealedRead.Unavailable -> { blocked = true; update(); null }
    }

    /** [produce] gets the text currently on disk when the store was blocked (so it can merge), else null. */
    @Synchronized fun save(produce: (onDisk: String?) -> String): Outcome {
        var disk: String? = null
        if (blocked) {
            val r = file.readResult()
            if (r is SealedRead.Unavailable) { update(); return Outcome.Deferred }
            disk = absorb(r)
        }
        return try { file.write(produce(disk)); plaintextPending = false; update(); Outcome.Saved }
        catch (e: Exception) { warning = if (plaintextPending) "Clipboard history could not be sealed yet; it will be retried." else "Clipboard history could not be saved; it will be retried."; Outcome.Failed }
    }

    private fun update() {
        warning = when { blocked -> "Clipboard history is temporarily unreadable (Android's secure storage is busy). Nothing was lost; it will be retried."
                         plaintextPending -> "Clipboard history could not be sealed yet; it will be retried."
                         else -> null }
    }

    fun delete() { file.delete(); blocked = false; plaintextPending = false; warning = null }
}
