package app.halo.cloud

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * F-057 FR-S1. The engine over a scripted transport (every outcome, including the failure ones) and the live
 * transport over a loopback stand-in. NOT verified against real Firebase — see DatabaseCheck.kt's header.
 */
class DatabaseCheckTest {

    /** An in-memory database with per-root rules and injectable faults. Records every request. */
    private class StubTransport(val uid: String = "uid-1") : DatabaseProbeTransport {
        var signIn: () -> SignInOutcome = { SignInOutcome.Ok(uid) }
        /** Roots whose rules refuse the given operations. */
        val denyWrite = HashSet<String>(); val denyRead = HashSet<String>(); val denyDelete = HashSet<String>()
        var mismatchOnRead = false
        var notFound = false
        var publicStatus = 401
        val publicOpenPaths = HashSet<String>()
        var signedInUid = uid
        var dropOn: String? = null                       // "PUT" / "GET" / "DELETE": throw a network error on that verb
        var dropFromRoot: String? = null
        val store = HashMap<String, String>()
        val log = CopyOnWriteArrayList<String>()

        override fun signIn() = signIn.invoke()
        override fun unauthenticatedStatus(path: String): Int { log.add("ANON $path"); return if (path in publicOpenPaths) 200 else publicStatus }
        override fun request(method: String, path: String, body: String?): ProbeResponse {
            log.add("$method $path")
            val root = path.substringBefore('/')
            if (dropOn == method && (dropFromRoot == null || dropFromRoot == root)) {
                if (method == "PUT") store[path] = body!!          // the request landed, the response didn't
                throw ProbeNetworkException()
            }
            if (notFound) return ProbeResponse(404, """{"error":"Not found"}""")
            return when (method) {
                "PUT" -> if (root in denyWrite) ProbeResponse(401, """{"error":"Permission denied"}""") else { store[path] = body!!; ProbeResponse(200, body) }
                "GET" -> if (root in denyRead) ProbeResponse(401, """{"error":"Permission denied"}""") else ProbeResponse(200, if (mismatchOnRead) "\"other\"" else store[path] ?: "null")
                "DELETE" -> if (root in denyDelete) ProbeResponse(401, """{"error":"Permission denied"}""") else { store.remove(path); ProbeResponse(200, "null") }
                else -> ProbeResponse(400, "")
            }
        }
    }

    private fun check(t: StubTransport, url: String = "https://demo-default-rtdb.firebaseio.com") =
        DatabaseCheck(t, url, nonce = { "n0nce" }).run()

    @Test fun healthyDatabasePassesEveryPath() {
        val t = StubTransport()
        val r = check(t)
        assertEquals(CheckStatus.PASS, r.overall)
        for (k in listOf(CheckKind.META, CheckKind.DEVICES, CheckKind.SMS, CheckKind.CLIPBOARD)) assertEquals("$k", CheckStatus.PASS, r.item(k).status)
        // write, read, delete under each of the four roots the app uses
        for (root in listOf("meta", "devices", "sms", "clipboard")) {
            assertTrue(t.log.any { it.startsWith("PUT $root/uid-1/_haloCheck_") })
            assertTrue(t.log.any { it.startsWith("GET $root/uid-1/_haloCheck_") })
            assertTrue(t.log.any { it.startsWith("DELETE $root/uid-1/_haloCheck_") })
        }
        assertTrue("nothing left behind", t.store.isEmpty())
    }

    /** The real v2.5 defect: rules published for sms/devices/meta but not clipboard. */
    @Test fun everyProbeIsAChildNamedHaloCheckDirectlyUnderRootAndUid() {
        val t = StubTransport()
        DatabaseCheck(t, "https://demo-default-rtdb.firebaseio.com").run()          // real nonces
        val writes = t.log.filter { it.startsWith("PUT ") }.map { it.removePrefix("PUT ") }
        assertEquals(4, writes.size)
        for (w in writes) {
            val parts = w.split('/')
            assertTrue(w, parts.size == 3 && parts[0] in listOf("meta", "devices", "sms", "clipboard") && parts[1] == "uid-1")
            assertTrue(w, DatabaseCheck.isProbeKey(parts[2]) && parts[2].length > DatabaseCheck.PROBE_PREFIX.length + 8)
        }
        assertEquals(4, writes.toSet().size)
        assertTrue(t.store.isEmpty())
    }

