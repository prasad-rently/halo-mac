package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Random
import java.util.concurrent.atomic.AtomicInteger

/** A procedural "photo": smooth blobs defined by a seed, renderable at any resolution, with optional noise/brightness. */
internal object SyntheticPhotos {
    fun scene(seed: Long, w: Int, h: Int, noise: Int = 0, noiseSeed: Long = 0, gain: Double = 1.0): DecodedImage {
        val r = Random(seed)
        val blobs = List(6) { doubleArrayOf(r.nextDouble(), r.nextDouble(), 0.08 + r.nextDouble() * 0.25, 0.2 + r.nextDouble() * 0.8) }
        val nr = Random(noiseSeed)
        val px = IntArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            var v = 0.12
            for (b in blobs) { val dx = (x + 0.5) / w - b[0]; val dy = (y + 0.5) / h - b[1]; v += b[3] * Math.exp(-(dx * dx + dy * dy) / (2 * b[2] * b[2])) * 0.5 }
            var g = (v * gain).coerceIn(0.0, 1.0) * 255
            if (noise > 0) g += nr.nextInt(2 * noise + 1) - noise
            val i = g.coerceIn(0.0, 255.0).toInt()
            px[y * w + x] = (0xFF shl 24) or (i shl 16) or (i shl 8) or i
        }
        return DecodedImage(px, w, h)
    }
}

class ScanEngineTest {
    private fun ref(id: Long, mod: Long = id) = PhotoRef(id, "content://media/$id", "IMG_$id.jpg", 1_000_000, 4000, 3000, mod)

    @Test fun `re-encoded and resized copies of one scene group together, a different scene does not`() {
        val photos = listOf(ref(1), ref(2), ref(3), ref(4))
        val decoder = ThumbnailDecoder { p ->
            when (p.id) {
                1L -> SyntheticPhotos.scene(7, 64, 48)
                2L -> SyntheticPhotos.scene(7, 64, 48, noise = 6, noiseSeed = 1)             // recompressed
                3L -> SyntheticPhotos.scene(7, 40, 30, noise = 3, noiseSeed = 2, gain = 1.04) // resized + slight exposure change
                else -> SyntheticPhotos.scene(8, 64, 48)                                       // a different picture
            }
        }
        val res = ScanEngine.hashAll(photos, decoder)
        val groups = Clustering.groups(res.hashed, Clustering.DEFAULT_THRESHOLD)
        assertEquals(1, groups.size)
        assertEquals(setOf(1L, 2L, 3L), groups[0].items.map { it.photo.id }.toSet())
    }

    @Test fun `undecodable photos are counted, not fatal`() {
        val res = ScanEngine.hashAll(listOf(ref(1), ref(2), ref(3)), ThumbnailDecoder { p -> if (p.id == 2L) null else if (p.id == 3L) error("corrupt") else SyntheticPhotos.scene(1, 32, 32) })
        assertEquals(1, res.hashed.size); assertEquals(2, res.failed)
    }

    @Test fun `cancel stops the scan promptly and reports cancellation`() {
        val token = CancelToken(); val decoded = AtomicInteger()
        val photos = (1L..2000L).map { ref(it) }
        try {
            ScanEngine.hashAll(photos, { decoded.incrementAndGet().also { if (it == 20) token.cancel() }; Thread.sleep(1); SyntheticPhotos.scene(1, 32, 32) }, token, parallelism = 2)
            fail("expected cancellation")
        } catch (_: ScanCancelled) {}
        assertTrue("kept decoding after cancel: ${decoded.get()}", decoded.get() < 100)
    }

    @Test fun `scan is capped at 20000 newest photos and says so`() {
        val photos = (1L..20_050L).map { ref(it) }
        val seen = AtomicInteger()
        val res = ScanEngine.hashAll(photos, { seen.incrementAndGet(); DecodedImage(IntArray(4) { 0xFF808080.toInt() }, 2, 2) }, parallelism = 8)
        assertEquals(20_000, seen.get()); assertEquals(20_050, res.truncatedFrom)
        assertTrue(res.hashed.none { it.photo.id <= 50 })              // the oldest 50 were the ones dropped
    }

    @Test fun `progress reaches total and never exceeds it`() {
        val max = AtomicInteger(); var total = 0
        ScanEngine.hashAll((1L..300L).map { ref(it) }, ThumbnailDecoder { SyntheticPhotos.scene(it.id, 16, 16) }, parallelism = 4, onProgress = { d, t -> total = t; max.accumulateAndGet(d) { a, b -> maxOf(a, b) } })
        assertEquals(300, max.get()); assertEquals(300, total)
    }
}
