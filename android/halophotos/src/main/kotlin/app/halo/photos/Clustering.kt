package app.halo.photos

/**
 * Union-find clustering over pairwise Hamming distance — `clusterByHash` in the Swift scanner — plus the group builder
 * (`makeGroup`): "recommended keep" = highest megapixels, ties broken by most recent modified date.
 * The Swift tie-break stops there (an exact tie is then arbitrary); here a final tie on the lower id makes the result
 * deterministic, which matters for stable UI and for tests.
 */
object Clustering {
    /** Default and UI range, as in the desktop app (default <= 8 of 64 bits, adjustable 1-20). */
    const val DEFAULT_THRESHOLD = 8
    const val MIN_THRESHOLD = 1
    const val MAX_THRESHOLD = 20
    /** Same cap policy as the desktop scanners: bound the work, newest photos first. */
    const val MAX_PHOTOS = 20_000

    /** Returns clusters (lists of indices into `hashes`), singletons included. O(n^2) popcounts — 12.5 M for 5,000 photos. */
    fun clusterIndices(hashes: LongArray, threshold: Int): List<List<Int>> {
        val n = hashes.size
        val parent = IntArray(n) { it }
        fun find(x0: Int): Int { var x = x0; while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for (i in 0 until n) {
            val hi = hashes[i]
            for (j in i + 1 until n) {
                if (java.lang.Long.bitCount(hi xor hashes[j]) <= threshold) {
                    val a = find(i); val b = find(j)
                    if (a != b) parent[a] = b
                }
            }
        }
        val by = LinkedHashMap<Int, MutableList<Int>>()
        for (i in 0 until n) by.getOrPut(find(i)) { mutableListOf() }.add(i)
        return by.values.toList()
    }

    fun recommendedKeep(items: List<HashedPhoto>): HashedPhoto =
        items.maxWithOrNull(
            compareBy<HashedPhoto> { it.photo.megapixels }
                .thenBy { it.photo.modifiedEpochSec }
                .thenByDescending { it.photo.id }        // exact tie: lowest id wins (deterministic)
        )!!

    /** Groups of >= 2, biggest reclaimable space first (as the desktop list is sorted). */
    fun groups(hashed: List<HashedPhoto>, threshold: Int): List<PhotoGroup> {
        require(threshold in 0..PHash.BITS) { "threshold $threshold" }
        val clusters = clusterIndices(LongArray(hashed.size) { hashed[it].hash }, threshold)
        return clusters.filter { it.size > 1 }.map { idx ->
            val items = idx.map { hashed[it] }.sortedBy { it.photo.id }
            PhotoGroup(id = items.minOf { it.photo.id }, items = items, recommendedKeepId = recommendedKeep(items).photo.id)
        }.sortedWith(compareByDescending<PhotoGroup> { it.wastedBytes }.thenBy { it.id })
    }
}
