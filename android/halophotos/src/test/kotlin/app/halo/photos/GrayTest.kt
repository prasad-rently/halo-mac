package app.halo.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GrayTest {
    private fun solid(argb: Int, w: Int, h: Int) = DecodedImage(IntArray(w * h) { argb }, w, h)

    @Test fun `black and white map to the extremes`() {
        assertTrue(Gray.to32x32(solid(0xFF000000.toInt(), 40, 30)).all { it == 0 })
        assertTrue(Gray.to32x32(solid(0xFFFFFFFF.toInt(), 40, 30)).all { it == 255 })
    }

    @Test fun `gray is computed in linear light - sRGB 188 is about half brightness`() {
        val g = Gray.to32x32(solid(0xFFBCBCBC.toInt(), 32, 32))   // sRGB 188 ~ 50% linear
        assertTrue("got ${g[0]}", g.all { Math.abs(it - 128) <= 1 })
    }

    @Test fun `green outweighs blue (Rec 709 luma weights)`() {
        val green = Gray.to32x32(solid(0xFF00FF00.toInt(), 32, 32))[0]
        val blue = Gray.to32x32(solid(0xFF0000FF.toInt(), 32, 32))[0]
        val red = Gray.to32x32(solid(0xFFFF0000.toInt(), 32, 32))[0]
        assertTrue(green > red && red > blue)
        assertEquals(Math.round(0.7152 * 255).toInt(), green)
    }

    @Test fun `fully transparent pixels are black`() {
        assertTrue(Gray.to32x32(solid(0x00FFFFFF, 32, 32)).all { it == 0 })
    }

    @Test fun `a 32x32 image passes through unchanged and integer upscales are invariant`() {
        val base = IntArray(32 * 32) { val v = (it * 7) % 256; (0xFF shl 24) or (v shl 16) or (v shl 8) or v }
        val a = Gray.to32x32(DecodedImage(base, 32, 32))
        // 2x nearest-neighbour upscale of the same picture must produce the same 32x32 grid (exact area averaging)
        val big = IntArray(64 * 64) { base[(it / 64 / 2) * 32 + (it % 64) / 2] }
        assertEquals(a.toList(), Gray.to32x32(DecodedImage(big, 64, 64)).toList())
    }

    @Test fun `non-square input is stretched to the square, not cropped - left and right halves survive`() {
        // 96x32: left third white, rest black -> in 32x32 the left ~11 columns are white
        val w = 96; val h = 32
        val img = DecodedImage(IntArray(w * h) { if (it % w < 32) 0xFFFFFFFF.toInt() else 0xFF000000.toInt() }, w, h)
        val g = Gray.to32x32(img)
        assertTrue(g[0] > 250 && g[9] > 250)
        assertTrue(g[20] == 0 && g[31] == 0)
    }
}
