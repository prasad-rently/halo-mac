package app.halo.cloud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

// F-057 FR-S1 — "Check my database".
//
// The v2.5 defect this exists for: a user published rules that covered `sms`, `devices` and `meta` but not
// `clipboard`. "Test connection" (which only touches meta/{uid}) said everything was fine, and then clipboard
// sync failed with a bare "permission denied" long after setup. This engine writes, reads back and deletes a
// probe under EACH path the app uses and says which one is refused, with the concrete fix.
//
// Shape: a pure engine ([DatabaseCheck]) over a narrow seam ([DatabaseProbeTransport]) so every outcome —
// including the failure ones — is exercised by stubbed-network tests. [LiveDatabaseProbeTransport] is the one
// real implementation (HttpURLConnection; same wire contract as FirebaseRtdbClient).
//
// What this file never does: log, or put into a report, a token, the password, the API key or any
// passphrase. Report text is built from fixed strings and path *templates* ("meta/{uid}"), never from an
// exception message — HttpURLConnection messages can carry the request URL, and the URL carries `?auth=<token>`.
//
// NOT verified against real Firebase: the status codes below (401/403 = denied, 404 = wrong URL or region)
// are what the REST documentation says; they are exercised here only against stubs and a loopback server.

enum class CheckKind { DATABASE_URL, SIGN_IN, META, DEVICES, SMS, CLIPBOARD, PUBLIC_ACCESS }
enum class CheckStatus { PASS, WARN, FAIL, SKIPPED }
enum class CheckProblem {
    NONE, INVALID_URL, DATABASE_NOT_FOUND, EMAIL_PASSWORD_DISABLED, BAD_CREDENTIALS, BAD_API_KEY, ACCOUNT_DISABLED,
    RATE_LIMITED, NETWORK, PERMISSION_DENIED, READ_DENIED, READ_BACK_MISMATCH, CLEANUP_FAILED, OPEN_RULES, UNKNOWN_ACCESS, UNEXPECTED, NOT_RUN,
}

/** One line of the report. [fix] is the concrete next step, null when there is nothing to do. */
data class CheckItem(val kind: CheckKind, val status: CheckStatus, val problem: CheckProblem, val title: String, val detail: String, val fix: String? = null)

data class DatabaseCheckReport(val items: List<CheckItem>) {
    val overall: CheckStatus get() = when {
        items.any { it.status == CheckStatus.FAIL } -> CheckStatus.FAIL
        items.any { it.status == CheckStatus.WARN } -> CheckStatus.WARN
        else -> CheckStatus.PASS
    }
    fun item(kind: CheckKind): CheckItem = items.first { it.kind == kind }
}

sealed interface SignInOutcome {
    data class Ok(val uid: String) : SignInOutcome
    /** Identity Toolkit refused; [code] is Firebase's own error code ("OPERATION_NOT_ALLOWED", …), nothing else. */
    data class Rejected(val code: String) : SignInOutcome
}

data class ProbeResponse(val status: Int, val body: String)

/** The network could not be reached at all. Deliberately carries no cause text (see file header). */
class ProbeNetworkException(message: String = "Couldn't reach the network.") : IOException(message)

/** What the engine needs from the network. [path] is relative to the database root, e.g. "meta/<uid>/_haloCheck_ab12". */
interface DatabaseProbeTransport {
    fun signIn(): SignInOutcome
    fun request(method: String, path: String, body: String?): ProbeResponse
    /** HTTP status of an UNAUTHENTICATED shallow read of the root. No credentials are sent. */
    fun unauthenticatedStatus(): Int
}

object DatabaseCheckText {
    const val RULES_FIX = "Publish the owner-only rules from docs/specs/firebase-rules.json (Firebase console → Realtime Database → Rules → Publish)."
    const val URL_FIX = "Copy the database URL from Firebase console → Realtime Database (top of the Data tab). A database outside the US uses https://<name>.<region>.firebasedatabase.app, not …firebaseio.com."
    const val AUTH_FIX = "Firebase console → Authentication → Sign-in method → enable Email/Password."
}

