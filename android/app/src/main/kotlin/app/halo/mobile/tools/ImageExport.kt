package app.halo.mobile.tools

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.IOException

/**
 * Getting a PNG out of the app WITHOUT a storage permission and without adding a FileProvider to the manifest:
 *  - [shareable] (Android 10+): a MediaStore insert into Pictures/Halo — an app may always add to its own media — then
 *    the system share sheet with that content:// URI. Below Android 10 writing to shared storage needs a permission
 *    Halo doesn't ask for, so there's no Share there ([canShare] is false) and "Save as…" is the way.
 *  - [writeTo]: the Storage Access Framework's "Save as…" picker hands back a URI the person chose; works on every version.
 */
internal object ImageExport {
    val canShare: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    fun fileName(prefix: String) = "$prefix-${java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date())}.png"

    /** Inserts the PNG into Pictures/Halo and returns its URI, or null on failure. Blocking: call off the main thread. */
    fun saveToPictures(ctx: Context, bitmap: Bitmap, name: String): Uri? {
        if (!canShare) return null
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name); put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Halo"); put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = try { resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) } catch (e: Exception) { null } ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) throw IOException("compress failed") } ?: throw IOException("no stream")
            resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            uri
        } catch (e: Exception) { runCatching { resolver.delete(uri, null, null) }; null }
    }

    /** Blocking write to a URI from the "Save as…" picker. */
    fun writeTo(ctx: Context, uri: Uri, bitmap: Bitmap): Boolean = try {
        ctx.contentResolver.openOutputStream(uri, "wt")?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } ?: false
    } catch (e: Exception) { false }

    fun shareIntent(uri: Uri): Intent = Intent.createChooser(
        Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share image")
}
