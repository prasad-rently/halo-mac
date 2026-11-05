package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Review of PR #69: stale-confirm protection and the transitive-chain (union-find) mitigation. */
class FreshnessAndChainTest {
    private fun ref(id: Long, size: Long = 1_000, mod: Long = 100, w: Int = 4000, h: Int = 3000) = PhotoRef(id, "content://media/$id", "IMG_$id.jpg", size, w, h, mod)
    private fun hp(id: Long, hash: Long, mp: Int = 12, mod: Long = 100) = HashedPhoto(PhotoRef(id, "content://media/$id", "IMG_$id.jpg", 1_000, mp * 1000, 1000, mod), hash)

    private fun group() = Clustering.groups(listOf(hp(1, 0L), hp(2, 0L, mp = 10), hp(3, 0L, mp = 9)), 8).single()

    @Test fun `an unchanged library is fresh`() {
        val g = Clustering.groups(listOf(hp(1, 0L), hp(2, 0L)), 8).single()
        assertTrue(Freshness.staleGroups(listOf(g), g.items.associate { it.photo.id to it.photo }).isEmpty())
    }

    @Test fun `a member deleted elsewhere makes the group stale - the keeper may be gone`() {
        val g = group()
        val now = g.items.associate { it.photo.id to it.photo } - g.recommendedKeepId
        assertEquals(setOf(g.id), Freshness.staleGroups(listOf(g), now))
    }

    @Test fun `a member edited in place makes the group stale`() {
        val g = group()
        val victim = g.items.first { it.photo.id != g.recommendedKeepId }.photo
        val now = g.items.associate { it.photo.id to it.photo } + (victim.id to victim.copy(modifiedEpochSec = victim.modifiedEpochSec + 1))
        assertEquals(setOf(g.id), Freshness.staleGroups(listOf(g), now))
        val resized = g.items.associate { it.photo.id to it.photo } + (victim.id to victim.copy(sizeBytes = victim.sizeBytes + 5))
        assertEquals(setOf(g.id), Freshness.staleGroups(listOf(g), resized))
    }

    @Test fun `groupsTouchedBy returns exactly the groups with something marked`() {
        val a = Clustering.groups(listOf(hp(1, 0L), hp(2, 0L)), 8).single()
        val b = Clustering.groups(listOf(hp(10, -1L), hp(11, -1L)), 8).single()
        val s = ReviewSession(listOf(a, b)); s.clearMarks(b.id)
        assertEquals(listOf(a.id), s.groupsTouchedBy(s.plan()).map { it.id })
    }

    @Test fun `a chain A-B-C where A and C differ by more than the threshold is flagged and NOT pre-selected`() {
        val a = hp(1, 0L); val b = hp(2, 0xFFL); val c = hp(3, 0xFFFFL)    // a-b 8, b-c 8, a-c 16
        val g = Clustering.groups(listOf(a, b, c), 8).single()
        assertEquals(16, g.diameter); assertTrue(g.chained)
        val s = ReviewSession(listOf(g))
        assertEquals("a chained group starts with nothing selected for Trash", 0, s.plan().count)
        s.keepBest(g.id)                                                   // an explicit user action still works
        assertEquals(2, s.plan().count)
    }

    @Test fun `a tight group is not chained and keeps its pre-selection`() {
        val g = Clustering.groups(listOf(hp(1, 0L), hp(2, 0xFL), hp(3, 0xF0L)), 8).single()   // diameter 8
        assertEquals(8, g.diameter); assertFalse(g.chained)
        assertEquals(2, ReviewSession(listOf(g)).plan().count)
    }
}
