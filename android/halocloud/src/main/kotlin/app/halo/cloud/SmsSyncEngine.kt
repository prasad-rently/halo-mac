package app.halo.cloud

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

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
}

/** Where the per-line high-water marks live between runs. */
interface SyncState {
    fun highWater(subscriptionId: Int): Long?
    fun setHighWater(subscriptionId: Int, dateMs: Long)
    fun clear()
    /**
     * Which pairing the marks were earned under, or null if none recorded. A mark only means "everything up
     * to here is in the cloud" for the cloud (and key) it was written against — see [SmsSyncEngine].
     */
    fun pairingEpoch(): String?
    fun setPairingEpoch(epoch: String)
}

class MemorySyncState : SyncState {
    private val m = HashMap<Int, Long>()
    private var epoch: String? = null
    override fun highWater(subscriptionId: Int) = m[subscriptionId]
    override fun setHighWater(subscriptionId: Int, dateMs: Long) { m[subscriptionId] = dateMs }
    override fun clear() { m.clear(); epoch = null }
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
) { val ok: Boolean get() = error == null && failed == 0 }

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
            val flag = (rtdb.get("$linePath/syncEnabled") as? JsonPrimitive)?.booleanOrNull
            rtdb.put(linePath, SmsWire.lineNode(l, crypto, flag))
            enabled[l.subscriptionId] = flag ?: true
        }

        val f = filter()
        val horizon = now - backfillDays() * DAY_MS
        var uploaded = 0; var filtered = 0; var disabled = 0; var failed = 0
        for (l in lines) {
            if (enabled[l.subscriptionId] == false) { disabled++; continue }                  // D29: a disabled line is not even read
            val rows = try { source.inbox(l.subscriptionId, state.highWater(l.subscriptionId) ?: horizon) }
                       catch (e: SecurityException) { return SyncReport(uploaded, filtered, disabled, failed, error = "SMS permission not granted.") }
            var mark = state.highWater(l.subscriptionId)
            for (r in rows) {
                if (!f.permits(r.address)) { filtered++; mark = maxOf(mark ?: 0, r.dateMs); continue }
                try {
                    rtdb.put("${root(uid)}/messages/${SmsWire.messageId(r)}", SmsWire.messageNode(r, crypto, deviceId, now))
                    uploaded++; mark = maxOf(mark ?: 0, r.dateMs)
                } catch (e: Exception) {
                    // Stop this line at the first failure so the mark never jumps over an un-uploaded row.
                    failed++; break
                }
            }
            if (mark != null) state.setHighWater(l.subscriptionId, mark)
        }
        return SyncReport(uploaded, filtered, disabled, failed)
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
        return SyncReport(removedFromCloud = removed, failed = failed)
    }

    /** "Sync older history": move every line's mark back so the next [sync] re-sends `days` of history (idempotent). */
    fun extendBackfill(days: Int) {
        adoptPairing()
        val horizon = clock() - days * DAY_MS
        for (l in source.lines()) {
            val cur = state.highWater(l.subscriptionId)
            if (cur == null || cur > horizon) state.setHighWater(l.subscriptionId, horizon)
        }
    }

    /** Write the per-line toggle to the registry the desktop also edits (D29). */
    fun setLineEnabled(subscriptionId: Int, enabled: Boolean) {
        rtdb.put("${root(rtdb.uid)}/lines/$subscriptionId/syncEnabled", JsonPrimitive(enabled))
    }

    companion object {
        const val DEFAULT_BACKFILL_DAYS = 90
        private const val DAY_MS = 86_400_000L
    }
}
