package app.halo.photos

/** One image as MediaStore reports it. `uri` is an opaque string (a content:// URI on Android) so this module stays JVM-only. */
data class PhotoRef(
    val id: Long,
    val uri: String,
    val name: String,
    val sizeBytes: Long,
    val width: Int,
    val height: Int,
    /** Last-modified, epoch seconds (MediaStore DATE_MODIFIED). 0 = unknown. */
    val modifiedEpochSec: Long,
) {
    /** Pixel count in megapixels — the "highest resolution wins" key (same as `megapixels` in the Swift model). */
    val megapixels: Double get() = width.toDouble() * height.toDouble() / 1_000_000.0
}

data class HashedPhoto(val photo: PhotoRef, val hash: Long)

/** A cluster of >= 2 visually similar photos. `recommendedKeepId` is the one "keep best" pre-selects to keep. */
data class PhotoGroup(val id: Long, val items: List<HashedPhoto>, val recommendedKeepId: Long) {
    init { require(items.size >= 2) { "a group has at least two photos" }; require(items.any { it.photo.id == recommendedKeepId }) }
    /** Bytes freed if everything but the recommended keep were deleted. */
    val wastedBytes: Long get() = items.filter { it.photo.id != recommendedKeepId }.sumOf { it.photo.sizeBytes }
}
