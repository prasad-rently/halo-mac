package app.halo.tools

/** A run of same-coloured text within one visual (screen) line. */
data class Segment(val text: String, val type: TokenType)

/** One drawn row. [number] is the source line number on the first row of a source line, null on wrapped continuations. */
data class VisualLine(val number: Int?, val segments: List<Segment>) { val text: String get() = segments.joinToString("") { it.text } }

/**
 * Turns code + highlight tokens into the rows the PNG renderer draws, with the two limits a phone-sized share image needs
 * made explicit instead of silent: long lines WRAP at [maxCols] (nothing is cut), and past [maxLines] source lines the image
 * stops and says how many were left out. Pure, so the wrapping/truncation rules are unit-tested without a Bitmap.
 */
data class CodeLayout(val lines: List<VisualLine>, val omittedLines: Int, val sourceLines: Int) {
    companion object {
        const val DEFAULT_COLS = 100
        const val DEFAULT_MAX_LINES = 300
        private const val TAB = "    "

        fun build(code: String, language: CodeLanguage, maxCols: Int = DEFAULT_COLS, maxLines: Int = DEFAULT_MAX_LINES): CodeLayout {
            require(maxCols >= 1 && maxLines >= 1)
            val text = code.replace("\r\n", "\n").replace('\r', '\n').replace("\t", TAB).trimEnd('\n')
            val tokens = SyntaxHighlighter.highlight(text, language)
            val out = ArrayList<VisualLine>()
            var lineNo = 1; var lineStart = 0; var omitted = 0
            val source = if (text.isEmpty()) 0 else text.count { it == '\n' } + 1

            // Split on '\n' while keeping token boundaries: walk tokens, cutting runs at newlines and at maxCols.
            var segs = ArrayList<Segment>(); var cols = 0; var first = true
            fun flushRow() { out += VisualLine(if (first) lineNo else null, segs); segs = ArrayList(); cols = 0; first = false }
            fun endLine() { flushRow(); lineNo++; first = true }
            outer@ for (t in tokens) {
                var i = t.start
                while (i < t.end) {
                    if (lineNo > maxLines) { omitted = source - maxLines; break@outer }
                    val c = text[i]
                    if (c == '\n') { endLine(); i++; continue }
                    if (cols >= maxCols) flushRow()
                    var j = i
                    while (j < t.end && text[j] != '\n' && cols + (j - i) < maxCols) j++
                    // Never split a surrogate pair across rows.
                    if (j < t.end && j > i && Character.isHighSurrogate(text[j - 1]) && Character.isLowSurrogate(text[j])) j--
                    if (j == i) j = minOf(i + Character.charCount(text.codePointAt(i)), t.end)
                    segs += Segment(text.substring(i, j), t.type); cols += j - i; i = j
                }
            }
            if (lineNo <= maxLines && segs.isNotEmpty()) flushRow()
            return CodeLayout(out, omitted, source)
        }
    }
}
