package app.halo.cloud

import kotlinx.serialization.json.JsonElement
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

    /**
     * The registry node for one SIM line, written in ONE request. The desktop attaches a child_added observer
     * and reads a child exactly once, when it first appears — so a node written field by field is seen
     * half-built (no label, no number) and never refreshed. `syncEnabled` belongs to the desktop (D29): the
     * caller passes back the value it just read so this whole-node write cannot reset it.
     */
    fun lineNode(l: SimLine, crypto: CryptoService, syncEnabled: Boolean? = null): JsonObject {
        val m = linkedMapOf<String, JsonElement>(
            "subscriptionId" to JsonPrimitive(l.subscriptionId),
            "label" to JsonPrimitive(l.label),
            "carrier" to JsonPrimitive(l.carrier),
            "ownNumberEnc" to JsonPrimitive(crypto.encrypt(l.ownNumber.ifBlank { "Unknown" })),
        )
        syncEnabled?.let { m["syncEnabled"] = JsonPrimitive(it) }
        return JsonObject(m)
    }

    fun deviceNode(name: String, nowMs: Long): JsonObject = JsonObject(mapOf(
        "name" to JsonPrimitive(name),
        "platform" to JsonPrimitive("android"),
        "lastSeen" to JsonPrimitive(nowMs),
    ))
}

/**
 * Which SIM line a provider row belongs to. The `sub_id` column is not always populated: some devices and
 * Android versions leave it -1 even on a single-SIM phone. A row that names no SIM we can see must not be
 * dropped — with one SIM there is only one place it can have come from.
 */
object SimAttribution {
    fun owns(lineSub: Int, rowSub: Int, activeSubs: Set<Int>): Boolean = when {
        rowSub == lineSub -> true
        activeSubs.isEmpty() -> lineSub == -1               // no SIM list at all: everything is the one synthetic line
        activeSubs.size == 1 -> rowSub < 0 && lineSub == activeSubs.single()
        else -> false                                        // several SIMs and no sub_id: not guessable, so not claimed
    }
}
