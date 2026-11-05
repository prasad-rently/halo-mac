package app.halo.cloud.expense

import kotlinx.serialization.Serializable

enum class Direction(val wire: String) {
    DEBIT("debit"), CREDIT("credit");
    val isExpense: Boolean get() = this == DEBIT
}

/** The classifier taxonomy (F-044 §7.4). Only [TRANSACTIONAL] feeds the expense pipeline. */
enum class SmsCategory(val wire: String) {
    TRANSACTIONAL("transactional"), OTP("otp"), PERSONAL("personal"), GOVERNMENT("government"),
    SERVICE("service"), PROMOTIONAL("promotional"), UNCATEGORIZED("uncategorized");
}

/** What the pipeline needs of one inbox row. */
data class SmsInput(val id: String, val sender: String, val body: String, val dateMs: Long, val category: SmsCategory)

/** Three-way parse result (D5). Only [Unreadable] (had a verb, no amount) counts toward the "couldn't read" tally. */
sealed interface ParseOutcome {
    data class Ok(val txn: ParsedTransaction) : ParseOutcome
    data object Unreadable : ParseOutcome
    data object NotTransaction : ParseOutcome
}

data class ParsedTransaction(
    val id: String,
    val amount: Double,
    val currency: String,
    val direction: Direction,
    val merchant: String?,
    val category: String,
    val dateMs: Long,
    val accountHint: String?,
    val confidence: Double,
    val sender: String,
    /** Kept only long enough to categorise; NEVER persisted (see [StoredTxn]). */
    val body: String = "",
    val isTransfer: Boolean = false,
    val isDuplicate: Boolean = false,
    val forceIncluded: Boolean = false,
) {
    /** Counts toward spend/income totals: not a transfer, not a collapsed duplicate. */
    val countsTowardTotals: Boolean get() = !isTransfer && !isDuplicate
}

/** User overrides (D9). Ids are the inbox message id, `smsId_date`. */
@Serializable
data class ExpenseOverrides(
    val excludedIds: Set<String> = emptySet(),
    val includedIds: Set<String> = emptySet(),
    val categoryById: Map<String, String> = emptyMap(),
)
