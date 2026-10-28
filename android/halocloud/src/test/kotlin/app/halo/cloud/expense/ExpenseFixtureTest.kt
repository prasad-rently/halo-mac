package app.halo.cloud.expense

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId

/**
 * The cross-language contract (F-056 FR-E1/E2): docs/specs/pattern-packs/expense-fixtures.v1.json, whose `expect`
 * blocks were recorded from the REAL Swift desktop implementation (HaloTests ExpenseFixtureTests re-checks it).
 * This Kotlin port must agree on parse / amount / direction / merchant / account / category, and on every
 * pipeline outcome. The ONE place it may legitimately differ is `expect.classifierKotlin` — see that field's note.
 */
class ExpenseFixtureTest {
    private val pack = PatternPack.indiaDefault
    private val root: JsonObject = Json.parseToJsonElement(File(System.getProperty("halo.expenseFixtures")!!).readText()).jsonObject
    private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    @Test fun `every single-message fixture agrees with the desktop`() {
        val msgs = root["messages"]!!.jsonArray
        assertTrue("fixture set must be substantial", msgs.size >= 50)
        val bad = ArrayList<String>()
        for (e in msgs) {
            val m = e.jsonObject; val id = m.s("id")!!; val x = m["expect"]!!.jsonObject
            val sender = m.s("sender")!!; val body = m.s("body")!!
            val cls = SmsClassifier.classify(sender, body, pack).wire
            val wantCls = x.s("classifierKotlin") ?: x.s("classifier")
            if (cls != wantCls) bad += "classifier $id: got $cls want $wantCls"

            val r = TransactionParser.parse(sender, body, id, 0L, pack)
            when (r) {
                ParseOutcome.NotTransaction -> if (x.s("parse") != "notTransaction") bad += "parse $id: got notTransaction want ${x.s("parse")}"
                ParseOutcome.Unreadable -> if (x.s("parse") != "unreadable") bad += "parse $id: got unreadable want ${x.s("parse")}"
                is ParseOutcome.Ok -> {
                    val t = r.txn
                    if (x.s("parse") != "ok") bad += "parse $id: got ok want ${x.s("parse")}"
                    else {
                        if (t.amount != x["amount"]!!.jsonPrimitive.double) bad += "amount $id: ${t.amount} vs ${x["amount"]}"
                        if (t.direction.wire != x.s("direction")) bad += "direction $id: ${t.direction.wire} vs ${x.s("direction")}"
                        if (t.merchant != x.s("merchant")) bad += "merchant $id: ${t.merchant} vs ${x.s("merchant")}"
                        if (t.accountHint != x.s("accountHint")) bad += "account $id: ${t.accountHint} vs ${x.s("accountHint")}"
                        val c = pack.category(t.merchant, t.body, t.direction)
                        if (c != x.s("category")) bad += "category $id: $c vs ${x.s("category")}"
                    }
                }
            }
        }
        assertTrue("Kotlin disagrees with the Swift-recorded fixtures:\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun `classifierKotlin divergences never create or hide a transaction - the parser rejects the message either way`() {
        val diverging = root["messages"]!!.jsonArray.map { it.jsonObject }.filter { it["expect"]!!.jsonObject.s("classifierKotlin") != null }
        assertTrue("at least the two known divergences", diverging.size >= 2)
        for (m in diverging) {
            val x = m["expect"]!!.jsonObject
            assertEquals("${m.s("id")}: a message the classifiers disagree on must not be a transaction on either side", "notTransaction", x.s("parse"))
        }
    }

    private fun runPipelines(zone: ZoneId) {
        val bad = ArrayList<String>()
        for (pe in root["pipelines"]!!.jsonArray) {
            val p = pe.jsonObject; val name = p.s("name")!!
            val ov = ExpenseOverrides(
                excludedIds = (p["excluded"] as? JsonArray)?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet(),
                includedIds = (p["included"] as? JsonArray)?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet(),
                categoryById = (p["categoryById"] as? JsonObject)?.mapValues { it.value.jsonPrimitive.content } ?: emptyMap())
            val msgs = p["messages"]!!.jsonArray.map {
                val o = it.jsonObject
                SmsInput(o.s("id")!!, o.s("sender")!!, o.s("body")!!, o["tsMs"]!!.jsonPrimitive.long, SmsClassifier.classify(o.s("sender")!!, o.s("body")!!, pack))
            }
            val res = TransactionPipeline.run(msgs, pack, ov, zone)
            if (res.unreadableCount != p["expectUnreadable"]!!.jsonPrimitive.int) bad += "$name unreadable ${res.unreadableCount}"
            val want = p["expect"]!!.jsonArray
            if (res.transactions.size != want.size) bad += "$name count ${res.transactions.size} vs ${want.size}: ${res.transactions.map { it.id }}"
            for (we in want) {
                val w = we.jsonObject; val id = w.s("id")!!
                val g = res.transactions.firstOrNull { it.id == id } ?: run { bad += "$name missing $id"; null } ?: continue
                if (g.amount != w["amount"]!!.jsonPrimitive.double || g.direction.wire != w.s("direction")) bad += "$name/$id amount/direction"
                if (g.category != w.s("category")) bad += "$name/$id category ${g.category} vs ${w.s("category")}"
                if (g.isTransfer != w["isTransfer"]!!.jsonPrimitive.boolean || g.isDuplicate != w["isDuplicate"]!!.jsonPrimitive.boolean
                    || g.countsTowardTotals != w["countsTowardTotals"]!!.jsonPrimitive.boolean) bad += "$name/$id flags t=${g.isTransfer} d=${g.isDuplicate}"
            }
        }
        assertTrue("pipeline mismatch ($zone):\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun `pipeline fixtures - self-transfer, near-duplicate window, overrides, unreadable tally`() = runPipelines(ZoneId.of("Asia/Kolkata"))

    // The self-transfer rule buckets by calendar day, so it depends on the zone. The fixtures' pairs sit minutes apart
    // mid-day in IST and never straddle local midnight in any real zone — prove it for a few.
    @Test fun `pipeline fixtures hold in other zones`() { runPipelines(ZoneId.of("UTC")); runPipelines(ZoneId.of("America/Los_Angeles")); runPipelines(ZoneId.of("Pacific/Kiritimati")) }

    @Test fun `the shared pack is the one on the classpath - word lists the desktop test also pins`() {
        val j = Json.parseToJsonElement(File(System.getProperty("halo.expenseFixtures")!!).parentFile.resolve("india-bank-sms.v1.json").readText()).jsonObject
        val parser = j["parser"]!!.jsonObject
        fun l(k: String) = parser[k]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(l("debitWords"), pack.debitWords); assertEquals(l("creditWords"), pack.creditWords)
        assertEquals(l("excludeWords"), pack.excludeWords); assertEquals(l("promoWords"), pack.promoWords)
        assertEquals(l("nonBankSenders"), pack.nonBankSenders); assertEquals(l("balancePrefix"), pack.balancePrefix)
        assertEquals(parser["amountRegex"]!!.jsonPrimitive.content, pack.amount.pattern())
        assertEquals(9, pack.categories.size)
    }
}
