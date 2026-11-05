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

/**
 * One SENT row (provider type 2) — a message the user wrote. Deliberately NOT an [SmsRecord]: everything downstream
 * of the inbox (the expenditure pipeline, F-048/F-056, reads [SmsSource.inbox]) takes [SmsRecord]s, so a sent row can
 * never be passed to it by accident — it does not type-check. A text the user sends ("I paid Rs 500, received?") is not
 * a bank alert and must never become a transaction.
 */
data class SentSmsRecord(
    val smsId: Long,
    /** The OTHER party — the recipient. Stored as `addressEnc` (the contact), so both sides of a chat share a thread. */
    val address: String,
    val body: String,
    val dateMs: Long,
    val threadId: Long,
    /** Which SIM sent it; -1 when the device doesn't say. */
    val subscriptionId: Int,
    val read: Boolean,
    val seen: Boolean,
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

    /** Provider `Telephony.Sms.MESSAGE_TYPE_INBOX`. */
    const val TYPE_INBOX = 1
    /** Provider `Telephony.Sms.MESSAGE_TYPE_SENT`. */
    const val TYPE_SENT = 2

    /** `{smsId}_{timestamp}` — idempotent: re-uploading the same row overwrites itself (D14). */
    fun messageId(r: SmsRecord): String = "${r.smsId}_${r.dateMs}"

    /**
     * Same shape for a sent row. Sent rows live under their own node (`sms/{uid}/{deviceId}/sent/…`, see [sentPath]),
     * so this can never collide with an inbox id — and `content://sms` hands out `_id`s from one table anyway.
     */
    fun sentMessageId(r: SentSmsRecord): String = "${r.smsId}_${r.dateMs}"

    /**
     * Where sent rows go. A SIBLING of `messages`, not a type-2 row inside it: a desktop built before sent-sync
     * observes `messages` only, and one that found a type-2 row there would show the user's own text as something
     * they RECEIVED (and notify for it). Under `sent/` an old Mac simply never looks.
     */
    fun sentPath(uid: String, deviceId: String): String = "sms/$uid/$deviceId/sent"

    /** Strip everything but digits and a leading +, so `+91 98765-43210` and `919876543210` thread together. */
    fun normalizeNumber(raw: String): String {
        val t = raw.trim()
        if (t.any { it.isLetter() }) return t.lowercase()          // an alphanumeric sender id (VM-HDFCBK)
        val digits = t.filter { it.isDigit() }
        return if (t.startsWith("+")) "+$digits" else digits
    }

    fun threadKey(crypto: CryptoService, deviceId: String, r: SmsRecord): String = threadKey(crypto, deviceId, r.subscriptionId, r.address)

    /** One formula for both directions: a contact's received and sent rows on one line must hash to ONE thread. */
    fun threadKey(crypto: CryptoService, deviceId: String, subscriptionId: Int, address: String): String =
        crypto.keyedHash("halo.threadkey.v1", "$deviceId|$subscriptionId|${normalizeNumber(address)}")

    fun messageNode(r: SmsRecord, crypto: CryptoService, deviceId: String, syncedAtMs: Long): JsonObject {
        val m = node(TYPE_INBOX, r.address, r.body, r.threadId, r.subscriptionId, r.dateMs, r.read, r.seen, crypto, deviceId, syncedAtMs)
        r.serviceCenter?.let { m["serviceCenter"] = JsonPrimitive(it) }
        return JsonObject(m)
    }

    /**
     * A sent row, `type` 2. Field names and order are the inbox node's, so the desktop decodes both with one reader;
     * `addressEnc` is the CONTACT (the recipient). The thread key is the same hash an inbox row from that contact on the
     * same line gets, which is what puts both sides of a conversation in one thread on the Mac.
     */
    fun sentMessageNode(r: SentSmsRecord, crypto: CryptoService, deviceId: String, syncedAtMs: Long): JsonObject =
        JsonObject(node(TYPE_SENT, r.address, r.body, r.threadId, r.subscriptionId, r.dateMs, r.read, r.seen, crypto, deviceId, syncedAtMs))

    private fun node(
        type: Int, address: String, body: String, threadId: Long, subscriptionId: Int, dateMs: Long, read: Boolean, seen: Boolean,
        crypto: CryptoService, deviceId: String, syncedAtMs: Long,
    ) = linkedMapOf<String, JsonElement>(
        "addressEnc" to JsonPrimitive(crypto.encrypt(address)),
        "bodyEnc" to JsonPrimitive(crypto.encrypt(body)),
        "threadKey" to JsonPrimitive(threadKey(crypto, deviceId, subscriptionId, address)),
        "threadId" to JsonPrimitive(threadId),
        "subscriptionId" to JsonPrimitive(subscriptionId),
        "date" to JsonPrimitive(dateMs),
        "type" to JsonPrimitive(type),
        "read" to JsonPrimitive(read),
        "seen" to JsonPrimitive(seen),
        "syncedAt" to JsonPrimitive(syncedAtMs),
        "schema" to JsonPrimitive(SCHEMA),
    )

    /**
     * The registry node for one SIM line, written in ONE request. The desktop attaches a child_added observer
     * and reads a child exactly once, when it first appears — so a node written field by field is seen
     * half-built (no label, no number) and never refreshed. `syncEnabled` belongs to the desktop (D29): the
     * caller passes back the value it just read so this whole-node write cannot reset it.
     */
    fun lineNode(
        l: SimLine, crypto: CryptoService, syncEnabled: Boolean? = null,
        lineVersion: Int? = null, updatedAtMs: Long? = null, ownNumberEnc: String? = null,
    ): JsonObject {
        val m = linkedMapOf<String, JsonElement>(
            "subscriptionId" to JsonPrimitive(l.subscriptionId),
            "label" to JsonPrimitive(l.label),
            "carrier" to JsonPrimitive(l.carrier),
            "ownNumberEnc" to JsonPrimitive(ownNumberEnc ?: crypto.encrypt(l.ownNumber.ifBlank { "Unknown" })),
        )
        syncEnabled?.let { m["syncEnabled"] = JsonPrimitive(it) }
        // H-21: the desktop reads a line once, when it first appears. These two fields are the change signal it
        // re-reads on: `lineVersion` goes up (and `updatedAt` moves) only when label / carrier / own number change,
        // so a rename on the phone reaches a Mac that is already running.
        lineVersion?.let { m["lineVersion"] = JsonPrimitive(it) }
        updatedAtMs?.let { m["updatedAt"] = JsonPrimitive(it) }
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
