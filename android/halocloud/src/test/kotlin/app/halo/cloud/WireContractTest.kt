package app.halo.cloud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
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
 * `docs/specs/wire-contract/phone-nodes.v1.json` is a committed fixture of every node kind the phone writes
 * (device, SIM line, SMS message, clipboard item), produced by THIS code. Two directions:
 *  - producer: the real engines are run on an in-memory database and their output must equal the fixture
 *    (same paths, same field names, same value types, same plaintext behind every `*Enc` field);
 *  - consumer: the fixture's ciphertexts must open under the documented key, and the clipboard node must parse
 *    with the phone's own reader.
 * The Swift desktop tests decode the same file (their half lives in HaloTests). Rename a field on either side
 * and one of the two suites goes red.
 *
 * Ciphertexts are randomly nonced, so they cannot be compared byte for byte; they are compared by what they open to.
 * Regenerate (after an INTENDED contract change, and tell the Swift side):
 *   HALO_WIRE_CONTRACT_WRITE=1 ./gradlew :halocloud:test --tests '*WireContractTest*'
 */
class WireContractTest {
    private val pretty = Json { prettyPrint = true; prettyPrintIndent = "  " }
    private val nowMs = 1_800_000_000_000L
    private val passphrase = "correct horse battery staple"
    private val salt = ByteArray(16) { it.toByte() }
    private val clipId = "00000000-0000-4000-8000-0000000000C1"

    private class Source(val lines: List<SimLine>, val rows: List<SmsRecord>) : SmsSource {
        override fun lines() = lines
        override fun inbox(subscriptionId: Int, sinceMs: Long) = rows.filter { it.subscriptionId == subscriptionId && it.dateMs >= sinceMs }
        override fun allMessageIds() = rows.map { SmsWire.messageId(it) }.toSet()
    }

    /** Run the real engines, return every node the phone wrote, keyed by path. */
    private fun produce(): Pair<LinkedHashMap<String, JsonObject>, FakeRtdb> {
        val db = FakeRtdb("uid-1"); val crypto = testCrypto()
        val rows = listOf(
            SmsRecord(42, "VM-HDFCBK", "Rs 500.00 debited from a/c XX1234 on 15-Jan. Avl bal Rs 9,500.00 — héllo ✓", nowMs - 3_600_000, 7, 1, read = false, seen = true, serviceCenter = "+919810051914"),
            SmsRecord(43, "+91 98765 43210", "See you at 5", nowMs - 1_800_000, 8, 2, read = true, seen = true),
        )
        SmsSyncEngine(db, crypto, "dev-A", "Pixel 8", Source(listOf(SimLine(1, "Airtel", "+919876543210", "Personal"), SimLine(2, "Jio", "", "Work")), rows), MemorySyncState(), { SenderFilter() }, { 90 }, { nowMs }).sync()
        ClipboardSyncEngine(db, crypto, "dev-A", "Pixel 8", { false }, { nowMs }).publish("https://halo.app/x?y=1")

        val out = LinkedHashMap<String, JsonObject>()
        fun grab(path: String) { out[path] = db.dump(path) as JsonObject }
        grab("devices/uid-1/dev-A")
        grab("sms/uid-1/dev-A/lines/1"); grab("sms/uid-1/dev-A/lines/2")
        grab("sms/uid-1/dev-A/messages/${SmsWire.messageId(rows[0])}"); grab("sms/uid-1/dev-A/messages/${SmsWire.messageId(rows[1])}")
        val itemKey = (db.dump("clipboard/uid-1/items") as JsonObject).keys.single()
        // The item id is random per publish; the fixture pins it so the Swift side has a stable key.
        val item = db.dump("clipboard/uid-1/items/$itemKey") as JsonObject
        out["clipboard/uid-1/items/$clipId"] = JsonObject(item.mapValues { (k, v) -> if (k == "itemId") JsonPrimitive(clipId) else v })
        return out to db
    }

    /** `*Enc` fields replaced by what they open to — the only comparable form of a randomly-nonced ciphertext. */
    private fun opened(node: JsonObject, crypto: CryptoService): JsonObject = JsonObject(node.mapValues { (k, v) ->
        if (k.endsWith("Enc")) buildJsonObject { put("decryptsTo", crypto.decrypt(v.jsonPrimitive.content)) } else v
    })

