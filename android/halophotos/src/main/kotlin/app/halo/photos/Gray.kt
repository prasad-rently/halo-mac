package app.halo.photos

/** A decoded thumbnail: ARGB_8888 pixels, row-major, non-premultiplied, already EXIF-rotated by the decoder. */
class DecodedImage(val argb: IntArray, val width: Int, val height: Int) {
    init { require(width > 0 && height > 0 && argb.size == width * height) { "bad image ${width}x$height / ${argb.size}" } }
}

/**
 * Thumbnail -> the 32x32 8-bit grayscale grid the hash is computed from. Mirrors `grayscale32x32` in the Swift scanner,
 * which draws the thumbnail into a 32x32 **linearGray** CGContext (stretched to the square — aspect ratio is NOT kept —
 * with `.high` interpolation).
 *
 * What is and is not identical to Swift:
 *  - Same: target size, stretch-to-square, linear-light gray, 8-bit quantisation at the end, EXIF-upright input.
 *  - Different: CoreGraphics' colour-managed conversion and its `.high` resampling kernel are not reproducible bit for
 *    bit off-Apple. Here: sRGB -> linear via the standard transfer curve, Rec.709 luma weights on the linear values, and
 *    exact area averaging (box filter). Hashes of the SAME real image will usually agree within a few bits across
 *    platforms but are not guaranteed equal; they never leave the phone, so only self-consistency matters for
 *    grouping. The *hash core* (PHash) is what the parity fixture pins bit for bit.
 */
object Gray {
    private val srgbToLinear = DoubleArray(256) { i ->
        val c = i / 255.0
        if (c <= 0.04045) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
    }

    /** Linear-light luma of one pixel in 0..1, scaled by alpha (transparent -> black, like drawing over a cleared gray context). */
    internal fun luma(argb: Int): Double {
        val a = (argb ushr 24) and 0xFF
        val r = srgbToLinear[(argb shr 16) and 0xFF]
        val g = srgbToLinear[(argb shr 8) and 0xFF]
        val b = srgbToLinear[argb and 0xFF]
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) * (a / 255.0)
    }

    /** Area-average the image down (or up) to SIDE x SIDE and quantise to 0..255. */
    fun to32x32(img: DecodedImage): IntArray {
        val side = PHash.SIDE
        val lum = DoubleArray(img.width * img.height) { luma(img.argb[it]) }
        // Separable area averaging: rows first (width -> side), then columns (height -> side).
        val tmp = DoubleArray(side * img.height)
        for (y in 0 until img.height) resampleLine(lum, y * img.width, 1, img.width, tmp, y * side, 1, side)
        val out = IntArray(side * side)
        val col = DoubleArray(side)
        val colIn = DoubleArray(img.height)
        for (x in 0 until side) {
            for (y in 0 until img.height) colIn[y] = tmp[y * side + x]
            resampleLine(colIn, 0, 1, img.height, col, 0, 1, side)
            for (y in 0 until side) out[y * side + x] = Math.round(col[y].coerceIn(0.0, 1.0) * 255.0).toInt()
        }
        return out
    }

    /** Exact box-filter resample of `inLen` samples into `outLen` bins (each output bin averages the input span it covers). */
    private fun resampleLine(src: DoubleArray, so: Int, ss: Int, inLen: Int, dst: DoubleArray, d0: Int, ds: Int, outLen: Int) {
        val ratio = inLen.toDouble() / outLen
        for (o in 0 until outLen) {
            val from = o * ratio
            val to = (o + 1) * ratio
            var i = from.toInt()
            var acc = 0.0
            var wsum = 0.0
            while (i < inLen && i < to) {
                val w = minOf(to, (i + 1).toDouble()) - maxOf(from, i.toDouble())
                if (w > 0) { acc += src[so + i * ss] * w; wsum += w }
                i++
            }
            dst[d0 + o * ds] = if (wsum > 0) acc / wsum else src[so + minOf(inLen - 1, from.toInt()) * ss]
        }
    }

    /** Convenience: decoded thumbnail -> 64-bit hash. */
    fun hash(img: DecodedImage): Long = PHash.hash(to32x32(img))
}
