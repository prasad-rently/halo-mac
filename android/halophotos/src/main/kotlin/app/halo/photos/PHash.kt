package app.halo.photos

/**
 * DCT perceptual hash — a line-for-line port of `perceptualHash(from:)` / `dct2D(_:)` in
 * Halo/Core/Scanner/PerceptualDuplicateDetector.swift (F-025). The contract is bit-for-bit equality with the Swift
 * code on the same 32x32 grid; `docs/specs/phash-parity.v1.json` is that contract and `PHashParityTest` enforces it.
 *
 * Everything that can change a result is kept in the SAME ORDER as the Swift source — summation order, the
 * `PI / n * (x + 0.5) * u` association, the `0.25 * cu * cv * sum` association — because floating-point addition is
 * not associative and a "tidied" expression can move a coefficient by an ulp. `StrictMath.cos` (fdlibm) is used rather
 * than `Math.cos`, which the JIT is allowed to replace with an intrinsic that differs in the last bit.
 */
object PHash {
    const val SIDE = 32
    /** Number of low-frequency coefficients kept (8x8). */
    const val LOW = 8
    const val BITS = 64

    // The DCT-II normalisation constants. Named so the mutation check can point at exactly what it breaks.
    internal const val NORM = 0.25
    internal val INV_SQRT2: Double = 1.0 / Math.sqrt(2.0)

    /** `dct2D`: naive separable 2-D DCT-II on a SIDE x SIDE grid, row-major, returned row-major (output[v*SIDE+u]). */
    fun dct2D(pixels: DoubleArray): DoubleArray {
        require(pixels.size == SIDE * SIDE) { "need ${SIDE * SIDE} samples, got ${pixels.size}" }
        val n = SIDE
        val cosTable = Array(n) { DoubleArray(n) }
        for (x in 0 until n) for (u in 0 until n) cosTable[x][u] = StrictMath.cos(Math.PI / n.toDouble() * (x.toDouble() + 0.5) * u.toDouble())

        // Pass 1: DCT along rows.
        val rows = Array(n) { DoubleArray(n) }
        for (y in 0 until n) for (u in 0 until n) {
            var sum = 0.0
            for (x in 0 until n) sum += pixels[y * n + x] * cosTable[x][u]
            rows[y][u] = sum
        }

        // Pass 2: DCT along columns, with orthonormal scaling factors applied.
        val out = DoubleArray(n * n)
        for (u in 0 until n) {
            val cu = if (u == 0) INV_SQRT2 else 1.0
            for (v in 0 until n) {
                val cv = if (v == 0) INV_SQRT2 else 1.0
                var sum = 0.0
                for (y in 0 until n) sum += rows[y][u] * cosTable[y][v]
                out[v * n + u] = NORM * cu * cv * sum
            }
        }
        return out
    }

    /** The 64 top-left coefficients in row-major order (index = y*8 + x), DC first. */
    fun lowFrequency(pixels: DoubleArray): DoubleArray {
        val dct = dct2D(pixels)
        val low = DoubleArray(LOW * LOW)
        var i = 0
        for (y in 0 until LOW) for (x in 0 until LOW) low[i++] = dct[y * SIDE + x]
        return low
    }

    /** Median of the 63 AC terms (DC excluded — it is a huge outlier), element `count / 2` of the sorted list, as in Swift. */
    fun median(low: DoubleArray): Double {
        val ac = low.copyOfRange(1, low.size)
        ac.sort()
        return ac[ac.size / 2]
    }

    /** Bit (63 - i) is set when coefficient i is strictly above the median. */
    fun hashOfCoefficients(low: DoubleArray): Long {
        val median = median(low)
        var h = 0L
        for (i in low.indices) if (low[i] > median) h = h or (1L shl (63 - i))
        return h
    }

    /** 32x32 grayscale grid (0..255 as doubles, row-major) -> 64-bit hash. */
    fun hashOfGrid(pixels: DoubleArray): Long = hashOfCoefficients(lowFrequency(pixels))

    fun hash(grayBytes: IntArray): Long = hashOfGrid(DoubleArray(grayBytes.size) { grayBytes[it].toDouble() })

    fun hamming(a: Long, b: Long): Int = java.lang.Long.bitCount(a xor b)
}
