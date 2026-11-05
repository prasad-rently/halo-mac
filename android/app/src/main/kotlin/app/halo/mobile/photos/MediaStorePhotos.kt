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
        val proj = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.DATE_MODIFIED,
        )
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

    /** Which of `ids` are still visible (not deleted / not trashed). Used to confirm what the system REALLY removed. */
    fun stillPresent(resolver: ContentResolver, ids: Collection<Long>): Set<Long> {
        val present = HashSet<Long>()
        ids.chunked(500).forEach { chunk ->
            resolver.query(collection, arrayOf(MediaStore.Images.Media._ID), "${MediaStore.Images.Media._ID} IN (${chunk.joinToString(",")})", null, null)?.use { c ->
                while (c.moveToNext()) present += c.getLong(0)
            }
        }
        return present
    }
}
