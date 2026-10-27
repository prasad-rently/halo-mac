package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncTest {

    private fun engine(db: FakeRtdb, id: String = "phone", filter: Boolean = false, clock: () -> Long = System::currentTimeMillis) =
        ClipboardSyncEngine(db, testCrypto(), id, "Pixel 8", { filter }, clock)

    @Test fun `publishes the envelope the desktop parses, content encrypted`() {
        val db = FakeRtdb(); val e = engine(db)
        assertEquals(ClipboardSyncEngine.Publish.Sent, e.publish("hello from the phone"))
        val items = db.dump("clipboard/uid-1/items") as JsonObject
        assertEquals(1, items.size)
        val node = items.values.single() as JsonObject
        for (k in listOf("itemId", "deviceId", "deviceName", "kind", "contentEnc", "createdAt", "schema")) assertTrue("missing $k", k in node)
        assertEquals("phone", node["deviceId"]!!.jsonPrimitive.content); assertEquals("text", node["kind"]!!.jsonPrimitive.content)
        assertEquals("hello from the phone", testCrypto().decrypt(node["contentEnc"]!!.jsonPrimitive.content))
        assertFalse(node.toString().contains("hello"))
        // The desktop's own parser accepts it.
        assertTrue(ClipboardEnvelope.from(node) != null)
    }

    @Test fun `a repeat of the same copy is dropped, a new one is sent`() {
        val db = FakeRtdb(); val e = engine(db)
        assertEquals(ClipboardSyncEngine.Publish.Sent, e.publish("a"))
        assertEquals(ClipboardSyncEngine.Publish.Duplicate, e.publish("a"))
        assertEquals(ClipboardSyncEngine.Publish.Sent, e.publish("b"))
        assertEquals(ClipboardSyncEngine.Publish.Empty, e.publish("   "))
        assertEquals(2, (db.dump("clipboard/uid-1/items") as JsonObject).size)
    }

    @Test fun `urls are tagged url`() {
        assertEquals("url", ClipboardSyncEngine.kindOf("https://halo.app/x?y=1")); assertEquals("text", ClipboardSyncEngine.kindOf("see https://halo.app"))
        assertEquals("text", ClipboardSyncEngine.kindOf("ftp://x"))
    }

    @Test fun `a remote item reaches the other device's history, but its own copies do not echo back`() {
        val db = FakeRtdb()
        val phone = engine(db, "phone"); val mac = engine(db, "mac")
        val gotOnPhone = ArrayList<RemoteClip>(); val gotOnMac = ArrayList<RemoteClip>()
        val h1 = phone.observe { gotOnPhone.add(it) }; val h2 = mac.observe { gotOnMac.add(it) }
        mac.publish("copied on the mac")
        phone.publish("copied on the phone")
        assertEquals(listOf("copied on the mac"), gotOnPhone.map { it.text })
        assertEquals(listOf("copied on the phone"), gotOnMac.map { it.text })
        h1.close(); h2.close()
    }

    @Test fun `after a restart the phone still does not re-receive its own old copies`() {
        val db = FakeRtdb()
        engine(db, "phone").publish("sent before the app was killed")
        val afterRestart = engine(db, "phone")                 // a fresh engine: its seen-set is empty, only deviceId can tell
        val got = ArrayList<RemoteClip>()
        afterRestart.observe { got.add(it) }
        assertEquals(emptyList<String>(), got.map { it.text })
    }

    @Test fun `existing items are delivered on attach, once, and an undecryptable one is skipped`() {
        val db = FakeRtdb(); val mac = engine(db, "mac")
        mac.publish("older")
        val stranger = ClipboardSyncEngine(db, CryptoService.create("a totally different key!!", ByteArray(16) { 5 }, CryptoService.MINIMUM_ITERATIONS), "other", "X")
        stranger.publish("wrong key")
        val got = ArrayList<RemoteClip>()
        engine(db, "phone").observe { got.add(it) }
        assertEquals(listOf("older"), got.map { it.text })
    }

    @Test fun `copying a received clip must not republish it`() {
        val db = FakeRtdb(); val phone = engine(db, "phone")
        phone.suppressEcho("from the mac")
        assertEquals(ClipboardSyncEngine.Publish.Duplicate, phone.publish("from the mac"))
        assertNull(db.dump("clipboard/uid-1/items"))
    }

    @Test fun `the opt-in filter keeps secrets off the cloud and counts them`() {
        val db = FakeRtdb(); val e = engine(db, filter = true)
        assertEquals(ClipboardSyncEngine.Publish.Excluded, e.publish("my password is hunter2"))
        assertEquals(ClipboardSyncEngine.Publish.Excluded, e.publish("AKIAIOSFODNN7EXAMPLE"))
        assertEquals(2, e.excludedCount); assertNull(db.dump("clipboard/uid-1/items"))
        // Off (the default, D5) syncs everything.
        assertEquals(ClipboardSyncEngine.Publish.Sent, engine(FakeRtdb(), filter = false).publish("my password is hunter2"))
    }

    @Test fun `sensitive filter matches the desktop rule for rule`() {
        val yes = listOf("password: x", "Bearer abc", "-----BEGIN PRIVATE KEY-----", "AKIAIOSFODNN7EXAMPLE", "ghp_" + "a".repeat(24), "xoxb-1234567890-abc",
            "eyJhbGciOi.eyJzdWIiOi.SflKxwRJSM", "sk-" + "A".repeat(24), "a".repeat(64))
        val no = listOf("", "   ", "hello world", "d41d8cd98f00b204e9800998ecf8427e" /* MD5 */, "da39a3ee5e6b4b0d3255bfef95601890afd80709" /* git sha */, "https://example.com")
        yes.forEach { assertTrue("should flag: $it", ClipboardSensitiveFilter.isSensitive(it)) }
        no.forEach { assertFalse("should not flag: $it", ClipboardSensitiveFilter.isSensitive(it)) }
    }

    @Test fun `the cloud window is capped at 500 items, oldest evicted`() {
        val db = FakeRtdb(); var t = 1_000_000L
        val e = engine(db, clock = { t })
        for (i in 0 until 502) {
            db.put("clipboard/uid-1/items/seed$i", JsonObject(mapOf("itemId" to JsonPrimitive("seed$i"), "createdAt" to JsonPrimitive(i.toLong()))))
        }
        t += 60_000
        e.publish("trigger the sweep")
        val left = (db.dump("clipboard/uid-1/items") as JsonObject)
        assertEquals(500, left.size)
        // 502 seeded + the new one = 503, so the three oldest go.
        assertFalse("seed0" in left); assertFalse("seed1" in left); assertFalse("seed2" in left); assertTrue("seed3" in left)
    }

    @Test fun `purge empties the cloud`() {
        val db = FakeRtdb(); val e = engine(db)
        e.publish("a"); e.publish("b"); e.purge()
        assertNull(db.dump("clipboard/uid-1/items"))
    }

    @Test fun `a failed upload can be retried with the same text`() {
        val db = FakeRtdb(); val e = engine(db)
        db.failWrites = { true }
        assertTrue(e.publish("retry me") is ClipboardSyncEngine.Publish.Failed)
        db.failWrites = null
        assertEquals(ClipboardSyncEngine.Publish.Sent, e.publish("retry me"))
    }
}
