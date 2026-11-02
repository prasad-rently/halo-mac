package app.halo.share

/**
 * A device's self-chosen name is untrusted text from the LAN that ends up in notifications and device lists.
 * Besides control characters, strip the Unicode bidirectional formatting characters: an override (U+202E) or an
 * isolate can reorder the characters around it and make "Mac" display as something else, or push our own
 * "wants to send a file" text into a different visual order. ZWJ/ZWNJ and variation selectors are deliberately kept (emoji, scripts that need them).
 */
object Alias {
    private fun hostile(c: Char): Boolean =
        c.isISOControl() ||
            c in '‪'..'‮' ||      // LRE RLE PDF LRO RLO (embedding / override)
            c in '⁦'..'⁩' ||      // LRI RLI FSI PDI (isolates)
            c == '‎' || c == '‏' || c == '؜' ||   // LRM RLM ALM (invisible direction marks)
            c == '\u2028' || c == '\u2029' ||    // line / paragraph separator
            c == '\u200B' || c in '\u2060'..'\u2064' || c == '\uFEFF' || c == '\u00AD'   // zero-width space, word joiner & invisible operators, BOM, soft hyphen: invisible, so a name made only of them would look blank

    /** Control and bidi characters removed, trimmed, at most [max] chars (never ending in half a surrogate pair). */
    fun clean(raw: String, max: Int): String {
        var s = raw.filter { !hostile(it) }.trim().take(max)
        if (s.isNotEmpty() && s.last().isHighSurrogate()) s = s.dropLast(1)
        return s
    }
}