    @Test fun anEmptyOrSlashBearingUidProbesNothing() {
        for (bad in listOf("", "a/b")) {
            val t = StubTransport().apply { signIn = { SignInOutcome.Ok(bad) } }
            val r = check(t)
            assertEquals(CheckStatus.FAIL, r.item(CheckKind.SIGN_IN).status)
            assertTrue(t.log.none { it.startsWith("PUT") })
        }
    }

    @Test fun aDropWhileWritingWithADeleteThatAlsoFailsNamesTheEntryThatMayRemain() {
        val t = StubTransport().apply { dropOn = "PUT"; dropFromRoot = "meta"; denyDelete.add("meta") }
        val d = check(t).item(CheckKind.META)
        assertEquals(CheckProblem.NETWORK, d.problem)
        assertTrue(d.detail, d.detail.contains("_haloCheck_n0nce") && d.detail.contains("meta/{uid}"))
    }

    @Test fun rulesThatOpenOnlyOneFolderAreCaughtEvenThoughTheRootIsLocked() {
        val t = StubTransport().apply { publicOpenPaths.add("clipboard") }
        val item = check(t).item(CheckKind.PUBLIC_ACCESS)
        assertEquals(CheckProblem.OPEN_RULES, item.problem)
        assertTrue(item.detail, item.detail.contains("clipboard/") && !item.detail.contains("sms/"))
        for (p in listOf("", "meta", "devices", "sms", "clipboard")) assertTrue(p, t.log.contains("ANON $p"))
    }

    @Test fun anUnreadableFolderStatusDoesNotPassAsRefused() {
        assertEquals(CheckProblem.UNKNOWN_ACCESS, check(StubTransport().apply { publicStatus = 500 }).item(CheckKind.PUBLIC_ACCESS).problem)
    }

    @Test fun identityToolkitProseForABadApiKeyIsRecognised() {
        fun j(s: String) = Json.parseToJsonElement(s).jsonObject
        assertEquals("API_KEY_INVALID", LiveDatabaseProbeTransport.signInErrorCode(j("""{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}""")))
        assertEquals("API_KEY_INVALID", LiveDatabaseProbeTransport.signInErrorCode(j("""{"error":{"message":"Bad request","details":[{"reason":"API_KEY_INVALID"}]}}""")))
        assertEquals("OPERATION_NOT_ALLOWED", LiveDatabaseProbeTransport.signInErrorCode(j("""{"error":{"message":"OPERATION_NOT_ALLOWED"}}""")))
        assertEquals("TOO_MANY_ATTEMPTS_TRY_LATER", LiveDatabaseProbeTransport.signInErrorCode(j("""{"error":{"message":"TOO_MANY_ATTEMPTS_TRY_LATER : slow down"}}""")))
        assertEquals("", LiveDatabaseProbeTransport.signInErrorCode(null))
    }

    @Test fun clipboardDeniedIsReportedOnItsOwnWithTheFix() {
        val t = StubTransport().apply { denyWrite.add("clipboard"); denyRead.add("clipboard") }
        val r = check(t)
        assertEquals(CheckStatus.FAIL, r.overall)
        assertEquals(CheckStatus.PASS, r.item(CheckKind.META).status)
        assertEquals(CheckStatus.PASS, r.item(CheckKind.DEVICES).status)
        assertEquals(CheckStatus.PASS, r.item(CheckKind.SMS).status)
        val clip = r.item(CheckKind.CLIPBOARD)
        assertEquals(CheckStatus.FAIL, clip.status)
        assertEquals(CheckProblem.PERMISSION_DENIED, clip.problem)
        assertTrue(clip.detail, clip.detail.contains("clipboard/{uid}"))
        assertTrue(clip.fix!!.contains("docs/specs/firebase-rules.json"))
        assertTrue(t.store.isEmpty())
    }

