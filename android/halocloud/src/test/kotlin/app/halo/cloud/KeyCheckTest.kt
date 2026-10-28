package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class KeyCheckTest {
    private val right = testCrypto()
    private val wrong = CryptoService.create("not the right passphrase", ByteArray(16) { it.toByte() }, CryptoService.MINIMUM_ITERATIONS)

    @Test fun `an empty database has nothing to test against`() = assertEquals(KeyCheck.Result.NO_SAMPLE, KeyCheck.verify(FakeRtdb(), right))

    @Test fun `the right passphrase opens a clipboard sample, the wrong one does not`() {
        val db = FakeRtdb()
        db.put("clipboard/uid-1/items/a", JsonObject(mapOf("contentEnc" to JsonPrimitive(right.encrypt("hi")))))
        assertEquals(KeyCheck.Result.MATCH, KeyCheck.verify(db, right))
        assertEquals(KeyCheck.Result.MISMATCH, KeyCheck.verify(db, wrong))
    }

    @Test fun `SMS line and message samples are used too`() {
        val db = FakeRtdb()
        db.put("sms/uid-1/dev/lines/1", JsonObject(mapOf("ownNumberEnc" to JsonPrimitive(right.encrypt("+91")))))
        assertEquals(KeyCheck.Result.MATCH, KeyCheck.verify(db, right)); assertEquals(KeyCheck.Result.MISMATCH, KeyCheck.verify(db, wrong))
        val db2 = FakeRtdb()
        db2.put("sms/uid-1/dev/messages/1_2", JsonObject(mapOf("bodyEnc" to JsonPrimitive(right.encrypt("x")))))
        assertEquals(KeyCheck.Result.MATCH, KeyCheck.verify(db2, right))
    }

    @Test fun `plaintext or malformed rows count as no usable sample, not a match`() {
        val db = FakeRtdb()
        db.put("clipboard/uid-1/items/a", JsonObject(mapOf("contentEnc" to JsonPrimitive(1))))
        assertEquals(KeyCheck.Result.NO_SAMPLE, KeyCheck.verify(db, right))
    }
}
