package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

// The phone-side SMS sync (F-044 FR-0…FR-6, F-049 Phase 1). Pure Kotlin over two seams — [SmsSource]
// (the device inbox) and [Rtdb] (the user's database) — so the whole algorithm is unit-tested on the
// JVM and the Android app only supplies a ContentResolver-backed source.
//
// The inbox IS the queue. Every upload is an idempotent overwrite keyed `smsId_date` (D14) and a
// per-line high-water mark only advances past rows that actually uploaded, so a failed run leaves the
// mark behind and the next run simply retries — no separate on-device queue to keep consistent (D13's
// intent, with one less moving part).

/** The device inbox. Implementations throw `SecurityException` when READ_SMS isn't granted. */
interface SmsSource {
    fun lines(): List<SimLine>
    /** Inbox rows with `date >= sinceMs` for one line, oldest first. */
    fun inbox(subscriptionId: Int, sinceMs: Long): List<SmsRecord>
    /** Every inbox row's message id — for the delete-mirroring reconcile (D25). */
    fun allMessageIds(): Set<String>

    /**
     * Sent rows (provider type 2) with `date >= sinceMs` for one line, oldest first. Only ever called when the user has
     * opted in to "Also sync messages I send" ([SmsSyncEngine]'s `syncSent`); with it off the sent box is not even read.
     * Defaults to nothing so a source that predates sent-sync — or a test fake — needs no change.
     */
    fun sent(subscriptionId: Int, sinceMs: Long): List<SentSmsRecord> = emptyList()
    /** Every sent row's message id — for the delete-mirroring reconcile of the sent side (D25). */
    fun allSentMessageIds(): Set<String> = emptySet()
}

/** Where the per-line high-water marks live between runs. */
interface SyncState {
    fun highWater(subscriptionId: Int): Long?
    fun setHighWater(subscriptionId: Int, dateMs: Long)
    fun clear()

    // Sent-sync keeps its OWN mark per line: the inbox mark says nothing about the sent box, and the two advance
    // independently (a long-quiet inbox with a busy sent box, or the reverse). Cleared by [clear] and by [clearSent].
    fun sentHighWater(subscriptionId: Int): Long?
    fun setSentHighWater(subscriptionId: Int, dateMs: Long)
    /** Forget every sent mark, failure counter and quarantine entry (the user removed what was uploaded). */
    fun clearSent()
    /**
     * Which pairing the marks were earned under, or null if none recorded. A mark only means "everything up
     * to here is in the cloud" for the cloud (and key) it was written against — see [SmsSyncEngine].
     */
    fun pairingEpoch(): String?
    fun setPairingEpoch(epoch: String)

    // H-14 — poison-row quarantine. A row that keeps failing for a reason other than connectivity must not
    // hold its whole line (and its high-water mark) hostage forever. Keys are `"<subscriptionId>|<messageId>"`.
    /** How many consecutive passes this row has failed (0 when unknown). */
    fun failures(key: String): Int
    fun setFailures(key: String, count: Int)
    /** Rows given up on: skipped by every pass until [clearQuarantine]. */
    fun quarantined(): Set<String>
    fun quarantine(key: String)
    /** Forget every quarantine entry and failure counter (the "Retry skipped" action). */
    fun clearQuarantine()
}

class MemorySyncState : SyncState {
    private val m = HashMap<Int, Long>()
    private val sentMarks = HashMap<Int, Long>()
    private var epoch: String? = null
    private val fails = HashMap<String, Int>()
    private val parkedRows = LinkedHashSet<String>()
    override fun failures(key: String) = fails[key] ?: 0
    override fun setFailures(key: String, count: Int) { if (count <= 0) fails.remove(key) else fails[key] = count }
    override fun quarantined(): Set<String> = parkedRows.toSet()
    override fun quarantine(key: String) { parkedRows.add(key); fails.remove(key) }
    override fun clearQuarantine() { parkedRows.clear(); fails.clear() }
    override fun highWater(subscriptionId: Int) = m[subscriptionId]
    override fun setHighWater(subscriptionId: Int, dateMs: Long) { m[subscriptionId] = dateMs }
    override fun clear() { m.clear(); sentMarks.clear(); epoch = null; fails.clear(); parkedRows.clear() }
    override fun sentHighWater(subscriptionId: Int) = sentMarks[subscriptionId]
    override fun setSentHighWater(subscriptionId: Int, dateMs: Long) { sentMarks[subscriptionId] = dateMs }
    override fun clearSent() { sentMarks.clear(); fails.keys.removeAll { it.startsWith(SmsSyncEngine.SENT_KEY_PREFIX) }; parkedRows.removeAll { it.startsWith(SmsSyncEngine.SENT_KEY_PREFIX) } }
    override fun pairingEpoch() = epoch
    override fun setPairingEpoch(epoch: String) { this.epoch = epoch }
}

