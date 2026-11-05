package app.halo.tools

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** Source of random bytes for the generators, injectable so tests can pin the output. Production = [SecureRandom]. */
fun interface RandomBytes { fun next(n: Int): ByteArray }

object SystemRandomBytes : RandomBytes {
    private val rng = SecureRandom()
    override fun next(n: Int): ByteArray = ByteArray(n).also(rng::nextBytes)
}

/** The Actions-catalog text utilities, ported from the desktop's clipboard / system actions (ActionLibrary.swift). */
enum class TransformId(val title: String, val subtitle: String, val usesInput: Boolean = true, val secretOutput: Boolean = false) {
    FORMAT_JSON("Format JSON", "Pretty-print with 4-space indent"),
    MINIFY_JSON("Minify JSON", "Compact into a single line"),
    COUNT_WORDS("Count words", "Words, characters, lines and bytes"),
    SORT_LINES("Sort lines", "Alphabetical, by Unicode code point"),
    URL_ENCODE("URL encode", "Percent-encode (keeps /)"),
    URL_DECODE("URL decode", "Turn %XX back into text"),
    BASE64_ENCODE("Base64 encode", "Text to Base64"),
    BASE64_DECODE("Base64 decode", "Base64 back to text"),
    UPPERCASE("UPPERCASE", "Convert to upper case"),
    LOWERCASE("lowercase", "Convert to lower case"),
    DEDUP_LINES("Remove duplicate lines", "Keep the first of each line"),
    STRIP_FORMATTING("Strip formatting", "Plain text only"),
    SHA256("SHA-256 hash", "Hex digest of the text"),
    QR_CODE("QR code", "Make a QR code of the text"),
    UUID("Generate UUID", "Random UUID v4", usesInput = false),
    PASSWORD("Generate password", "20 random letters and digits", usesInput = false, secretOutput = true),
}

sealed interface TransformResult {
    /** [note] is a one-line, content-free summary ("12 lines"); never repeats the text. */
    data class Output(val text: String, val note: String? = null, val secret: Boolean = false) : TransformResult
    /** The text to be drawn as a QR code (the app renders it). */
    data class Qr(val payload: String) : TransformResult
    data class Failure(val message: String) : TransformResult
}

data class TextStats(val words: Int, val characters: Int, val lines: Int, val bytes: Int) {
    /** The desktop action's exact three-line report. Its "Characters" is `wc -c`, i.e. BYTES — identical for ASCII only. */
    fun desktopFormat(): String = "Words:      $words\nCharacters: $bytes\nLines:      $lines"
    fun format(): String = "Words:      $words\nCharacters: $characters\nLines:      $lines\nBytes:      $bytes"

    companion object {
        fun of(text: String): TextStats {
            val t = shellText(text)
            var words = 0; var inWord = false
            for (c in t) { if (c.isWhitespace()) inWord = false else if (!inWord) { inWord = true; words++ } }
            return TextStats(words, t.codePointCount(0, t.length), t.count { it == '\n' } + 1, t.toByteArray(Charsets.UTF_8).size)
        }
    }
}

/**
 * Mirrors the shell idiom `TEXT=$(pbpaste)`: command substitution strips every trailing newline (and only newlines).
 * All desktop clipboard actions start there, so every transform here does too — otherwise "abc\n" and "abc" would
 * hash, encode and count differently on the two platforms.
 */
internal fun shellText(s: String): String = s.trimEnd('\n')

object TextTransforms {
    /** Largest payload a QR code can hold at error-correction M in binary mode (ISO 18004, version 40). */
    const val QR_MAX_BYTES = 2331

