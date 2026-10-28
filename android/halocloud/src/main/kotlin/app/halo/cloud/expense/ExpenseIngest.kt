package app.halo.cloud.expense

import app.halo.cloud.SenderFilter
import app.halo.cloud.SmsSource
import app.halo.cloud.SmsWire

/** What the user chose to include. Sender filter = the same list as SMS sync (FR-E5); lines are per-SIM toggles. */
class ExpenseSettings(
    val filter: () -> SenderFilter = { SenderFilter() },
    /** SIM subscription ids the user switched OFF for expense tracking. */
    val disabledLines: () -> Set<Int> = { emptySet() },
    val backfillDays: () -> Int = { DEFAULT_BACKFILL_DAYS },
) { companion object { const val DEFAULT_BACKFILL_DAYS = 90 } }

data class IngestReport(
    val scanned: Int = 0,
    val parsed: Int = 0,
    val unreadable: Int = 0,
    val filtered: Int = 0,
    val skippedLines: Int = 0,
    val cancelled: Boolean = false,
    val error: String? = null,
) { val ok: Boolean get() = error == null }

/**
 * Reads the device inbox through [SmsSource] and fills the [ExpenseLedger]. Entirely local: no `Rtdb`, no
 * sockets, no HTTP — the parse path has no network seam at all (FR-E3; checked by a test over this package's
 * bytecode). Incremental: each line resumes from its high-water mark. Cancellable: [isCancelled] is polled per
 * row, and a cancelled or crashed run leaves a valid ledger + marks behind to resume from (rows are read
 * oldest-first, so a mark never jumps over an unread row).
 */
class ExpenseIngest(
    private val source: SmsSource,
    private val ledger: ExpenseLedger,
    private val settings: ExpenseSettings = ExpenseSettings(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    fun run(isCancelled: () -> Boolean = { false }): IngestReport {
        val lines = try { source.lines() } catch (e: SecurityException) { return IngestReport(error = "SMS permission not granted.") }
        val filter = settings.filter()
        val off = settings.disabledLines()
        val horizon = clock() - settings.backfillDays() * DAY_MS
        val pack = ledger.pack
        var scanned = 0; var parsed = 0; var unreadable = 0; var filtered = 0; var skippedLines = 0
        var sinceCheckpoint = 0
        fun report(cancelled: Boolean = false, error: String? = null) = IngestReport(scanned, parsed, unreadable, filtered, skippedLines, cancelled, error)

        for (l in lines) {
            if (l.subscriptionId in off) { skippedLines++; continue }
            if (isCancelled()) { ledger.flush(); return report(cancelled = true) }
            val rows = try { source.inbox(l.subscriptionId, ledger.highWater(l.subscriptionId) ?: horizon) }
                       catch (e: SecurityException) { ledger.flush(); return report(error = "SMS permission not granted.") }
            for (r in rows) {
                if (isCancelled()) { ledger.flush(); return report(cancelled = true) }
                scanned++
                val id = SmsWire.messageId(r)
                if (!filter.permits(r.address)) {
                    filtered++
                    ledger.record(TransactionPipeline.One.Skip, id)      // a sender excluded after the fact must disappear too
                } else {
                    val cat = SmsClassifier.classify(r.address, r.body, pack)
                    when (val one = TransactionPipeline.parseOne(SmsInput(id, r.address, r.body, r.dateMs, cat), pack)) {
                        is TransactionPipeline.One.Txn -> { parsed++; ledger.record(one, id) }
                        TransactionPipeline.One.Unreadable -> { unreadable++; ledger.record(one, id) }
                        TransactionPipeline.One.Skip -> ledger.record(one, id)
                    }
                }
                ledger.setHighWater(l.subscriptionId, maxOf(ledger.highWater(l.subscriptionId) ?: 0L, r.dateMs))
                // Checkpoint as we go so a long first scan that the OS kills still moves forward.
                if (++sinceCheckpoint >= CHECKPOINT_EVERY) { ledger.flush(); sinceCheckpoint = 0 }
            }
        }
        ledger.flush()
        return report()
    }

    /** "Scan older history": move every line's mark back so the next [run] re-reads `days` of inbox (idempotent by message id). */
    fun extendBackfill(days: Int) {
        val horizon = clock() - days * DAY_MS
        for (l in source.lines()) {
            val cur = ledger.highWater(l.subscriptionId)
            if (cur == null || cur > horizon) ledger.setHighWater(l.subscriptionId, horizon)
        }
        ledger.flush()
    }

    companion object {
        const val DAY_MS = 86_400_000L
        const val CHECKPOINT_EVERY = 500
    }
}
