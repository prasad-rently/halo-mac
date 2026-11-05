package app.halo.tools

sealed interface FormatResult {
    data class Ok(val text: String) : FormatResult
    /** No formatter for this language: the code is shown (and highlighted) exactly as given. */
    data class Unsupported(val reason: String) : FormatResult
    data class Invalid(val reason: String) : FormatResult
}

/**
 * Indenters for the markup / data / brace languages. These are *re-indenters*, not parsers: they never rename, reorder or
 * drop anything, they only change whitespace, and they never throw on malformed input (an unmatched tag or brace
 * just stops indenting further). Only JSON can be rejected, because it has a real grammar.
 * Every formatter is idempotent — formatting its own output is a no-op — which the tests pin.
 */
object CodeFormatter {
    private val brace = setOf(CodeLanguage.JAVASCRIPT, CodeLanguage.TYPESCRIPT)

    fun supports(lang: CodeLanguage): Boolean = lang == CodeLanguage.JSON || lang == CodeLanguage.XML || lang == CodeLanguage.HTML || lang == CodeLanguage.CSS || lang in brace

    fun format(code: String, lang: CodeLanguage, indent: Int = 2): FormatResult {
        if (!supports(lang)) return FormatResult.Unsupported("There's no formatter for ${lang.label} yet — it's shown as you wrote it.")
        val text = code.replace("\r\n", "\n").replace('\r', '\n').trim('\n')
        if (text.isBlank()) return FormatResult.Ok("")
        return when (lang) {
            CodeLanguage.JSON -> try { FormatResult.Ok(JsonFormat.pretty(text, indent, asciiOnly = false)) } catch (e: JsonFormat.InvalidJson) { FormatResult.Invalid("This isn't valid JSON (${e.message}).") }
            CodeLanguage.XML -> FormatResult.Ok(MarkupFormatter.format(text, html = false, indent))
            CodeLanguage.HTML -> FormatResult.Ok(MarkupFormatter.format(text, html = true, indent))
            CodeLanguage.CSS -> FormatResult.Ok(CssFormatter.format(text, indent))
            else -> FormatResult.Ok(BraceFormatter.format(text, indent))
        }
    }
}

// ── XML / HTML ─────────────────────────────────────────────────────────────────────────────────

internal object MarkupFormatter {
    private sealed interface T {
        data class Text(val s: String) : T
        data class Open(val raw: String, val name: String, val selfClosing: Boolean) : T
        data class Close(val raw: String, val name: String) : T
        data class Other(val raw: String) : T          // comment, doctype, processing instruction, CDATA
        data class Raw(val s: String) : T               // verbatim content of <script>/<style>/<pre>/<textarea>
    }

    private val VOID = setOf("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr")
    private val RAW_TEXT = setOf("script", "style", "pre", "textarea")

    private fun tokenize(src: String, html: Boolean): List<T> {
        val out = ArrayList<T>(); var i = 0
        fun other(open: String, close: String) {
            val e = src.indexOf(close, i + open.length)
            val end = if (e < 0) src.length else e + close.length
            out += T.Other(src.substring(i, end)); i = end
        }
        while (i < src.length) {
            if (src[i] != '<') {
                val e = src.indexOf('<', i).let { if (it < 0) src.length else it }
                out += T.Text(src.substring(i, e)); i = e; continue
            }
            when {
                src.startsWith("<!--", i) -> other("<!--", "-->")
                src.startsWith("<![CDATA[", i) -> other("<![CDATA[", "]]>")
                src.startsWith("<?", i) -> other("<?", "?>")
                src.startsWith("<!", i) -> other("<!", ">")
                src.startsWith("</", i) && i + 2 < src.length && src[i + 2].isLetter() -> {
                    val e = tagEnd(src, i); val raw = src.substring(i, e)
                    out += T.Close(raw, raw.drop(2).trimEnd('>').trim().lowercase()); i = e
                }
                i + 1 < src.length && (src[i + 1].isLetter() || src[i + 1] == '_') -> {
                    val e = tagEnd(src, i); val raw = src.substring(i, e)
                    val name = raw.drop(1).takeWhile { !it.isWhitespace() && it != '>' && it != '/' }
                    val lname = if (html) name.lowercase() else name
                    val selfClosing = raw.endsWith("/>") || (html && lname in VOID)
                    out += T.Open(raw, lname, selfClosing); i = e
                    if (html && !selfClosing && lname in RAW_TEXT) {
                        val close = Regex("</" + Regex.escape(lname) + "\\s*>", RegexOption.IGNORE_CASE).find(src, i)
                        val end = close?.range?.first ?: src.length
                        if (end > i) out += T.Raw(src.substring(i, end))
                        i = end
                    }
                }
                else -> { out += T.Text("<"); i++ }
            }
        }
        return out
    }

