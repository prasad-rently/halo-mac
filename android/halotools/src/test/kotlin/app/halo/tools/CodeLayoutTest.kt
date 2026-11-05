package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeLayoutTest {
    private fun layout(code: String, lang: CodeLanguage = CodeLanguage.JAVASCRIPT, cols: Int = 10, max: Int = 300) = CodeLayout.build(code, lang, cols, max)

    @Test fun numbersLinesAndNormalisesTabsAndLineEndings() {
        val l = layout("a\r\n\tb\rc")
        assertEquals(listOf("a", "    b", "c"), l.lines.map { it.text }); assertEquals(listOf(1, 2, 3), l.lines.map { it.number })
        assertEquals(3, l.sourceLines); assertEquals(0, l.omittedLines)
    }

    @Test fun longLinesWrapWithoutLosingAnyCharacterAndOnlyTheFirstRowIsNumbered() {
        val src = "0123456789abcdefghij0123"
        val l = layout(src)
        assertEquals(listOf("0123456789", "abcdefghij", "0123"), l.lines.map { it.text }); assertEquals(listOf(1, null, null), l.lines.map { it.number })
        assertEquals(src, l.lines.joinToString("") { it.text })
    }

    @Test fun wrappingKeepsTokenColoursAcrossTheBreak() {
        val l = layout("x = \"abcdefghijklmnop\";", cols = 8)
        assertEquals("x = \"abcdefghijklmnop\";", l.lines.joinToString("") { it.text })
        val stringChars = l.lines.flatMap { it.segments }.filter { it.type == TokenType.STRING }.sumOf { it.text.length }
        assertEquals("\"abcdefghijklmnop\"".length, stringChars)
    }

    @Test fun neverSplitsASurrogatePair() {
        val l = layout("12345678😀xyz", lang = CodeLanguage.PLAIN_TEXT, cols = 9)
        assertTrue(l.lines.all { row -> row.text.none { Character.isHighSurrogate(it) } || row.text.last().let { !Character.isHighSurrogate(it) } })
        assertEquals("12345678😀xyz", l.lines.joinToString("") { it.text })
    }

    @Test fun beyondMaxLinesItStopsAndReportsHowManyWereLeftOut() {
        val l = layout((1..10).joinToString("\n") { "l$it" }, max = 4)
        assertEquals(4, l.lines.size); assertEquals(6, l.omittedLines); assertEquals(10, l.sourceLines)
        assertEquals("l4", l.lines.last().text)
    }

    @Test fun blankLinesAreKeptAndEmptyInputGivesNoRows() {
        assertEquals(listOf("a", "", "b"), layout("a\n\nb").lines.map { it.text })
        assertTrue(layout("").lines.isEmpty()); assertEquals(1, layout("x").lines.single().number)
    }

    @Test fun exactlyMaxLinesIsNotTruncated() {
        val l = layout("a\nb\nc", max = 3); assertEquals(3, l.lines.size); assertEquals(0, l.omittedLines)
    }
}