    @Test fun aWriteThatWasRefusedIssuesNoDelete() {
        val t = StubTransport().apply { denyWrite.add("meta") }
        check(t)
        assertFalse("a refused write left nothing to clean up", t.log.any { it.startsWith("DELETE meta/") })
    }

    @Test fun writeAllowedButReadDeniedFailsAndTheProbeIsCleanedUp() {
        val t = StubTransport().apply { denyRead.add("sms") }
        val r = check(t)
        assertEquals(CheckProblem.READ_DENIED, r.item(CheckKind.SMS).problem)
        assertTrue("probe must not be left behind", t.store.isEmpty())
    }

    @Test fun readBackMismatchFailsAndTheProbeIsCleanedUp() {
        val t = StubTransport().apply { mismatchOnRead = true }
        val r = check(t)
        assertEquals(CheckProblem.READ_BACK_MISMATCH, r.item(CheckKind.META).problem)
        assertTrue(t.store.isEmpty())
    }

    @Test fun networkDropWhileReadingStillCleansUp() {
        val t = StubTransport().apply { dropOn = "GET"; dropFromRoot = "devices" }
        val r = check(t)
        assertEquals(CheckProblem.NETWORK, r.item(CheckKind.DEVICES).problem)
        assertTrue("DELETE was attempted after the dropped read", t.log.any { it.startsWith("DELETE devices/") })
        assertTrue(t.store.isEmpty())
        // later paths are not hammered once the network is gone
        assertEquals(CheckStatus.SKIPPED, r.item(CheckKind.SMS).status)
        assertEquals(CheckStatus.SKIPPED, r.item(CheckKind.CLIPBOARD).status)
    }

    @Test fun networkDropWhileWritingTriesToCleanUpAProbeThatMayHaveLanded() {
        val t = StubTransport().apply { dropOn = "PUT"; dropFromRoot = "meta" }
        check(t)
        assertTrue(t.log.any { it.startsWith("DELETE meta/") })
        assertTrue("the write that landed but was never acknowledged is removed", t.store.isEmpty())
    }

    @Test fun aProbeThatCannotBeDeletedIsAWarningThatNamesIt() {
        val t = StubTransport().apply { denyDelete.add("clipboard") }
        val r = check(t)
        val clip = r.item(CheckKind.CLIPBOARD)
        assertEquals(CheckStatus.WARN, clip.status)
        assertEquals(CheckProblem.CLEANUP_FAILED, clip.problem)
        assertTrue(clip.detail.contains("_haloCheck_n0nce"))
        assertEquals(CheckStatus.WARN, r.overall)
    }

    @Test fun wrongRegionOrUrlIs404AndTheRestIsSkipped() {
        val t = StubTransport().apply { notFound = true }
        val r = check(t)
        val url = r.item(CheckKind.DATABASE_URL)
        assertEquals(CheckProblem.DATABASE_NOT_FOUND, url.problem)
        assertTrue(url.fix!!.contains("firebasedatabase.app"))
        assertEquals(CheckStatus.SKIPPED, r.item(CheckKind.CLIPBOARD).status)
        assertEquals(CheckStatus.SKIPPED, r.item(CheckKind.PUBLIC_ACCESS).status)
        assertEquals(1, t.log.count { it.startsWith("PUT") })
    }

    @Test fun emailPasswordDisabledIsNamedAndNoPathIsTried() {
        val t = StubTransport().apply { signIn = { SignInOutcome.Rejected("OPERATION_NOT_ALLOWED") }; publicStatus = 200 }
        val r = check(t)
        val s = r.item(CheckKind.SIGN_IN)
        assertEquals(CheckProblem.EMAIL_PASSWORD_DISABLED, s.problem)
        assertTrue(s.fix!!.contains("Sign-in method"))
        assertEquals(CheckStatus.SKIPPED, r.item(CheckKind.META).status)
        assertTrue("no authenticated database traffic without a session", t.log.all { it.startsWith("ANON") })
        assertEquals("open rules are still detected without signing in", CheckProblem.OPEN_RULES, r.item(CheckKind.PUBLIC_ACCESS).problem)
    }

