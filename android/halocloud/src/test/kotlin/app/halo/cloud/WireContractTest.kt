package app.halo.cloud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * H-20 (Kotlin half). The phone's wire format is a contract with the Mac, and until now nothing tested it across
 * the language boundary: the Swift suite decoded hand-written JSON and the Kotlin suite checked fields it chose
 * itself, so a renamed field could pass both.
 *
 * `docs/specs/wire-contract/phone-nodes.v1.json` is the shared fixture (the desktop's HaloTests decode the same file).
 *  - producer: the REAL writers (SmsSyncEngine, ClipboardEnvelope.node, SmsWire) are run over the fixture's scenario
 *    and each node must equal the fixture's — same field names, same value types, same plaintext behind every `*Enc`;
 *  - consumer: every fixture ciphertext must open under the fixture's own key to its `expect`ed plaintext, and the
 *    clipboard nodes must parse with the phone's own reader.
 * Ciphertext is randomly nonced, so it is compared by what it opens to, never by bytes. Rename a field on either side
 * and one of the two suites fails.
 */
class WireContractTest {
    private val fx: JsonObject = Json.parseToJsonElement(File(System.getProperty("halo.wireContract") ?: error("halo.wireContract not set")).readText()).jsonObject
    private val cryptoBlock = fx.getValue("crypto").jsonObject
    private val crypto = CryptoService.create(
        cryptoBlock.getValue("passphrase").jsonPrimitive.content,
        Base64.getDecoder().decode(cryptoBlock.getValue("saltBase64").jsonPrimitive.content),
        cryptoBlock.getValue("iterations").jsonPrimitive.content.toInt(),
    )
    private val uid = fx.getValue("uid").jsonPrimitive.content
    private val deviceId = fx.getValue("deviceId").jsonPrimitive.content
    private val nowMs = 1_800_000_000_000L
    private fun JsonObject.arr(k: String): List<JsonObject> = getValue(k).jsonArray.map { it.jsonObject }
    private fun JsonObject.s(k: String) = getValue(k).jsonPrimitive.content
    private fun JsonObject.l(k: String) = getValue(k).jsonPrimitive.content.toLong()

    private class Source(val lines: List<SimLine>, val rows: List<SmsRecord>) : SmsSource {
        override fun lines() = lines
        override fun inbox(subscriptionId: Int, sinceMs: Long) = rows.filter { it.subscriptionId == subscriptionId && it.dateMs >= sinceMs }
        override fun allMessageIds() = rows.map { SmsWire.messageId(it) }.toSet()
    }

    /** `*Enc` fields replaced by what they open to; the only comparable form of a randomly-nonced ciphertext. */
    private fun opened(node: JsonObject, ignore: Set<String> = emptySet()): JsonObject = JsonObject(
        node.filterKeys { it !in ignore }.mapValues { (k, v) -> if (k.endsWith("Enc")) buildJsonObject { put("opensTo", crypto.decrypt(v.jsonPrimitive.content)) } else v }.toSortedMap()
    )

    private fun sameNode(what: String, want: JsonObject, got: JsonObject, ignoreInGot: Set<String> = emptySet()) =
        assertEquals(what, opened(want), opened(got, ignoreInGot))

    /** What the phone's SMS engine writes for the fixture's scenario. */
    private fun runSmsEngine(): FakeRtdb {
        val db = FakeRtdb(uid)
        val lines = fx.arr("lines")
        // The desktop owns `syncEnabled` (D29): the fixture's second line carries it, as if the Mac had toggled it.
        for (l in lines) if ("syncEnabled" in l.getValue("node").jsonObject) db.put("sms/$uid/$deviceId/lines/${l.s("key")}/syncEnabled", l.getValue("node").jsonObject.getValue("syncEnabled"))
        val simLines = lines.map { l ->
            val n = l.getValue("node").jsonObject; val e = l.getValue("expect").jsonObject
            SimLine(n.s("subscriptionId").toInt(), n.s("carrier"), e.s("ownNumber").let { if (it == "Unknown") "" else it }, n.s("label"))
        }
        val rows = fx.arr("messages").map { m ->
            val n = m.getValue("node").jsonObject; val e = m.getValue("expect").jsonObject
            SmsRecord(m.s("key").substringBefore('_').toLong(), e.s("address"), e.s("body"), e.l("dateMs"), n.l("threadId"), e.s("subscriptionId").toInt(),
                read = n.getValue("read").jsonPrimitive.booleanOrNull!!, seen = n.getValue("seen").jsonPrimitive.booleanOrNull!!, serviceCenter = (n["serviceCenter"] as? JsonPrimitive)?.content)
        }
        SmsSyncEngine(db, crypto, deviceId, "Pixel 8", Source(simLines, rows), MemorySyncState(), { SenderFilter() }, { 90 }, { nowMs }).sync()
        return db
    }

    @Test fun `producer - the phone's SMS engine writes the fixture's device, line and message nodes`() {
        val db = runSmsEngine()
        sameNode("device", fx.getValue("device").jsonObject.getValue("node").jsonObject, db.dump("devices/$uid/$deviceId") as JsonObject)
        for (l in fx.arr("lines")) {
            val got = db.dump("sms/$uid/$deviceId/lines/${l.s("key")}") as JsonObject
            // lineVersion/updatedAt are the H-21b additions the shared fixture does not carry yet (see README there).
            sameNode("line ${l.s("key")}", l.getValue("node").jsonObject, got, ignoreInGot = H21_FIELDS)
            assertTrue("line ${l.s("key")} must carry the H-21 change signal", H21_FIELDS.all { it in got })
        }
        for (m in fx.arr("messages")) sameNode("message ${m.s("key")}", m.getValue("node").jsonObject, db.dump("sms/$uid/$deviceId/messages/${m.s("key")}") as JsonObject)
    }

    @Test fun `producer - ClipboardEnvelope writes the fixture's clipboard nodes, and the engine's own item has the same field set`() {
        for (c in fx.arr("clipboard")) {
            val n = c.getValue("node").jsonObject; val e = c.getValue("expect").jsonObject
            val language = (e["language"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
            val got = ClipboardEnvelope(n.s("itemId"), n.s("deviceId"), n.s("deviceName"), n.s("kind"), crypto.encrypt(e.s("text")), language, n.l("createdAt").toDouble()).node()
            sameNode("clipboard ${c.s("key")}", n, got)
        }
        // And what ClipboardSyncEngine really publishes has exactly the fixture's field names (minus the optional `language`).
        val db = FakeRtdb(uid); ClipboardSyncEngine(db, crypto, deviceId, "Pixel 8", { false }, { nowMs }).publish("hello from the phone")
        val published = (db.dump("clipboard/$uid/items") as JsonObject).values.single() as JsonObject
        assertEquals(fx.arr("clipboard").first().getValue("node").jsonObject.keys, published.keys)
    }

    @Test fun `consumer - every fixture ciphertext opens under the fixture's key to its expected plaintext, and clipboard nodes parse`() {
        for (l in fx.arr("lines")) assertEquals(l.getValue("expect").jsonObject.s("ownNumber"), crypto.decrypt(l.getValue("node").jsonObject.s("ownNumberEnc")))
        for (m in fx.arr("messages")) {
            val n = m.getValue("node").jsonObject; val e = m.getValue("expect").jsonObject
            assertEquals(e.s("address"), crypto.decrypt(n.s("addressEnc"))); assertEquals(e.s("body"), crypto.decrypt(n.s("bodyEnc")))
        }
        for (c in fx.arr("clipboard")) {
            val n = c.getValue("node").jsonObject; val e = c.getValue("expect").jsonObject
            val env = ClipboardEnvelope.from(n)
            assertNotNull("ClipboardEnvelope.from rejected ${c.s("key")}", env)
            assertEquals(e.s("text"), crypto.decrypt(env!!.contentEnc)); assertEquals(e.s("kind"), env.kind); assertEquals(e.l("createdAt"), env.createdAtMs.toLong())
        }
    }

    private companion object { val H21_FIELDS = setOf("lineVersion", "updatedAt") }
}
