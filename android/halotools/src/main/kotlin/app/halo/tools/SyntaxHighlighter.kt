package app.halo.tools

import java.util.regex.Pattern

enum class TokenType { PLAIN, KEYWORD, STRING, COMMENT, FUNCTION, NUMBER, TYPE, OPERATOR }

/** A coloured run [start, end) of the source. [SyntaxHighlighter.highlight] returns runs that tile the whole text. */
data class Token(val start: Int, val end: Int, val type: TokenType)

/**
 * Regex highlighter in the spirit of the desktop's `SyntaxHighlighter` (same token kinds, same patterns, same keyword
 * lists) — "not a full parser", good enough for a code screenshot. Two deliberate differences, both fixes of the
 * desktop's paint-over-everything order (where `// a + b` got a coloured `+` and `"x 123"` a coloured 123):
 *  - comments and strings are found first, left to right in ONE pass, and nothing inside them is recoloured;
 *  - keywords are applied after function-call and type colouring, so SQL's `SELECT` stays a keyword rather than becoming a "type".
 * String patterns are written as unrolled loops (`[^"\\]*(?:\\.[^"\\]*)*`) because the alternation form recurses once
 * per character in java.util.regex and overflows the stack on a long string literal.
 */
object SyntaxHighlighter {
    // Possessive (`*+`) on purpose: with the plain `(?:\\.[^"\\\n]*)*` group java.util.regex recurses once per escape sequence and a
    // string with ~10k escapes (a minified JSON blob, a long \n-joined literal) threw StackOverflowError — an Error, which killed the app.
    private const val DQ = "\"[^\"\\\\\\n]*+(?:\\\\.[^\"\\\\\\n]*+)*+\""
    private const val SQ = "'[^'\\\\\\n]*+(?:\\\\.[^'\\\\\\n]*+)*+'"
    private const val BT = "`[^`\\\\]*+(?:\\\\[\\s\\S][^`\\\\]*+)*+`"

    private fun commentsAndStrings(lang: CodeLanguage): Pattern {
        val parts = mutableListOf<String>()
        val slashSlash = lang in setOf(CodeLanguage.SWIFT, CodeLanguage.JAVASCRIPT, CodeLanguage.TYPESCRIPT, CodeLanguage.GO, CodeLanguage.RUST, CodeLanguage.JAVA)
        if (lang == CodeLanguage.HTML || lang == CodeLanguage.XML) parts += "<!--[\\s\\S]*?(?:-->|\\z)"
        if (slashSlash) parts += "//[^\\n]*"      // not for CSS/JSON: `url(http://x)` and "http://x" are not comments
        if (slashSlash || lang == CodeLanguage.CSS || lang == CodeLanguage.SQL) parts += "/\\*[\\s\\S]*?(?:\\*/|\\z)"
        if (lang == CodeLanguage.SQL) parts += "--[^\\n]*"
        if (lang == CodeLanguage.PYTHON || lang == CodeLanguage.BASH || lang == CodeLanguage.RUBY) parts += "#[^\\n]*"
        if (lang == CodeLanguage.PYTHON) { parts += "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"; parts += "'''[\\s\\S]*?(?:'''|\\z)" }
        parts += DQ; parts += SQ
        if (lang != CodeLanguage.JSON) parts += BT
        return Pattern.compile(parts.joinToString("|"))
    }

    private val cache = HashMap<CodeLanguage, Pattern>()
    private val keywordCache = HashMap<CodeLanguage, Pattern?>()
    private val NUMBER = Pattern.compile("\\b\\d+(?:\\.\\d*)?([eE][+-]?\\d+)?\\b")
    private val HEX = Pattern.compile("\\b0[xX][0-9a-fA-F]+\\b")
    private val FUNCTION = Pattern.compile("\\b([a-zA-Z_]\\w*)\\s*(?=\\()")
    private val TYPE = Pattern.compile("\\b[A-Z][a-zA-Z0-9]*\\b")
    private val OPERATOR = Pattern.compile("[+\\-*/%=<>!&|^~?:]+")
    private val HTML_TAG = Pattern.compile("</?[a-zA-Z][a-zA-Z0-9]*")
    private val HTML_ATTR = Pattern.compile("\\b[a-zA-Z\\-]+(?==)")
    private val CSS_SELECTOR = Pattern.compile("[.#][a-zA-Z][a-zA-Z0-9_\\-]*")
    private val CSS_PROP = Pattern.compile("[a-zA-Z\\-]+(?=\\s*:)")
    private val JSON_KEY = Pattern.compile("$DQ\\s*(?=:)")

    @Synchronized private fun pattern(lang: CodeLanguage) = cache.getOrPut(lang) { commentsAndStrings(lang) }
    @Synchronized private fun keywords(lang: CodeLanguage): Pattern? = keywordCache.getOrPut(lang) {
        if (lang.keywords.isEmpty()) null else Pattern.compile("\\b(" + lang.keywords.joinToString("|") { Pattern.quote(it) } + ")\\b")
    }

    fun highlight(code: String, lang: CodeLanguage): List<Token> {
        if (code.isEmpty()) return emptyList()
        val types = Array(code.length) { TokenType.PLAIN }
        if (lang == CodeLanguage.PLAIN_TEXT) return runs(types)
        val locked = BooleanArray(code.length)

        fun paint(p: Pattern, type: TokenType, lock: Boolean = false, overLocked: Boolean = false) {
            val m = p.matcher(code)
            while (m.find()) for (i in m.start() until m.end()) if (overLocked || !locked[i]) { types[i] = type; if (lock) locked[i] = true }
        }

        // 1. comments and strings, one left-to-right pass (so a quote inside a comment, or `//` inside a string, is inert)
        val m = pattern(lang).matcher(code)
        while (m.find()) {
            val c0 = code[m.start()]
            val t = if (c0 == '"' || c0 == '\'' || c0 == '`') TokenType.STRING else TokenType.COMMENT
            for (i in m.start() until m.end()) { types[i] = t; locked[i] = true }
        }

        paint(NUMBER, TokenType.NUMBER); paint(HEX, TokenType.NUMBER)
        paint(FUNCTION, TokenType.FUNCTION)
        if (lang != CodeLanguage.JSON && lang != CodeLanguage.HTML && lang != CodeLanguage.XML && lang != CodeLanguage.CSS) paint(TYPE, TokenType.TYPE)
        keywords(lang)?.let { paint(it, TokenType.KEYWORD) }
        paint(OPERATOR, TokenType.OPERATOR)

        if (lang == CodeLanguage.HTML || lang == CodeLanguage.XML) { paint(HTML_TAG, TokenType.KEYWORD); paint(HTML_ATTR, TokenType.FUNCTION) }
        if (lang == CodeLanguage.CSS) { paint(CSS_SELECTOR, TokenType.FUNCTION); paint(CSS_PROP, TokenType.KEYWORD) }
        if (lang == CodeLanguage.JSON) paint(JSON_KEY, TokenType.KEYWORD, overLocked = true)   // keys are strings too, but read better as keywords (as on the desktop)
        return runs(types)
    }

    private fun runs(types: Array<TokenType>): List<Token> {
        val out = ArrayList<Token>()
        var s = 0
        for (i in 1..types.size) if (i == types.size || types[i] != types[s]) { out += Token(s, i, types[s]); s = i }
        return out
    }
}
