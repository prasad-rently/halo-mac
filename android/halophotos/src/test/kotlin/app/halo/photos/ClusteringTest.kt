package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClusteringTest {
    private fun p(id: Long, mp: Int = 12, mod: Long = 1000, size: Long = 1_000_000) =
        PhotoRef(id, "content://media/$id", "IMG_$id.jpg", size, mp * 1000, 1000, mod)   // width*height = mp megapixels
    private fun h(id: Long, hash: Long, mp: Int = 12, mod: Long = 1000, size: Long = 1_000_000) = HashedPhoto(p(id, mp, mod, size), hash)

    @Test fun `hamming threshold is inclusive`() {
        val a = h(1, 0L); val b = h(2, 0xFFL)      // 8 bits apart
        assertEquals(1, Clustering.groups(listOf(a, b), 8).size)
        assertEquals(0, Clustering.groups(listOf(a, b), 7).size)
    }

    @Test fun `clustering is transitive - a chain of near pairs forms one group`() {
        val a = h(1, 0L); val b = h(2, 0xFFL); val c = h(3, 0xFFFFL)   // a-b 8, b-c 8, a-c 16
        val gs = Clustering.groups(listOf(a, b, c), 8)
        assertEquals(1, gs.size); assertEquals(3, gs[0].items.size)
    }

    @Test fun `singletons never form a group`() {
        assertTrue(Clustering.groups(listOf(h(1, 0L), h(2, -1L)), 8).isEmpty())
    }

    @Test fun `recommended keep is highest resolution`() {
        val g = Clustering.groups(listOf(h(1, 0, mp = 8), h(2, 0, mp = 12, mod = 1), h(3, 0, mp = 10, mod = 9999)), 8).single()
        assertEquals(2L, g.recommendedKeepId)
    }

    @Test fun `resolution ties are broken by most recent modified date, then by lowest id`() {
        assertEquals(2L, Clustering.groups(listOf(h(1, 0, mod = 100), h(2, 0, mod = 200)), 8).single().recommendedKeepId)
        assertEquals(1L, Clustering.groups(listOf(h(2, 0, mod = 100), h(1, 0, mod = 100)), 8).single().recommendedKeepId)
    }

    @Test fun `groups are ordered by reclaimable bytes`() {
        val small = listOf(h(1, 0, size = 10), h(2, 0, size = 10))
        val big = listOf(h(3, -1L, size = 5_000), h(4, -1L, size = 5_000))
        val gs = Clustering.groups(small + big, 8)
        assertEquals(listOf(3L, 1L), gs.map { it.id })
        assertEquals(5_000L, gs[0].wastedBytes)
    }
}
