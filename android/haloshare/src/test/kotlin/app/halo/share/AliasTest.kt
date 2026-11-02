package app.halo.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AliasTest {
    @Test fun `bidi overrides, embeddings, isolates and direction marks are stripped`() {
        val rlo = "\u202E"; val pdf = "\u202C"
        assertEquals("gpj.exe", Alias.clean("${rlo}exe.jpg${pdf}".reversed().let { "gpj.exe" }, 40))     // sanity: ordinary text unchanged
        assertEquals("Mac", Alias.clean("${rlo}Mac${pdf}", 40))
        for (c in listOf('\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069', '\u200E', '\u200F', '\u061C', '\u2028', '\u2029'))
            assertEquals("U+${c.code.toString(16)}", "ab", Alias.clean("a${c}b", 40))
    }

    @Test fun `control characters go, ordinary and joiner-using text stays, length is bounded`() {
        assertEquals("ab", Alias.clean("a\u0007\nb", 40))
        assertEquals("  trimmed".trim(), Alias.clean("  trimmed  ", 40))
        val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67"        // ZWJ emoji sequence must survive
        assertEquals(family, Alias.clean(family, 40))
        assertEquals("שלום", Alias.clean("שלום", 40))                                       // genuine RTL text is not damaged, only the control chars are removed
        assertEquals(5, Alias.clean("abcdefghij", 5).length)
        val cut = Alias.clean("ab\uD83D\uDE00", 3)                                         // would end in half a surrogate pair
        assertTrue(cut == "ab"); assertEquals("", Alias.clean("\u202E\u2066", 40))
    }
}
