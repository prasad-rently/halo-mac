package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Random

class ReviewSessionTest {
    private fun ph(id: Long, mp: Int = 10, size: Long = 2_000_000) =
        HashedPhoto(PhotoRef(id, "content://media/$id", "IMG_$id.jpg", size, mp * 1000, 1000, id), 0L)

    private fun group(base: Long, n: Int) =
        Clustering.groups((0 until n).map { ph(base + it, mp = 10 + it) }, 8).single()

    private fun invariantHolds(s: ReviewSession) = s.groups.all { g -> g.items.any { !s.isMarked(g.id, it.photo.id) } }

    // ---- invariant 1: at least one photo per group is always kept -------------------------------------------------

    @Test fun `keep best pre-selects everything except the recommended keep`() {
        val g = group(1, 4); val s = ReviewSession(listOf(g))
        assertEquals(g.items.map { it.photo.id }.toSet() - g.recommendedKeepId, s.markedIds(g.id))
        assertEquals(setOf(g.recommendedKeepId), s.keptIds(g.id))
    }

    @Test fun `the last kept photo of a group can never be marked`() {
        val g = group(1, 3); val s = ReviewSession(listOf(g))
        // everything but the keeper is marked; trying to mark the keeper must be refused
        assertEquals(ReviewSession.Toggle.REFUSED_LAST_KEPT, s.toggle(g.id, g.recommendedKeepId))
        assertFalse(s.isMarked(g.id, g.recommendedKeepId))
        // unmark another, then the keeper CAN be marked (someone else is kept), but then that other is the last
        val other = g.items.first { it.photo.id != g.recommendedKeepId }.photo.id
        assertEquals(ReviewSession.Toggle.UNMARKED, s.toggle(g.id, other))
        assertEquals(ReviewSession.Toggle.MARKED, s.toggle(g.id, g.recommendedKeepId))
        assertEquals(ReviewSession.Toggle.REFUSED_LAST_KEPT, s.toggle(g.id, other))
        assertTrue(invariantHolds(s))
    }

    @Test fun `fuzz - no sequence of operations can leave a group with every photo marked`() {
        val rnd = Random(20261105)
        repeat(200) { round ->
            val s = ReviewSession(listOf(group(1, 2 + rnd.nextInt(5)), group(100, 2 + rnd.nextInt(4)), group(200, 2)))
            repeat(60) {
                val gs = s.groups
                if (gs.isEmpty()) return@repeat
                val g = gs[rnd.nextInt(gs.size)]
                val pid = g.items[rnd.nextInt(g.items.size)].photo.id
                when (rnd.nextInt(6)) {
                    0, 1, 2 -> s.toggle(g.id, pid)
                    3 -> s.keepBest(g.id)
                    4 -> s.keepOnly(g.id, pid)
                    else -> if (rnd.nextInt(8) == 0) s.ignoreGroup(g.id) else s.clearMarks(g.id)
                }
                assertTrue("round $round broke the invariant", invariantHolds(s))
                // a full delete cycle must preserve it too
                if (rnd.nextInt(10) == 0) s.requestDeletion()?.let { r -> val c = r.confirm(); s.completeDeletion(c, c.plan.items.map { it.id }.toSet()); assertTrue(invariantHolds(s)) }
            }
        }
    }

    @Test fun `the deletion plan never contains a whole group`() {
        val groups = listOf(group(1, 3), group(100, 2))
        val s = ReviewSession(groups)
        groups.forEach { g -> s.keepOnly(g.id, g.items.last().photo.id); g.items.forEach { s.toggle(g.id, it.photo.id) } } // hammer toggles
        val planIds = s.plan().items.map { it.id }.toSet()
        groups.forEach { g -> assertTrue("a group was fully planned for deletion", g.items.any { it.photo.id !in planIds }) }
    }

    // ---- invariant 2: nothing is deleted without confirming exactly what was shown --------------------------------

    @Test fun `no confirmation object exists until the user confirms - request alone deletes nothing`() {
        val s = ReviewSession(listOf(group(1, 3)))
        val req = s.requestDeletion()!!
        assertEquals(2, req.plan.count)
        assertEquals(4_000_000L, req.plan.totalBytes)
        assertEquals(1, s.groups.size)                                // untouched
        assertEquals(3, s.groups[0].items.size)
    }

    @Test fun `the only way to obtain a ConfirmedDeletion is DeletionRequest confirm`() {
        val req = ReviewSession(listOf(group(1, 2))).requestDeletion()!!
        assertEquals(1, req.confirm().plan.count)
        // The constructor is `internal`: the Android module (a separate Gradle module) cannot call it - that is enforced by
        // the compiler, and this guards the rest: no source file outside ReviewSession.kt constructs one.
        for (prop in listOf("halo.photosSrc", "halo.appPhotosSrc")) {
            val dir = java.io.File(System.getProperty(prop))
            if (!dir.exists()) continue
            dir.walkTopDown().filter { it.isFile && it.extension == "kt" && it.name != "ReviewSession.kt" }.forEach {
                assertFalse("${it.name} constructs ConfirmedDeletion directly", Regex("""\bConfirmedDeletion\s*\(""").containsMatchIn(it.readText()))
            }
        }
    }

    @Test fun `a request is void if the marks change after it was shown - the user cannot confirm one list and delete another`() {
        val g = group(1, 4); val s = ReviewSession(listOf(g))
        val req = s.requestDeletion()!!
        s.toggle(g.id, g.items.first { it.photo.id != g.recommendedKeepId }.photo.id)   // user edits selection behind the dialog
        assertFalse(req.isStillValid)
        try { req.confirm(); fail("stale confirmation accepted") } catch (_: IllegalStateException) {}
    }

    @Test fun `nothing marked means no request at all`() {
        val g = group(1, 2); val s = ReviewSession(listOf(g))
        s.clearMarks(g.id)
        assertNull(s.requestDeletion())
    }

    // ---- invariant 3: bookkeeping trusts the OS -------------------------------------------------------------------

    @Test fun `completeDeletion removes only what the system reports deleted and dissolves groups left with one photo`() {
        val g = group(1, 3); val s = ReviewSession(listOf(g))
        val c = s.requestDeletion()!!.confirm()
        val ids = c.plan.items.map { it.id }
        s.completeDeletion(c, setOf(ids[0]))                           // user denied / system trashed only one
        assertEquals(1, s.groups.size); assertEquals(2, s.groups[0].items.size)
        assertTrue(invariantHolds(s))
        s.completeDeletion(c, setOf(ids[1], 9999L))                    // 9999 was never in the plan: ignored
        assertTrue(s.groups.isEmpty())                                 // only the keeper is left -> no longer a group
    }

    @Test fun `ids outside the confirmed plan are never removed`() {
        val g = group(1, 3); val s = ReviewSession(listOf(g))
        val c = s.requestDeletion()!!.confirm()
        s.completeDeletion(c, setOf(g.recommendedKeepId))              // the keeper was not in the plan
        assertEquals(3, s.groups.single().items.size)
    }

    @Test fun `ignoring a group removes it and its marks from any later plan`() {
        val a = group(1, 3); val b = group(100, 2); val s = ReviewSession(listOf(a, b))
        s.ignoreGroup(a.id)
        assertEquals(1, s.ignoredGroupCount)
        assertEquals(1, s.plan().count)
        assertEquals(listOf(b.id), s.groups.map { it.id })
    }
}
