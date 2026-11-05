package app.halo.cloud.expense

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

/**
 * classify(keep transactional) -> parse -> markSelfTransfers -> dedup(window) -> categorise -> overrides.
 * Port of the desktop `TransactionPipeline.swift` (F-048 §11.1 / §11.4). Pure and re-runnable: the phone
 * re-runs [finish] over its stored parses on every read, so an override or a pack change shows at once.
 *
 * Self-transfer pairing buckets by calendar DAY, so it needs a time zone; the desktop uses the system's
 * `Calendar.current` and so does the default here.
 */
object TransactionPipeline {

    data class Result(
        /** Includes transfers and duplicates (flagged), newest first. */
        val transactions: List<ParsedTransaction>,
        /** Had a verb, no amount (D5). */
        val unreadableCount: Int,
    )

    /** Parse + categorise ONE message; null when the pipeline would skip it. Mirrors the per-message body of Swift `run`. */
    sealed interface One {
        data class Txn(val t: ParsedTransaction) : One
        data object Unreadable : One
        data object Skip : One
    }

    fun parseOne(m: SmsInput, pack: PatternPack, forced: Boolean = false): One {
        if (m.category != SmsCategory.TRANSACTIONAL && !forced) return One.Skip     // keep transactional only
        return when (val r = TransactionParser.parse(m.sender, m.body, m.id, m.dateMs, pack)) {
            is ParseOutcome.Ok -> One.Txn(r.txn.copy(forceIncluded = forced, category = pack.category(r.txn.merchant, r.txn.body, r.txn.direction)))
            ParseOutcome.Unreadable -> if (forced) One.Skip else One.Unreadable       // only genuine unreadables count (D5)
            ParseOutcome.NotTransaction -> One.Skip
        }
    }

    fun run(messages: List<SmsInput>, pack: PatternPack, overrides: ExpenseOverrides = ExpenseOverrides(),
            zone: ZoneId = ZoneId.systemDefault()): Result {
        val oks = ArrayList<ParsedTransaction>()
        var unreadable = 0
        for (m in messages) {
            if (m.id in overrides.excludedIds) continue                       // force-exclude (D9)
            when (val r = parseOne(m, pack, forced = m.id in overrides.includedIds)) {
                is One.Txn -> oks.add(r.t)
                One.Unreadable -> unreadable++
                One.Skip -> {}
            }
        }
        return Result(finish(oks, pack, overrides, zone), unreadable)
    }

    /** The post-parse stages, shared with the on-disk ledger: overrides, self-transfers, near-duplicates, sort. */
    fun finish(parsed: List<ParsedTransaction>, pack: PatternPack, overrides: ExpenseOverrides, zone: ZoneId = ZoneId.systemDefault()): List<ParsedTransaction> {
        val oks = parsed.filter { it.id !in overrides.excludedIds }
            .map { t -> overrides.categoryById[t.id]?.let { t.copy(category = it) } ?: t }
            .toMutableList()
        markSelfTransfers(oks, zone)
        dedup(oks, pack.dedupWindowMs)
        for (i in oks.indices) if (oks[i].isTransfer) oks[i] = oks[i].copy(category = "Transfers")
        return oks.sortedByDescending { it.dateMs }
    }

    /** D7 — same day + same amount, one debit and one credit -> both are a self-transfer. */
    fun markSelfTransfers(txns: MutableList<ParsedTransaction>, zone: ZoneId) {
        class Bucket { val debits = ArrayList<Int>(); val credits = ArrayList<Int>() }
        val buckets = LinkedHashMap<String, Bucket>()
        for ((i, t) in txns.withIndex()) {
            val day: LocalDate = Instant.ofEpochMilli(t.dateMs).atZone(zone).toLocalDate()
            val key = "$day|${Math.round(t.amount * 100)}"
            val b = buckets.getOrPut(key) { Bucket() }
            if (t.direction == Direction.DEBIT) b.debits.add(i) else b.credits.add(i)
        }
        for (b in buckets.values) {
            for (k in 0 until minOf(b.debits.size, b.credits.size)) {
                txns[b.debits[k]] = txns[b.debits[k]].copy(isTransfer = true)
                txns[b.credits[k]] = txns[b.credits[k]].copy(isTransfer = true)
            }
        }
    }

    /** D8/D15 — same amount + direction within the window -> the later one is a duplicate. */
    fun dedup(txns: MutableList<ParsedTransaction>, windowMs: Long) {
        val kept = ArrayList<Int>()
        for (i in txns.indices.sortedBy { txns[it].dateMs }) {
            if (txns[i].isTransfer) continue
            val t = txns[i]
            val dup = kept.any { j -> val k = txns[j]; k.amount == t.amount && k.direction == t.direction && abs(k.dateMs - t.dateMs) <= windowMs }
            if (dup) txns[i] = t.copy(isDuplicate = true) else kept.add(i)
        }
    }
}
