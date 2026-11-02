package app.halo.cloud.expense

import kotlin.math.abs

/**
 * Deterministic, offline SMS -> transaction parser (F-048 §11.3, the Hamza heuristics). A line-for-line
 * port of the desktop `TransactionParser.swift`, driven by the same pattern pack. Works on the uppercased
 * body in UTF-16 offsets (Kotlin strings are UTF-16, as NSString is), so verb/amount distances compare.
 *
 *   reject -> direction(earliest verb) -> amount(regex, drop-balance, nearest-to-verb) -> account tail + merchant
 *
 * Pure: no I/O, no network, no clock.
 */
object TransactionParser {

    /** Category is left empty — the pipeline assigns it via [PatternPack.category]. */
    fun parse(rawSender: String, rawBody: String, messageId: String, dateMs: Long, pack: PatternPack): ParseOutcome {
        val sender = rawSender.uppercase()
        val upper = rawBody.uppercase()

        // 1-3. Hard rejects -> NotTransaction.
        if (sender.endsWith("-P")) return ParseOutcome.NotTransaction
        if (pack.nonBankSenders.any { sender.contains(it) }) return ParseOutcome.NotTransaction
        if (pack.excludeWords.any { upper.contains(it) }) return ParseOutcome.NotTransaction
        if (pack.promoWords.any { upper.contains(it) }) return ParseOutcome.NotTransaction
        if (pack.rejectPatterns.any { it.matcher(upper).find() }) return ParseOutcome.NotTransaction

        // 4. Direction — earliest debit vs credit verb wins.
        val (direction, verbLoc) = earliestVerb(upper, pack) ?: return ParseOutcome.NotTransaction

        // 5. Amount — regex, drop balances, nearest-to-verb.
        val amount = nearestAmount(upper, verbLoc, pack) ?: return ParseOutcome.Unreadable

        // 6. Extras (best-effort).
        val account = firstCapture(pack.account, upper)
        val merchant = firstCapture(pack.merchant, upper)?.trim { it == ' ' || it == '\t' }

        var confidence = 0.6
        if (account != null) confidence += 0.2
        if (merchant != null) confidence += 0.2
        confidence = minOf(confidence, 1.0)

        return ParseOutcome.Ok(ParsedTransaction(
            id = messageId, amount = amount, currency = pack.currency, direction = direction, merchant = merchant,
            category = "", dateMs = dateMs, accountHint = account, confidence = confidence, sender = rawSender, body = rawBody))
    }

    private fun earliestVerb(upper: String, pack: PatternPack): Pair<Direction, Int>? {
        var best: Pair<Direction, Int>? = null
        fun consider(words: List<String>, dir: Direction) {
            for (w in words) {
                val loc = upper.indexOf(w)
                if (loc >= 0 && (best == null || loc < best!!.second)) best = dir to loc
            }
        }
        consider(pack.debitWords, Direction.DEBIT)
        consider(pack.creditWords, Direction.CREDIT)
        return best
    }

    private fun nearestAmount(upper: String, verbLoc: Int, pack: PatternPack): Double? {
        val m = pack.amount.matcher(upper)
        var best: Double? = null
        var bestDist = Int.MAX_VALUE
        var prevEnd = 0
        while (m.find()) {
            val loc = m.start(); val end = m.end()
            val isBalance = isBalanceAmount(upper, loc, end, prevEnd, pack)
            prevEnd = end
            if (isBalance) continue
            val v = m.group(1).replace(",", "").toDoubleOrNull() ?: continue
            val d = abs(loc - verbLoc)
            if (d < bestDist) { bestDist = d; best = v }        // strict <: on a tie the earlier match wins, as min() does
        }
        return best
    }

    /**
     * An amount is the BALANCE, not the transaction, when (a) a balance word starts a word in the [PatternPack.balanceContextChars]
     * before it - looking back only to the previous sentence boundary and the previous amount, so "Low avl bal alert. Rs 700
     * debited" keeps the 700 - or (b) the text right after it reads "is your available balance". (The old rule looked back a fixed
     * 14 chars, which missed "AVAILABLE BALANCE IN YOUR ACCOUNT IS INR 5,000".)
     */
    private fun isBalanceAmount(upper: String, loc: Int, end: Int, prevEnd: Int, pack: PatternPack): Boolean {
        var from = maxOf(prevEnd, loc - pack.balanceContextChars, 0)
        if (from < loc) {
            val seg = upper.substring(from, loc)
            val b = pack.balanceClauseBoundary.matcher(seg)
            var cut = -1
            while (b.find()) cut = b.end()
            if (cut >= 0) from += cut
        }
        for (w in pack.balancePrefix) {
            var i = upper.indexOf(w, from)
            while (i >= 0 && i + w.length <= loc) {
                if (i == 0 || !PatternPack.isLetter(upper[i - 1])) return true
                i = upper.indexOf(w, i + 1)
            }
        }
        val tail = upper.substring(end, minOf(upper.length, end + BALANCE_AFTER_CHARS))
        return pack.balanceAfter.matcher(tail).find()
    }

    private const val BALANCE_AFTER_CHARS = 40

    /** First non-empty capture group of the first match. */
    private fun firstCapture(p: java.util.regex.Pattern, upper: String): String? {
        val m = p.matcher(upper)
        if (!m.find()) return null
        for (i in 1..m.groupCount()) { val g = m.group(i); if (g != null && g.isNotEmpty()) return g }
        return null
    }
}