    /** Index just past the `>` that ends the tag starting at [from], skipping `>` inside quoted attribute values. */
    private fun tagEnd(s: String, from: Int): Int {
        var i = from + 1; var q = '\u0000'
        while (i < s.length) {
            val c = s[i]
            if (q != '\u0000') { if (c == q) q = '\u0000' } else if (c == '"' || c == '\'') q = c else if (c == '>') return i + 1
            i++
        }
        return s.length
    }

    /** Whitespace inside a tag (outside quotes) collapses to single spaces; attribute values are untouched. */
    private fun tidyTag(raw: String): String {
        val sb = StringBuilder(); var q = '\u0000'
        for (c in raw) {
            if (q != '\u0000') { sb.append(c); if (c == q) q = '\u0000' }
            else if (c == '"' || c == '\'') { sb.append(c); q = c }
            else if (c.isWhitespace()) { if (sb.isNotEmpty() && sb.last() != ' ') sb.append(' ') }
            else sb.append(c)
        }
        var r = sb.toString()                                  // only the space before the tag's own closing `>` / `/>`, never one inside a value
        if (r.endsWith(" />")) r = r.dropLast(3) + "/>" else if (r.endsWith(" >")) r = r.dropLast(2) + ">"
        return r
    }

    fun format(src: String, html: Boolean, indent: Int): String {
        val toks = tokenize(src, html)
        val lines = ArrayList<String>(); var depth = 0
        fun line(s: String) { lines += " ".repeat(depth * indent) + s }
        fun collapse(s: String) = s.trim().split(Regex("\\s+")).joinToString(" ")
        var i = 0
        while (i < toks.size) {
            when (val t = toks[i]) {
                is T.Text -> { val c = collapse(t.s); if (c.isNotEmpty()) line(c) }
                is T.Other -> line(t.raw.trim().let { if (it.startsWith("<!--") || it.startsWith("<![CDATA[")) it else tidyTag(it) })
                is T.Close -> { depth = maxOf(0, depth - 1); line(tidyTag(t.raw)) }
                is T.Raw -> { /* consumed with its opening tag below */ }
                is T.Open -> {
                    if (t.selfClosing) { line(tidyTag(t.raw)) }
                    else {
                        val n1 = toks.getOrNull(i + 1); val n2 = toks.getOrNull(i + 2)
                        if (n1 is T.Raw && n2 is T.Close && n2.name == t.name) {
                            if (t.name == "pre" || t.name == "textarea") lines += " ".repeat(depth * indent) + tidyTag(t.raw) + n1.s + n2.raw      // whitespace is content here
                            else {
                                line(tidyTag(t.raw)); depth++
                                dedent(n1.s).forEach { l -> if (l.isEmpty()) lines += "" else line(l) }
                                depth--; line(tidyTag(n2.raw))
                            }
                            i += 3; continue
                        }
                        if (n1 is T.Close && n1.name == t.name) { line(tidyTag(t.raw) + tidyTag(n1.raw)); i += 2; continue }
                        if (n1 is T.Text && n2 is T.Close && n2.name == t.name) { line(tidyTag(t.raw) + collapse(n1.s) + tidyTag(n2.raw)); i += 3; continue }
                        line(tidyTag(t.raw)); depth++
                    }
                }
            }
            i++
        }
        return lines.joinToString("\n") { it.trimEnd() }
    }

    private fun dedent(s: String): List<String> {
        val ls = s.trim('\n').split('\n').map { it.trimEnd() }
        val common = ls.filter { it.isNotBlank() }.minOfOrNull { l -> l.takeWhile { it == ' ' || it == '\t' }.length } ?: 0
        return ls.map { if (it.isBlank()) "" else it.substring(common) }
    }
}

// ── CSS ────────────────────────────────────────────────────────────────────────────────────────

internal object CssFormatter {
    private sealed interface Item {
        data class Comment(val s: String) : Item
        data class Decl(val s: String) : Item
        data class Rule(val prelude: String, val body: List<Item>) : Item
    }

    private class Parser(val s: String) {
        var i = 0

