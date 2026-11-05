package app.halo.photos

/**
 * The review/delete state machine. Three invariants live HERE (not in the UI) so they hold however the UI is written,
 * and each has a test that fails if it is removed:
 *
 *  1. **At least one photo per group is always kept.** Every way of marking goes through [mark], which refuses to mark
 *     the last unmarked member. "Keep best" marks all but one; "toggle" can never mark the last survivor.
 *  2. **Nothing is deleted without an explicit confirmation of exactly what was shown.** [ConfirmedDeletion] has an
 *     `internal` constructor reachable only from [DeletionRequest.confirm], which in turn only exists after
 *     [requestDeletion] snapshotted the marks. Any change to the marks after that invalidates the request, so the
 *     user can never confirm one list and have another deleted. The Android layer accepts ONLY a [ConfirmedDeletion].
 *  3. **Deletion bookkeeping trusts the OS, not the request**: [completeDeletion] removes only ids the system reports
 *     as actually deleted (and that were in the confirmed plan).
 */
class ReviewSession(initial: List<PhotoGroup>) {
    private val groupMap = LinkedHashMap<Long, PhotoGroup>()
    private val marked = HashMap<Long, MutableSet<Long>>()      // groupId -> marked photo ids
    private val ignored = HashSet<Long>()
    private var version = 0

    init {
        initial.forEach { groupMap[it.id] = it }
        initial.forEach { keepBest(it.id) }
        version = 0
    }

    val groups: List<PhotoGroup> get() = groupMap.values.toList()
    val ignoredGroupCount: Int get() = ignored.size

    fun isMarked(groupId: Long, photoId: Long): Boolean = marked[groupId]?.contains(photoId) == true
    fun markedIds(groupId: Long): Set<Long> = marked[groupId]?.toSet() ?: emptySet()
    fun keptIds(groupId: Long): Set<Long> = groupMap[groupId]?.items?.map { it.photo.id }?.toSet().orEmpty() - markedIds(groupId)

    enum class Toggle { MARKED, UNMARKED, REFUSED_LAST_KEPT, NOT_FOUND }

    /** Flip one photo. Marking the last unmarked member of its group is refused. */
    fun toggle(groupId: Long, photoId: Long): Toggle {
        val g = groupMap[groupId] ?: return Toggle.NOT_FOUND
        if (g.items.none { it.photo.id == photoId }) return Toggle.NOT_FOUND
        return if (isMarked(groupId, photoId)) { marked[groupId]!!.remove(photoId); version++; Toggle.UNMARKED }
        else if (mark(groupId, photoId)) Toggle.MARKED else Toggle.REFUSED_LAST_KEPT
    }

    /** "Keep best": mark every member except the recommended keep (highest resolution, then newest). */
    fun keepBest(groupId: Long) {
        val g = groupMap[groupId] ?: return
        keepOnly(groupId, g.recommendedKeepId)
    }

    /** Keep exactly `photoId` and mark the rest — the user picking a different keeper. */
    fun keepOnly(groupId: Long, photoId: Long) {
        val g = groupMap[groupId] ?: return
        if (g.items.none { it.photo.id == photoId }) return
        marked[groupId] = mutableSetOf()
        g.items.forEach { if (it.photo.id != photoId) mark(groupId, it.photo.id) }
        version++
    }

    fun clearMarks(groupId: Long) { marked[groupId]?.clear(); version++ }

    /** Skip a group: it leaves the list and nothing in it can be deleted this session. */
    fun ignoreGroup(groupId: Long) {
        if (groupMap.remove(groupId) != null) { marked.remove(groupId); ignored += groupId; version++ }
    }

    /** The one place a mark is added. Refuses to mark the last unmarked member of the group. */
    private fun mark(groupId: Long, photoId: Long): Boolean {
        val g = groupMap[groupId] ?: return false
        val set = marked.getOrPut(groupId) { mutableSetOf() }
        if (photoId in set) return true
        if (set.size >= g.items.size - 1) return false       // would leave nothing kept
        set += photoId; version++
        return true
    }

    fun plan(): DeletionPlan = DeletionPlan(groupMap.values.flatMap { g -> g.items.filter { isMarked(g.id, it.photo.id) }.map { it.photo } })

    /** Snapshot the marks for the user to confirm. Null when nothing is marked. Deletes nothing. */
    fun requestDeletion(): DeletionRequest? {
        val p = plan()
        return if (p.count == 0) null else DeletionRequest(p, this, version)
    }

    /** Apply a deletion the OS reports as done. Only ids from the confirmed plan are honoured. */
    fun completeDeletion(confirmed: ConfirmedDeletion, deletedIds: Set<Long>) {
        val allowed = confirmed.plan.items.map { it.id }.toSet()
        val gone = deletedIds intersect allowed
        if (gone.isEmpty()) return
        for (g in groups) {
            val remaining = g.items.filter { it.photo.id !in gone }
            if (remaining.size < 2) { groupMap.remove(g.id); marked.remove(g.id); continue }
            val keep = if (remaining.any { it.photo.id == g.recommendedKeepId }) g.recommendedKeepId else Clustering.recommendedKeep(remaining).photo.id
            groupMap[g.id] = g.copy(items = remaining, recommendedKeepId = keep)
            marked[g.id]?.removeAll(gone)
            // Invariant 1 again, defensively: if survivors are somehow all marked, release the recommended keep.
            val m = marked[g.id]
            if (m != null && m.size >= remaining.size) m.remove(keep)
        }
        version++
    }

    internal fun versionForRequest() = version
}

/** What would be deleted: count + total size for the confirmation dialog. */
class DeletionPlan(val items: List<PhotoRef>) {
    val count: Int get() = items.size
    val totalBytes: Long get() = items.sumOf { it.sizeBytes }
}

/** Pending, unconfirmed. Holds the exact list the user is shown. */
class DeletionRequest internal constructor(val plan: DeletionPlan, private val session: ReviewSession, private val atVersion: Int) {
    val isStillValid: Boolean get() = session.versionForRequest() == atVersion
    /** The user pressed "Move N photos to Trash". Fails if the marks changed since the request was shown. */
    fun confirm(): ConfirmedDeletion {
        check(isStillValid) { "the selection changed after the confirmation was shown" }
        return ConfirmedDeletion(plan)
    }
}

/** The only thing the Android deletion code accepts. Constructor is internal: it cannot be built outside this module. */
class ConfirmedDeletion internal constructor(val plan: DeletionPlan)
