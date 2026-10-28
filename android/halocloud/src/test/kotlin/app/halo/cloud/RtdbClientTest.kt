package app.halo.cloud

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The real HTTP client against a loopback stand-in for Google's two auth endpoints and the RTDB REST
 * surface — including the SSE stream. Proves the wire behaviour (tokens, refresh, retry, streaming)
 * without a Firebase project; the live round-trip is a separate, manual check.
 */
class RtdbClientTest {

    private lateinit var server: HttpServer
    private val backing = FakeRtdb("uid-9")
    private var expiresIn = "3600"
    private val signIns = AtomicInteger(); private val refreshes = AtomicInteger()
    private val rejectNextData = AtomicInteger()
    private val seenOnDb = CopyOnWriteArrayList<String>()
    private var openToPublic = false
    private var now = 1_000_000L
    private var tokenSerial = 0
    @Volatile private var validToken = ""

    private val config get() = FirebaseConfig("API-KEY", "proj", "1:2:android:3", "2", "http://127.0.0.1:${server.address.port}/db")
    private val endpoints get() = AuthEndpoints("http://127.0.0.1:${server.address.port}/idt", "http://127.0.0.1:${server.address.port}/sec")
    private fun client() = FirebaseRtdbClient(config, CloudAuthCredential("me@x.io", "hunter2-pass"), endpoints, allowInsecureDatabase = true, clock = { now })

