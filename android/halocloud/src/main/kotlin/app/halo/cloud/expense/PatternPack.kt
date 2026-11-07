package app.halo.cloud.expense

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.util.regex.Pattern

// F-056 / F-048 D16. The phone half of the expenditure tracker is driven by the SAME pattern pack as the
// desktop: docs/specs/pattern-packs/india-bank-sms.v1.json. The Gradle build packages that one file into
// this module's resources (halocloud/build.gradle.kts), so there is no second copy to drift. Nothing in
// this package touches the network: amounts are sensitive and cloud sync of derived data is a v2.7 decision.

/** One §12 spend-category rule: first rule with any trigger as a substring of UPPER(merchant + " " + body) wins. */
data class CategoryRule(
    val category: String,
    /** Substring triggers. */
    val triggers: List<String>,
    /** Whole-word triggers (v2): must not sit inside a longer run of A-Z letters, so CRED does not match CREDITED. */
    val wordTriggers: List<String> = emptyList(),
)

/** The pack's classifier section (F-044 §7.4). */
data class ClassifierRules(
    val otpKeywords: List<String>,
    val otpNumber: Pattern,
    val govSenders: List<String>,
    val govKeywords: List<String>,
    val transactionalStrong: List<String>,
    val moneyTokens: List<String>,
    val transactionalVerbs: List<String>,
    val serviceKeywords: List<String>,
    val promoKeywords: List<String>,
    val personalDigitsMin: Int,
    val personalDigitsMax: Int,
)

class PatternPack(
    val id: String,
    val version: Int,
    val currency: String,
    val balanceContextChars: Int,
    val dedupWindowMs: Long,
    val amount: Pattern,
    val account: Pattern,
    val merchant: Pattern,
    val debitWords: List<String>,
    val creditWords: List<String>,
    val excludeWords: List<String>,
    /** Regexes over the UPPERCASED body; a hit means NotTransaction (credit-card bill-payment acknowledgements). */
    val rejectPatterns: List<Pattern>,
    val promoWords: List<String>,
    val nonBankSenders: List<String>,
    val balancePrefix: List<String>,
    /** Where a "sentence" ends when looking back from an amount for a balance word. */
    val balanceClauseBoundary: Pattern,
    /** Matched at the start of the text right after an amount: "is your available balance". */
    val balanceAfter: Pattern,
    val categories: List<CategoryRule>,
    val classifier: ClassifierRules,
) {
    /**
     * First rule whose any trigger appears in merchant+body -> its category; a credit is always Income;
     * otherwise Other. (Self-transfers are set separately by the pipeline, D7.)
     */
    fun category(merchant: String?, body: String, direction: Direction): String {
        if (direction == Direction.CREDIT) return "Income"
        val hay = ((merchant ?: "") + " " + body).uppercase()
        for (rule in categories) if (rule.triggers.any { hay.contains(it) } || rule.wordTriggers.any { containsWord(hay, it) }) return rule.category
        return "Other"
    }

    /** All names for a UI legend: the pack's rules plus the synthetic Income / Transfers / Other. */
    val allCategoryNames: List<String> get() = categories.map { it.category }.filter { it != "Transfers" } + listOf("Income", "Transfers", "Other")

    companion object {
        /** A-Z letters only: the boundary test for word triggers and balance words (the text is already uppercased). */
        internal fun isLetter(c: Char) = c in 'A'..'Z'

        /** True when [word] occurs in [hay] with no A-Z letter immediately before or after it. */
        fun containsWord(hay: String, word: String): Boolean {
            var from = 0
            while (true) {
                val i = hay.indexOf(word, from)
                if (i < 0) return false
                val before = i == 0 || !isLetter(hay[i - 1])
                val after = i + word.length >= hay.length || !isLetter(hay[i + word.length])
                if (before && after) return true
                from = i + 1
            }
        }

        const val RESOURCE = "/india-bank-sms.v1.json"

        /** The pack that ships with the app, read from the one shared file. */
        val indiaDefault: PatternPack by lazy {
            val s = PatternPack::class.java.getResourceAsStream(RESOURCE)
                ?: error("$RESOURCE is not on the classpath — halocloud's processResources should package docs/specs/pattern-packs/india-bank-sms.v1.json")
            parse(s.use { String(it.readBytes(), Charsets.UTF_8) })
        }

        private fun JsonArray.strings() = map { it.jsonPrimitive.content }
        private fun JsonObject.list(k: String) = (this[k] ?: error("pattern pack: missing '$k'")).jsonArray.strings()
        private fun JsonObject.str(k: String) = (this[k] ?: error("pattern pack: missing '$k'")).jsonPrimitive.content

        fun parse(text: String): PatternPack {
            val root = Json.parseToJsonElement(text).jsonObject
            val tuning = root["tuning"]!!.jsonObject
            val c = root["classifier"]!!.jsonObject
            val p = root["parser"]!!.jsonObject
            val cats = root["categories"]!!.jsonObject["rules"]!!.jsonArray.map {
                val o = it.jsonObject; CategoryRule(o.str("category"), o.list("triggers"), if (o["wordTriggers"] == null) emptyList() else o.list("wordTriggers"))
            }
            return PatternPack(
                id = root.str("id"),
                version = (root["version"] as JsonPrimitive).int,
                currency = root.str("currency"),
                balanceContextChars = tuning["balanceContextChars"]!!.jsonPrimitive.int,
                dedupWindowMs = tuning["dedupWindowMs"]!!.jsonPrimitive.long,
                // The pack's regexes are written case-tolerant ("at"/"to"/"x"); the parser runs them over the
                // UPPERCASED body, exactly as the desktop does with its uppercased copies of the same patterns.
                amount = Pattern.compile(p.str("amountRegex"), Pattern.CASE_INSENSITIVE),
                account = Pattern.compile(p.str("accountRegex"), Pattern.CASE_INSENSITIVE),
                merchant = Pattern.compile(p.str("merchantRegex"), Pattern.CASE_INSENSITIVE),
                debitWords = p.list("debitWords"),
                creditWords = p.list("creditWords"),
                excludeWords = p.list("excludeWords"),
                rejectPatterns = p.list("rejectPatterns").map { Pattern.compile(it) },
                promoWords = p.list("promoWords"),
                nonBankSenders = p.list("nonBankSenders"),
                balancePrefix = p.list("balancePrefix"),
                balanceClauseBoundary = Pattern.compile(p.str("balanceClauseBoundaryRegex")),
                balanceAfter = Pattern.compile(p.str("balanceAfterRegex")),
                categories = cats,
                classifier = ClassifierRules(
                    otpKeywords = c.list("otpKeywords"),
                    otpNumber = Pattern.compile(c.str("otpNumberRegex"), Pattern.CASE_INSENSITIVE),
                    govSenders = c.list("govSenders"),
                    govKeywords = c.list("govKeywords"),
                    transactionalStrong = c.list("transactionalStrong"),
                    moneyTokens = c.list("moneyTokens"),
                    transactionalVerbs = c.list("transactionalVerbs"),
                    serviceKeywords = c.list("serviceKeywords"),
                    promoKeywords = c.list("promoKeywords"),
                    personalDigitsMin = tuning["personalSenderDigitsMin"]!!.jsonPrimitive.int,
                    personalDigitsMax = tuning["personalSenderDigitsMax"]!!.jsonPrimitive.int,
                ),
            )
        }
    }
}
