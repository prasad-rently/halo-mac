package app.halo.cloud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

// The Kotlin half of Halo's Realtime Database client. It speaks the same two documented REST APIs the
// desktop does (Halo/Core/Cloud/FirebaseRTDBClient.swift) and for the same reason: it needs nothing
// from the Firebase SDK, so it is plain JVM, runs under unit test in seconds, and the whole wire
// contract is visible in one file.
//
//   Auth: Identity Toolkit  POST identitytoolkit.googleapis.com/v1/accounts:signInWithPassword
//         Refresh           POST securetoken.googleapis.com/v1/token
//   Data: RTDB REST         GET/PUT/DELETE  <databaseURL>/<path>.json?auth=<idToken>
//   Live: RTDB streaming    GET <databaseURL>/<path>.json  Accept: text/event-stream
//
// Blocking by design: callers are WorkManager workers or a dedicated thread, never the main thread.

class RtdbException(val kind: Kind, message: String, /** HTTP status when the server answered, else 0. */ val status: Int = 0) : IOException(message) {
    enum class Kind { NOT_CONFIGURED, CONFIGURE_FAILED, AUTH_FAILED, OPERATION_FAILED, NETWORK }

    /**
     * H-14: could this failure plausibly be about the one row being written (too big, rejected by a rule), as opposed
     * to the connection, the session or the server's health? Only the former may count toward quarantining a row —
     * an outage (5xx), a rate limit (429/408), a missing database (404) or a session problem would otherwise park
     * healthy messages one by one while the cloud is merely unavailable.
     */
    val isRowFault: Boolean
        get() = kind == Kind.OPERATION_FAILED && status != 404 && status != 408 && status != 429 && status !in 500..599
}

/** What the sync engines need from a database. Kept narrow so tests can use an in-memory fake. */
interface Rtdb {
    /** The signed-in user id (the `{uid}` in every path). */
    val uid: String
    fun get(path: String): JsonElement?
    fun put(path: String, value: JsonElement)
    /**
     * Merge `value`'s children into the node at `path`, leaving other children untouched. NOT atomic: it is one
     * request per child, so a live observer can see the node half-written. Write a whole node with [put] when a
     * reader that fires once per new child (the desktop's `child_added`) must see it complete.
     */
    fun patch(path: String, value: JsonObject)
    fun delete(path: String)
    /** The child keys of a node without their values (`?shallow=true`) — cheap even for a huge node. */
    fun shallowKeys(path: String): Set<String>
    /** Existing children first, then new ones as they appear. Close the handle to stop. */
    fun observeChildAdded(path: String, onChild: (key: String, value: JsonElement?) -> Unit): AutoCloseable
}

/** Where the credentials are sent. Production is Google; tests point it at a loopback server. */
data class AuthEndpoints(
    val identityToolkit: String = "https://identitytoolkit.googleapis.com/v1",
    val secureToken: String = "https://securetoken.googleapis.com/v1",
) {
    companion object { val GOOGLE = AuthEndpoints() }
}

