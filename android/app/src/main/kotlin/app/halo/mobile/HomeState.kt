package app.halo.mobile

/** What the Home status ring says. Pure so the rules are testable; the screen only maps it to colours. */
enum class CloudHealth { NOT_PAIRED, NEEDS_ATTENTION, OFF, SYNCING, NEVER, OK, WARNING, ERROR }

fun cloudHealth(
    paired: Boolean, problem: Boolean, smsOn: Boolean, clipOn: Boolean, syncing: Boolean,
    lastSyncAt: Long, lastError: String?, quarantined: Int,
): CloudHealth = when {
    problem -> CloudHealth.NEEDS_ATTENTION
    !paired -> CloudHealth.NOT_PAIRED
    syncing -> CloudHealth.SYNCING
    !smsOn && !clipOn -> CloudHealth.OFF
    lastError != null -> CloudHealth.ERROR
    quarantined > 0 -> CloudHealth.WARNING
    smsOn && lastSyncAt == 0L -> CloudHealth.NEVER
    else -> CloudHealth.OK
}

/** A one-tap code found in a message ("Your code is 482913"). Null when the text carries no code-like number next to a code word. */
object OtpCode {
    private val word = Regex("(?i)\\b(code|otp|passcode|verification|verify|one[- ]time|pin|token)\\b")
    private val digits = Regex("(?<![\\d.,])(\\d{4,8}|\\d{3}[ -]\\d{3})(?!\\d)(?![.,]\\d)")
    fun find(body: String): String? {
        if (!word.containsMatchIn(body)) return null
        val m = digits.find(body) ?: return null
        return m.value.replace(" ", "").replace("-", "")
    }
}

/** How a clipboard history item is coloured: links cyan, code purple, everything else accent (desktop's ClipboardView convention). */
enum class ClipKind(val label: String) { TEXT("Text"), URL("Link"), CODE("Code");
    companion object {
        private val codeHints = listOf("{", "};", "=>", "();", "</", "def ", "func ", "import ", "const ", "SELECT ", "#include", "return ")
        fun of(kind: String, text: String): ClipKind = when {
            kind == "url" -> URL
            text.trim().let { (it.startsWith("https://") || it.startsWith("http://")) && it.none(Char::isWhitespace) } -> URL   // a bare link copied as plain text
            text.contains('\n') && codeHints.count { text.contains(it) } >= 2 -> CODE
            codeHints.count { text.contains(it) } >= 3 -> CODE
            else -> TEXT
        }
    }
}