/** Which senders to sync (FR-6). Deny wins; a non-empty allow list means "only these". */
data class SenderFilter(val allow: Set<String> = emptySet(), val deny: Set<String> = emptySet()) {
    fun permits(address: String): Boolean {
        val n = SmsWire.normalizeNumber(address)
        fun hit(set: Set<String>) = set.any { SmsWire.normalizeNumber(it).let { s -> s.isNotEmpty() && (s == n || matchesTail(s, n)) } }
        if (hit(deny)) return false
        return allow.isEmpty() || hit(allow)
    }

    // Numbers are compared on their last 10 digits so "+91 98765 43210" matches "098765 43210".
    private fun matchesTail(a: String, b: String): Boolean {
        if (a.any { it.isLetter() } || b.any { it.isLetter() }) return false
        val ta = a.filter { it.isDigit() }.takeLast(10); val tb = b.filter { it.isDigit() }.takeLast(10)
        return ta.length >= 7 && ta == tb
    }
}

data class SyncReport(
    val uploaded: Int = 0,
    val skippedByFilter: Int = 0,
    /** How many SIM lines were skipped because their sync toggle is off. */
    val skippedDisabledLines: Int = 0,
    val failed: Int = 0,
    val removedFromCloud: Int = 0,
    val error: String? = null,
    /** The run stopped on trouble that can clear by itself (network, a busy database) — worth a backed-off retry. */
    val retryable: Boolean = false,
    /** Rows currently quarantined (H-14): given up on after [SmsSyncEngine.QUARANTINE_AFTER] failed passes, until "Retry skipped". */
    val quarantined: Int = 0,
    /** Sent messages uploaded this pass (0 unless "Also sync messages I send" is on). Counted separately from [uploaded]. */
    val uploadedSent: Int = 0,
) {
    val ok: Boolean get() = error == null && failed == 0

    companion object {
        /**
         * An exception that escaped a sync pass. A missing permission or a wrong password will not fix itself, so
         * retrying those only burns sign-in attempts; a dropped connection will, and a live SMS that hits one must
         * not wait for the 15-minute safety-net pass.
         */
        fun fromFailure(e: Exception): SyncReport {
            val transient = when (e) {
                is RtdbException -> e.kind == RtdbException.Kind.NETWORK || e.kind == RtdbException.Kind.OPERATION_FAILED
                is java.io.IOException -> true
                else -> false
            }
            return SyncReport(error = e.message ?: "Sync failed.", retryable = transient)
        }
    }
}