    @Before fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = Executors.newCachedThreadPool()
        server.createContext("/idt") { ex ->
            val body = Json.parseToJsonElement(ex.requestBody.readBytes().decodeToString()).jsonObject
            if (body["password"]?.toString() != "\"hunter2-pass\"") return@createContext reply(ex, 400, """{"error":{"message":"INVALID_LOGIN_CREDENTIALS"}}""")
            signIns.incrementAndGet(); validToken = "id-${++tokenSerial}"
            reply(ex, 200, """{"idToken":"$validToken","refreshToken":"refresh-1","localId":"uid-9","expiresIn":"$expiresIn"}""")
        }
        server.createContext("/sec") { ex ->
            val form = ex.requestBody.readBytes().decodeToString()
            if (!form.contains("refresh_token=refresh-1")) return@createContext reply(ex, 400, "{}")
            refreshes.incrementAndGet(); validToken = "id-${++tokenSerial}"
            reply(ex, 200, """{"id_token":"$validToken","refresh_token":"refresh-1","user_id":"uid-9","expires_in":"3600"}""")
        }
        server.createContext("/db") { ex -> db(ex) }
        server.start()
    }

    @After fun stop() { server.stop(0) }

    private fun reply(ex: HttpExchange, status: Int, body: String) {
        val b = body.toByteArray(); ex.responseHeaders.add("Content-Type", "application/json"); ex.sendResponseHeaders(status, b.size.toLong()); ex.responseBody.use { it.write(b) }
    }

    private fun db(ex: HttpExchange) {
        val query = ex.requestURI.rawQuery.orEmpty().split('&').filter { it.contains('=') }.associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
        // Read the body once, up front: the leak test below must see bodies, not just the URL and headers
        // (a password smuggled into a PUT payload would otherwise pass), and a stream can only be read once.
        val requestBody = ex.requestBody.readBytes().decodeToString()
        seenOnDb.add(ex.requestMethod + " " + ex.requestURI + " " + ex.requestHeaders.entries.joinToString() + " BODY:" + requestBody)
        val path = URLDecoder.decode(ex.requestURI.rawPath.removePrefix("/db").removePrefix("/").removeSuffix(".json"), "UTF-8")
        val auth = query["auth"]
        if (auth == null) {
            if (openToPublic) return reply(ex, 200, "{}")
            return reply(ex, 401, """{"error":"Permission denied"}""")
        }
        if (rejectNextData.getAndUpdate { if (it > 0) it - 1 else 0 } > 0 || auth != validToken) return reply(ex, 401, """{"error":"Permission denied"}""")
        when (ex.requestMethod) {
            "GET" -> if (ex.requestHeaders.getFirst("Accept") == "text/event-stream") stream(ex, path)
                     else if (query["shallow"] == "true") reply(ex, 200, JsonObject(backing.shallowKeys(path).associateWith { JsonPrimitive(true) }).toString())
                     else reply(ex, 200, (backing.get(path) ?: JsonNull).toString())
            "PUT" -> { backing.put(path, Json.parseToJsonElement(requestBody)); reply(ex, 200, "{}") }
            "DELETE" -> { backing.delete(path); reply(ex, 200, "null") }
            else -> reply(ex, 405, "{}")
        }
    }

    private fun stream(ex: HttpExchange, path: String) {
        ex.responseHeaders.add("Content-Type", "text/event-stream"); ex.sendResponseHeaders(200, 0)
        val out = ex.responseBody
        val done = CountDownLatch(1)
        fun emit(event: String, data: String) { synchronized(out) { try { out.write("event: $event\ndata: $data\n\n".toByteArray()); out.flush() } catch (e: Exception) { done.countDown() } } }
        // Snapshot once and derive both the opening event and the "already sent" set from it, so a child
        // written between the two can never be missed.
        val snapshot = backing.get(path)
        val seen = HashSet<String>((snapshot as? JsonObject)?.keys ?: emptySet())
        emit("put", """{"path":"/","data":${snapshot ?: JsonNull}}""")
        val poll = Thread {
            while (done.count > 0) {
                for (k in backing.shallowKeys(path)) if (seen.add(k)) emit("put", """{"path":"/$k","data":${backing.get("$path/$k")}}""")
                emit("keep-alive", "null"); Thread.sleep(40)
            }
        }.apply { isDaemon = true; start() }
        done.await(30, TimeUnit.SECONDS); runCatching { out.close() }
    }

    @Test fun `signs in and returns the uid`() { assertEquals("uid-9", client().signIn()) }

    @Test fun `a wrong password is explained, not leaked`() {
        val bad = FirebaseRtdbClient(config, CloudAuthCredential("me@x.io", "nope"), endpoints, true)
        try { bad.signIn(); fail() } catch (e: RtdbException) { assertEquals(RtdbException.Kind.AUTH_FAILED, e.kind); assertEquals("Wrong email or password for this Firebase project.", e.message) }
    }

    @Test fun `an unreachable auth server is a network error, not a rejected password`() {
        val dead = AuthEndpoints("http://127.0.0.1:1/idt", "http://127.0.0.1:1/sec")      // nothing listens on port 1
        val c = FirebaseRtdbClient(config, CloudAuthCredential("me@x.io", "hunter2-pass"), dead, allowInsecureDatabase = true)
        try { c.signIn(); fail() } catch (e: RtdbException) { assertEquals(RtdbException.Kind.NETWORK, e.kind); assertFalse(e.message!!.contains("hunter2")) }
    }

    @Test fun `put get delete and shallow keys round-trip, with awkward keys`() {
        val c = client(); c.signIn()
        c.put("sms/uid-9/dev A/messages/42_1700", JsonObject(mapOf("body" to JsonPrimitive("héllo / ünïcode"))))
        c.put("sms/uid-9/dev A/messages/43_1701", JsonPrimitive(1))
        assertEquals("héllo / ünïcode", ((c.get("sms/uid-9/dev A/messages/42_1700") as JsonObject)["body"] as JsonPrimitive).content)
        assertEquals(setOf("42_1700", "43_1701"), c.shallowKeys("sms/uid-9/dev A/messages"))
        c.delete("sms/uid-9/dev A/messages/42_1700")
        assertNull(c.get("sms/uid-9/dev A/messages/42_1700"))
        assertEquals(emptySet<String>(), c.shallowKeys("nothing/here"))
        assertNull(c.get("nothing/here"))
    }

    @Test fun `patch writes only the named children`() {
        val c = client(); c.signIn()
        c.put("sms/uid-9/d/lines/1/syncEnabled", JsonPrimitive(false))
        c.patch("sms/uid-9/d/lines/1", JsonObject(mapOf("label" to JsonPrimitive("Work"))))
        val node = c.get("sms/uid-9/d/lines/1") as JsonObject
        assertEquals("Work", (node["label"] as JsonPrimitive).content); assertEquals("false", (node["syncEnabled"] as JsonPrimitive).content)
    }

    @Test fun `an expired token is refreshed with the refresh token, not by signing in again`() {
        expiresIn = "10"
        val c = client(); c.signIn()
        now += 60_000                                   // past expiry minus the 2-minute skew
        c.put("meta/uid-9/x", JsonPrimitive(1))
        assertEquals(1, refreshes.get()); assertEquals(1, signIns.get())
    }

    @Test fun `a 401 mid-flight triggers one renewal and a retry`() {
        val c = client(); c.signIn()
        rejectNextData.set(1)
        c.put("meta/uid-9/x", JsonPrimitive(2))
        assertEquals(1, refreshes.get())
        assertEquals("2", (c.get("meta/uid-9/x") as JsonPrimitive).content)
    }

    @Test fun `a persistent permission failure surfaces as a clear error`() {
        val c = client(); c.signIn()
        rejectNextData.set(5)
        try { c.put("meta/uid-9/x", JsonPrimitive(3)); fail() } catch (e: RtdbException) { assertTrue(e.message!!.startsWith("Permission denied")) }
    }

    @Test fun `the password is only ever sent to the auth endpoints, never to the database host`() {
        val c = client(); c.signIn()
        c.put("meta/uid-9/y", JsonObject(mapOf("k" to JsonPrimitive(1)))); c.patch("meta/uid-9/y", JsonObject(mapOf("z" to JsonPrimitive("v"))))
        c.get("meta/uid-9/y"); c.shallowKeys("meta/uid-9"); c.delete("meta/uid-9/y")
        // The recorder includes method, URL, every header and the request BODY, so each of these is covered.
        assertTrue("PUT bodies must have been recorded for this test to mean anything", seenOnDb.any { it.startsWith("PUT ") && it.contains("BODY:{") })
        assertEquals(5, seenOnDb.size)    // put, patch (one child = one PUT), get, shallow, delete — every request was inspected
        assertTrue("password reached the database host: ${seenOnDb.filter { it.contains("hunter2") }}", seenOnDb.none { it.contains("hunter2") })
        // Also the URL-encoded spelling, in case it were ever sent as a query/form value.
        assertTrue(seenOnDb.none { it.contains(java.net.URLEncoder.encode("hunter2-pass", "UTF-8")) })
    }

    @Test fun `testConnection round-trips meta and cleans up after itself`() {
        client().testConnection()
        assertNull(backing.get("meta/uid-9/_haloTest"))
        assertTrue(backing.writes.any { it == "meta/uid-9/_haloTest" })
    }

    @Test fun `public-access probe distinguishes a locked database from an open one`() {
        val c = client()
        assertEquals(FirebaseRtdbClient.PublicAccess.LOCKED, c.checkPublicAccess())
        openToPublic = true
        assertEquals(FirebaseRtdbClient.PublicAccess.OPEN, c.checkPublicAccess())
    }

    @Test fun `observeChildAdded delivers existing children, then new ones, without repeats`() {
        val c = client(); c.signIn()
        c.put("clipboard/uid-9/items/a", JsonObject(mapOf("v" to JsonPrimitive(1))))
        val got = CopyOnWriteArrayList<String>(); val latch = CountDownLatch(3)
        val handle = c.observeChildAdded("clipboard/uid-9/items") { k, v -> got.add("$k=${(v as? JsonObject)?.get("v")}"); latch.countDown() }
        c.put("clipboard/uid-9/items/b", JsonObject(mapOf("v" to JsonPrimitive(2))))
        c.put("clipboard/uid-9/items/c", JsonObject(mapOf("v" to JsonPrimitive(3))))
        assertTrue("stream did not deliver in time: $got", latch.await(10, TimeUnit.SECONDS))
        handle.close()
        assertEquals(listOf("a=1", "b=2", "c=3"), got.sorted())
    }

    @Test fun `https is required in production`() {
        try { FirebaseRtdbClient(FirebaseConfig("k", "p", "a", "s", "http://example.com"), CloudAuthCredential("a", "b")); fail() }
        catch (e: RtdbException) { assertEquals(RtdbException.Kind.CONFIGURE_FAILED, e.kind) }
        assertEquals("https://x-default-rtdb.firebaseio.com", FirebaseRtdbClient.normalizedDatabaseUrl(" https://x-default-rtdb.firebaseio.com/ "))
        assertNull(FirebaseRtdbClient.normalizedDatabaseUrl("x-default-rtdb.firebaseio.com")); assertNull(FirebaseRtdbClient.normalizedDatabaseUrl("ftp://h"))
    }

    @Test fun `path encoding cannot be tricked into a new segment`() {
        assertEquals("a/b%20c/d.json", FirebaseRtdbClient.requestPath("a/b c/d"))
        assertEquals(".json", FirebaseRtdbClient.requestPath(""))
        assertEquals("sms/u/x%23y.json", FirebaseRtdbClient.requestPath("sms/u/x#y"))
    }

    @Test fun `stream model folds put and patch and treats null as delete`() {
        val m = LinkedHashMap<String, Any?>()
        assertEquals(StreamModel.Outcome.CHANGED, StreamModel.apply("put", """{"path":"/","data":{"a":{"x":1}}}""", m))
        StreamModel.apply("put", """{"path":"/b","data":{"x":2}}""", m)
        StreamModel.apply("patch", """{"path":"/a","data":{"y":3}}""", m)
        assertEquals(setOf("a", "b"), m.keys)
        StreamModel.apply("put", """{"path":"/a","data":null}""", m)
        assertEquals(setOf("b"), m.keys)
        assertEquals(StreamModel.Outcome.UNCHANGED, StreamModel.apply("keep-alive", "null", m))
        assertEquals(StreamModel.Outcome.REAUTH, StreamModel.apply("auth_revoked", "\"x\"", m))
        assertEquals(StreamModel.Outcome.CANCELLED, StreamModel.apply("cancel", "null", m))
        assertFalse(m.isEmpty())
    }
}