    private fun fixtureFile() = File(System.getProperty("halo.wireContract") ?: error("halo.wireContract not set"))

    private fun render(nodes: Map<String, JsonObject>, crypto: CryptoService): String {
        val root = buildJsonObject {
            put("version", 1)
            put("doc", "Nodes exactly as the Android phone writes them (produced by halocloud's real engines — see WireContractTest). Ciphertext fields are randomly nonced: compare what they decrypt to, not their bytes. The Swift HaloTests decode this same file.")
            put("crypto", buildJsonObject {
                put("passphrase", passphrase); put("saltB64", Base64.getEncoder().encodeToString(salt)); put("iterations", CryptoService.MINIMUM_ITERATIONS)
            })
            put("uid", "uid-1")
            put("nodes", JsonObject(nodes))
            put("decrypted", JsonObject(nodes.mapValues { (_, n) -> buildJsonObject { for ((k, v) in n) if (k.endsWith("Enc")) put(k, crypto.decrypt(v.jsonPrimitive.content)) } }.filterValues { it.isNotEmpty() }))
        }
        return pretty.encodeToString(JsonElement.serializer(), root) + "\n"
    }

    @Test fun `the phone's output equals the committed fixture, and the fixture opens under the documented key`() {
        val crypto = testCrypto()
        val (produced, _) = produce()
        val f = fixtureFile()
        if (System.getProperty("halo.wireContract.write") == "1") { f.parentFile.mkdirs(); f.writeText(render(produced, crypto)) }
        assertTrue("fixture missing: run once with HALO_WIRE_CONTRACT_WRITE=1 — $f", f.exists())

        val fixture = Json.parseToJsonElement(f.readText()).jsonObject
        // The fixture's key parameters are part of the contract the Swift side relies on.
        val c = fixture.getValue("crypto").jsonObject
        assertEquals(passphrase, c.getValue("passphrase").jsonPrimitive.content)
        assertEquals(Base64.getEncoder().encodeToString(salt), c.getValue("saltB64").jsonPrimitive.content)
        assertEquals(CryptoService.MINIMUM_ITERATIONS, c.getValue("iterations").jsonPrimitive.content.toInt())

        val nodes = fixture.getValue("nodes").jsonObject
        assertEquals("same set of node paths", nodes.keys.sorted(), produced.keys.sorted())
        for ((path, want) in nodes) {
            val got = produced.getValue(path)
            // Field names AND order-insensitive values, with encrypted fields compared by plaintext. A renamed,
            // dropped, added or retyped field fails here with the path in the message.
            assertEquals("node $path", sorted(opened(want.jsonObject, crypto)), sorted(opened(got, crypto)))
        }
    }

    @Test fun `consumer direction - the fixture's clipboard node parses with the phone's own reader and decrypts`() {
        val crypto = testCrypto()
        val nodes = Json.parseToJsonElement(fixtureFile().readText()).jsonObject.getValue("nodes").jsonObject
        val clip = nodes.getValue("clipboard/uid-1/items/$clipId")
        val env = ClipboardEnvelope.from(clip)
        assertNotNull("ClipboardEnvelope.from rejected the fixture's node", env)
        assertEquals("https://halo.app/x?y=1", crypto.decrypt(env!!.contentEnc))
        assertEquals("url", env.kind); assertEquals(clipId, env.itemId); assertEquals("dev-A", env.deviceId)
    }

    @Test fun `line nodes carry the H-21 change signal`() {
        val nodes = Json.parseToJsonElement(fixtureFile().readText()).jsonObject.getValue("nodes").jsonObject
        for (p in listOf("sms/uid-1/dev-A/lines/1", "sms/uid-1/dev-A/lines/2")) {
            val n = nodes.getValue(p).jsonObject
            assertTrue("$p lineVersion", "lineVersion" in n); assertTrue("$p updatedAt", "updatedAt" in n)
        }
    }

    private fun sorted(o: JsonObject): JsonObject = JsonObject(o.toSortedMap())
}