    @Test fun otherSignInRefusals() {
        fun problem(code: String) = check(StubTransport().apply { signIn = { SignInOutcome.Rejected(code) } }).item(CheckKind.SIGN_IN).problem
        assertEquals(CheckProblem.BAD_CREDENTIALS, problem("INVALID_LOGIN_CREDENTIALS"))
        assertEquals(CheckProblem.BAD_API_KEY, problem("API_KEY_INVALID"))
        assertEquals(CheckProblem.ACCOUNT_DISABLED, problem("USER_DISABLED"))
        assertEquals(CheckProblem.UNEXPECTED, problem("SOMETHING_NEW"))
    }

    @Test fun signInNetworkFailureIsNetworkNotCredentials() {
        val r = check(StubTransport().apply { signIn = { throw ProbeNetworkException() } })
        assertEquals(CheckProblem.NETWORK, r.item(CheckKind.SIGN_IN).problem)
    }

    @Test fun openRulesAreAWarning() {
        val r = check(StubTransport().apply { publicStatus = 200 })
        assertEquals(CheckProblem.OPEN_RULES, r.item(CheckKind.PUBLIC_ACCESS).problem)
        assertEquals(CheckStatus.WARN, r.overall)
        assertTrue(r.item(CheckKind.PUBLIC_ACCESS).fix!!.contains("firebase-rules.json"))
    }

    @Test fun malformedUrlStopsEarly() {
        val t = StubTransport()
        val r = DatabaseCheck(t, "http://insecure.example.com", nonce = { "x" }).run()
        assertEquals(CheckProblem.INVALID_URL, r.item(CheckKind.DATABASE_URL).problem)
        assertTrue(t.log.isEmpty())
    }

    @Test fun reportNeverContainsSecrets() {
        val t = StubTransport().apply { denyWrite.add("clipboard"); publicStatus = 200 }
        val r = DatabaseCheck(t, "https://demo-default-rtdb.firebaseio.com", nonce = { "n0nce" }).run()
        val text = r.toString() + r.items.joinToString { it.title + it.detail + it.fix }
        for (secret in listOf("hunter2-pass", "API-KEY-SECRET", "ID-TOKEN-SECRET", "me@x.io", "passphrase")) assertFalse(secret, text.contains(secret, ignoreCase = true))
        // and the uid appears only as a template, never a concrete value
        assertFalse(text.contains("uid-1"))
    }

    // ── The real transport, against a loopback stand-in with rules that forget clipboard ──────────

    private val servers = ArrayList<HttpServer>()
    @After fun stop() { servers.forEach { it.stop(0) } }

    private class Seen { val db = CopyOnWriteArrayList<String>(); val idtBodies = CopyOnWriteArrayList<String>(); val unauth = CopyOnWriteArrayList<String>() }