        fun items(top: Boolean): List<Item> {
            val out = ArrayList<Item>(); val buf = StringBuilder()
            fun flushDecl() { val d = buf.toString().trim(); if (d.isNotEmpty()) out += Item.Decl(d); buf.setLength(0) }
            fun put(c: Char) { if (c.isWhitespace()) { if (buf.isNotEmpty() && buf.last() != ' ') buf.append(' ') } else buf.append(c) }
            while (i < s.length) {
                val c = s[i]
                when {
                    c == '/' && s.startsWith("/*", i) -> {
                        val e = s.indexOf("*/", i + 2).let { if (it < 0) s.length else it + 2 }
                        val text = s.substring(i, e); i = e
                        if (buf.isBlank()) out += Item.Comment(text) else buf.append(text)
                    }
                    c == '"' || c == '\'' -> { buf.append(string(c)) }
                    c == '(' -> {
                        val isUrl = buf.toString().takeLast(3).equals("url", ignoreCase = true)
                        buf.append(parenthesised(isUrl))
                    }
                    c == ',' -> { buf.append(", "); i++ }
                    c == ';' -> { flushDecl(); i++ }
                    c == '{' -> { i++; val prelude = buf.toString().trim(); buf.setLength(0); out += Item.Rule(prelude, items(false)) }
                    c == '}' -> { flushDecl(); i++; if (!top) return out }     // a stray `}` at top level is dropped, not echoed
                    else -> { put(c); i++ }
                }
            }
            flushDecl()
            return out
        }

        private fun string(q: Char): String {
            val st = i; i++
            while (i < s.length && s[i] != q) { if (s[i] == '\\') i++; i++ }
            i = minOf(i + 1, s.length)
            return s.substring(st, i)
        }

        /** Text from `(` to its matching `)`. `url(...)` is copied untouched; anything else gets whitespace collapsed and comma spacing. */
        private fun parenthesised(verbatim: Boolean): String {
            val sb = StringBuilder(); var depth = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '"' || c == '\'') { sb.append(string(c)); continue }
                if (c == '(') depth++
                if (c == ')') depth--
                if (verbatim) sb.append(c)
                else if (c == ',') { sb.append(", ") }
                else if (c.isWhitespace()) { if (sb.isNotEmpty() && sb.last() != ' ' && sb.last() != '(') sb.append(' ') }
                else { if (c == ')' && sb.isNotEmpty() && sb.last() == ' ') sb.setLength(sb.length - 1); sb.append(c) }
                i++
                if (depth == 0) break
            }
            return sb.toString()
        }
    }

    fun format(src: String, indent: Int): String {
        val items = Parser(src).items(top = true)
        val out = ArrayList<String>()
        fun emit(items: List<Item>, depth: Int) {
            val pad = " ".repeat(depth * indent)
            items.forEachIndexed { idx, it ->
                when (it) {
                    is Item.Comment -> it.s.split('\n').forEachIndexed { n, l -> out += if (n == 0) pad + l.trim() else pad + " " + l.trim() }
                    is Item.Decl -> out += pad + declaration(it.s) + ";"
                    is Item.Rule -> {
                        if (depth == 0 && items.getOrNull(idx - 1) is Item.Rule) out += ""
                        if (it.body.isEmpty()) out += "$pad${it.prelude} {}"
                        else { out += "$pad${it.prelude} {"; emit(it.body, depth + 1); out += "$pad}" }
                    }
                }
            }
        }
        emit(items, 0)
        return out.joinToString("\n") { it.trimEnd() }
    }

    /** `color:red` -> `color: red`; at-rules and anything without a top-level colon are left as written. */
    private fun declaration(d: String): String {
        if (d.startsWith("@")) return d
        var depth = 0; var q = '\u0000'
        for ((i, c) in d.withIndex()) {
            if (q != '\u0000') { if (c == q) q = '\u0000'; continue }
            when (c) { '"', '\'' -> q = c; '(' -> depth++; ')' -> depth--; ':' -> if (depth == 0) return d.substring(0, i).trim() + ": " + d.substring(i + 1).trim() }
        }
        return d
    }
}

// ── JavaScript / TypeScript ────────────────────────────────────────────────────────────────────

/**
 * Whitespace-only re-indenter for C-style braces. Strings, template literals, regex literals and comments are copied
 * verbatim, so a `{`, `;` or `//` inside them is inert. `for (;;)` stays on one line (a `;` inside parentheses is not a
 * statement break). Operators and the user's own spacing are not rewritten.
 */
internal object BraceFormatter {
    private val CONTINUES = setOf("else", "catch", "finally", "while")

