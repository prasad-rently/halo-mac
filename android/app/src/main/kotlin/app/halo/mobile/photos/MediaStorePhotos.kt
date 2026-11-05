package app.halo.mobile.photos

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import app.halo.photos.PhotoRef

/**
 * Lists images from MediaStore — what the app is ALLOWED to see. With full access that is the whole library; with Android 14's
 * "Selected photos" grant MediaStore itself returns only the chosen ones, so this code needs no special case: it scans exactly
 * what the system lets it see (the UI says so, see PhotosScreen).
 */
object MediaStorePhotos {
    private val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    fun uriFor(id: Long) = ContentUris.withAppendedId(collection, id)

    /** Newest first. Trashed items are excluded by default on API 30+, which is what lets us verify a trash request afterwards. */
    fun query(context: Context, limit: Int): List<PhotoRef> {
        val out = ArrayList<PhotoRef>()
        context.contentResolver.query(collection, proj, "${MediaStore.Images.Media.SIZE} > 0", null, "${MediaStore.Images.Media.DATE_MODIFIED} DESC")?.use { c ->
            val iId = c.getColumnIndexOrThrow(proj[0]); val iName = c.getColumnIndexOrThrow(proj[1]); val iSize = c.getColumnIndexOrThrow(proj[2])
            val iW = c.getColumnIndexOrThrow(proj[3]); val iH = c.getColumnIndexOrThrow(proj[4]); val iMod = c.getColumnIndexOrThrow(proj[5])
            while (c.moveToNext() && out.size < limit) {
                val id = c.getLong(iId)
                out += PhotoRef(id, uriFor(id).toString(), c.getString(iName) ?: "image-$id", c.getLong(iSize), c.getInt(iW), c.getInt(iH), c.getLong(iMod))
            }
        }
        return out
    }

    private val proj = arrayOf(
        MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.SIZE,
        MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.DATE_MODIFIED,
    )

    /** How many images the library really has (the scan is capped; this is what the "newest N of M" notice quotes). Null if unknown. */
    fun count(context: Context): Int? = try {
        context.contentResolver.query(collection, arrayOf(MediaStore.Images.Media._ID), "${MediaStore.Images.Media.SIZE} > 0", null, null)?.use { it.count }
    } catch (e: Exception) { null }

    /**
     * The CURRENT rows for `ids` (those still visible: not deleted, not trashed). Null = the provider could not be asked
     * (null cursor / SecurityException) — callers must treat that as "unknown", never as "everything is gone".
     * Used both to re-validate a plan against the device before trashing and to verify what the system really removed.
     */
    fun lookup(resolver: ContentResolver, ids: Collection<Long>): Map<Long, PhotoRef>? {
        val out = HashMap<Long, PhotoRef>()
        try {
            for (chunk in ids.chunked(500)) {
                val c = resolver.query(collection, proj, "${MediaStore.Images.Media._ID} IN (${chunk.joinToString(",")})", null, null) ?: return null
                c.use {
                    val iId = it.getColumnIndexOrThrow(proj[0]); val iName = it.getColumnIndexOrThrow(proj[1]); val iSize = it.getColumnIndexOrThrow(proj[2])
                    val iW = it.getColumnIndexOrThrow(proj[3]); val iH = it.getColumnIndexOrThrow(proj[4]); val iMod = it.getColumnIndexOrThrow(proj[5])
                    while (it.moveToNext()) {
                        val id = it.getLong(iId)
                        out[id] = PhotoRef(id, uriFor(id).toString(), it.getString(iName) ?: "image-$id", it.getLong(iSize), it.getInt(iW), it.getInt(iH), it.getLong(iMod))
                    }
                }
            }
        } catch (e: Exception) { return null }
        return out
    }
}