    private fun loopback(seen: Seen, allowClipboard: Boolean, emailPasswordEnabled: Boolean = true): Pair<FirebaseConfig, AuthEndpoints> {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).also { servers.add(it); it.executor = Executors.newCachedThreadPool() }
        val data = HashMap<String, String>()
        fun reply(ex: HttpExchange, status: Int, body: String) { val b = body.toByteArray(); ex.sendResponseHeaders(status, b.size.toLong()); ex.responseBody.use { it.write(b) } }
        server.createContext("/idt") { ex ->
            seen.idtBodies.add(ex.requestBody.readBytes().decodeToString())
            if (!emailPasswordEnabled) reply(ex, 400, """{"error":{"message":"OPERATION_NOT_ALLOWED"}}""")
            else reply(ex, 200, """{"idToken":"ID-TOKEN-SECRET","refreshToken":"r","localId":"uid-9","expiresIn":"3600"}""")
        }
        server.createContext("/db") { ex ->
            val q = ex.requestURI.rawQuery.orEmpty().split('&').filter { it.contains('=') }.associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
            val path = URLDecoder.decode(ex.requestURI.rawPath.removePrefix("/db").removePrefix("/").removeSuffix(".json"), "UTF-8")
            if (q["auth"] == null) { seen.unauth.add(ex.requestURI.toString()); return@createContext reply(ex, 401, """{"error":"Permission denied"}""") }
            seen.db.add("${ex.requestMethod} ${ex.requestURI.rawPath}")
            if (q["auth"] != "ID-TOKEN-SECRET") return@createContext reply(ex, 401, "{}")
            if (path.startsWith("clipboard/") && !allowClipboard) return@createContext reply(ex, 401, """{"error":"Permission denied"}""")
            when (ex.requestMethod) {
                "PUT" -> { data[path] = ex.requestBody.readBytes().decodeToString(); reply(ex, 200, data[path]!!) }
                "GET" -> reply(ex, 200, data[path] ?: "null")
                "DELETE" -> { data.remove(path); reply(ex, 200, "null") }
                else -> reply(ex, 405, "")
            }
        }
        server.start()
        val port = server.address.port
        return FirebaseConfig("API-KEY-SECRET", "proj", "1:2:android:3", "2", "http://127.0.0.1:$port/db") to AuthEndpoints("http://127.0.0.1:$port/idt", "http://127.0.0.1:$port/sec")
    }

    @Test fun liveTransportFindsTheClipboardRuleGapOverRealHttp() {
        val seen = Seen()
        val (cfg, ep) = loopback(seen, allowClipboard = false)
        val transport = LiveDatabaseProbeTransport(cfg, CloudAuthCredential("me@x.io", "hunter2-pass"), ep, allowInsecureDatabase = true)
        val r = DatabaseCheck(transport, cfg.databaseURL, allowInsecureDatabase = true).run()
        assertEquals(CheckStatus.PASS, r.item(CheckKind.META).status)
        assertEquals(CheckStatus.PASS, r.item(CheckKind.SMS).status)
        assertEquals(CheckProblem.PERMISSION_DENIED, r.item(CheckKind.CLIPBOARD).problem)
        assertEquals("public check is unauthenticated and was refused", CheckStatus.PASS, r.item(CheckKind.PUBLIC_ACCESS).status)
        assertEquals("root + the four folders", 5, seen.unauth.size)
        assertTrue("the unauthenticated probes carry no credentials", seen.unauth.all { it.contains("shallow=true") && !it.contains("auth=") })
        // the password went to the auth endpoint and only there
        assertTrue(seen.idtBodies.single().contains("hunter2-pass"))
        assertFalse(seen.db.any { it.contains("hunter2") })
        assertNotNull(r.items)
    }

    @Test fun liveTransportReportsDisabledEmailPassword() {
        val seen = Seen()
        val (cfg, ep) = loopback(seen, allowClipboard = true, emailPasswordEnabled = false)
        val r = DatabaseCheck(LiveDatabaseProbeTransport(cfg, CloudAuthCredential("me@x.io", "hunter2-pass"), ep, true), cfg.databaseURL, true).run()
        assertEquals(CheckProblem.EMAIL_PASSWORD_DISABLED, r.item(CheckKind.SIGN_IN).problem)
        assertTrue(seen.db.isEmpty())
    }

    @Test fun liveTransportOnADeadPortIsANetworkErrorWithNoTokenInTheText() {
        val (cfg, ep) = loopback(Seen(), allowClipboard = true)
        servers.forEach { it.stop(0) }
        val r = DatabaseCheck(LiveDatabaseProbeTransport(cfg, CloudAuthCredential("me@x.io", "hunter2-pass"), ep, true), cfg.databaseURL, true).run()
        assertEquals(CheckProblem.NETWORK, r.item(CheckKind.SIGN_IN).problem)
        assertFalse(r.toString().contains("hunter2-pass"))
    }
}