class FirebaseRtdbClient(
    private val config: FirebaseConfig,
    private val credential: CloudAuthCredential,
    private val endpoints: AuthEndpoints = AuthEndpoints.GOOGLE,
    /** Debug/test only: lets `http://` loopback databases through. Production refuses anything but https. */
    private val allowInsecureDatabase: Boolean = false,
    private val clock: () -> Long = System::currentTimeMillis,
) : Rtdb {

    private class Tokens(val idToken: String, val refreshToken: String, val expiresAtMs: Long, val uid: String)

    private val base: String = normalizedDatabaseUrl(config.databaseURL, allowInsecureDatabase)
        ?: throw RtdbException(RtdbException.Kind.CONFIGURE_FAILED, "The Realtime Database URL must be a valid https:// address.")

    @Volatile private var tokens: Tokens? = null
    private val tokenLock = Any()

    override val uid: String get() = tokens?.uid ?: throw RtdbException(RtdbException.Kind.NOT_CONFIGURED, "Not signed in.")

    /** Sign in with the stored credential. Safe to call again; replaces the session. */
    fun signIn(): String = synchronized(tokenLock) {
        val t = requestTokens(); tokens = t; t.uid
    }

    // ── Data ──────────────────────────────────────────────────────────────────────────────────

    override fun get(path: String): JsonElement? = decode(send("GET", path, null))

    override fun put(path: String, value: JsonElement) { send("PUT", path, value.toString()) }

    // Written as one PUT per child rather than an HTTP PATCH: `HttpURLConnection` has no PATCH verb and a
    // method-override header would be an untested assumption about the server. Not atomic, which is fine —
    // every caller's children are independent fields.
    override fun patch(path: String, value: JsonObject) { for ((k, v) in value) put("$path/$k", v) }

    override fun delete(path: String) { send("DELETE", path, null) }

    override fun shallowKeys(path: String): Set<String> {
        val v = decode(send("GET", path, null, query = "shallow=true")) ?: return emptySet()
        return (v as? JsonObject)?.keys ?: emptySet()
    }

    // ── Test connection / exposure ────────────────────────────────────────────────────────────

    /** Sign in, then write and read back `meta/{uid}/_haloTest`. Throws a descriptive [RtdbException]. */
    fun testConnection() {
        val id = signIn()
        val path = "meta/$id/_haloTest"
        val token = java.util.UUID.randomUUID().toString()
        put(path, JsonPrimitive(token))
        val back = get(path)
        if ((back as? JsonPrimitive)?.contentOrNull != token) {
            throw RtdbException(RtdbException.Kind.OPERATION_FAILED, "Round-trip mismatch — check your database rules allow the signed-in account to read/write meta/\$uid.")
        }
        runCatching { delete(path) }
    }

    enum class PublicAccess { LOCKED, OPEN, UNKNOWN }

    /** An unauthenticated, keys-only read: 200 means the database is open to the internet. Sends no credentials. */
    fun checkPublicAccess(): PublicAccess = try {
        val conn = URL("$base/.json?shallow=true").openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000; conn.readTimeout = 10_000
        when (conn.responseCode) { 200 -> PublicAccess.OPEN; 401, 403 -> PublicAccess.LOCKED; else -> PublicAccess.UNKNOWN }
    } catch (e: Exception) { PublicAccess.UNKNOWN }

    // ── Live observation ──────────────────────────────────────────────────────────────────────

    override fun observeChildAdded(path: String, onChild: (String, JsonElement?) -> Unit): AutoCloseable {
        val handle = StreamHandle()
        val thread = Thread({ runStream(path, onChild, handle) }, "halo-rtdb-stream").apply { isDaemon = true; start() }
        return AutoCloseable { handle.close(); thread.interrupt() }
    }

    /**
     * H-15: close() raced the reader. The old code kept `stop` and the live connection in two unsynchronised places,
     * so a close() landing between "connection opened" and "connection published" saw no connection to disconnect;
     * the reader then sat in a blocking read (up to the 120 s read timeout) on a stream nobody wanted, and could
     * deliver a child after close() returned. [attach] and [close] now take one lock, so whichever comes second sees
     * the other: attach-after-close disconnects at once and reports false.
     */
    internal class StreamHandle {
        private val lock = Any()
        @Volatile var stopped = false; private set
        private var active: HttpURLConnection? = null
        /** @return false when already closed — the caller must not use [conn]. */
        fun attach(conn: HttpURLConnection): Boolean = synchronized(lock) {
            if (stopped) { conn.disconnect(); false } else { active = conn; true }
        }
        fun detach(conn: HttpURLConnection) = synchronized(lock) { if (active === conn) active = null }
        fun close() { val c = synchronized(lock) { stopped = true; active.also { active = null } }; c?.disconnect() }
    }

    private fun runStream(path: String, onChild: (String, JsonElement?) -> Unit, handle: StreamHandle) {
        val delivered = HashSet<String>()
        var backoffMs = 1_000L
        while (!handle.stopped) {
            var conn: HttpURLConnection? = null
            try {
                conn = open("GET", path, null, null).also { it.setRequestProperty("Accept", "text/event-stream"); it.readTimeout = 120_000 }
                if (!handle.attach(conn)) return
                val status = conn.responseCode
                if (status != 200) {
                    if (status == 401 || status == 403) invalidate()
                    throw RtdbException(RtdbException.Kind.OPERATION_FAILED, "Live connection refused (HTTP $status).", status)
                }
                backoffMs = 1_000
                val model = LinkedHashMap<String, Any?>()
                var event = ""
                BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                    while (!handle.stopped) {
                        val line = reader.readLine() ?: break
                        if (handle.stopped) return
                        if (line.startsWith("event:")) event = line.substring(6).trim()
                        else if (line.startsWith("data:")) {
                            when (StreamModel.apply(event, line.substring(5).trim(), model)) {
                                StreamModel.Outcome.CHANGED -> {
                                    for (key in model.keys.sorted()) if (key !in delivered) { delivered.add(key); onChild(key, StreamModel.toJson(model[key])) }
                                    delivered.retainAll(model.keys)    // a removed child that comes back must fire again
                                }
                                StreamModel.Outcome.REAUTH -> { invalidate(); throw RtdbException(RtdbException.Kind.AUTH_FAILED, "Session expired — reconnecting.") }
                                StreamModel.Outcome.CANCELLED -> throw RtdbException(RtdbException.Kind.OPERATION_FAILED, "The server cancelled the stream (check database rules).")
                                StreamModel.Outcome.UNCHANGED -> {}
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                if (handle.stopped) return
            } finally { conn?.let { handle.detach(it); it.disconnect() } }
            if (handle.stopped) return
            try { Thread.sleep(backoffMs) } catch (e: InterruptedException) { return }
            backoffMs = minOf(backoffMs * 2, 30_000)
        }
    }

    // ── Requests ──────────────────────────────────────────────────────────────────────────────

    private fun send(method: String, path: String, body: String?, query: String? = null): String {
        var attempt = 0
        while (true) {
            val conn = open(method, path, body, query)
            try {
                val status = try { conn.responseCode } catch (e: IOException) { throw RtdbException(RtdbException.Kind.NETWORK, "Network error: ${e.message}") }
                val text = (if (status in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
                if (status == 401 && attempt == 0) { attempt++; invalidate(); continue }   // the token raced its expiry
                if (status !in 200..299) throw RtdbException(RtdbException.Kind.OPERATION_FAILED, messageForStatus(status, text), status)
                return text
            } finally { conn.disconnect() }
        }
    }

    private fun open(method: String, path: String, body: String?, query: String?): HttpURLConnection {
        val token = validIdToken()
        val q = buildString { append("auth=").append(URLEncoder.encode(token, "UTF-8")); if (query != null) append('&').append(query) }
        val conn = URL("$base/${requestPath(path)}?$q").openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 15_000; conn.readTimeout = 30_000
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        return conn
    }

    // ── Tokens ────────────────────────────────────────────────────────────────────────────────

    private fun validIdToken(): String = synchronized(tokenLock) {
        val t = tokens ?: throw RtdbException(RtdbException.Kind.NOT_CONFIGURED, "Not signed in.")
        if (t.expiresAtMs - clock() > REFRESH_SKEW_MS) return t.idToken
        val fresh = try { refreshTokens(t.refreshToken) } catch (e: RtdbException) { requestTokens() }
        tokens = fresh
        fresh.idToken
    }

    private fun invalidate() = synchronized(tokenLock) {
        tokens = tokens?.let { Tokens(it.idToken, it.refreshToken, 0, it.uid) }
    }

    private fun requestTokens(): Tokens {
        val url = "${endpoints.identityToolkit}/accounts:signInWithPassword?key=${URLEncoder.encode(config.apiKey, "UTF-8")}"
        val payload = JsonObject(mapOf("email" to JsonPrimitive(credential.email), "password" to JsonPrimitive(credential.password), "returnSecureToken" to JsonPrimitive(true)))
        val (status, text) = post(url, "application/json", payload.toString())
        val json = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: throw RtdbException(RtdbException.Kind.AUTH_FAILED, "Unexpected sign-in response.")
        if (status != 200) throw RtdbException(RtdbException.Kind.AUTH_FAILED, authMessage(json))
        val id = json["idToken"]?.jsonPrimitive?.contentOrNull
        val refresh = json["refreshToken"]?.jsonPrimitive?.contentOrNull
        val uid = json["localId"]?.jsonPrimitive?.contentOrNull
        if (id == null || refresh == null || uid == null) throw RtdbException(RtdbException.Kind.AUTH_FAILED, "Sign-in response was missing a token.")
        val seconds = json["expiresIn"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull() ?: 3600.0
        return Tokens(id, refresh, clock() + (seconds * 1000).toLong(), uid)
    }

    private fun refreshTokens(refreshToken: String): Tokens {
        val url = "${endpoints.secureToken}/token?key=${URLEncoder.encode(config.apiKey, "UTF-8")}"
        val (status, text) = post(url, "application/x-www-form-urlencoded", "grant_type=refresh_token&refresh_token=${URLEncoder.encode(refreshToken, "UTF-8")}")
        val json = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()
        val id = json?.get("id_token")?.jsonPrimitive?.contentOrNull
        val refresh = json?.get("refresh_token")?.jsonPrimitive?.contentOrNull
        val uid = json?.get("user_id")?.jsonPrimitive?.contentOrNull
        if (status != 200 || id == null || refresh == null || uid == null) throw RtdbException(RtdbException.Kind.AUTH_FAILED, "Couldn't renew the session.")
        val seconds = json["expires_in"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull() ?: 3600.0
        return Tokens(id, refresh, clock() + (seconds * 1000).toLong(), uid)
    }

    private fun post(url: String, contentType: String, body: String): Pair<Int, String> {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"; conn.doOutput = true
            conn.connectTimeout = 15_000; conn.readTimeout = 30_000
            conn.setRequestProperty("Content-Type", contentType)
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = conn.responseCode
            val text = (if (status in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            return status to text
        } catch (e: IOException) {
            throw RtdbException(RtdbException.Kind.NETWORK, "Network error: ${e.message}")      // not AUTH_FAILED: the credential was never judged
        } finally { conn.disconnect() }
    }

    companion object {
        private const val REFRESH_SKEW_MS = 120_000L

        /** `https://…` only (tokens ride in the query string), no query/fragment, trailing slash stripped. */
        fun normalizedDatabaseUrl(raw: String, allowInsecure: Boolean = false): String? {
            val t = raw.trim()
            val u = runCatching { java.net.URI(t) }.getOrNull() ?: return null
            val scheme = u.scheme?.lowercase()
            if (scheme != "https" && !(allowInsecure && scheme == "http")) return null
            if (u.host.isNullOrEmpty()) return null
            val port = if (u.port > 0) ":${u.port}" else ""
            return "$scheme://${u.host}$port${u.path.orEmpty().trimEnd('/')}"
        }

        /** Each component percent-encoded on its own so an encoded `/` can never be introduced; empty = the root. */
        fun requestPath(path: String): String {
            val parts = path.split('/').filter { it.isNotEmpty() }.map { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
            return if (parts.isEmpty()) ".json" else parts.joinToString("/") + ".json"
        }

        fun authMessage(json: JsonObject): String {
            val raw = (json["error"] as? JsonObject)?.get("message")?.jsonPrimitive?.contentOrNull ?: ""
            return when (val code = raw.split(' ').firstOrNull().orEmpty()) {
                "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS" -> "Wrong email or password for this Firebase project."
                "USER_DISABLED" -> "That Firebase account has been disabled."
                "TOO_MANY_ATTEMPTS_TRY_LATER" -> "Too many sign-in attempts — wait a few minutes and try again."
                "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED" -> "Email/Password sign-in isn't enabled for this Firebase project (Authentication → Sign-in method)."
                "API_KEY_INVALID", "INVALID_API_KEY" -> "The API key isn't valid for this Firebase project."
                "" -> "Sign-in failed."
                else -> "Sign-in failed ($code)."
            }
        }

        fun messageForStatus(status: Int, body: String): String {
            val detail = runCatching { Json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.contentOrNull }.getOrNull()
            return when (status) {
                401, 403 -> "Permission denied — check your database rules allow this account to read/write its own data."
                404 -> "Database not found — check the Realtime Database URL (it must match your database's region)."
                400 -> "Request rejected${detail?.let { ": $it" } ?: ""}."
                429, 503 -> "The database is rate-limiting or unavailable — try again shortly."
                else -> "Database request failed (HTTP $status)${detail?.let { ": $it" } ?: ""}."
            }
        }

        private fun decode(text: String): JsonElement? {
            if (text.isBlank()) return null
            val v = Json.parseToJsonElement(text)
            return if (v is JsonNull) null else v
        }
    }
}

/** Folds RTDB streaming events (`put`/`patch`) into a local copy of the observed node. */
internal object StreamModel {
    enum class Outcome { CHANGED, UNCHANGED, REAUTH, CANCELLED }

    @Suppress("UNCHECKED_CAST")
    fun apply(event: String, payload: String, model: MutableMap<String, Any?>): Outcome {
        when (event) {
            "keep-alive" -> return Outcome.UNCHANGED
            "cancel" -> return Outcome.CANCELLED
            "auth_revoked" -> return Outcome.REAUTH
            "put", "patch" -> {
                val obj = runCatching { Json.parseToJsonElement(payload).jsonObject }.getOrNull() ?: return Outcome.UNCHANGED
                val path = obj["path"]?.jsonPrimitive?.contentOrNull ?: return Outcome.UNCHANGED
                val parts = path.split('/').filter { it.isNotEmpty() }
                val data = obj["data"]
                if (event == "put") set(model, parts, data)
                else (data as? JsonObject)?.forEach { (k, v) -> set(model, parts + k.split('/').filter { it.isNotEmpty() }, v) }
                return Outcome.CHANGED
            }
            else -> return Outcome.UNCHANGED
        }
    }

    /** Set — or, for null, delete — `value` at `path`. Objects become nested maps; anything else stays a leaf. */
    @Suppress("UNCHECKED_CAST")
    private fun set(model: MutableMap<String, Any?>, path: List<String>, value: JsonElement?) {
        val isNull = value == null || value is JsonNull
        if (path.isEmpty()) {
            model.clear()
            if (value is JsonObject) value.forEach { (k, v) -> model[k] = explode(v) }
            return
        }
        val head = path.first()
        if (path.size == 1) { if (isNull) model.remove(head) else model[head] = explode(value!!); return }
        val child = (model[head] as? MutableMap<String, Any?>) ?: LinkedHashMap()
        set(child, path.drop(1), value)
        if (child.isEmpty()) model.remove(head) else model[head] = child
    }

    private fun explode(v: JsonElement): Any? = if (v is JsonObject) LinkedHashMap<String, Any?>().also { m -> v.forEach { (k, x) -> m[k] = explode(x) } } else v

    @Suppress("UNCHECKED_CAST")
    fun toJson(v: Any?): JsonElement? = when (v) {
        null -> null
        is JsonElement -> v
        is Map<*, *> -> JsonObject((v as Map<String, Any?>).mapValues { toJson(it.value) ?: JsonNull })
        else -> JsonPrimitive(v.toString())
    }

    @Suppress("unused") fun doubleOf(e: JsonElement?): Double? = (e as? JsonPrimitive)?.doubleOrNull
}
