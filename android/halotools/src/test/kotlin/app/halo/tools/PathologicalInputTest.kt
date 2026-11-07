package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Review of PR #74: inputs a person can paste by accident (or on purpose) that used to crash the app (StackOverflowError /
 * OutOfMemoryError are Errors, not Exceptions — nothing in the UI catches them) or pin a core for minutes. Each test has a
 * timeout: a regression is a red test, not a hung build.
 */
class PathologicalInputTest {
    @Test(timeout = 10_000) fun deeplyNestedJsonIsRejectedNotCrashed() {
        val deep = "[".repeat(5_000) + "]".repeat(5_000)
        for (id in listOf(TransformId.FORMAT_JSON, TransformId.MINIFY_JSON)) {
            val r = TextTransforms.apply(id, deep)
            assertTrue("$id: $r", r is TransformResult.Failure)
        }
        assertTrue(CodeFormatter.format(deep, CodeLanguage.JSON) is FormatResult.Invalid)
    }

    @Test fun jsonAtTheLimitStillFormatsAndBracketsInStringsDontCount() {
        val ok = "[".repeat(JsonFormat.MAX_DEPTH) + "]".repeat(JsonFormat.MAX_DEPTH)
        assertTrue(TextTransforms.apply(TransformId.MINIFY_JSON, ok) is TransformResult.Output)
        val inString = "{\"a\":\"" + "[".repeat(10_000) + "\"}"
        assertEquals("{\"a\":\"" + "[".repeat(10_000) + "\"}", (TextTransforms.apply(TransformId.MINIFY_JSON, inString) as TransformResult.Output).text)
        // an escaped quote must not end the string early (which would count the brackets after it)
        val escaped = "{\"a\":\"\\\"" + "[".repeat(10_000) + "\"}"
        assertTrue(TextTransforms.apply(TransformId.MINIFY_JSON, escaped) is TransformResult.Output)
    }

    @Test(timeout = 20_000) fun longStringWithManyEscapesDoesNotOverflowTheRegexStack() {
        for (lang in listOf(CodeLanguage.JAVASCRIPT, CodeLanguage.JSON, CodeLanguage.PYTHON)) {
            val toks = SyntaxHighlighter.highlight("\"" + "\\n".repeat(100_000) + "\"", lang)
            assertEquals("$lang: one string token", TokenType.STRING, toks.first().type)
        }
        val bt = SyntaxHighlighter.highlight("`" + "\\n".repeat(100_000) + "`", CodeLanguage.JAVASCRIPT)
        assertEquals(TokenType.STRING, bt.first().type)
    }

    @Test(timeout = 10_000) fun longDigitRunIsLinearNotQuadratic() {
        SyntaxHighlighter.highlight("1".repeat(200_000) + "x", CodeLanguage.JAVASCRIPT)
    }

    @Test(timeout = 10_000) fun manyUnterminatedCommentOpenersAreLinear() {
        SyntaxHighlighter.highlight("<!-- ".repeat(40_000), CodeLanguage.HTML)
        SyntaxHighlighter.highlight("/* ".repeat(60_000), CodeLanguage.JAVASCRIPT)
        SyntaxHighlighter.highlight("\"\"\" ".repeat(60_000), CodeLanguage.PYTHON)
    }

    @Test fun anUnterminatedCommentRunsToTheEnd() {
        val toks = SyntaxHighlighter.highlight("a /* never closed\nb", CodeLanguage.JAVASCRIPT)
        assertEquals(TokenType.COMMENT, toks.last().type)
        assertEquals(19, toks.last().end)
    }

    @Test(timeout = 20_000) fun deepNestingDoesNotBuildQuadraticIndentation() {
        val html = CodeFormatter.format("<a>".repeat(60_000), CodeLanguage.HTML) as FormatResult.Ok
        assertTrue(html.text.length < 40_000_000)
        val xml = CodeFormatter.format("<a>".repeat(60_000), CodeLanguage.XML) as FormatResult.Ok
        assertTrue(xml.text.length < 40_000_000)
        val js = CodeFormatter.format("{".repeat(100_000) + "}".repeat(100_000), CodeLanguage.JAVASCRIPT) as FormatResult.Ok
        assertTrue(js.text.length < 40_000_000)
    }

    @Test(timeout = 20_000) fun deeplyNestedCssBracesDoNotOverflowTheStack() {
        CodeFormatter.format("a{".repeat(50_000) + "}".repeat(50_000), CodeLanguage.CSS)
    }

    @Test(timeout = 20_000) fun manyClosingBracesAreLinear() {
        CodeFormatter.format("if (a) { b(); }\n".repeat(30_000), CodeLanguage.JAVASCRIPT)
    }

    @Test fun cappedIndentationIsStillIdempotent() {
        val once = (CodeFormatter.format("<a>".repeat(200) + "x" + "</a>".repeat(200), CodeLanguage.HTML) as FormatResult.Ok).text
        assertEquals(once, (CodeFormatter.format(once, CodeLanguage.HTML) as FormatResult.Ok).text)
    }
}