class SmsSyncEngine(
    private val rtdb: Rtdb,
    private val crypto: CryptoService,
    private val deviceId: String,
    private val deviceName: String,
    private val source: SmsSource,
    private val state: SyncState,
    private val filter: () -> SenderFilter = { SenderFilter() },
    private val backfillDays: () -> Int = { DEFAULT_BACKFILL_DAYS },
    private val clock: () -> Long = System::currentTimeMillis,
    /**
     * Identifies this pairing. A fresh pairing (new key after the Mac's re-key, new project, wipe-and-pair) means
     * everything the old marks vouched for is NOT in the new cloud under the new key, so the marks are dropped and
     * the inbox is re-sent from the backfill horizon (D24: "devices re-sync from their inboxes under the new key").
     * Re-sending is safe — every upload is an idempotent overwrite keyed `smsId_date`.
     */
    private val pairingEpoch: String = "",
    /**
     * "Also sync messages I send" — OFF by default, because it widens what leaves the device from "what people sent me"
     * to "what I wrote". Read on every pass, so turning it off takes effect on the very next one: with it false the sent
     * box is not read, nothing is uploaded, nothing about it is reconciled.
     */
    private val syncSent: () -> Boolean = { false },
) {
    private fun root(uid: String) = "sms/$uid/$deviceId"

    private fun adoptPairing() {
        if (state.pairingEpoch() != pairingEpoch) { state.clear(); state.setPairingEpoch(pairingEpoch) }
    }

    /** Register the device + SIM lines, then upload everything new on every enabled line. */
    fun sync(): SyncReport {
        val uid = rtdb.uid
        adoptPairing()
        val now = clock()
        val lines = try { source.lines() } catch (e: SecurityException) { return SyncReport(error = "Phone permission not granted.") }

        // FR-0: device + line registries. Written before the messages so the desktop can label them on arrival.
        // Each node goes up as ONE put — never field by field (see SmsWire.lineNode): the desktop reads a new
        // child once, so a half-written registry entry would be shown with no label or number until it restarts.
        rtdb.put("devices/$uid/$deviceId", SmsWire.deviceNode(deviceName, now))
        val enabled = HashMap<Int, Boolean>()
        for (l in lines) {
            val linePath = "${root(uid)}/lines/${l.subscriptionId}"
            // The desktop owns the per-line toggle (D29): read it back rather than trusting a local copy, and
            // carry it through the whole-node write so a sync never resets it.
            val existing = rtdb.get(linePath) as? JsonObject
            val flag = (existing?.get("syncEnabled") as? JsonPrimitive)?.booleanOrNull
            // H-21: bump `lineVersion`/`updatedAt` only when what the Mac displays actually changed; an unchanged
            // line keeps both (and its ciphertext) so a routine sync is a byte-identical rewrite, not a "change".
            val prevVersion = (existing?.get("lineVersion") as? JsonPrimitive)?.intOrNull
            val prevUpdated = (existing?.get("updatedAt") as? JsonPrimitive)?.longOrNull
            val prevEnc = (existing?.get("ownNumberEnc") as? JsonPrimitive)?.takeIf { it.isString }?.content
            val unchanged = existing != null &&
                (existing["label"] as? JsonPrimitive)?.contentOrNull == l.label &&
                (existing["carrier"] as? JsonPrimitive)?.contentOrNull == l.carrier &&
                prevEnc != null && runCatching { crypto.decrypt(prevEnc) }.getOrNull() == l.ownNumber.ifBlank { "Unknown" }
            val version = if (unchanged && prevVersion != null) prevVersion else (prevVersion ?: 0) + 1
            val updatedAt = if (unchanged && prevUpdated != null) prevUpdated else now
            rtdb.put(linePath, SmsWire.lineNode(l, crypto, flag, version, updatedAt, if (unchanged) prevEnc else null))
            enabled[l.subscriptionId] = flag ?: true
        }

        val f = filter()
        val horizon = now - backfillDays() * DAY_MS
        val tally = Tally()
        var disabled = 0
        val parked = state.quarantined()
        for (l in lines) {
            if (enabled[l.subscriptionId] == false) { disabled++; continue }                  // D29: a disabled line is not even read
            val rows = try { source.inbox(l.subscriptionId, state.highWater(l.subscriptionId) ?: horizon) }
                       catch (e: SecurityException) { return SyncReport(tally.uploaded, tally.filtered, disabled, tally.failed, error = "SMS permission not granted.") }
            val sub = l.subscriptionId
            val mark = uploadRows(rows, state.highWater(sub), f, parked, tally,
                address = { it.address }, date = { it.dateMs }, key = { quarantineKey(sub, it) },
                put = { r -> rtdb.put("${root(uid)}/messages/${SmsWire.messageId(r)}", SmsWire.messageNode(r, crypto, deviceId, now)) },
                checkpoint = { state.setHighWater(sub, it) })
            if (mark != null) state.setHighWater(sub, mark)
        }
        val inboxUploaded = tally.uploaded

        // Sent messages — opt-in, and its own pass over its own marks (see [syncSent]). A line the user switched off is
        // not read for sent either (D29), and the sender filters apply to the CONTACT, whichever direction.
        var sentUploaded = 0
        if (syncSent()) {
            tally.uploaded = 0
            for (l in lines) {
                if (enabled[l.subscriptionId] == false) continue
                val sub = l.subscriptionId
                val rows = try { source.sent(sub, state.sentHighWater(sub) ?: horizon) }
                           catch (e: SecurityException) { return SyncReport(inboxUploaded, tally.filtered, disabled, tally.failed, error = "SMS permission not granted.", uploadedSent = tally.uploaded) }
                val mark = uploadRows(rows, state.sentHighWater(sub), f, parked, tally,
                    address = { it.address }, date = { it.dateMs }, key = { sentQuarantineKey(sub, it) },
                    put = { r -> rtdb.put("${SmsWire.sentPath(uid, deviceId)}/${SmsWire.sentMessageId(r)}", SmsWire.sentMessageNode(r, crypto, deviceId, now)) },
                    checkpoint = { state.setSentHighWater(sub, it) })
                if (mark != null) state.setSentHighWater(sub, mark)
            }
            sentUploaded = tally.uploaded
        }
        return SyncReport(inboxUploaded, tally.filtered, disabled, tally.failed, quarantined = state.quarantined().size, uploadedSent = sentUploaded)
    }

    private class Tally { var uploaded = 0; var filtered = 0; var failed = 0 }

    /**
     * One line's rows, oldest first, through filter -> quarantine -> upload, advancing a mark only past rows that are
     * really in the cloud (or deliberately given up on). Shared by the inbox and the sent pass so the two cannot drift:
     * same filters, same H-14 quarantine, same checkpointing. Returns the new mark (null if there was none and nothing moved).
     */
    private fun <R> uploadRows(
        rows: List<R>, startMark: Long?, f: SenderFilter, parked: Set<String>, t: Tally,
        address: (R) -> String, date: (R) -> Long, key: (R) -> String, put: (R) -> Unit, checkpoint: (Long) -> Unit,
    ): Long? {
        var mark = startMark
        var sinceCheckpoint = 0
        for (r in rows) {
            if (!f.permits(address(r))) { t.filtered++; mark = maxOf(mark ?: 0, date(r)); continue }
            val k = key(r)
            // H-14: a quarantined row is skipped, and the mark moves past it so it can never block its line.
            if (k in parked) { mark = maxOf(mark ?: 0, date(r)); continue }
            try {
                put(r)
                if (state.failures(k) > 0) state.setFailures(k, 0)
                t.uploaded++; mark = maxOf(mark ?: 0, date(r))
                // Checkpoint as we go: a long backfill can outlive its worker (WorkManager's 10-minute limit,
                // or the process), and a mark saved only at the end would restart that backfill from nothing
                // every time — it could never finish. Rows are oldest-first, so the mark is always safe.
                if (++sinceCheckpoint >= CHECKPOINT_EVERY) { checkpoint(mark); sinceCheckpoint = 0 }
            } catch (e: Exception) {
                // A dropped connection, an outage, a rate limit or a session problem says nothing about THIS row,
                // so none of them counts toward quarantine ([RtdbException.isRowFault]). A failure that can be about
                // the row itself (the server refusing it, a rule rejecting it, a local encoding error) does: after
                // QUARANTINE_AFTER consecutive failed passes the row is parked and the line carries on (H-14).
                val rowFault = if (e is RtdbException) e.isRowFault else true
                if (rowFault) {
                    val n = state.failures(k) + 1
                    if (n >= QUARANTINE_AFTER) { state.quarantine(k); mark = maxOf(mark ?: 0, date(r)); continue }
                    state.setFailures(k, n)
                }
                // Stop this line at the first failure so the mark never jumps over an un-uploaded row.
                t.failed++; break
            }
        }
        return mark
    }

    private fun quarantineKey(subscriptionId: Int, r: SmsRecord) = "$subscriptionId|${SmsWire.messageId(r)}"
    /** Distinct from every inbox key, so a sent row and an inbox row can never share a failure counter or a quarantine entry. */
    private fun sentQuarantineKey(subscriptionId: Int, r: SentSmsRecord) = "$SENT_KEY_PREFIX$subscriptionId|${SmsWire.sentMessageId(r)}"

    /**
     * "Retry skipped" (H-14): un-park every quarantined row. Their lines' marks already moved past them, so each
     * line's mark is wound back to just before its oldest skipped row; the next [sync] re-sends from there
     * (idempotent — every upload is an overwrite keyed `smsId_date`).
     */
    fun retryQuarantined() {
        adoptPairing()
        val oldest = HashMap<Int, Long>(); val oldestSent = HashMap<Int, Long>()
        for (raw in state.quarantined()) {
            val sent = raw.startsWith(SENT_KEY_PREFIX)
            val key = raw.removePrefix(SENT_KEY_PREFIX)
            val sub = key.substringBefore('|').toIntOrNull() ?: continue
            val date = key.substringAfterLast('_').toLongOrNull() ?: continue
            val into = if (sent) oldestSent else oldest
            into[sub] = minOf(into[sub] ?: Long.MAX_VALUE, date)
        }
        for ((sub, date) in oldest) {
            val cur = state.highWater(sub)
            if (cur == null || cur > date - 1) state.setHighWater(sub, date - 1)
        }
        for ((sub, date) in oldestSent) {
            val cur = state.sentHighWater(sub)
            if (cur == null || cur > date - 1) state.setSentHighWater(sub, date - 1)
        }
        state.clearQuarantine()
    }

    /**
     * D25: the phone is the source of truth, so cloud rows that are no longer in the inbox are removed.
     * Keys-only listing keeps it cheap. Refuses to act on an empty inbox — that is far more likely a
     * revoked permission or a provider hiccup than "the user deleted every message".
     */
    fun reconcile(): SyncReport {
        val uid = rtdb.uid
        val local = try { source.allMessageIds() } catch (e: SecurityException) { return SyncReport(error = "SMS permission not granted.") }
        val cloud = rtdb.shallowKeys("${root(uid)}/messages")
        if (local.isEmpty() && cloud.isNotEmpty()) return SyncReport(error = "The inbox read back empty — not removing anything from the cloud.")
        var removed = 0; var failed = 0
        for (key in cloud - local) {
            try { rtdb.delete("${root(uid)}/messages/$key"); removed++ } catch (e: Exception) { failed++ }
        }
        // The sent side mirrors deletions the same way — but only while the user has it switched on. With it off the
        // sent box is not read at all; whatever was left in the cloud stays until "remove what was uploaded".
        var error: String? = null
        if (syncSent()) {
            val localSent = try { source.allSentMessageIds() } catch (e: SecurityException) { return SyncReport(removedFromCloud = removed, failed = failed, error = "SMS permission not granted.") }
            val sentPath = SmsWire.sentPath(uid, deviceId)
            val cloudSent = rtdb.shallowKeys(sentPath)
            if (localSent.isEmpty() && cloudSent.isNotEmpty()) error = "The sent box read back empty — not removing anything from the cloud."
            else for (key in cloudSent - localSent) {
                try { rtdb.delete("$sentPath/$key"); removed++ } catch (e: Exception) { failed++ }
            }
        }
        return SyncReport(removedFromCloud = removed, failed = failed, error = error)
    }

    /**
     * The user turned "Also sync messages I send" off and asked for what was already uploaded to go too: delete the
     * device's whole `sent` node (one request, which is what the separate node buys) and forget the sent marks and
     * quarantine so a later opt-in starts clean from the backfill horizon. Inbox rows are untouched.
     */
    fun removeAllSent() {
        rtdb.delete(SmsWire.sentPath(rtdb.uid, deviceId))
        state.clearSent()
    }

    /** "Sync older history": move every line's mark back so the next [sync] re-sends `days` of history (idempotent). */
    fun extendBackfill(days: Int) {
        adoptPairing()
        val horizon = clock() - days * DAY_MS
        for (l in source.lines()) {
            val cur = state.highWater(l.subscriptionId)
            if (cur == null || cur > horizon) state.setHighWater(l.subscriptionId, horizon)
            // Sent marks too — but only if there is one: with sent-sync never on, "older history" must not start it.
            val curSent = state.sentHighWater(l.subscriptionId)
            if (curSent != null && curSent > horizon) state.setSentHighWater(l.subscriptionId, horizon)
        }
    }

    /** Write the per-line toggle to the registry the desktop also edits (D29). */
    fun setLineEnabled(subscriptionId: Int, enabled: Boolean) {
        rtdb.put("${root(rtdb.uid)}/lines/$subscriptionId/syncEnabled", JsonPrimitive(enabled))
    }

    companion object {
        const val DEFAULT_BACKFILL_DAYS = 90
        const val CHECKPOINT_EVERY = 50
        /** Consecutive failed passes after which a row is quarantined (H-14). */
        const val QUARANTINE_AFTER = 5
        /** Quarantine / failure-counter keys of sent rows start with this, so they never alias an inbox key. */
        const val SENT_KEY_PREFIX = "sent:"
        private const val DAY_MS = 86_400_000L
    }
}
