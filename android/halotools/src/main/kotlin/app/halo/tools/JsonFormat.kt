package app.halo.tools

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * JSON pretty-printer / minifier that reproduces what the desktop actions print.
 *
 * The desktop "Format JSON" is `python3 -m json.tool` (indent 4) and "Minify JSON" is
 * `json.dumps(data, separators=(',',':'))`. Both run Python's default `ensure_ascii=True`, so every character outside
 * space..`~` is written as a lowercase `\uXXXX` escape (surrogate pairs as two escapes) — [asciiOnly] reproduces that, and
 * is what the Actions transforms use. The Code Beautifier passes `asciiOnly = false` because a code screenshot full of
 * `é` helps nobody.
 *
 * Deliberate difference from Python: number *tokens are kept verbatim* (`1.0`, `1E5`, `10000000000000000000` print as
 * typed), where Python re-renders floats (`1E5` -> `100000.0`). Integers and ordinary decimals are identical; see the
 * transform-vectors fixture for what is asserted. Key order is preserved and a duplicate key keeps its first position
 * with the last value — Python's `dict` does the same.
 */
object JsonFormat {
    class InvalidJson(message: String) : Exception(message)

    private val parser = Json

    // kotlinx's strict parser still lets an unquoted bare word through as a "primitive" ({"a": hunter2} parses), so every
    // non-string primitive is re-checked against the JSON grammar (plus Python's NaN / Infinity, which json.load accepts).
    private val NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
    private val LITERALS = setOf("true", "false", "null", "NaN", "Infinity", "-Infinity")

    private fun validate(e: JsonElement) {
        when (e) {
            is JsonPrimitive -> if (!e.isString && e.content !in LITERALS && !NUMBER.matches(e.content)) throw InvalidJson("unexpected value")
            is JsonArray -> e.forEach(::validate)
            is JsonObject -> e.values.forEach(::validate)
        }
    }

    // The message never quotes the input: it can be a password or token the user pasted.
    fun parse(text: String): JsonElement {
        val e = try { parser.parseToJsonElement(text) } catch (e: Exception) { throw InvalidJson("it doesn't parse") }
        validate(e)
        return e
    }

    fun pretty(text: String, indent: Int = 4, asciiOnly: Boolean = true): String =
        StringBuilder().also { write(parse(text), it, indent, asciiOnly, 0) }.toString()

    fun minify(text: String, asciiOnly: Boolean = true): String =
        StringBuilder().also { write(parse(text), it, null, asciiOnly, 0) }.toString()

    private fun write(e: JsonElement, out: StringBuilder, indent: Int?, ascii: Boolean, depth: Int) {
        when (e) {
            is JsonPrimitive -> if (e.isString) quote(e.content, out, ascii) else out.append(e.content)
            is JsonArray -> {
                if (e.isEmpty()) { out.append("[]"); return }
                out.append('[')
                e.forEachIndexed { i, v ->
                    if (i > 0) out.append(',')
                    newline(out, indent, depth + 1)
                    write(v, out, indent, ascii, depth + 1)
                }
                newline(out, indent, depth); out.append(']')
            }
            is JsonObject -> {
                if (e.isEmpty()) { out.append("{}"); return }
                out.append('{')
                var first = true
                for ((k, v) in e) {
                    if (!first) out.append(',')
                    first = false
                    newline(out, indent, depth + 1)
                    quote(k, out, ascii); out.append(if (indent != null) ": " else ":")
                    write(v, out, indent, ascii, depth + 1)
                }
                newline(out, indent, depth); out.append('}')
            }
        }
    }

    private fun newline(out: StringBuilder, indent: Int?, depth: Int) {
        if (indent == null) return
        out.append('\n'); repeat(indent * depth) { out.append(' ') }
    }

    private fun quote(s: String, out: StringBuilder, ascii: Boolean) {
        out.append('"')
        for (c in s) {
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c == '\b' -> out.append("\\b")
                c == '\u000c' -> out.append("\\f")
                c < ' ' -> out.append("\\u%04x".format(c.code))
                ascii && (c > '~') -> out.append("\\u%04x".format(c.code))    // includes DEL (0x7f), as Python does
                else -> out.append(c)
            }
        }
        out.append('"')
    }
}
