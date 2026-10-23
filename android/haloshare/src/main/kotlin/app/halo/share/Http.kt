package app.halo.share

import java.io.File

/**
 * A parsed HTTP/1.1 request line and headers — **no body**. Pure and byte-oriented, so the framing
 * rules are testable without a socket (protocol doc §1: never assume the head and the body arrive
 * in separate reads).
 */
data class HttpRequestHead(
    val method: String,
    val path: String,
    val query: Map<String, String>,
    /** Header names are lower-cased. */
    val headers: Map<String, String>,
) {
    /** 0 when absent or unparseable. */
    val contentLength: Int get() = headers["content-length"]?.trim()?.toIntOrNull() ?: 0
    val isChunked: Boolean get() = headers["transfer-encoding"]?.lowercase()?.contains("chunked") == true
    val expectsContinue: Boolean get() = headers["expect"]?.lowercase() == "100-continue"

    companion object {
        /** `head` is everything before the blank line. Decoding is lossy, never failing. */
        fun parse(head: ByteArray): HttpRequestHead? {
            val text = String(head, Charsets.UTF_8)
            val lines = text.split("\r\n")
            val requestLine = lines.firstOrNull() ?: return null
            val parts = requestLine.split(' ', limit = 3).filter { it.isNotEmpty() }
            if (parts.size < 2) return null

            val target = parts[1]
            val qIndex = target.indexOf('?')
            val path = if (qIndex >= 0) target.substring(0, qIndex) else target
            if (!path.startsWith("/")) return null

            val query = LinkedHashMap<String, String>()
            if (qIndex >= 0) {
                for (pair in target.substring(qIndex + 1).split('&')) {
                    if (pair.isEmpty()) continue
                    val eq = pair.indexOf('=')
                    val name = if (eq >= 0) pair.substring(0, eq) else pair
                    if (name.isEmpty()) continue
                    val value = if (eq >= 0) pair.substring(eq + 1) else ""
                    query[percentDecode(name)] = percentDecode(value)
                }
            }

            val headers = LinkedHashMap<String, String>()
            for (line in lines.drop(1)) {
                if (line.isEmpty()) continue
                val colon = line.indexOf(':')
                if (colon < 0) continue
                headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
            return HttpRequestHead(parts[0].uppercase(), path, query, headers)
        }

        /** `%XX` decoding that leaves `+` alone (query strings here are not form-encoded). */
        fun percentDecode(s: String): String {
            if (!s.contains('%')) return s
            val bytes = s.toByteArray(Charsets.UTF_8)
            val out = java.io.ByteArrayOutputStream(bytes.size)
            var i = 0
            while (i < bytes.size) {
                if (bytes[i] == '%'.code.toByte() && i + 2 < bytes.size) {
                    val value = String(bytes, i + 1, 2, Charsets.US_ASCII).toIntOrNull(16)
                    if (value != null) { out.write(value); i += 3; continue }
                }
                out.write(bytes[i].toInt())
                i++
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }
    }
}

internal object HttpResponse {
    private fun reason(status: Int) = when (status) {
        200 -> "OK"; 204 -> "No Content"; 400 -> "Bad Request"; 401 -> "Unauthorized"
        403 -> "Forbidden"; 404 -> "Not Found"; 409 -> "Conflict"; 411 -> "Length Required"
        413 -> "Payload Too Large"; 422 -> "Unprocessable Entity"; 429 -> "Too Many Requests"
        500 -> "Internal Server Error"; else -> "Unknown"
    }

    fun bytes(status: Int, json: String? = null): ByteArray {
        val payload = (json ?: "").toByteArray(Charsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 $status ${reason(status)}\r\nConnection: close\r\nContent-Length: ${payload.size}\r\n")
            if (json != null) append("Content-Type: application/json\r\n")
            append("\r\n")
        }
        return head.toByteArray(Charsets.UTF_8) + payload
    }

    fun error(status: Int, message: String) =
        bytes(status, "{\"error\":\"${message.replace("\\", "\\\\").replace("\"", "\\\"")}\"}")
}

/**
 * Turning a sender-supplied file name into a path that is safe to write (protocol doc §7).
 * Legitimate sub-folders are kept; `..`, `.`, empty components, absolute prefixes and NUL are not.
 * `\` is a separator (Windows senders).
 */
object SafeFileName {

    fun relativePath(raw: String): String? {
        if (raw.contains('\u0000')) return null
        val parts = raw.replace('\\', '/').split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "." && it != ".." }
        return parts.takeIf { it.isNotEmpty() }?.joinToString("/")
    }

    /**
     * `base/<safe path>`, inside `base`, with ` (1)`, ` (2)` … before the extension if it already
     * exists — never an overwrite. Containment is checked lexically (see the Swift Kit's
     * `SafeFileName` for the `/private` bug that taught us not to depend on what exists on disk).
     */
    fun uniqueDestination(rawName: String, base: File): File {
        fun build(relative: String): File {
            var f = base
            for (c in relative.split('/')) if (c.isNotEmpty()) f = File(f, c)
            return f
        }
        var candidate = build(relativePath(rawName) ?: "file")
        val root = if (base.path.endsWith("/")) base.path else base.path + "/"
        if (!candidate.path.startsWith(root)) candidate = build("file")
        if (!candidate.exists()) return candidate

        val dir = candidate.parentFile!!
        val name = candidate.name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var n = 1
        while (true) {
            val next = File(dir, "$stem ($n)$ext")
            if (!next.exists()) return next
            n++
        }
    }
}
