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

/**
 * The key that sealed this data can never be used again (the Keystore entry is gone, or unrecoverable/invalidated).
 * Unlike [SealCorruptException] this says nothing about the *blob* — it is intact, just unreadable by anyone — so it is
 * never "safe to replace" silently: the user is told, and explicitly resets. Unlike a transient failure, retrying
 * will not help (but costs nothing, so callers still re-check).
 */
class SealKeyUnusableException(message: String, cause: Throwable? = null) : Exception(message, cause)

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
    /** The file is intact but its key is permanently gone ([SealKeyUnusableException]). **Do not overwrite it silently** — surface it and let the user reset. */
    object KeyUnusable : SealedRead
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
        catch (e: SealKeyUnusableException) { SealedRead.KeyUnusable }
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
    /** The file's key is permanently gone: nothing on disk can be read again and the user has to reset (see [warning]). Implies [blocked]. */
    @Volatile var keyLost = false; private set
    @Volatile var plaintextPending = false; private set
    /** Human-readable, content-free status for the UI; null when everything is fine. */
    @Volatile var warning: String? = null; private set

    @Synchronized fun load(): String? = absorb(file.readResult())

    private fun absorb(r: SealedRead): String? = when (r) {
        is SealedRead.Text -> { blocked = false; keyLost = false; plaintextPending = r.migrationFailed; update(); r.text }
        SealedRead.Missing, SealedRead.Corrupt -> { blocked = false; keyLost = false; plaintextPending = false; update(); null }
        is SealedRead.Unavailable -> { blocked = true; keyLost = false; update(); null }
        SealedRead.KeyUnusable -> { blocked = true; keyLost = true; update(); null }
    }

    /** [produce] gets the text currently on disk when the store was blocked (so it can merge), else null. */
    @Synchronized fun save(produce: (onDisk: String?) -> String): Outcome {
        var disk: String? = null
        if (blocked) {
            val r = file.readResult()
            if (r is SealedRead.Unavailable || r is SealedRead.KeyUnusable) { absorb(r); return Outcome.Deferred }
            disk = absorb(r)
        }
        return try { file.write(produce(disk)); plaintextPending = false; update(); Outcome.Saved }
        catch (e: Exception) { warning = if (plaintextPending) "Clipboard history could not be sealed yet; it will be retried." else "Clipboard history could not be saved; it will be retried."; Outcome.Failed }
    }

    private fun update() {
        warning = when { keyLost -> "Clipboard history can't be unlocked: this phone's secure key was lost, so the saved history is unreadable. New clips are only held in memory until you reset the history."
                         blocked -> "Clipboard history is temporarily unreadable (Android's secure storage is busy). Nothing was lost; it will be retried."
                         plaintextPending -> "Clipboard history could not be sealed yet; it will be retried."
                         else -> null }
    }

    @Synchronized fun delete() { file.delete(); blocked = false; keyLost = false; plaintextPending = false; warning = null }
}


/**
 * Keystore failure triage. A permanent failure ([java.security.UnrecoverableKeyException], or Android's
 * `KeyPermanentlyInvalidatedException`, matched by name so this module stays Android-free) means the key is gone for
 * good; anything else (`KeyStoreException`, provider/IPC errors…) is treated as transient and retried.
 */
object Keystore {
    fun isPermanentKeyFailure(t: Throwable): Boolean =
        generateSequence(t) { it.cause }.take(8).any { it is java.security.UnrecoverableKeyException || it.javaClass.name == "android.security.keystore.KeyPermanentlyInvalidatedException" }
}

/** A key store as the policy sees it: read, create, delete. On Android: the AndroidKeyStore entry. */
interface KeyAccess<K : Any> {
    /** The key, or null if there is none. May throw. */
    fun get(): K?
    fun generate(): K
    fun delete()
}

/**
 * When a key may be created. The rule (H-13 follow-up): **sealing and opening never create a key.** Silently making a
 * new one whenever `get()` returned null orphaned every blob sealed under the old key — they would then fail
 * authentication and look "corrupt", i.e. replaceable. A key is created only by [ensure], which the pairing flow and an
 * explicit user reset call.
 */
class KeyPolicy<K : Any>(private val access: KeyAccess<K>) {
    /** For seal and open. Throws [SealKeyUnusableException] for a missing/permanently unusable key, the original exception for a transient one. */
    fun use(): K {
        val k = try { access.get() } catch (e: Exception) {
            if (Keystore.isPermanentKeyFailure(e)) throw SealKeyUnusableException("the secure key is permanently unusable", e) else throw e
        }
        return k ?: throw SealKeyUnusableException("the secure key is missing")
    }

    /** Make sure a usable key exists, creating one if there is none or the old one is permanently unusable (nothing sealed under it can be read anyway). A transient failure is rethrown — never answered with a new key. */
    fun ensure(): K {
        val existing = try { access.get() } catch (e: Exception) {
            if (!Keystore.isPermanentKeyFailure(e)) throw e
            access.delete(); null
        }
        return existing ?: access.generate()
    }
}

/** What loading a sealed profile found (the pairing profile is a raw sealed blob, no magic header). */
sealed interface ProfileLoad<out T> {
    data class Loaded<T>(val value: T) : ProfileLoad<T>
    /** No file: not paired. */
    object Missing : ProfileLoad<Nothing>
    /** Authentic-decryption failed or the content is unparsable: unrecoverable, so pairing again (which replaces it) loses nothing. */
    object Corrupt : ProfileLoad<Nothing>
    /** Could not open it right now (a Keystore hiccup, an I/O error). The file is intact: show "temporarily unavailable — will retry" and **never overwrite it**. */
    data class Unavailable(val reason: String) : ProfileLoad<Nothing>
    /** The key is permanently gone: say so and offer "reset and pair again"; do not pretend it is merely "not paired". */
    object KeyLost : ProfileLoad<Nothing>
}

/** A sealed file with no magic header (the on-disk format of `cloud-profile.bin`, unchanged), with the same Unavailable/Corrupt/KeyLost triage as [SealedFile]. */
class SealedBlobFile(private val file: File, private val sealer: Sealer) {
    fun <T> load(parse: (String) -> T): ProfileLoad<T> {
        val bytes = try { if (file.exists()) file.readBytes() else return ProfileLoad.Missing } catch (e: Exception) { return ProfileLoad.Unavailable("read failed: ${e.javaClass.simpleName}") }
        if (bytes.isEmpty()) return ProfileLoad.Missing
        val plain = try { sealer.open(bytes) }
        catch (e: SealKeyUnusableException) { return ProfileLoad.KeyLost }
        catch (e: SealCorruptException) { return ProfileLoad.Corrupt }
        catch (e: AEADBadTagException) { return ProfileLoad.Corrupt }
        catch (e: Exception) { return ProfileLoad.Unavailable("open failed: ${e.javaClass.simpleName}") }
        return try { ProfileLoad.Loaded(parse(plain.toString(Charsets.UTF_8))) } catch (e: Exception) { ProfileLoad.Corrupt }
    }

    /** Seals first (a failing sealer touches nothing), then temp + rename. */
    fun write(text: String) {
        val out = sealer.seal(text.toByteArray(Charsets.UTF_8))
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(file)) { file.writeBytes(out); tmp.delete() }
    }

    fun delete() { file.delete(); File(file.parentFile, file.name + ".tmp").delete() }
}
