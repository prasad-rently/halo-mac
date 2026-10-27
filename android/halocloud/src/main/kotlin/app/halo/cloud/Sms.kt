package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// F-044 §7 wire format for the phone -> cloud half of the SMS console. The desktop reads exactly these
// fields (Halo/Features/SMSConsole/SMSSyncClient.swift): message `addressEnc`/`bodyEnc`/`date`/
// `subscriptionId`/`read`, line `label`/`ownNumberEnc`/`carrier`/`syncEnabled`, device `name`/`platform`.

/** One inbox row as read from the device's SMS provider. */
data class SmsRecord(
    val smsId: Long,
    /** The OTHER party — the sender, for an inbox row. */
    val address: String,
    val body: String,
    val dateMs: Long,
    val threadId: Long,
    /** Which SIM received it; -1 when the device doesn't say. */
    val subscriptionId: Int,
    val read: Boolean,
    val seen: Boolean,
    val serviceCenter: String? = null,
)

/** One SIM on this device. [ownNumber] is blank when the carrier hasn't provisioned it (D20). */
data class SimLine(
    val subscriptionId: Int,
    val carrier: String,
    val ownNumber: String,
    val label: String,
)

object SmsWire {
    const val SCHEMA = 1

    /** `{smsId}_{timestamp}` — idempotent: re-uploading the same row overwrites itself (D14). */
    fun messageId(r: SmsRecord): String = "${r.smsId}_${r.dateMs}"

    /** Strip everything but digits and a leading +, so `+91 98765-43210` and `919876543210` thread together. */
    fun normalizeNumber(raw: String): String {
        val t = raw.trim()
        if (t.any { it.isLetter() }) return t.lowercase()          // an alphanumeric sender id (VM-HDFCBK)
        val digits = t.filter { it.isDigit() }
        return if (t.startsWith("+")) "+$digits" else digits
    }

    fun threadKey(crypto: CryptoService, deviceId: String, r: SmsRecord): String =
        crypto.keyedHash("halo.threadkey.v1", "$deviceId|${r.subscriptionId}|${normalizeNumber(r.address)}")

    fun messageNode(r: SmsRecord, crypto: CryptoService, deviceId: String, syncedAtMs: Long): JsonObject {
        val m = linkedMapOf(
            "addressEnc" to JsonPrimitive(crypto.encrypt(r.address)),
            "bodyEnc" to JsonPrimitive(crypto.encrypt(r.body)),
            "threadKey" to JsonPrimitive(threadKey(crypto, deviceId, r)),
            "threadId" to JsonPrimitive(r.threadId),
            "subscriptionId" to JsonPrimitive(r.subscriptionId),
            "date" to JsonPrimitive(r.dateMs),
            "type" to JsonPrimitive(1),                           // inbox only in v1 (D23)
            "read" to JsonPrimitive(r.read),
            "seen" to JsonPrimitive(r.seen),
            "syncedAt" to JsonPrimitive(syncedAtMs),
            "schema" to JsonPrimitive(SCHEMA),
        )
        r.serviceCenter?.let { m["serviceCenter"] = JsonPrimitive(it) }
        return JsonObject(m)
    }

    /** `syncEnabled` is deliberately absent: the desktop (or this app) owns it, and a sync must not reset it. */
    fun lineNode(l: SimLine, crypto: CryptoService): JsonObject = JsonObject(mapOf(
        "subscriptionId" to JsonPrimitive(l.subscriptionId),
        "label" to JsonPrimitive(l.label),
        "carrier" to JsonPrimitive(l.carrier),
        "ownNumberEnc" to JsonPrimitive(crypto.encrypt(l.ownNumber.ifBlank { "Unknown" })),
    ))

    fun deviceNode(name: String, nowMs: Long): JsonObject = JsonObject(mapOf(
        "name" to JsonPrimitive(name),
        "platform" to JsonPrimitive("android"),
        "lastSeen" to JsonPrimitive(nowMs),
    ))
}