    fun format(src: String, indent: Int): String {
        val out = StringBuilder(); var depth = 0; var lineStart = true; var space = false
        val stack = ArrayList<Char>(); var prevSig = '\u0000'; var prevWord = ""
        val pad = " ".repeat(indent)
        fun newline() { while (out.isNotEmpty() && out.last() == ' ') out.setLength(out.length - 1); if (out.isNotEmpty() && out.last() != '\n') out.append('\n'); lineStart = true; space = false }
        fun emit(t: String, glue: Boolean = false) {
            if (lineStart) { repeat(depth) { out.append(pad) }; lineStart = false }
            else if (space && !glue) out.append(' ')
            out.append(t); space = false
        }
        var i = 0
        fun nextSig(from: Int): Int { var j = from; while (j < src.length && src[j].isWhitespace()) j++; return j }
        while (i < src.length) {
            val c = src[i]
            when {
                c.isWhitespace() -> { space = true; i++ }
                c == '/' && src.startsWith("//", i) -> {
                    val e = src.indexOf('\n', i).let { if (it < 0) src.length else it }
                    emit(src.substring(i, e).trimEnd()); newline(); i = e
                }
                c == '/' && src.startsWith("/*", i) -> {
                    val e = src.indexOf("*/", i + 2).let { if (it < 0) src.length else it + 2 }
                    val comment = src.substring(i, e)
                    emit(comment); i = e
                    if (comment.contains('\n')) newline()
                }
                c == '"' || c == '\'' || c == '`' -> {
                    var e = i + 1
                    while (e < src.length && src[e] != c) { if (src[e] == '\\') e++; if (c != '`' && e < src.length && src[e] == '\n') break; e++ }
                    e = minOf(e + 1, src.length)
                    emit(src.substring(i, e)); i = e; prevSig = c; prevWord = ""
                }
                c == '/' && regexAllowed(prevSig, prevWord) -> {
                    var e = i + 1; var cls = false
                    while (e < src.length && src[e] != '\n') {
                        val d = src[e]
                        if (d == '\\') e++ else if (d == '[') cls = true else if (d == ']') cls = false else if (d == '/' && !cls) break
                        e++
                    }
                    if (e < src.length && src[e] == '/') { e++; while (e < src.length && src[e].isLetter()) e++ } else e = i + 1
                    emit(src.substring(i, e)); i = e; prevSig = '/'; prevWord = ""
                }
                c == '{' -> {
                    val j = nextSig(i + 1)
                    if (!lineStart && prevSig != '(' && prevSig != '[' && prevSig != '$') space = true      // `){` -> `) {`
                    emit("{")
                    if (j < src.length && src[j] == '}') { out.append('}'); i = j + 1; prevSig = '}'; prevWord = ""; if (!continuesAfter(src, i)) newline() else space = true }
                    else { stack += '{'; depth++; newline(); i++; prevSig = '{'; prevWord = "" }
                }
                c == '}' -> {
                    if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
                    depth = maxOf(0, depth - 1); newline(); emit("}"); i++; prevSig = '}'; prevWord = ""
                    if (!continuesAfter(src, i)) newline() else space = true
                }
                c == ';' -> { emit(";", glue = true); i++; prevSig = ';'; prevWord = ""; if (stack.lastOrNull() == '(') space = true else newline() }
                c == ',' -> { emit(",", glue = true); i++; prevSig = ','; prevWord = ""; if (stack.lastOrNull() == '{') newline() else space = true }
                c == '(' || c == '[' -> { emit(c.toString()); stack += c; i++; prevSig = c; prevWord = "" }
                c == ')' || c == ']' -> { if (stack.isNotEmpty()) stack.removeAt(stack.size - 1); emit(c.toString(), glue = true); i++; prevSig = c; prevWord = "" }
                else -> {
                    var e = i
                    while (e < src.length && !src[e].isWhitespace() && src[e] !in "{};,()[]\"'`" && !(src[e] == '/' && e + 1 < src.length && (src[e + 1] == '/' || src[e + 1] == '*'))) e++
                    if (e == i) e = i + 1
                    val tok = src.substring(i, e)
                    emit(tok); i = e
                    prevSig = tok.last(); prevWord = if (tok.all { it.isLetterOrDigit() || it == '_' || it == '$' }) tok else ""
                }
            }
        }
        return out.toString().trimEnd('\n').lines().joinToString("\n") { it.trimEnd() }
    }

    /** After a `}`: keep `else` / `catch` / `finally` / `while` (do-while), and closers like `)` `,` `;` `.`, on the brace's line. */
    private fun continuesAfter(src: String, from: Int): Boolean {
        var j = from; while (j < src.length && src[j].isWhitespace()) j++
        if (j >= src.length) return false
        if (src[j] in ")],;.") return true
        val w = src.substring(j).takeWhile { it.isLetter() }
        return w in CONTINUES
    }

    /** A `/` starts a regex literal after an operator/opening punctuation or a keyword such as `return`, never after an operand. */
    private fun regexAllowed(prev: Char, word: String): Boolean {
        if (prev == '\u0000') return true
        if (word == "return" || word == "typeof" || word == "case" || word == "in" || word == "of") return true
        return prev in "(,=:[!&|?{};+-*%<>~^"
    }
}
