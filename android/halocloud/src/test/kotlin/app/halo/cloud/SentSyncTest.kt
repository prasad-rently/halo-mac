package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Sent-message sync (F-044 D23's deferred half, backlog V2.7-20).
 *
 * Invariants pinned here, each with a test that goes red if the rule is broken:
 *  1. opt-in — with "Also sync messages I send" off the sent box is not READ, let alone uploaded;
 *  2. a sent message is never an inbox message — separate node, separate record type, separate marks and keys;
 *  3. a sent message never reaches the expenditure pipeline (F-048/F-056 read `SmsSource.inbox()` only);
 *  4. the rest of the sync's rules (per-SIM, sender filters, quarantine, delete mirroring, backfill horizon) hold for sent rows.
 */
class SentSyncTest {

    private val now = 1_800_000_000_000L
    private val day = 86_400_000L
    private val sim1 = SimLine(1, "Airtel", "+919876543210", "Personal")
    private val sim2 = SimLine(2, "Jio", "", "Work")

    /** A source that records which boxes were read. */
    private class Source(var lines: List<SimLine>, val inbox: MutableList<Pair<Int, SmsRecord>> = mutableListOf(), val sent: MutableList<Pair<Int, SentSmsRecord>> = mutableListOf()) : SmsSource {
        var sentReads = 0
        var denied = false
        override fun lines() = lines
        override fun inbox(subscriptionId: Int, sinceMs: Long) = inbox.filter { it.first == subscriptionId && it.second.dateMs >= sinceMs }.map { it.second }.sortedBy { it.dateMs }
        override fun allMessageIds() = inbox.map { SmsWire.messageId(it.second) }.toSet()
        override fun sent(subscriptionId: Int, sinceMs: Long): List<SentSmsRecord> {
            sentReads++
            if (denied) throw SecurityException("no READ_SMS")
            return sent.filter { it.first == subscriptionId && it.second.dateMs >= sinceMs }.map { it.second }.sortedBy { it.dateMs }
        }
        override fun allSentMessageIds(): Set<String> { sentReads++; return sent.map { SmsWire.sentMessageId(it.second) }.toSet() }
    }

    private fun inboxRow(id: Long, from: String, body: String, date: Long, sub: Int = 1) = SmsRecord(id, from, body, date, threadId = 7, subscriptionId = sub, read = false, seen = true)
    private fun sentRow(id: Long, to: String, body: String, date: Long, sub: Int = 1) = SentSmsRecord(id, to, body, date, threadId = 7, subscriptionId = sub, read = true, seen = true)

    private class Harness(
        val db: FakeRtdb = FakeRtdb(), val src: Source, val state: MemorySyncState = MemorySyncState(),
        var sentOn: Boolean = true, var filter: SenderFilter = SenderFilter(), val clock: () -> Long,
    ) {
        val engine = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, state, { filter }, { 90 }, clock, pairingEpoch = "p", syncSent = { sentOn })
    }

    private fun harness(src: Source, sentOn: Boolean = true) = Harness(src = src, sentOn = sentOn, clock = { now })
    private fun sentNode(db: FakeRtdb, id: String) = db.dump("sms/uid-1/dev-A/sent/$id") as? JsonObject
    private fun sentIds(db: FakeRtdb) = ((db.dump("sms/uid-1/dev-A/sent") as? JsonObject)?.keys ?: emptySet())

    // ── opt-in ──────────────────────────────────────────────────────────────────────────────────────

    @Test fun `OFF is the default - an engine built without the setting never reads the sent box and uploads nothing`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(5, "+919812300000", "my secret plan", now - day)))
        val db = FakeRtdb()
        val engine = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, MemorySyncState(), { SenderFilter() }, { 90 }, { now })   // no syncSent argument
        val r = engine.sync()
        assertEquals(0, r.uploadedSent); assertEquals("the sent box must not even be read", 0, src.sentReads)
        assertNull(db.dump("sms/uid-1/dev-A/sent")); assertNull(db.dump("sms/uid-1/dev-A/messages"))
        engine.reconcile(); assertEquals("reconcile must not read it either", 0, src.sentReads)
    }

    @Test fun `switching it off stops uploads on the very next pass and leaves what was uploaded until it is removed`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(5, "+919812300000", "one", now - 2 * day)))
        val h = harness(src)
        assertEquals(1, h.engine.sync().uploadedSent)
        src.sent.add(1 to sentRow(6, "+919812300000", "two", now - day))
        h.sentOn = false; val readsBefore = src.sentReads
        val r = h.engine.sync()
        assertEquals(0, r.uploadedSent); assertEquals(readsBefore, src.sentReads)
        assertEquals(setOf("5_${now - 2 * day}"), sentIds(h.db))
    }

    @Test fun `removeAllSent deletes every uploaded sent message, keeps the inbox, and a later opt-in starts from the horizon`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "VM-HDFCBK", "hello", now - day)),
            sent = mutableListOf(1 to sentRow(5, "+919812300000", "one", now - 2 * day), 1 to sentRow(6, "+919812300000", "two", now - day)))
        val h = harness(src)
        assertEquals(2, h.engine.sync().uploadedSent)
        h.sentOn = false
        h.engine.removeAllSent()
        assertNull(h.db.dump("sms/uid-1/dev-A/sent"))
        assertNotNull("inbox rows are not touched", h.db.dump("sms/uid-1/dev-A/messages/1_${now - day}"))
        assertNull(h.state.sentHighWater(1))
        h.sentOn = true
        assertEquals("re-opting-in re-sends from the backfill horizon, not from a stale mark", 2, h.engine.sync().uploadedSent)
    }

    // ── a sent message is not an inbox message ──────────────────────────────────────────────────────

    @Test fun `a sent row goes to the sent node as type 2 with the contact encrypted, never under messages`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(42, "+91 98123 00000", "On my way, Rs 500 paid & received ✅", now - day)))
        val h = harness(src)
        val r = h.engine.sync()
        assertEquals(1, r.uploadedSent); assertEquals("a sent row is not counted as an inbox upload", 0, r.uploaded); assertTrue(r.ok)
        assertNull("nothing under messages/ — an older Mac would show it as received", h.db.dump("sms/uid-1/dev-A/messages"))

        val node = sentNode(h.db, "42_${now - day}")!!
        val c = testCrypto()
        assertEquals("+91 98123 00000", c.decrypt(node["addressEnc"]!!.jsonPrimitive.content))
        assertEquals("On my way, Rs 500 paid & received ✅", c.decrypt(node["bodyEnc"]!!.jsonPrimitive.content))
        assertEquals("2", node["type"]!!.jsonPrimitive.content)
        assertEquals(1, node["subscriptionId"]!!.jsonPrimitive.content.toInt()); assertEquals(now - day, node["date"]!!.jsonPrimitive.content.toLong())
        assertFalse("plaintext must not leak into the stored node", node.toString().contains("my way") || node.toString().contains("98123"))
    }

    @Test fun `both sides of a conversation share one thread key`() {
        val c = testCrypto()
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "+919812300000", "hi", now - 2 * day)), sent = mutableListOf(1 to sentRow(2, "+91 98123-00000", "hello back", now - day)))
        val h = harness(src); h.engine.sync()
        val inKey = (h.db.dump("sms/uid-1/dev-A/messages/1_${now - 2 * day}") as JsonObject)["threadKey"]!!.jsonPrimitive.content
        assertEquals(inKey, sentNode(h.db, "2_${now - day}")!!["threadKey"]!!.jsonPrimitive.content)
        // …but another SIM's thread with the same contact is a different one (D21), sent side included.
        assertNotEquals(inKey, SmsWire.threadKey(c, "dev-A", 2, "+919812300000"))
    }

    @Test fun `ids are stable across passes, and a sent id can never alias an inbox id`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(7, "A", "in", now - day)), sent = mutableListOf(1 to sentRow(8, "B", "out", now - day)))
        val h = harness(src)
        h.engine.sync(); val first = sentIds(h.db)
        h.engine.sync(); assertEquals("re-upload overwrites itself", first, sentIds(h.db))
        assertEquals(setOf("8_${now - day}"), first)
        // Even if the provider ever reused a number, the two ids live in different nodes and keep different quarantine keys.
        assertNull(h.db.dump("sms/uid-1/dev-A/messages/8_${now - day}")); assertNull(sentNode(h.db, "7_${now - day}"))
    }

    // ── the expenditure pipeline must never see a sent message (F-048/F-056) ───────────────────────

    @Test fun `a sent bank-style text never comes out of inbox() and is never an SmsRecord`() {
        val bankLike = "Rs 5,000.00 debited from a/c XX1234 via UPI. Avl bal Rs 9,500."
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(9, "+919812300000", bankLike, now - day)))
        // What the expense ingest reads — the same call, the same arguments:
        assertTrue("inbox() must not surface a sent row", src.inbox(1, 0).isEmpty())
        assertTrue(src.allMessageIds().isEmpty())
        // And the types do not mix: a SentSmsRecord is not something the inbox pipeline's parameter type accepts.
        assertFalse(SmsRecord::class.java.isAssignableFrom(SentSmsRecord::class.java))
        assertFalse(SentSmsRecord::class.java.isAssignableFrom(SmsRecord::class.java))
        // The inbox side of a sync counts nothing for it.
        val r = harness(src).engine.sync(); assertEquals(0, r.uploaded); assertEquals(1, r.uploadedSent)
    }

    @Test fun `only the sync code may touch the sent box - an allowlist source guard over every module, real from day one`() {
        // The previous version scanned `halocloud/.../expense/`, a directory that does not exist until F-056 lands (and F-056's
        // app-side files live under app/.../mobile/expense/, which that path would never have covered). Scan EVERY main
        // source file instead and allow only the files that legitimately implement or drive sent-sync: any new file that
        // names the sent API (expense code, a ViewModel, a worker...) fails the build until someone consciously adds it here.
        val androidRoot = File(System.getProperty("user.dir")).parentFile
        val sources = androidRoot.listFiles { f -> f.isDirectory }.orEmpty()
            .map { File(it, "src/main/kotlin") }.filter { it.isDirectory }
            .flatMap { it.walkTopDown().filter { f -> f.isFile && f.extension == "kt" }.toList() }
        assertTrue("guard found no sources under $androidRoot - it would be vacuous", sources.any { it.name == "SmsSyncEngine.kt" })
        // Non-vacuous against the REAL F-056 code (integrated tree): both halves of the expense feature must be in the scanned set,
        // and the ingest must read through inbox() — so the guard is demonstrably looking at what it is guarding.
        val expense = sources.filter { "/expense/" in it.path.replace('\\', '/') }
        assertTrue("F-056 core (halocloud/.../expense) not scanned: $expense", expense.any { it.name == "ExpenseIngest.kt" } && expense.any { it.name == "ExpenseLedger.kt" })
        assertTrue("F-056 app side (app/.../mobile/expense) not scanned", expense.any { it.name == "ExpenseRuntime.kt" } && expense.any { it.name == "ExpenseViewModel.kt" })
        assertTrue("the expense ingest must read the inbox via SmsSource.inbox()", expense.first { it.name == "ExpenseIngest.kt" }.readText().contains(".inbox("))
        val offenders = sources.filter { it.name !in SENT_API_ALLOWED && FORBIDDEN_IN_EXPENSE.any { tok -> tok in it.readText() } }.map { it.name }
        assertTrue("only $SENT_API_ALLOWED may use the sent-box API; found it in $offenders (the expenditure pipeline must read SmsSource.inbox() only)", offenders.isEmpty())
    }

    // ── a requested "delete what was uploaded" is never lost ────────────────────────────────────────

    @Test fun `a removal that cannot reach the cloud stays owed, holds sent upload, and completes on a later pass`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(5, "+919812300000", "one", now - 2 * day)))
        val h = harness(src)
        assertEquals(1, h.engine.sync().uploadedSent)
        h.sentOn = false
        h.db.failWrites = { it.endsWith("/dev-A/sent") }                         // offline when "Stop and delete" was tapped
        try { h.engine.removeAllSent(); org.junit.Assert.fail("the delete must fail offline") } catch (e: RtdbException) { }
        assertTrue("the request is remembered", h.state.sentRemovalPending())
        assertEquals("nothing was removed", 1, sentIds(h.db).size)

        // Even if the user flips it back on meanwhile, nothing sent is uploaded while the removal is owed.
        h.sentOn = true; src.sent.add(1 to sentRow(6, "+919812300000", "two", now - day))
        val r = h.engine.sync()
        assertEquals(0, r.uploadedSent); assertTrue(r.sentRemovalPending); assertTrue(r.retryable)
        assertEquals(setOf("5_${now - 2 * day}"), sentIds(h.db))

        h.db.failWrites = null                                                     // back online: the next pass finishes the job first
        val ok = h.engine.sync()
        assertFalse(ok.sentRemovalPending); assertFalse(h.state.sentRemovalPending())
        assertEquals("re-enabled and clean: both rows are re-sent from the horizon, none were left behind", 2, ok.uploadedSent)
    }

    @Test fun `an owed removal completes even when sent-sync stays off, and is not undone`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(5, "+919812300000", "one", now - day)))
        val h = harness(src); h.engine.sync(); h.sentOn = false
        h.db.failWrites = { it.endsWith("/dev-A/sent") }
        try { h.engine.removeAllSent() } catch (e: RtdbException) { }
        assertFalse("still owed -> resume reports it", h.engine.resumeSentRemoval())
        h.db.failWrites = null
        assertTrue(h.engine.resumeSentRemoval()); assertNull(h.db.dump("sms/uid-1/dev-A/sent")); assertFalse(h.state.sentRemovalPending())
        assertEquals(0, h.engine.sync().uploadedSent)
    }

    @Test fun `a new pairing does not forget an owed removal`() {
        val state = MemorySyncState(); state.setSentRemovalPending(true); state.clear()
        assertTrue(state.sentRemovalPending())
    }

    // ── per-SIM, filters, high-water, quarantine, reconcile ─────────────────────────────────────────

    @Test fun `each SIM keeps its own sent mark, independent of the inbox mark`() {
        val src = Source(listOf(sim1, sim2), inbox = mutableListOf(1 to inboxRow(1, "A", "x", now - 5 * day)),
            sent = mutableListOf(1 to sentRow(5, "B", "s1", now - 3 * day), 2 to sentRow(6, "C", "s2", now - 2 * day, sub = 2)))
        val h = harness(src); h.engine.sync()
        assertEquals(now - 3 * day, h.state.sentHighWater(1)); assertEquals(now - 2 * day, h.state.sentHighWater(2))
        assertEquals("the inbox mark is its own", now - 5 * day, h.state.highWater(1)); assertNull(h.state.highWater(2))
        h.db.writes.clear(); h.engine.sync()
        assertEquals("only the tie at each mark is re-sent", 2, h.db.writes.count { it.contains("/sent/") })
    }

    @Test fun `a line switched off is not read for sent either`() {
        val src = Source(listOf(sim1, sim2), sent = mutableListOf(1 to sentRow(5, "B", "s1", now - day), 2 to sentRow(6, "C", "s2", now - day, sub = 2)))
        val h = harness(src); h.engine.sync(); h.db.delete("sms/uid-1/dev-A/sent")
        h.engine.setLineEnabled(2, false); h.state.clear(); h.state.setPairingEpoch("p")
        assertEquals(1, h.engine.sync().uploadedSent)
        assertEquals(setOf("5_${now - day}"), sentIds(h.db))
    }

    @Test fun `sender filters apply to the contact in both directions - deny wins, allow narrows`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(1, "+919800000001", "to blocked", now - 3 * day), 1 to sentRow(2, "+919800000002", "to ok", now - 2 * day), 1 to sentRow(3, "+919800000003", "to other", now - day)))
        val h = harness(src); h.filter = SenderFilter(deny = setOf("+91 98000 00001"))
        var r = h.engine.sync(); assertEquals(2, r.uploadedSent); assertEquals(1, r.skippedByFilter)
        assertNull(sentNode(h.db, "1_${now - 3 * day}"))
        h.db.delete("sms/uid-1/dev-A/sent"); h.state.clearSent(); h.filter = SenderFilter(allow = setOf("+919800000002"))
        r = h.engine.sync(); assertEquals(setOf("2_${now - 2 * day}"), sentIds(h.db))
    }

    @Test fun `a missing permission on the sent box is reported, not thrown`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(5, "B", "x", now - day))); src.denied = true
        val r = harness(src).engine.sync()
        assertNotNull(r.error); assertEquals(0, r.uploadedSent)
    }

    @Test fun `a failure stops the sent line at the failed row and the mark never skips it`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(1, "B", "a", now - 3 * day), 1 to sentRow(2, "B", "b", now - 2 * day), 1 to sentRow(3, "B", "c", now - day)))
        val h = harness(src)
        h.db.failWrites = { it.endsWith("/sent/2_${now - 2 * day}") }
        val r = h.engine.sync(); assertEquals(1, r.uploadedSent); assertEquals(1, r.failed)
        assertEquals(now - 3 * day, h.state.sentHighWater(1))
        h.db.failWrites = null; assertTrue(h.engine.sync().ok)
        assertEquals(3, sentIds(h.db).size)
    }

    @Test fun `a poison sent row is quarantined without blocking later sent rows, under a key that is not an inbox key`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(2, "A", "in", now - 2 * day)),
            sent = mutableListOf(1 to sentRow(1, "B", "a", now - 3 * day), 1 to sentRow(2, "B", "poison", now - 2 * day), 1 to sentRow(3, "B", "c", now - day)))
        val h = harness(src)
        h.db.failWrites = { it.endsWith("/sent/2_${now - 2 * day}") }; h.db.failKind = RtdbException.Kind.OPERATION_FAILED; h.db.failStatus = 400
        repeat(SmsSyncEngine.QUARANTINE_AFTER) { h.engine.sync() }
        assertEquals(setOf("sent:1|2_${now - 2 * day}"), h.state.quarantined())
        assertNotNull("the later sent row went through", sentNode(h.db, "3_${now - day}"))
        assertNotNull("and the inbox row with the same smsId was never confused with the poison sent row", h.db.dump("sms/uid-1/dev-A/messages/2_${now - 2 * day}"))
        // Retry skipped rewinds the SENT mark (not the inbox one) and re-sends once the cause is gone.
        h.db.failWrites = null; h.engine.retryQuarantined()
        assertTrue(h.state.quarantined().isEmpty()); assertEquals(now - 2 * day - 1, h.state.sentHighWater(1))
        assertTrue(h.engine.sync().ok); assertNotNull(sentNode(h.db, "2_${now - 2 * day}"))
    }

    @Test fun `reconcile mirrors a deletion of a sent message, and only the sent side`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "A", "in", now - day)),
            sent = mutableListOf(1 to sentRow(2, "B", "out1", now - 2 * day), 1 to sentRow(3, "B", "out2", now - day)))
        val h = harness(src); h.engine.sync()
        src.sent.removeAll { it.second.smsId == 2L }
        val r = h.engine.reconcile()
        assertEquals(1, r.removedFromCloud); assertTrue(r.ok)
        assertEquals(setOf("3_${now - day}"), sentIds(h.db)); assertNotNull(h.db.dump("sms/uid-1/dev-A/messages/1_${now - day}"))
    }

    @Test fun `reconcile never wipes the sent cloud when the sent box reads back empty`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "A", "in", now - day)), sent = mutableListOf(1 to sentRow(2, "B", "out", now - day)))
        val h = harness(src); h.engine.sync()
        src.sent.clear()
        val r = h.engine.reconcile()
        assertNotNull(r.error); assertEquals(0, r.removedFromCloud); assertEquals(1, sentIds(h.db).size)
    }

    @Test fun `with sent-sync off reconcile leaves leftover cloud sent rows alone`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "A", "in", now - day)), sent = mutableListOf(1 to sentRow(2, "B", "out", now - day)))
        val h = harness(src); h.engine.sync()
        h.sentOn = false; src.sent.clear(); val reads = src.sentReads
        val r = h.engine.reconcile()
        assertTrue(r.ok); assertEquals(reads, src.sentReads); assertEquals(1, sentIds(h.db).size)
    }

    @Test fun `a fresh pairing drops the sent marks like the inbox marks, and Sync older history widens the sent window only once sent-sync has run`() {
        val src = Source(listOf(sim1), sent = mutableListOf(1 to sentRow(1, "B", "old", now - 120 * day), 1 to sentRow(2, "B", "new", now - 10 * day)))
        val db = FakeRtdb(); val state = MemorySyncState()
        fun engine(epoch: String, on: Boolean) = SmsSyncEngine(db, testCrypto(), "dev-A", "Pixel 8", src, state, { SenderFilter() }, { 90 }, { now }, pairingEpoch = epoch, syncSent = { on })
        engine("p1", false).extendBackfill(180)
        assertNull("sent-sync never ran, so 'older history' must not start it", state.sentHighWater(1))
        assertEquals(1, engine("p1", true).sync().uploadedSent)                       // 90-day horizon: only the new one
        engine("p1", true).extendBackfill(180); engine("p1", true).sync()
        assertEquals(2, sentIds(db).size)
        db.delete("sms/uid-1"); assertEquals("a new pairing re-sends from the horizon", 1, engine("p2", true).sync().uploadedSent)
    }

    @Test fun `an old phone's data is unchanged - without sent-sync no sent node is ever created and the inbox node keeps its shape`() {
        val src = Source(listOf(sim1), inbox = mutableListOf(1 to inboxRow(1, "VM-HDFCBK", "Rs 500 debited", now - day)), sent = mutableListOf(1 to sentRow(2, "B", "x", now - day)))
        val h = harness(src, sentOn = false); h.engine.sync()
        assertNull(h.db.dump("sms/uid-1/dev-A/sent"))
        val node = h.db.dump("sms/uid-1/dev-A/messages/1_${now - day}") as JsonObject
        assertEquals("1", node["type"]!!.jsonPrimitive.content)
        assertEquals(setOf("addressEnc", "bodyEnc", "threadKey", "threadId", "subscriptionId", "date", "type", "read", "seen", "syncedAt", "schema"), node.keys)
    }

    private companion object {
        /** Anything that would let the expense package reach the sent box. */
        val FORBIDDEN_IN_EXPENSE = listOf(".sent(", "allSentMessageIds", "SentSmsRecord", "sentHighWater", "sentPath", "Sms.Sent", "TYPE_SENT", "syncSent", "removeAllSent")
        /** The only files that implement or drive sent-sync. */
        val SENT_API_ALLOWED = setOf("SmsSyncEngine.kt", "Sms.kt", "AndroidSmsSource.kt", "CloudStore.kt", "CloudViewModel.kt", "SmsSync.kt", "CloudScreens.kt")
    }
}
