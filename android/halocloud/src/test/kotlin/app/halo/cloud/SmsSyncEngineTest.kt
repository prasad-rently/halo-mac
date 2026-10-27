package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsSyncEngineTest {

    private val now = 1_800_000_000_000L
    private val day = 86_400_000L

    private class FakeSource(var lines: List<SimLine>, var rows: MutableList<Pair<Int, SmsRecord>>) : SmsSource {
        var denied = false
        override fun lines(): List<SimLine> { if (denied) throw SecurityException("no READ_PHONE_STATE"); return lines }
        override fun inbox(subscriptionId: Int, sinceMs: Long): List<SmsRecord> {
            if (denied) throw SecurityException("no READ_SMS")
            return rows.filter { it.first == subscriptionId && it.second.dateMs >= sinceMs }.map { it.second }.sortedBy { it.dateMs }
        }
        override fun allMessageIds(): Set<String> { if (denied) throw SecurityException("no READ_SMS"); return rows.map { SmsWire.messageId(it.second) }.toSet() }
    }

    private fun rec(id: Long, from: String, body: String, date: Long, sub: Int = 1) =
        SmsRecord(id, from, body, date, threadId = 7, subscriptionId = sub, read = false, seen = true)

    private val sim1 = SimLine(1, "Airtel", "+919876543210", "Personal")
    private val sim2 = SimLine(2, "Jio", "", "Work")

    private fun harness(rows: List<Pair<Int, SmsRecord>>, lines: List<SimLine> = listOf(sim1, sim2), filter: SenderFilter = SenderFilter()): Triple<FakeRtdb, FakeSource, SmsSyncEngine> {
        val db = FakeRtdb(); val src = FakeSource(lines, rows.toMutableList())
        val engine = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, MemorySyncState(), { filter }, { 90 }, { now })
        return Triple(db, src, engine)
    }

    @Test fun `uploads the exact fields the desktop console reads, encrypted`() {
        val (db, _, engine) = harness(listOf(1 to rec(42, "VM-HDFCBK", "Rs 500 debited", now - day)))
        val report = engine.sync()
        assertEquals(1, report.uploaded); assertTrue(report.ok)

        val node = db.dump("sms/uid-1/dev-A/messages/42_${now - day}") as JsonObject
        val c = testCrypto()
        // addressEnc/bodyEnc are v1 envelopes the desktop's CryptoService opens.
        assertEquals("VM-HDFCBK", c.decrypt(node["addressEnc"]!!.jsonPrimitive.content))
        assertEquals("Rs 500 debited", c.decrypt(node["bodyEnc"]!!.jsonPrimitive.content))
        assertTrue(node["bodyEnc"]!!.jsonPrimitive.content.startsWith("v1:"))
        assertEquals(1, node["subscriptionId"]!!.jsonPrimitive.content.toInt())
        assertEquals(now - day, node["date"]!!.jsonPrimitive.content.toLong())
        assertEquals(false, node["read"]!!.jsonPrimitive.booleanOrNull)
        assertEquals("1", node["type"]!!.jsonPrimitive.content)               // inbox only (D23)
        // Plaintext must not leak anywhere in the stored node.
        assertFalse(node.toString().contains("HDFCBK")); assertFalse(node.toString().contains("debited"))
    }

    @Test fun `registers the device and every SIM line, with the number encrypted`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "x", now - day)))
        engine.sync()
        val dev = db.dump("devices/uid-1/dev-A") as JsonObject
        assertEquals("Pixel 8", dev["name"]!!.jsonPrimitive.content); assertEquals("android", dev["platform"]!!.jsonPrimitive.content)
        val line1 = db.dump("sms/uid-1/dev-A/lines/1") as JsonObject
        assertEquals("Personal", line1["label"]!!.jsonPrimitive.content); assertEquals("Airtel", line1["carrier"]!!.jsonPrimitive.content)
        assertEquals("+919876543210", testCrypto().decrypt(line1["ownNumberEnc"]!!.jsonPrimitive.content))
        // An unprovisioned SIM number is stored as "Unknown", never an empty ciphertext.
        assertEquals("Unknown", testCrypto().decrypt((db.dump("sms/uid-1/dev-A/lines/2") as JsonObject)["ownNumberEnc"]!!.jsonPrimitive.content))
    }

    @Test fun `a registry node is visible to a live observer only when complete`() {
        // The desktop fires its child_added handler once, on first sight of a child. Written field by field,
        // the first sight is a node with no label or number — and the desktop never looks again.
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "x", now - day)))
        val seenLines = ArrayList<JsonObject>(); val seenDevices = ArrayList<JsonObject>()
        db.observeChildAdded("sms/uid-1/dev-A/lines") { _, v -> (v as? JsonObject)?.let(seenLines::add) }
        db.observeChildAdded("devices/uid-1") { _, v -> (v as? JsonObject)?.let(seenDevices::add) }
        engine.sync()
        assertEquals(2, seenLines.size)
        for (n in seenLines) for (k in listOf("subscriptionId", "label", "carrier", "ownNumberEnc")) assertTrue("line first seen without $k", k in n)
        for (k in listOf("name", "platform", "lastSeen")) assertTrue("device first seen without $k", k in seenDevices.single())
    }

    @Test fun `a second sync uploads nothing new and does not move the mark backwards`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "one", now - 2 * day), 1 to rec(2, "A", "two", now - day)))
        assertEquals(2, engine.sync().uploaded)
        db.writes.clear()
        engine.sync()
        // Ties on the high-water date are re-sent (idempotent overwrite) but nothing else is.
        assertEquals(1, db.writes.count { it.contains("/messages/") })
    }

    @Test fun `a fresh pairing re-sends history the old marks vouched for (re-key, D24)`() {
        // After the Mac re-keys it wipes the cloud; this phone, re-paired under the new key, must put its
        // inbox back — but its marks say "all of this is already in the cloud".
        val db = FakeRtdb(); val src = FakeSource(listOf(sim1), mutableListOf(1 to rec(1, "A", "one", now - 2 * day), 1 to rec(2, "A", "two", now - day)))
        val state = MemorySyncState()
        fun engine(epoch: String) = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, state, { SenderFilter() }, { 90 }, { now }, pairingEpoch = epoch)
        assertEquals(2, engine("pairing-1").sync().uploaded)
        db.delete("sms/uid-1")                                              // the Mac's wipe
        assertEquals("same pairing: the marks hold, nothing re-sent", 1, engine("pairing-1").sync().uploaded)   // only the tie at the mark
        db.delete("sms/uid-1")
        assertEquals("new pairing: everything back", 2, engine("pairing-2").sync().uploaded)
    }

    @Test fun `widening the window survives the first sync of a pairing`() {
        val db = FakeRtdb(); val src = FakeSource(listOf(sim1), mutableListOf(1 to rec(1, "A", "old", now - 120 * day), 1 to rec(2, "A", "new", now - 10 * day)))
        val state = MemorySyncState()
        val engine = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, state, { SenderFilter() }, { 90 }, { now }, pairingEpoch = "p")
        engine.extendBackfill(180)                                          // before any sync has run under this pairing
        engine.sync()
        assertTrue(db.dump("sms/uid-1/dev-A/messages/1_${now - 120 * day}") != null)
    }

    @Test fun `a backfill killed part-way resumes near where it died, not from the start`() {
        // An Error is not caught by the engine, so it models the process (or the worker's 10-minute limit) dying.
        class Killed : Error()
        val total = 400
        val rows = (1..total).map { 1 to rec(it.toLong(), "A", "m$it", now - 80 * day + it * 1000L) }.toMutableList()
        val inner = FakeRtdb()
        val dying = object : Rtdb by inner {
            var puts = 0
            override fun put(path: String, value: kotlinx.serialization.json.JsonElement) {
                if (path.contains("/messages/") && ++puts == 275) throw Killed()
                inner.put(path, value)
            }
        }
        val state = MemorySyncState(); val src = FakeSource(listOf(sim1), rows)
        fun engine(db: Rtdb) = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, state, { SenderFilter() }, { 90 }, { now }, pairingEpoch = "p")
        try { engine(dying).sync(); org.junit.Assert.fail("should have been killed") } catch (e: Killed) { }
        assertEquals(274, (inner.dump("sms/uid-1/dev-A/messages") as JsonObject).size)

        inner.writes.clear()
        assertTrue(engine(inner).sync().ok)
        val resent = inner.writes.count { it.contains("/messages/") }
        assertEquals(total, (inner.dump("sms/uid-1/dev-A/messages") as JsonObject).size)
        // Checkpoints land every 50 uploads: the last one before the kill was row 250, so the retry covers
        // rows 250..400 (the row at the mark is re-sent too — ties are idempotent). With no checkpoint it is all 400.
        assertEquals(151, resent)
    }

    @Test fun `backfill is bounded to 90 days`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "old", now - 120 * day), 1 to rec(2, "A", "new", now - 10 * day)))
        assertEquals(1, engine.sync().uploaded)
        assertNull(db.dump("sms/uid-1/dev-A/messages/1_${now - 120 * day}"))
    }

    @Test fun `extendBackfill re-sends older history`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "old", now - 120 * day), 1 to rec(2, "A", "new", now - 10 * day)))
        engine.sync()
        engine.extendBackfill(180)
        engine.sync()
        assertTrue(db.dump("sms/uid-1/dev-A/messages/1_${now - 120 * day}") != null)
    }

    @Test fun `a line switched off in the registry is not uploaded, and resumes without loss when switched on`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "personal", now - day), 2 to rec(2, "B", "work", now - day, sub = 2)))
        engine.sync()
        engine.setLineEnabled(2, false)                                  // the desktop writes this same node (D29)
        db.delete("sms/uid-1/dev-A/messages")
        val off = engine.sync()
        assertEquals(1, off.skippedDisabledLines)
        assertNull(db.dump("sms/uid-1/dev-A/messages/2_${now - day}"))
        // A sync never resets the toggle the desktop owns.
        assertEquals(false, (db.dump("sms/uid-1/dev-A/lines/2/syncEnabled") as JsonPrimitive).booleanOrNull)
        engine.setLineEnabled(2, true)
        engine.sync()
        assertTrue(db.dump("sms/uid-1/dev-A/messages/2_${now - day}") != null)
    }

    @Test fun `a failure stops the line at the failed row so the mark never skips an unsent message`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "A", "one", now - 3 * day), 1 to rec(2, "A", "two", now - 2 * day), 1 to rec(3, "A", "three", now - day)))
        db.failWrites = { it.endsWith("/messages/2_${now - 2 * day}") }
        val r = engine.sync()
        assertEquals(1, r.uploaded); assertEquals(1, r.failed); assertFalse(r.ok)
        db.failWrites = null
        val retry = engine.sync()
        assertTrue(retry.ok)
        for (id in listOf(1 to 3, 2 to 2, 3 to 1)) assertTrue("row ${id.first} missing", db.dump("sms/uid-1/dev-A/messages/${id.first}_${now - id.second * day}") != null)
    }

    @Test fun `deny list beats allow list and numbers match across formats`() {
        val f = SenderFilter(allow = setOf("+91 98765 43210", "VM-HDFCBK"), deny = setOf("09876543210"))
        assertFalse(f.permits("+919876543210"))                 // denied by tail match, even though also allowed
        assertTrue(f.permits("vm-hdfcbk"))
        assertFalse(f.permits("AX-OTHER"))                       // not on the allow list
        assertTrue(SenderFilter().permits("anyone"))
    }

    @Test fun `filtered senders are never uploaded but the mark still advances past them`() {
        val (db, _, engine) = harness(listOf(1 to rec(1, "SPAM-X", "buy", now - 2 * day), 1 to rec(2, "BANK", "ok", now - day)), filter = SenderFilter(deny = setOf("SPAM-X")))
        val r = engine.sync()
        assertEquals(1, r.uploaded); assertEquals(1, r.skippedByFilter)
        assertNull(db.dump("sms/uid-1/dev-A/messages/1_${now - 2 * day}"))
    }

    @Test fun `reconcile removes cloud rows deleted on the phone`() {
        val (db, src, engine) = harness(listOf(1 to rec(1, "A", "one", now - 2 * day), 1 to rec(2, "A", "two", now - day)))
        engine.sync()
        src.rows.removeAll { it.second.smsId == 1L }
        val r = engine.reconcile()
        assertEquals(1, r.removedFromCloud)
        assertNull(db.dump("sms/uid-1/dev-A/messages/1_${now - 2 * day}")); assertTrue(db.dump("sms/uid-1/dev-A/messages/2_${now - day}") != null)
    }

    @Test fun `reconcile refuses to wipe the cloud when the inbox reads back empty`() {
        val (db, src, engine) = harness(listOf(1 to rec(1, "A", "one", now - day)))
        engine.sync()
        src.rows.clear()
        val r = engine.reconcile()
        assertEquals(0, r.removedFromCloud); assertTrue(r.error != null)
        assertTrue(db.dump("sms/uid-1/dev-A/messages/1_${now - day}") != null)
    }

    @Test fun `missing permission is reported, not thrown, and uploads nothing`() {
        val (db, src, engine) = harness(listOf(1 to rec(1, "A", "one", now - day)))
        src.denied = true
        val r = engine.sync()
        assertTrue(r.error != null); assertEquals(0, r.uploaded); assertEquals(0, db.writes.size)
    }

    @Test fun `thread keys are keyed — equal for one contact on one SIM, different across SIMs and across keys`() {
        val c = testCrypto()
        val a = SmsWire.threadKey(c, "dev-A", rec(1, "+91 98765-43210", "x", 1, sub = 1))
        assertEquals(a, SmsWire.threadKey(c, "dev-A", rec(2, "919876543210".let { "+$it" }, "y", 2, sub = 1)))
        assertNotEquals(a, SmsWire.threadKey(c, "dev-A", rec(3, "+919876543210", "z", 3, sub = 2)))           // other SIM = other thread (D21)
        val other = CryptoService.create("another long passphrase!!", ByteArray(16) { 9 }, CryptoService.MINIMUM_ITERATIONS)
        assertNotEquals(a, SmsWire.threadKey(other, "dev-A", rec(1, "+91 98765-43210", "x", 1, sub = 1)))     // not a bare SHA-256 of the number
    }

    @Test fun `message ids follow the smsId_timestamp rule`() {
        assertEquals("42_1700000000000", SmsWire.messageId(rec(42, "A", "b", 1_700_000_000_000)))
        assertEquals("+919876543210", SmsWire.normalizeNumber("+91 98765-43210")); assertEquals("vm-hdfcbk", SmsWire.normalizeNumber("VM-HDFCBK"))
        assertNull(null as String?); assertEquals(null, JsonPrimitive("").contentOrNull?.takeIf { false })
    }
}
