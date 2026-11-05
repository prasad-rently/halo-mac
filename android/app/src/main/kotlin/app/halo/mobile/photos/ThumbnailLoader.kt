package app.halo.mobile.photos

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.util.LruCache
import android.media.ExifInterface
import app.halo.photos.DecodedImage
import app.halo.photos.PhotoRef
import app.halo.photos.ThumbnailDecoder

/**
 * Decodes DOWNSAMPLED bitmaps only — a 12 MP photo is never materialised at full size:
 *  - API 28+: ImageDecoder.setTargetSize (decodes straight to the small size; applies EXIF orientation itself; handles HEIC/WebP).
 *  - API 26-27: BitmapFactory with a power-of-two inSampleSize from the bounds pass, then EXIF rotation by hand.
 */
internal object Decode {
    fun bitmap(context: Context, uri: Uri, longSide: Int): Bitmap? = try {
        if (Build.VERSION.SDK_INT >= 28) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                val w = info.size.width; val h = info.size.height
                val scale = longSide.toFloat() / maxOf(w, h)
                if (scale < 1f) decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE        // pixels must be readable for hashing
                decoder.isMutableRequired = false
            }
        } else legacy(context, uri, longSide)
    } catch (e: Exception) { null } catch (e: OutOfMemoryError) { null }

    private fun legacy(context: Context, uri: Uri, longSide: Int): Bitmap? {
        val cr = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= longSide) sample *= 2
        val bmp = cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }) } ?: return null
        val degrees = cr.openInputStream(uri)?.use {
            when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90; ExifInterface.ORIENTATION_ROTATE_180 -> 180; ExifInterface.ORIENTATION_ROTATE_270 -> 270; else -> 0
            }   // mirrored orientations (rare) are left as-is
        } ?: 0
        if (degrees == 0) return bmp
        val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(degrees.toFloat()) }, true)
        if (rotated !== bmp) bmp.recycle()
        return rotated
    }
}

/** The hashing decoder: ~64 px thumbnail -> ARGB ints for the pure-Kotlin pipeline. Thread-safe (stateless). */
class AndroidThumbnailDecoder(private val context: Context) : ThumbnailDecoder {
    override fun decode(photo: PhotoRef): DecodedImage? {
        val bmp = Decode.bitmap(context, Uri.parse(photo.uri), HASH_LONG_SIDE) ?: return null
        return try {
            val px = IntArray(bmp.width * bmp.height)
            bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height)
            DecodedImage(px, bmp.width, bmp.height)
        } finally { bmp.recycle() }
    }
    companion object { const val HASH_LONG_SIDE = 64 }   // same as kCGImageSourceThumbnailMaxPixelSize in the desktop scanner
}

/** Display thumbnails for the review list, in a byte-bounded LRU (never more than ~1/16 of the heap, capped at 24 MB). */
class ThumbnailCache(private val context: Context) {
    private val cache = object : LruCache<Long, Bitmap>(((Runtime.getRuntime().maxMemory() / 16).toInt()).coerceAtMost(24 * 1024 * 1024)) {
        override fun sizeOf(key: Long, value: Bitmap) = value.byteCount
    }
    fun peek(id: Long): Bitmap? = cache.get(id)
    fun load(photo: PhotoRef): Bitmap? = cache.get(photo.id) ?: Decode.bitmap(context, Uri.parse(photo.uri), DISPLAY_LONG_SIDE)?.also { cache.put(photo.id, it) }
    companion object { const val DISPLAY_LONG_SIDE = 320 }
}
