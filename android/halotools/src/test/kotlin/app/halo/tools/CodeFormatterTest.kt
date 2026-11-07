package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeFormatterTest {
    private fun fmt(lang: CodeLanguage, code: String): String = (CodeFormatter.format(code, lang) as FormatResult.Ok).text
    private fun idempotent(lang: CodeLanguage, code: String) { val once = fmt(lang, code); assertEquals("second pass changed the output for $lang", once, fmt(lang, once)) }

    // ── JSON ───────────────────────────────────────────────────────────────────────────────────

    @Test fun jsonUsesTwoSpacesKeepsUnicodeAndRejectsGarbage() {
        assertEquals("{\n  \"a\": [\n    1,\n    {\n      \"b\": \"é\"\n    }\n  ],\n  \"c\": {}\n}", fmt(CodeLanguage.JSON, "{\"a\":[1,{\"b\":\"é\"}],\"c\":{}}"))
        assertTrue(CodeFormatter.format("{oops", CodeLanguage.JSON) is FormatResult.Invalid)
        assertFalse("must not echo the input", (CodeFormatter.format("{\"pw\": hunter2}", CodeLanguage.JSON) as FormatResult.Invalid).reason.contains("hunter2"))
    }

    // ── XML / HTML ─────────────────────────────────────────────────────────────────────────────

    @Test fun xmlIndentsAndKeepsTextOnlyElementsOnOneLine() {
        val x = "<?xml version=\"1.0\"?><root><a x=\"1\"><b>text</b><c/></a>\n<!-- note --><d></d></root>"
        assertEquals("<?xml version=\"1.0\"?>\n<root>\n  <a x=\"1\">\n    <b>text</b>\n    <c/>\n  </a>\n  <!-- note -->\n  <d></d>\n</root>", fmt(CodeLanguage.XML, x))
    }

    @Test fun htmlVoidElementsDoNotIndentAndRawTextIsPreserved() {
        val h = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>T</title><style>\n  a{color:red}\n</style></head><body><p>Hi<br>there</p><pre>  keep\n   this </pre><script>\nif (a < b) { x() }\n</script></body></html>"
        assertEquals(
            "<!DOCTYPE html>\n<html>\n  <head>\n    <meta charset=\"utf-8\">\n    <title>T</title>\n    <style>\n      a{color:red}\n    </style>\n  </head>\n  <body>\n    <p>\n      Hi\n      <br>\n      there\n    </p>\n    <pre>  keep\n   this </pre>\n    <script>\n      if (a < b) { x() }\n    </script>\n  </body>\n</html>",
            fmt(CodeLanguage.HTML, h))
    }

    @Test fun attributeValuesWithGreaterThanAndSpacesSurvive() {
        assertEquals("<a title=\"a > b  c\" href='x'>go</a>", fmt(CodeLanguage.HTML, "<a   title=\"a > b  c\"\n   href='x' >go</a>"))
        assertEquals("<img src=\"a b >\"/>", fmt(CodeLanguage.HTML, "<img src=\"a b >\" />"))
    }

    @Test fun malformedMarkupNeverThrowsAndNeverLosesText() {
        for (bad in listOf("<div><span>unclosed", "</b></i>stray", "a < b > c", "<div", "<!-- never closed", "<a href=\"x>y", "<<>>", "<p>1</p></p></p>")) {
            val r = fmt(CodeLanguage.HTML, bad)
            val visible = Regex("[A-Za-z0-9]+").findAll(bad).map { it.value }.toList()
            for (w in visible) assertTrue("'$w' vanished from: $r", r.contains(w))
        }
    }

    @Test fun markupIsIdempotent() {
        idempotent(CodeLanguage.HTML, "<ul><li>a</li><li><b>b</b> and <i>c</i></li></ul><script>\nvar a = {b: 1};\n</script><!-- c -->")
        idempotent(CodeLanguage.XML, "<r><a><b>1</b></a><a/></r>")
    }

    // ── CSS ────────────────────────────────────────────────────────────────────────────────────

    @Test fun cssPutsEachDeclarationOnItsLineAndSpacesColonsAndCommas() {
        assertEquals("a:hover, .b>c {\n  color: red;\n  margin: 0 auto;\n}\n\n@media (max-width:600px) {\n  .x {\n    display: none;\n  }\n}",
            fmt(CodeLanguage.CSS, "a:hover,.b>c{color:red;margin:0   auto}@media (max-width:600px){.x{display:none}}"))
    }

    @Test fun cssUrlsStringsAndCommentsAreNotMangled() {
        val out = fmt(CodeLanguage.CSS, "a{background:url(data:image/png;base64,AAA=,BBB) no-repeat;content:\"a;b{c}\";/* x;y */}")
        assertEquals("a {\n  background: url(data:image/png;base64,AAA=,BBB) no-repeat;\n  content: \"a;b{c}\";\n  /* x;y */\n}", out)
    }

    @Test fun cssTopLevelCommentsEmptyRulesAndStrayBraces() {
        assertEquals("/* top */\na {}", fmt(CodeLanguage.CSS, "/* top */ a{ }"))
        fmt(CodeLanguage.CSS, "a{color:red}}}b{")          // must simply not throw
    }

    @Test fun cssIsIdempotent() {
        idempotent(CodeLanguage.CSS, "@import url(x.css);a,b{color:red;background:rgba(0,0,0,.5)}@media print{a{b:c}}/*c*/ d{e:f}")
    }

    // ── JS / TS ────────────────────────────────────────────────────────────────────────────────

    @Test fun jsBreaksBlocksAndStatements() {
        val expected = "function f(a, b) {\n  if (a) {\n    return b;\n  } else {\n    x();\n  }\n}"
        assertEquals(expected, fmt(CodeLanguage.JAVASCRIPT, "function f(a, b){if (a){return b;}else{x();}}"))
        assertEquals(expected, fmt(CodeLanguage.JAVASCRIPT, "function f(a, b) {\n\n    if (a) {   return b;\n } else\n{ x(); }\n}"))
    }

    @Test fun jsForLoopHeaderStaysOnOneLine() {
        assertEquals("for (let i = 0; i < n; i++) {\n  s += i;\n}", fmt(CodeLanguage.JAVASCRIPT, "for (let i = 0; i < n; i++) { s += i; }"))
    }

    @Test fun jsStringsTemplatesRegexAndCommentsAreInert() {
        val src = "const a = \"{;}\"; const b = '//x'; const c = `t ${'$'}{x} {`; const r = /[{;]\\/x/g; // {not a block;}\n/* { ; } */ let z = 1;"
        val out = fmt(CodeLanguage.JAVASCRIPT, src)
        for (keep in listOf("\"{;}\"", "'//x'", "`t ${'$'}{x} {`", "/[{;]\\/x/g", "// {not a block;}", "/* { ; } */")) assertTrue("lost $keep in:\n$out", out.contains(keep))
        assertEquals("no extra indentation from inert braces", 0, out.lines().count { it.startsWith(" ") })
    }

    @Test fun jsObjectsAndCallbacks() {
        assertEquals("const o = {\n  a: 1,\n  b: [1, 2],\n  c: {}\n};\nfoo(function () {\n  go();\n});",
            fmt(CodeLanguage.JAVASCRIPT, "const o = {a: 1, b: [1, 2], c: {}}; foo(function () {go();});"))
    }

    @Test fun jsOnlyChangesWhitespace() {
        val src = "if(a){b(\"x y\");}else if(c){d(/ab+c/.test(e),'}');}\nwhile(i--){f()}try{g()}catch(e){h()}finally{k()}"
        val out = fmt(CodeLanguage.JAVASCRIPT, src)
        assertEquals(src.filterNot { it.isWhitespace() }, out.filterNot { it.isWhitespace() })
    }

    @Test fun jsIsIdempotent() {
        idempotent(CodeLanguage.JAVASCRIPT, "function f(a,b){if(a){return b;}else{x();}}\nconst o={a:1,b:[1,2]};// done\nfor(;;){break}")
        idempotent(CodeLanguage.TYPESCRIPT, "interface A{x:number;y:string}\nclass B implements A{x=1;y='s';m():void{}}")
    }

    @Test fun jsUnbalancedBracesDoNotThrowOrGoNegative() {
        fmt(CodeLanguage.JAVASCRIPT, "}}}} a(); {{{"); fmt(CodeLanguage.JAVASCRIPT, "\"unterminated"); fmt(CodeLanguage.JAVASCRIPT, "/* never closed")
    }

    // ── support matrix ─────────────────────────────────────────────────────────────────────────

    @Test fun unsupportedLanguagesAreSaidSoNotSilentlyReflowed() {
        for (l in listOf(CodeLanguage.PYTHON, CodeLanguage.SWIFT, CodeLanguage.BASH, CodeLanguage.SQL, CodeLanguage.PLAIN_TEXT, CodeLanguage.RUBY)) {
            assertFalse(CodeFormatter.supports(l)); assertTrue(CodeFormatter.format("x", l) is FormatResult.Unsupported)
        }
    }

    @Test fun windowsLineEndingsAreNormalised() = assertEquals("a {\n  b: c;\n}", fmt(CodeLanguage.CSS, "a{\r\nb:c;\r\n}"))
}
