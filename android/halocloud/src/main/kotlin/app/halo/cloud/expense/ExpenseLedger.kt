package app.halo.cloud.expense

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.YearMonth
import java.time.ZoneId

/** At-rest sealing seam. On the phone this is the Android Keystore's `SecretBox`; the JVM tests use software AES-GCM. */
interface Sealer {
    fun seal(plain: ByteArray): ByteArray
    /** Throws on a wrong key or a tampered/corrupt blob. */
    fun open(blob: ByteArray): ByteArray
}

/**
 * The persisted form of a parsed transaction. Deliberately WITHOUT the SMS body: what is stored is derived
 * data (amount, merchant, category, account tail, sender header), not the message. The category is computed
 * once from the body at parse time, then kept.
 */
@Serializable
data class StoredTxn(
    val id: String,
    val amount: Double,
    val direction: String,          // Direction.wire
    val merchant: String? = null,
    val category: String,
    val dateMs: Long,
    val accountHint: String? = null,
    val confidence: Double,
    val sender: String,
    /** The SIM line this was read from (null = unknown). Lets a later "SIM off" / sender-deny change remove it again. */
    val line: Int? = null,
) {
    fun toParsed(currency: String) = ParsedTransaction(
        id = id, amount = amount, currency = currency, direction = if (direction == "credit") Direction.CREDIT else Direction.DEBIT,
        merchant = merchant, category = category, dateMs = dateMs, accountHint = accountHint, confidence = confidence, sender = sender)

    companion object {
        fun of(t: ParsedTransaction, line: Int? = null) = StoredTxn(t.id, t.amount, t.direction.wire, t.merchant, t.category, t.dateMs, t.accountHint, t.confidence, t.sender, line)
    }
}

@Serializable
data class LedgerState(
    val schema: Int = SCHEMA,
    /** Which pack (and parser revision) produced [txns]; a mismatch means "rescan", never "trust old rows". */
    val packId: String = "",
    val packVersion: Int = 0,
    val parserRev: Int = 0,
    /** Per-line (SIM) high-water mark: every inbox row dated at or before it has been read. */
    val marks: Map<Int, Long> = emptyMap(),
    val txns: Map<String, StoredTxn> = emptyMap(),
    /** Ids of messages that had a verb but no readable amount (D5). */
    val unreadable: Set<String> = emptySet(),
    val overrides: ExpenseOverrides = ExpenseOverrides(),
) {
    companion object { const val SCHEMA = 1 }
}

/** One month's view for the UI. Transfers and collapsed duplicates stay in [recent] (flagged) but never in the totals. */
data class MonthSummary(
    val month: YearMonth,
    val spent: Double,
    val received: Double,
    val byCategory: List<Pair<String, Double>>,
    val recent: List<ParsedTransaction>,
    val unreadableCount: Int,
) { val net: Double get() = received - spent }

/**
 * The sealed, local-only expense store (F-056 FR-E3). The file on disk is ciphertext ([Sealer]); it is
 * written atomically (temp + rename) so a crash mid-write leaves the previous good file. A file that cannot
 * be opened (Keystore reset, corruption, tamper) is treated as "no data" — the next scan rebuilds it from
 * the inbox, which is the source of truth, so nothing is lost but time.
 */