    fun apply(id: TransformId, input: String, random: RandomBytes = SystemRandomBytes): TransformResult {
        if (!id.usesInput) return when (id) {
            TransformId.UUID -> TransformResult.Output(uuid(random), "Random (version 4) UUID")
            else -> TransformResult.Output(password(random), "20 characters, A–Z a–z 0–9", secret = true)
        }
        val text = shellText(input)
        if (text.isEmpty()) return TransformResult.Failure("There's no text to transform.")
        return when (id) {
            TransformId.FORMAT_JSON -> json { JsonFormat.pretty(text).let { TransformResult.Output(it, "${it.count { c -> c == '\n' } + 1} lines") } }
            TransformId.MINIFY_JSON -> json { TransformResult.Output(JsonFormat.minify(text), "Single line") }
            TransformId.COUNT_WORDS -> TransformResult.Output(TextStats.of(text).format())
            TransformId.SORT_LINES -> {
                val lines = text.split('\n')
                TransformResult.Output(lines.sortedWith(CODE_POINT_ORDER).joinToString("\n"), "${lines.size} lines sorted")
            }
            TransformId.URL_ENCODE -> TransformResult.Output(percentEncode(pyStrip(text)))
            TransformId.URL_DECODE -> TransformResult.Output(percentDecode(pyStrip(text)))
            TransformId.BASE64_ENCODE -> TransformResult.Output(Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8)))
            TransformId.BASE64_DECODE -> base64Decode(text)
            TransformId.UPPERCASE -> TransformResult.Output(text.uppercase(java.util.Locale.ROOT))
            TransformId.LOWERCASE -> TransformResult.Output(text.lowercase(java.util.Locale.ROOT))
            TransformId.DEDUP_LINES -> {
                val lines = text.split('\n'); val kept = LinkedHashSet(lines).toList()
                TransformResult.Output(kept.joinToString("\n"), "Removed ${lines.size - kept.size} duplicate lines (${lines.size} → ${kept.size})")
            }
            TransformId.STRIP_FORMATTING -> TransformResult.Output(text, "Plain text only")
            TransformId.SHA256 -> TransformResult.Output(sha256Hex(text))
            TransformId.QR_CODE ->
                if (text.toByteArray(Charsets.UTF_8).size > QR_MAX_BYTES) TransformResult.Failure("Too long for a QR code (the limit is about $QR_MAX_BYTES bytes).")
                else TransformResult.Qr(text)
            TransformId.UUID, TransformId.PASSWORD -> error("generators handled above")
        }
    }

    private inline fun json(block: () -> TransformResult): TransformResult =
        try { block() } catch (e: JsonFormat.InvalidJson) { TransformResult.Failure("This isn't valid JSON: ${e.message}") }

    /** Code-point order — what `sort` gives in the C locale the desktop runs it in, and unlike String.compareTo it ranks emoji after U+FFFF. */
    private val CODE_POINT_ORDER = Comparator<String> { a, b ->
        var i = 0; var j = 0
        while (i < a.length && j < b.length) {
            val ca = a.codePointAt(i); val cb = b.codePointAt(j)
            if (ca != cb) return@Comparator ca.compareTo(cb)
            i += Character.charCount(ca); j += Character.charCount(cb)
        }
        (a.length - i).compareTo(b.length - j)
    }

    /** Python's `str.strip()` (what the desktop URL actions apply first). */
    internal fun pyStrip(s: String): String {
        var a = 0; var b = s.length
        fun ws(c: Char) = c.isWhitespace() || c == '\u00a0' || c in '\u001c'..'\u001f' || c == '\u0085'
        while (a < b && ws(s[a])) a++
        while (b > a && ws(s[b - 1])) b--
        return s.substring(a, b)
    }

    /** `urllib.parse.quote(s)` — safe = "/" plus the RFC 3986 unreserved set. */
    fun percentEncode(s: String): String {
        val sb = StringBuilder()
        for (byte in s.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xff
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '_' || ch == '.' || ch == '-' || ch == '~' || ch == '/') sb.append(ch)
            else sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
        }
        return sb.toString()
    }

    /** `urllib.parse.unquote(s)` — `+` is NOT a space, a malformed `%` stays literal, invalid UTF-8 becomes U+FFFD. */
    fun percentDecode(s: String): String {
        val out = StringBuilder(); val pending = java.io.ByteArrayOutputStream()
        fun flush() { if (pending.size() > 0) { out.append(String(pending.toByteArray(), Charsets.UTF_8)); pending.reset() } }
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0) {
                pending.write(hex(s[i + 1]) * 16 + hex(s[i + 2])); i += 3
            } else { flush(); out.append(c); i++ }
        }
        flush()
        return out.toString()
    }
    private fun hex(c: Char): Int = when (c) { in '0'..'9' -> c - '0'; in 'a'..'f' -> c - 'a' + 10; in 'A'..'F' -> c - 'A' + 10; else -> -1 }

    /**
     * macOS `base64 --decode`, slightly more forgiving: whitespace anywhere is ignored, URL-safe `-`/`_` are accepted and
     * missing `=` padding is added (so a JWT segment decodes). Anything else invalid fails; so does a result that isn't UTF-8 text.
     */
    private fun base64Decode(text: String): TransformResult {
        val cleaned = text.filterNot { it == ' ' || it == '\t' || it == '\n' || it == '\r' }.replace('-', '+').replace('_', '/').trimEnd('=')
        if (cleaned.isEmpty() || cleaned.length % 4 == 1) return TransformResult.Failure("This isn't valid Base64.")
        val bytes = try { Base64.getDecoder().decode(cleaned + "=".repeat((4 - cleaned.length % 4) % 4)) }
        catch (e: IllegalArgumentException) { return TransformResult.Failure("This isn't valid Base64.") }
        val decoded = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (e: CharacterCodingException) { return TransformResult.Failure("The decoded data isn't text (it's binary, so showing it would only garble it).") }
        return TransformResult.Output(shellText(decoded))
    }

    fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** `uuidgen` on macOS prints an UPPER-CASE v4 UUID; so do we. */
    fun uuid(random: RandomBytes = SystemRandomBytes): String {
        val b = random.next(16).copyOf(16)
        b[6] = ((b[6].toInt() and 0x0f) or 0x40).toByte()
        b[8] = ((b[8].toInt() and 0x3f) or 0x80).toByte()
        val h = b.joinToString("") { "%02X".format(it) }
        return "${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}"
    }

    /** The desktop recipe, `openssl rand -base64 24 | tr -d '/+=' | cut -c1-20`, retried (never padded) in the ~1-in-10^8 case it comes up short. */
    fun password(random: RandomBytes = SystemRandomBytes): String {
        repeat(32) {
            val s = Base64.getEncoder().encodeToString(random.next(24)).filter { it != '/' && it != '+' && it != '=' }
            if (s.length >= 20) return s.substring(0, 20)
        }
        error("random source produced no usable password")
    }
}
