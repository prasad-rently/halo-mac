package app.halo.cloud.expense

import app.halo.cloud.SimLine
import app.halo.cloud.SmsRecord
import app.halo.cloud.SmsSource
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Software AES-256-GCM stand-in for the Keystore-backed SecretBox: same `iv || ct || tag` shape. */
class AesGcmSealer(private val key: ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }) : Sealer {
    override fun seal(plain: ByteArray): ByteArray {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return iv + c.doFinal(plain)
    }
    override fun open(blob: ByteArray): ByteArray {
        require(blob.size > 12) { "sealed blob too short" }
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, blob, 0, 12))
        return c.doFinal(blob, 12, blob.size - 12)
    }
}

/** In-memory inbox. [read] counts rows handed out so tests can prove a second run is incremental. */
class FakeSmsSource(var rows: List<SmsRecord> = emptyList(), var simLines: List<SimLine> = listOf(SimLine(1, "Airtel", "", "SIM 1"))) : SmsSource {
    var read = 0
    var denied = false
    override fun lines(): List<SimLine> { if (denied) throw SecurityException("no READ_SMS"); return simLines }
    override fun inbox(subscriptionId: Int, sinceMs: Long): List<SmsRecord> {
        if (denied) throw SecurityException("no READ_SMS")
        return rows.filter { it.subscriptionId == subscriptionId && it.dateMs >= sinceMs }.sortedBy { it.dateMs }.also { read += it.size }
    }
    override fun allMessageIds(): Set<String> = rows.map { "${it.smsId}_${it.dateMs}" }.toSet()
}

fun sms(id: Long, sender: String, body: String, dateMs: Long, sub: Int = 1) =
    SmsRecord(smsId = id, address = sender, body = body, dateMs = dateMs, threadId = 1, subscriptionId = sub, read = true, seen = true)