class DatabaseCheck(
    private val transport: DatabaseProbeTransport,
    private val databaseUrl: String,
    private val allowInsecureDatabase: Boolean = false,
    private val nonce: () -> String = { UUID.randomUUID().toString().replace("-", "").take(12) },
) {
    /** Every top-level path the apps use, in the order they are checked. */
    private val paths = listOf(CheckKind.META to "meta", CheckKind.DEVICES to "devices", CheckKind.SMS to "sms", CheckKind.CLIPBOARD to "clipboard")

    fun run(): DatabaseCheckReport {
        val out = LinkedHashMap<CheckKind, CheckItem>()
        fun skipped(kind: CheckKind, why: String) = CheckItem(kind, CheckStatus.SKIPPED, CheckProblem.NOT_RUN, titleOf(kind), why)
        fun skipRest(from: CheckKind, why: String) { for (k in CheckKind.values()) if (k !in out && k.ordinal >= from.ordinal) out[k] = skipped(k, why) }

        // 1. The address itself.
        if (FirebaseRtdbClient.normalizedDatabaseUrl(databaseUrl, allowInsecureDatabase) == null) {
            out[CheckKind.DATABASE_URL] = CheckItem(CheckKind.DATABASE_URL, CheckStatus.FAIL, CheckProblem.INVALID_URL, "Database address", "The database URL isn't a valid https:// address.", DatabaseCheckText.URL_FIX)
            skipRest(CheckKind.SIGN_IN, "Needs a valid database address.")
            return DatabaseCheckReport(out.values.toList())
        }
        out[CheckKind.DATABASE_URL] = CheckItem(CheckKind.DATABASE_URL, CheckStatus.PASS, CheckProblem.NONE, titleOf(CheckKind.DATABASE_URL), "The address is well-formed.")

        // 2. Sign-in (also the Email/Password-disabled and bad-key checks).
        val uid: String? = try {
            when (val s = transport.signIn()) {
                is SignInOutcome.Ok -> { out[CheckKind.SIGN_IN] = CheckItem(CheckKind.SIGN_IN, CheckStatus.PASS, CheckProblem.NONE, titleOf(CheckKind.SIGN_IN), "Signed in."); s.uid }
                is SignInOutcome.Rejected -> { out[CheckKind.SIGN_IN] = signInFailure(s.code); null }
            }
        } catch (e: ProbeNetworkException) {
            out[CheckKind.SIGN_IN] = CheckItem(CheckKind.SIGN_IN, CheckStatus.FAIL, CheckProblem.NETWORK, titleOf(CheckKind.SIGN_IN), "Couldn't reach Google to sign in.", "Check this device's internet connection and try again.")
            null
        }

        // 3. A probe under each path.
        var urlWrong = false
        var offline = uid == null && out.getValue(CheckKind.SIGN_IN).problem == CheckProblem.NETWORK
        for ((kind, root) in paths) {
            when {
                uid == null -> out[kind] = skipped(kind, "Needs a successful sign-in.")
                urlWrong -> out[kind] = skipped(kind, "The database address looks wrong — fix that first.")
                offline -> out[kind] = skipped(kind, "The network went away — try again.")
                else -> {
                    val item = probe(kind, root, uid)
                    out[kind] = item
                    if (item.problem == CheckProblem.DATABASE_NOT_FOUND) {
                        urlWrong = true
                        out[CheckKind.DATABASE_URL] = item.copy(kind = CheckKind.DATABASE_URL, title = titleOf(CheckKind.DATABASE_URL))
                        out[kind] = skipped(kind, "The database address looks wrong — see above.")
                    }
                    if (item.problem == CheckProblem.NETWORK) offline = true
                }
            }
        }

        // 4. Is the database open to the whole internet? Independent of sign-in.
        out[CheckKind.PUBLIC_ACCESS] = if (urlWrong || offline) skipped(CheckKind.PUBLIC_ACCESS, "Skipped.") else publicAccess()
        return DatabaseCheckReport(CheckKind.values().map { out.getValue(it) })
    }

    private fun probe(kind: CheckKind, root: String, uid: String): CheckItem {
        val template = "$root/{uid}"
        val name = "_haloCheck_${nonce()}"
        val path = "$root/$uid/$name"
        val token = nonce() + nonce()
        val fail = { p: CheckProblem, detail: String, fix: String? -> CheckItem(kind, CheckStatus.FAIL, p, titleOf(kind), detail, fix) }

        // WRITE. Only a write that may have landed needs cleaning up: a refused one left nothing behind.
        val put = try { transport.request("PUT", path, JsonPrimitive(token).toString()) } catch (e: ProbeNetworkException) {
            cleanUp(path)                         // the request may have reached the server before the connection dropped
            return fail(CheckProblem.NETWORK, "The connection dropped while writing to $template.", "Check the internet connection and run the check again.")
        }
        if (put.status !in 200..299) return refused(kind, template, put.status, "write")

        // READ BACK. From here on the probe exists, so every exit path removes it.
        val read = try { transport.request("GET", path, null) } catch (e: ProbeNetworkException) {
            cleanUp(path)
            return fail(CheckProblem.NETWORK, "The connection dropped while reading from $template.", "Check the internet connection and run the check again.")
        }
        if (read.status !in 200..299) {
            val cleaned = cleanUp(path)
            return if (read.status == 401 || read.status == 403)
                fail(CheckProblem.READ_DENIED, "Writing to $template works but reading it back is refused.${leftover(cleaned, template, name)}", DatabaseCheckText.RULES_FIX)
            else fail(CheckProblem.UNEXPECTED, "Reading back from $template failed (HTTP ${read.status}).${leftover(cleaned, template, name)}", null)
        }
        val matches = runCatching { Json.parseToJsonElement(read.body).jsonPrimitive.contentOrNull == token }.getOrDefault(false)
        if (!matches) {
            val cleaned = cleanUp(path)
            return fail(CheckProblem.READ_BACK_MISMATCH, "What was read back from $template wasn't what was written.${leftover(cleaned, template, name)}", DatabaseCheckText.RULES_FIX)
        }

        // DELETE. Writing was allowed and reading was allowed; if the probe can't be removed, say where it is.
        return if (cleanUp(path)) CheckItem(kind, CheckStatus.PASS, CheckProblem.NONE, titleOf(kind), "Write, read and delete all work under $template.")
        else CheckItem(kind, CheckStatus.WARN, CheckProblem.CLEANUP_FAILED, titleOf(kind),
            "Read and write work under $template, but the test entry \"$name\" couldn't be deleted.", "Delete \"$name\" under $template in the Firebase console (Realtime Database → Data), and check your rules allow deleting.")
    }

    private fun refused(kind: CheckKind, template: String, status: Int, what: String): CheckItem = when (status) {
        401, 403 -> CheckItem(kind, CheckStatus.FAIL, CheckProblem.PERMISSION_DENIED, titleOf(kind), "Your database rules refuse to $what under $template.", DatabaseCheckText.RULES_FIX)
        404 -> CheckItem(kind, CheckStatus.FAIL, CheckProblem.DATABASE_NOT_FOUND, titleOf(kind), "There is no database at this address.", DatabaseCheckText.URL_FIX)
        429, 503 -> CheckItem(kind, CheckStatus.FAIL, CheckProblem.RATE_LIMITED, titleOf(kind), "The database is rate-limiting or unavailable.", "Wait a minute and run the check again.")
        else -> CheckItem(kind, CheckStatus.FAIL, CheckProblem.UNEXPECTED, titleOf(kind), "The database answered the $what to $template with HTTP $status.", null)
    }

    private fun leftover(cleaned: Boolean, template: String, name: String) = if (cleaned) "" else " The test entry \"$name\" under $template couldn't be removed — delete it in the Firebase console."

    /** One best-effort delete. True only when the server confirmed it. */
    private fun cleanUp(path: String): Boolean = try { transport.request("DELETE", path, null).status in 200..299 } catch (e: ProbeNetworkException) { false }

    private fun publicAccess(): CheckItem {
        val status = try { transport.unauthenticatedStatus() } catch (e: ProbeNetworkException) { -1 }
        return when (status) {
            200 -> CheckItem(CheckKind.PUBLIC_ACCESS, CheckStatus.WARN, CheckProblem.OPEN_RULES, titleOf(CheckKind.PUBLIC_ACCESS),
                "Your database answers anyone on the internet without signing in (test-mode rules). Message text stays encrypted, but device names, labels and timestamps are readable, and a stranger could write to it.", DatabaseCheckText.RULES_FIX)
            401, 403 -> CheckItem(CheckKind.PUBLIC_ACCESS, CheckStatus.PASS, CheckProblem.NONE, titleOf(CheckKind.PUBLIC_ACCESS), "Anonymous access is refused.")
            else -> CheckItem(CheckKind.PUBLIC_ACCESS, CheckStatus.WARN, CheckProblem.UNKNOWN_ACCESS, titleOf(CheckKind.PUBLIC_ACCESS), "Couldn't tell whether the database is open to the public.", null)
        }
    }

    private fun signInFailure(code: String): CheckItem {
        fun f(p: CheckProblem, d: String, fix: String?) = CheckItem(CheckKind.SIGN_IN, CheckStatus.FAIL, p, titleOf(CheckKind.SIGN_IN), d, fix)
        return when (code) {
            "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED" -> f(CheckProblem.EMAIL_PASSWORD_DISABLED, "Email/Password sign-in is turned off for this Firebase project.", DatabaseCheckText.AUTH_FIX)
            "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS" -> f(CheckProblem.BAD_CREDENTIALS, "The email or password doesn't match a user in this Firebase project.", "Firebase console → Authentication → Users: check the user exists, or pair again from your Mac.")
            "API_KEY_INVALID", "INVALID_API_KEY" -> f(CheckProblem.BAD_API_KEY, "The API key isn't valid for this Firebase project.", "Pair again from your Mac, or copy the Web API key from Firebase console → Project settings.")
            "USER_DISABLED" -> f(CheckProblem.ACCOUNT_DISABLED, "That Firebase user has been disabled.", "Firebase console → Authentication → Users → enable the user.")
            "TOO_MANY_ATTEMPTS_TRY_LATER" -> f(CheckProblem.RATE_LIMITED, "Too many sign-in attempts.", "Wait a few minutes and run the check again.")
            else -> f(CheckProblem.UNEXPECTED, "Sign-in was refused.", null)       // the code is deliberately not echoed
        }
    }

    companion object {
        fun titleOf(kind: CheckKind) = when (kind) {
            CheckKind.DATABASE_URL -> "Database address"
            CheckKind.SIGN_IN -> "Sign-in"
            CheckKind.META -> "Settings (meta)"
            CheckKind.DEVICES -> "Devices"
            CheckKind.SMS -> "SMS"
            CheckKind.CLIPBOARD -> "Clipboard"
            CheckKind.PUBLIC_ACCESS -> "Open to the public?"
        }
    }
}

