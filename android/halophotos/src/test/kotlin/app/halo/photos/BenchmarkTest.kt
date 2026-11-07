package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * JVM synthetic benchmark for the 5,000-photo target. It measures the pure-Kotlin pipeline (gray conversion + DCT hash +
 * clustering) fed by pre-rendered 64x48 thumbnails — i.e. everything EXCEPT the image decode, which is device-specific
 * and is NOT measured here (see PR: not verified on a phone). Numbers are printed; the assertion bounds are loose so a
 * slow CI box does not flake, while a 10x algorithmic regression still fails.
 */
class BenchmarkTest {
    @Test fun `5000 photos with planted near-duplicates - hash, cluster, and every planted twin lands in its source's group`() {
        val rnd = Random(42)
        // 4,000 unique scenes; 500 of them get a re-encoded twin and 250 of those a third copy -> 500 groups
        val base = (0 until 4000).map { SyntheticPhotos.scene(it.toLong(), 64, 48) }
        val photos = ArrayList<PhotoRef>(); val img = HashMap<Long, DecodedImage>()
        var id = 1L
        val twinOf = HashMap<Long, Long>()   // twin id -> source id
        for (b in base) { photos += PhotoRef(id, "u$id", "p$id", 3_000_000, 4000, 3000, id); img[id] = b; id++ }
        for (k in 0 until 500) {
            val src = base[k]
            val twin = DecodedImage(IntArray(src.argb.size) { i -> val c = src.argb[i] and 0xFF; val v = (c + rnd.nextInt(7) - 3).coerceIn(0, 255); (0xFF shl 24) or (v shl 16) or (v shl 8) or v }, src.width, src.height)
            twinOf[id] = (k + 1).toLong(); photos += PhotoRef(id, "u$id", "p$id", 2_500_000, 4000, 3000, id); img[id] = twin; id++
            if (k < 250) { twinOf[id] = (k + 1).toLong(); photos += PhotoRef(id, "u$id", "p$id", 2_000_000, 3000, 2250, id); img[id] = twin; id++ }
        }
        // 4000 + 500 + 250 = 4750; padded with unique scenes to exactly 5000
        while (photos.size < 5000) { photos += PhotoRef(id, "u$id", "p$id", 1_000_000, 4000, 3000, id); img[id] = SyntheticPhotos.scene(100_000 + id, 64, 48); id++ }

        val t0 = System.nanoTime()
        val res = ScanEngine.hashAll(photos, { img[it.id] }, parallelism = 4)
        val t1 = System.nanoTime()
        val groups = Clustering.groups(res.hashed, Clustering.DEFAULT_THRESHOLD)
        val t2 = System.nanoTime()
        val msHash = (t1 - t0) / 1_000_000; val msCluster = (t2 - t1) / 1_000_000
        println("BENCH 5000 photos: hash ${msHash} ms (${"%.2f".format(msHash.toDouble() * 4 / 5000)} ms CPU/photo @4 threads), cluster ${msCluster} ms, groups=${groups.size}, cpus=${Runtime.getRuntime().availableProcessors()}")
        assertEquals(5000, res.hashed.size)
        val groupOf = HashMap<Long, Long>(); groups.forEach { g -> g.items.forEach { groupOf[it.photo.id] = g.id } }
        val missed = twinOf.filter { (t, src) -> groupOf[t] == null || groupOf[t] != groupOf[src] }
        assertTrue("planted twins not grouped with their source: ${missed.size}", missed.isEmpty())
        assertTrue("planted groups should all be found: ${groups.size}", groups.size >= 500)
        assertTrue("hash phase far too slow: $msHash ms", msHash < 60_000)
        assertTrue("cluster phase far too slow: $msCluster ms", msCluster < 15_000)
    }
}
