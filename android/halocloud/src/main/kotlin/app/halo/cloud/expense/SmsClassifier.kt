package app.halo.cloud.expense

/**
 * The pack-driven classifier: ordered otp -> personal -> government -> `-P` shortcut -> transactional ->
 * service -> promotional -> DLT suffix -> uncategorized, with the keyword lists read from the pattern pack
 * (docs/specs/pattern-packs/india-bank-sms.v1.json, `classifier`).
 *
 * NOTE (see expense-fixtures.v1.json): the desktop's `SmsClassifier.swift` is a *compact* hard-coded port
 * with shorter lists, so the two can classify an edge message differently. The fixtures record where.
 */
object SmsClassifier {
    fun classify(sender: String, body: String, pack: PatternPack = PatternPack.indiaDefault): SmsCategory {
        val k = pack.classifier
        val s = sender.uppercase()
        val b = body.uppercase()

        // 1. OTP
        if (k.otpKeywords.any { b.contains(it) } || k.otpNumber.matcher(b).find()) return SmsCategory.OTP
        // 2. Personal: sender is a bare phone number.
        if (isPersonalSender(sender, k)) return SmsCategory.PERSONAL
        // 3. Government
        if (k.govSenders.any { s.contains(it) } || k.govKeywords.any { b.contains(it) }) return SmsCategory.GOVERNMENT
        // -P promotional DLT header shortcut (before the transactional content check).
        if (s.endsWith("-P")) return SmsCategory.PROMOTIONAL
        // 4. Transactional
        if (k.transactionalStrong.any { b.contains(it) }) return SmsCategory.TRANSACTIONAL
        if (k.moneyTokens.any { b.contains(it) } && k.transactionalVerbs.any { b.contains(it) }) return SmsCategory.TRANSACTIONAL
        // 5. Service  6. Promotional
        if (k.serviceKeywords.any { b.contains(it) }) return SmsCategory.SERVICE
        if (k.promoKeywords.any { b.contains(it) }) return SmsCategory.PROMOTIONAL
        // 7. DLT suffix fallback
        return when {
            s.endsWith("-T") -> SmsCategory.TRANSACTIONAL
            s.endsWith("-S") -> SmsCategory.SERVICE
            s.endsWith("-G") -> SmsCategory.GOVERNMENT
            else -> SmsCategory.UNCATEGORIZED
        }
    }

    /** No letters, only `[0-9 +()-.]`, digit count within the pack's range. */
    private fun isPersonalSender(sender: String, k: ClassifierRules): Boolean {
        if (sender.isEmpty() || sender.any { it.isLetter() }) return false
        if (!sender.all { it.isDigit() || it in " +()-." }) return false
        return sender.count { it.isDigit() } in k.personalDigitsMin..k.personalDigitsMax
    }
}
