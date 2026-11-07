package app.halo.photos

import java.util.concurrent.atomic.AtomicInteger

/** Decodes a small thumbnail (<= ~64 px on the long side is enough). MUST be thread-safe; return null if undecodable. */
fun interface ThumbnailDecoder { fun decode(photo: PhotoRef): DecodedImage? }

class CancelToken { @Volatile var isCancelled = false; fun cancel() { isCancelled = true } }
class ScanCancelled : RuntimeException("scan cancelled")

class ScanResult(val hashed: List<HashedPhoto>, val failed: Int, val totalConsidered: Int, val truncatedFrom: Int?)

/**
 * Phase 1 of a scan: thumbnail -> 64-bit hash for every photo. Clustering is a separate, cheap step
 * ([Clustering.groups]) so moving the threshold slider re-groups instantly without re-decoding anything.
 *
 * Bounded memory by construction: `parallelism` workers each hold ONE thumbnail at a time and pull the next index from
 * an atomic counter — nothing is queued up front, and the retained result is just (PhotoRef, Long) per photo.
 */
object ScanEngine {
    fun hashAll(
        photos: List<PhotoRef>,
        decoder: ThumbnailDecoder,
        cancel: CancelToken = CancelToken(),
        parallelism: Int = 4,
        /** Called from worker threads (done, total). Make it thread-safe / post to the UI. */
        onProgress: (Int, Int) -> Unit = { _, _ -> },
    ): ScanResult {
        // Newest first, then cap — the same bound the desktop scanners use.
        val ordered = photos.sortedByDescending { it.modifiedEpochSec }
        val capped = ordered.take(Clustering.MAX_PHOTOS)
        val n = capped.size
        val hashes = LongArray(n)
        val ok = BooleanArray(n)
        val next = AtomicInteger(0)
        val done = AtomicInteger(0)
        val failed = AtomicInteger(0)
        val error = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)

        val workers = List(parallelism.coerceIn(1, 16)) {
            Thread {
                while (!cancel.isCancelled && error.get() == null) {
                    val i = next.getAndIncrement()
                    if (i >= n) break
                    try {
                        val img = decoder.decode(capped[i])
                        if (img != null) { hashes[i] = Gray.hash(img); ok[i] = true } else failed.incrementAndGet()
                    } catch (e: Exception) { failed.incrementAndGet() }
                    catch (e: OutOfMemoryError) { failed.incrementAndGet() }
                    catch (t: Throwable) { error.compareAndSet(null, t); break }
                    onProgress(done.incrementAndGet(), n)
                }
            }.also { it.isDaemon = true; it.start() }
        }
        workers.forEach { it.join() }
        error.get()?.let { throw it }
        if (cancel.isCancelled) throw ScanCancelled()

        val out = ArrayList<HashedPhoto>(n)
        for (i in 0 until n) if (ok[i]) out += HashedPhoto(capped[i], hashes[i])
        return ScanResult(out, failed.get(), n, if (photos.size > n) photos.size else null)
    }
}
