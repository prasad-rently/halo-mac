package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assume.assumeTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * HaloCloudKit (iOS) <-> the REAL Kotlin engines, through android/tools/fake-firebase.py. Driven by
 * ios/HaloCloudKit/scripts/e2e-kotlin-ios.sh, which copies this file into android/halocloud/src/test for the run and removes
 * it afterwards (so the android module is not modified by the iOS PR). Skipped unless HALO_E2E_PORT is set.
 *
 *   publish: real SmsSyncEngine.sync() (2 SIM lines, 2 messages) + real ClipboardSyncEngine.publish() -> iOS reads them
 *   verify:  the iOS package published a clipboard item -> the real Kotlin ClipboardSyncEngine.observe() decodes it
 */
class IosInteropE2E {
    private val port = System.getenv("HALO_E2E_PORT")
    private val mode = System.getenv("HALO_E2E_MODE") ?: ""

    private fun client(): FirebaseRtdbClient {
        val origin = "http://127.0.0.1:$port"
        val c = FirebaseRtdbClient(
            FirebaseConfig("any", "p", "a", "g", origin), CloudAuthCredential("me@halo.test", "halo-test-password"),
            AuthEndpoints("$origin/identitytoolkit/v1", "$origin/securetoken/v1"), allowInsecureDatabase = true)
        c.signIn(); return c
    }
    private fun crypto(): CryptoService = CryptoService.create(
        System.getenv("HALO_E2E_PASSPHRASE")!!, Base64.getDecoder().decode(System.getenv("HALO_E2E_SALT_B64")!!), System.getenv("HALO_E2E_ITERATIONS")!!.toInt())

    private class Src : SmsSource {
        private val demo = System.getenv("HALO_E2E_DEMO") == "1"
        val rows = listOf(
            1 to SmsRecord(9001, "VM-HDFCBK", "Rs 500.00 debited from a/c XX1234. Avl bal Rs 9,500.", 1_799_996_400_000, 77, 1, read = false, seen = true),
            2 to SmsRecord(9002, "+91 98765 43210", "Kotlin says hi ✅ café / ok", 1_799_998_200_000, 78, 2, read = true, seen = true),
        ) + if (!demo) emptyList() else listOf(
            // Extra rows for the Simulator walkthrough only (HALO_E2E_DEMO=1); the e2e assertions use the two above.
            1 to SmsRecord(9003, "AX-AXISBK", "482913 is the OTP for your Axis transaction. Do not share.", 1_799_999_000_000, 79, 1, read = false, seen = true),
            1 to SmsRecord(9004, "VM-HDFCBK", "Rs 1,250.00 debited via UPI. Avl bal Rs 8,250.", 1_799_999_500_000, 77, 1, read = false, seen = true),
            2 to SmsRecord(9005, "Amazon", "Your order has shipped and will arrive tomorrow.", 1_799_999_700_000, 80, 2, read = true, seen = true),
        )
        override fun lines() = listOf(SimLine(1, "Airtel", "+919876543210", "Personal"), SimLine(2, "Jio", "", "Work"))
        override fun inbox(subscriptionId: Int, sinceMs: Long) = rows.filter { it.first == subscriptionId && it.second.dateMs >= sinceMs }.map { it.second }
        override fun allMessageIds() = rows.map { SmsWire.messageId(it.second) }.toSet()
    }

    @Test fun publishFromKotlin() {
        assumeTrue(port != null && mode == "publish")
        val db = client(); val crypto = crypto()
        val demo = System.getenv("HALO_E2E_DEMO") == "1"
        val report = SmsSyncEngine(db, crypto, "kotlin-dev", "Pixel (Kotlin engine)", Src(), MemorySyncState(), clock = { 1_800_000_000_000 }).sync()
        assertTrue(report.ok); assertEquals(if (demo) 5 else 2, report.uploaded)
        val clip = ClipboardSyncEngine(db, crypto, "kotlin-dev", "Pixel (Kotlin engine)").publish("hello from Kotlin ✨ https://example.com/x?y=1")
        assertEquals(ClipboardSyncEngine.Publish.Sent, clip)
    }

    @Test fun verifyIosClipboardItemDecodesInTheKotlinEngine() {
        assumeTrue(port != null && mode == "verify")
        val db = client(); val crypto = crypto()
        val expected = File(System.getenv("HALO_E2E_EXPECT_FILE")!!).readText()
        val latch = CountDownLatch(1); var got: RemoteClip? = null
        // The real receive path: a DIFFERENT device id than the iOS app's, so the item is not dropped as an echo.
        val engine = ClipboardSyncEngine(db, crypto, "kotlin-dev", "Pixel (Kotlin engine)")
        val h = engine.observe { c -> if (c.deviceName == "iPhone (HaloCloudKit)") { got = c; latch.countDown() } }
        try { assertTrue("iOS item not received", latch.await(15, TimeUnit.SECONDS)) } finally { h.close() }
        assertEquals(expected, got!!.text)
        // and the node is structurally what the desktop/Kotlin parser accepts
        val items = db.get("clipboard/${db.uid}/items") as JsonObject
        val node = items.values.map { it as JsonObject }.first { (it["deviceName"] as JsonPrimitive).contentOrNull == "iPhone (HaloCloudKit)" }
        assertTrue(ClipboardEnvelope.from(node) != null)
    }
}
