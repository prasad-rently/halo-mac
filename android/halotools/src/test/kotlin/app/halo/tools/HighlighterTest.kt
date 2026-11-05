package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HighlighterTest {
    private fun typeAt(code: String, lang: CodeLanguage, needle: String): TokenType {
        val i = code.indexOf(needle); require(i >= 0)
        return SyntaxHighlighter.highlight(code, lang).first { i >= it.start && i < it.end }.type
    }
    private fun tile(code: String, lang: CodeLanguage) {
        val t = SyntaxHighlighter.highlight(code, lang)
        assertEquals("runs must tile the text with no gaps", code.length, t.sumOf { it.end - it.start })
        t.zipWithNext().forEach { (a, b) -> assertEquals(a.end, b.start) }
    }

    @Test fun commentsAndStringsAreInertInside() {
        val js = "let s = \"a // b + 1\"; // it's + 2\nx = 'q'"
        assertEquals(TokenType.STRING, typeAt(js, CodeLanguage.JAVASCRIPT, "// b"))            // `//` inside a string is not a comment
        assertEquals(TokenType.STRING, typeAt(js, CodeLanguage.JAVASCRIPT, "+ 1"))             // operators/numbers inside a string are not recoloured
        assertEquals(TokenType.COMMENT, typeAt(js, CodeLanguage.JAVASCRIPT, "+ 2"))
        assertEquals(TokenType.COMMENT, typeAt(js, CodeLanguage.JAVASCRIPT, "'s"))             // the apostrophe in a comment doesn't open a string
        assertEquals(TokenType.STRING, typeAt(js, CodeLanguage.JAVASCRIPT, "'q'"))
    }

    @Test fun keywordsNumbersFunctionsTypes() {
        val c = "if (x > 0x1F) { return Foo.bar(3.5e2); }"
        assertEquals(TokenType.KEYWORD, typeAt(c, CodeLanguage.JAVASCRIPT, "if")); assertEquals(TokenType.KEYWORD, typeAt(c, CodeLanguage.JAVASCRIPT, "return"))
        assertEquals(TokenType.NUMBER, typeAt(c, CodeLanguage.JAVASCRIPT, "0x1F")); assertEquals(TokenType.NUMBER, typeAt(c, CodeLanguage.JAVASCRIPT, "3.5e2"))
        assertEquals(TokenType.FUNCTION, typeAt(c, CodeLanguage.JAVASCRIPT, "bar")); assertEquals(TokenType.TYPE, typeAt(c, CodeLanguage.JAVASCRIPT, "Foo"))
        assertEquals(TokenType.OPERATOR, typeAt(c, CodeLanguage.JAVASCRIPT, ">"))
    }

    @Test fun sqlKeywordsStayKeywordsEvenWhenCapitalised() {
        assertEquals(TokenType.KEYWORD, typeAt("SELECT a FROM t -- note", CodeLanguage.SQL, "SELECT"))
        assertEquals(TokenType.COMMENT, typeAt("SELECT a FROM t -- note", CodeLanguage.SQL, "note"))
    }

    @Test fun cssUrlSlashesAreNotComments_jsonKeysAreKeywords_pythonHashIsAComment() {
        assertTrue(SyntaxHighlighter.highlight("a{background:url(http://x.test/a.png)}", CodeLanguage.CSS).none { it.type == TokenType.COMMENT })
        assertEquals(TokenType.KEYWORD, typeAt("{\"key\": \"v\"}", CodeLanguage.JSON, "\"key\""))
        assertEquals(TokenType.STRING, typeAt("{\"key\": \"http://v\"}", CodeLanguage.JSON, "http"))
        assertEquals(TokenType.COMMENT, typeAt("x = 1 # c", CodeLanguage.PYTHON, "# c"))
        assertEquals(TokenType.STRING, typeAt("x = '''a\nb'''", CodeLanguage.PYTHON, "b'"))
    }

    @Test fun htmlTagsAndAttributes() {
        val h = "<div class=\"a\"><!-- c --></div>"
        assertEquals(TokenType.KEYWORD, typeAt(h, CodeLanguage.HTML, "<div")); assertEquals(TokenType.FUNCTION, typeAt(h, CodeLanguage.HTML, "class"))
        assertEquals(TokenType.STRING, typeAt(h, CodeLanguage.HTML, "\"a\"")); assertEquals(TokenType.COMMENT, typeAt(h, CodeLanguage.HTML, "<!--"))
    }

    @Test fun plainTextIsLeftAlone_emptyIsEmpty() {
        assertEquals(listOf(TokenType.PLAIN), SyntaxHighlighter.highlight("don't \"stop\" 12", CodeLanguage.PLAIN_TEXT).map { it.type })
        assertTrue(SyntaxHighlighter.highlight("", CodeLanguage.SWIFT).isEmpty())
    }

    @Test fun runsAlwaysTileTheText_andAHugeStringDoesNotOverflowTheStack() {
        for (l in CodeLanguage.values()) tile("a = \"x\" // c\n/* d */ 'e' `f` 12 Foo(bar) <t a=\"1\">", l)
        val big = "s = \"" + "x".repeat(200_000) + "\""
        tile(big, CodeLanguage.JAVASCRIPT)
        assertEquals(TokenType.STRING, typeAt(big, CodeLanguage.JAVASCRIPT, "xxxx"))
    }

    @Test fun unterminatedStringsAndCommentsDoNotThrow() {
        tile("x = \"never closed\ny = 2", CodeLanguage.JAVASCRIPT); tile("/* never", CodeLanguage.JAVASCRIPT)
    }

    @Test fun languageDetectionFollowsTheDesktopHeuristics() {
        assertEquals(CodeLanguage.JSON, LanguageDetector.detect("{\"a\": 1}")); assertEquals(CodeLanguage.HTML, LanguageDetector.detect("<!DOCTYPE html><html></html>"))
        assertEquals(CodeLanguage.SWIFT, LanguageDetector.detect("import SwiftUI")); assertEquals(CodeLanguage.PYTHON, LanguageDetector.detect("def f():\n  pass"))
        assertEquals(CodeLanguage.CSS, LanguageDetector.detect("a { color: red }")); assertEquals(CodeLanguage.SQL, LanguageDetector.detect("select * from t"))
        assertEquals(CodeLanguage.XML, LanguageDetector.detect("<?xml version=\"1.0\"?><a/>")); assertEquals(CodeLanguage.PLAIN_TEXT, LanguageDetector.detect("just words"))
    }

    @Test fun themesMatchTheDesktopsEight() {
        assertEquals(listOf("midnight", "noir", "aurora", "sunset", "ocean", "forest", "candy", "ice"), CodeTheme.all.map { it.id })
        assertEquals(0xFF4F7CFF, CodeTheme.byId("midnight").keyword); assertEquals(CodeTheme.default, CodeTheme.byId("nope"))
        assertTrue(CodeTheme.all.all { th -> TokenType.values().all { th.color(it) != 0L } })
    }

    @Test fun languageListIsTheDesktopsFourteenPlusXml() {
        assertEquals(15, CodeLanguage.values().size); assertEquals(57, CodeLanguage.SWIFT.keywords.size); assertTrue(CodeLanguage.JSON.keywords.isEmpty())
    }
}