class ExpenseLedger(
    private val file: File,
    private val sealer: Sealer,
    val pack: PatternPack = PatternPack.indiaDefault,
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    // Mutable working copy: a 10 000-message inbox must not copy a map per row. Serialised as a LedgerState on flush.
    private val marks = HashMap<Int, Long>()
    private val txns = LinkedHashMap<String, StoredTxn>()
    private val unreadable = HashSet<String>()
    private var overrides = ExpenseOverrides()

    init {
        val s = load()
        marks.putAll(s.marks); txns.putAll(s.txns); unreadable.addAll(s.unreadable); overrides = s.overrides
    }

    private fun load(): LedgerState {
        val fresh = LedgerState(packId = pack.id, packVersion = pack.version, parserRev = PARSER_REV)
        val s = try {
            if (!file.exists()) return fresh
            json.decodeFromString(LedgerState.serializer(), String(sealer.open(file.readBytes()), Charsets.UTF_8))
        } catch (e: Exception) { return fresh }
        if (s.schema != LedgerState.SCHEMA || s.packId != pack.id || s.packVersion != pack.version || s.parserRev != PARSER_REV) {
            // Parsed under different rules: drop the derived rows and marks (so the inbox is re-read), keep the user's overrides.
            return fresh.copy(overrides = s.overrides)
        }
        return s
    }

    @Synchronized fun highWater(subscriptionId: Int): Long? = marks[subscriptionId]
    @Synchronized fun setHighWater(subscriptionId: Int, dateMs: Long) { marks[subscriptionId] = dateMs }
    @Synchronized fun overrides(): ExpenseOverrides = overrides
    @Synchronized fun transactionCount(): Int = txns.size

    /** Record one parsed message. Idempotent by id (the boundary row of a resumed scan is read twice). */
    @Synchronized fun record(one: TransactionPipeline.One, id: String, line: Int? = null) {
        when (one) {
            is TransactionPipeline.One.Txn -> { txns[id] = StoredTxn.of(one.t, line); unreadable.remove(id) }
            TransactionPipeline.One.Unreadable -> { unreadable.add(id); txns.remove(id) }
            TransactionPipeline.One.Skip -> { txns.remove(id); unreadable.remove(id) }
        }
    }

    /**
     * Drop every stored row [keep] rejects (a SIM switched off, a sender denied since it was read). The marks of the
     * lines that lost rows are forgotten too, so that allowing them again re-reads the inbox instead of leaving a
     * permanent hole behind the mark. Returns how many rows were dropped. Overrides are untouched.
     */
    @Synchronized fun purge(keep: (StoredTxn) -> Boolean): Int {
        val gone = txns.values.filter { !keep(it) }
        if (gone.isEmpty()) return 0
        gone.forEach { txns.remove(it.id) }
        gone.mapNotNull { it.line }.toSet().forEach { marks.remove(it) }
        return gone.size
    }

    /** Write the ledger now. Called at checkpoints during a scan and when it ends or is cancelled. */
    @Synchronized fun flush() {
        val st = LedgerState(packId = pack.id, packVersion = pack.version, parserRev = PARSER_REV,
            marks = HashMap(marks), txns = LinkedHashMap(txns), unreadable = HashSet(unreadable), overrides = overrides)
        val bytes = sealer.seal(json.encodeToString(LedgerState.serializer(), st).toByteArray(Charsets.UTF_8))
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        // fsync before the rename: a rename over unsynced data can leave a zero-length file after a power loss, which
        // would read as "empty" and quietly drop the user's overrides.
        java.io.FileOutputStream(tmp).use { it.write(bytes); it.flush(); it.fd.sync() }
        if (!tmp.renameTo(file)) { file.delete(); if (!tmp.renameTo(file)) { tmp.delete(); error("could not replace ${file.name}") } }
    }

    // --- user overrides (D9) -------------------------------------------------------------------

    @Synchronized fun exclude(id: String) { overrides = overrides.copy(excludedIds = overrides.excludedIds + id, includedIds = overrides.includedIds - id); flush() }
    @Synchronized fun unexclude(id: String) { overrides = overrides.copy(excludedIds = overrides.excludedIds - id); flush() }
    @Synchronized fun setCategory(id: String, category: String) { overrides = overrides.copy(categoryById = overrides.categoryById + (id to category)); flush() }

    /** Forget everything derived (keeps overrides) — "scan again from scratch". */
    @Synchronized fun resetScan() { marks.clear(); txns.clear(); unreadable.clear(); flush() }

    // --- reads -----------------------------------------------------------------------------------

    /** Every transaction after self-transfer / duplicate detection and overrides, newest first. */
    @Synchronized fun all(): List<ParsedTransaction> {
        val parsed = txns.values.map { it.toParsed(pack.currency) }
        return TransactionPipeline.finish(parsed, pack, overrides, zone)
    }

    @Synchronized fun excludedTransactions(): List<ParsedTransaction> =
        txns.values.filter { it.id in overrides.excludedIds }.map { it.toParsed(pack.currency) }.sortedByDescending { it.dateMs }

    @Synchronized fun unreadableCount(): Int = (unreadable - overrides.excludedIds).size

    fun month(month: YearMonth, recentLimit: Int = 50): MonthSummary {
        val inMonth = all().filter { YearMonth.from(java.time.Instant.ofEpochMilli(it.dateMs).atZone(zone)) == month }
        val counted = inMonth.filter { it.countsTowardTotals }
        val spent = counted.filter { it.direction == Direction.DEBIT }.sumOf { it.amount }
        val received = counted.filter { it.direction == Direction.CREDIT }.sumOf { it.amount }
        val byCat = counted.filter { it.direction == Direction.DEBIT }.groupBy { it.category }
            .map { (k, v) -> k to v.sumOf { it.amount } }.sortedByDescending { it.second }
        return MonthSummary(month, spent, received, byCat, inMonth.take(recentLimit), unreadableCount())
    }

    companion object {
        /** Bump when TransactionParser / categorisation logic changes in a way that alters stored rows. */
        const val PARSER_REV = 1
    }
}
