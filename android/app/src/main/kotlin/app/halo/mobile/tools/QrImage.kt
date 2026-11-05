package app.halo.mobile.tools

import android.graphics.Bitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.WriterException
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * QR generation with the zxing core the pairing scanner already ships. Error correction M (what Python's `qrcode.make`, the
 * desktop action's first choice, defaults to), UTF-8, 2-module quiet zone, drawn black-on-white at every theme — a QR only scans reliably that way.
 */
internal object QrImage {
    /** Null if the payload doesn't fit (more than ~2.3 KB) or can't be encoded. */
    fun matrix(payload: String): BitMatrix? = try {
        QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 0, 0, mapOf(
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.MARGIN to 2))
    } catch (e: WriterException) { null } catch (e: IllegalArgumentException) { null }

    /** Integer-scales the modules so the bitmap is at least [minPx] wide with crisp edges. */
    fun bitmap(payload: String, minPx: Int = 768): Bitmap? {
        val m = matrix(payload) ?: return null
        val scale = maxOf(1, (minPx + m.width - 1) / m.width)
        val w = m.width * scale; val h = m.height * scale
        val px = IntArray(w * h)
        for (y in 0 until h) { val row = (y / scale); for (x in 0 until w) px[y * w + x] = if (m[x / scale, row]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }
}
