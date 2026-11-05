package app.halo.photos

/**
 * "Is what the user is about to confirm still what was scanned?" The scan can be minutes or hours old by the time the user
 * presses Trash. A photo can be edited in place (same MediaStore id, different pixels), replaced, or deleted by another app,
 * and the group's recommended keeper can vanish — after which "the others" may be ALL the copies that are left.
 * [staleGroups] compares the device's current rows with the rows seen at scan time; any group whose members are not all
 * present and unchanged must not be trashed from.
 */
object Freshness {
    /** What identifies "the same file, unmodified" among the columns MediaStore gives us. */
    private fun same(a: PhotoRef, b: PhotoRef) =
        a.sizeBytes == b.sizeBytes && a.modifiedEpochSec == b.modifiedEpochSec && a.width == b.width && a.height == b.height

    /** Ids of groups in which any member is missing from `current` (null/absent = gone) or no longer matches its scan-time row. */
    fun staleGroups(groups: List<PhotoGroup>, current: Map<Long, PhotoRef>): Set<Long> =
        groups.filter { g -> g.items.any { current[it.photo.id]?.let { now -> !same(it.photo, now) } ?: true } }.map { it.id }.toSet()
}