/** The real network. Same wire contract as [FirebaseRtdbClient]; one token, no refresh (a check is seconds long). */
class LiveDatabaseProbeTransport(
    private val config: FirebaseConfig,
    private val credential: CloudAuthCredential,
    private val endpoints: AuthEndpoints = AuthEndpoints.GOOGLE,
    private val allowInsecureDatabase: Boolean = false,
) : DatabaseProbeTransport {
    private val base: String? = FirebaseRtdbClient.normalizedDatabaseUrl(config.databaseURL, allowInsecureDatabase)
    @Volatile private var idToken: String? = null

    override fun signIn(): SignInOutcome {
        val url = "${endpoints.identityToolkit}/accounts:signInWithPassword?key=${URLEncoder.encode(config.apiKey, "UTF-8")}"
        val payload = kotlinx.serialization.json.JsonObject(mapOf("email" to JsonPrimitive(credential.email), "password" to JsonPrimitive(credential.password), "returnSecureToken" to JsonPrimitive(true)))
        val r = http(url, "POST", payload.toString())
        val json = runCatching { Json.parseToJsonElement(r.body).jsonObject }.getOrNull()
        if (r.status == 200) {
            val token = json?.get("idToken")?.jsonPrimitive?.contentOrNull
            val uid = json?.get("localId")?.jsonPrimitive?.contentOrNull
            if (token != null && uid != null) { idToken = token; return SignInOutcome.Ok(uid) }
            return SignInOutcome.Rejected("MALFORMED_RESPONSE")
        }
        val raw = (json?.get("error") as? kotlinx.serialization.json.JsonObject)?.get("message")?.jsonPrimitive?.contentOrNull.orEmpty()
        return SignInOutcome.Rejected(raw.split(' ').firstOrNull().orEmpty())
    }

    override fun request(method: String, path: String, body: String?): ProbeResponse {
        val b = base ?: throw ProbeNetworkException("The database address is invalid.")
        val token = idToken ?: throw ProbeNetworkException("Not signed in.")
        return http("$b/${FirebaseRtdbClient.requestPath(path)}?auth=${URLEncoder.encode(token, "UTF-8")}", method, body)
    }

    override fun unauthenticatedStatus(): Int {
        val b = base ?: return -1
        return http("$b/.json?shallow=true", "GET", null).status
    }

    private fun http(url: String, method: String, body: String?): ProbeResponse {
        val conn = try { URL(url).openConnection() as HttpURLConnection } catch (e: Exception) { throw ProbeNetworkException() }
        try {
            conn.requestMethod = method
            conn.connectTimeout = 10_000; conn.readTimeout = 15_000
            if (body != null) { conn.doOutput = true; conn.setRequestProperty("Content-Type", "application/json"); conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) } }
            val status = conn.responseCode
            val text = (if (status in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            return ProbeResponse(status, text)
        } catch (e: IOException) {
            throw ProbeNetworkException()          // never e.message: it can contain the URL, and the URL contains the token
        } finally { conn.disconnect() }
    }
}
