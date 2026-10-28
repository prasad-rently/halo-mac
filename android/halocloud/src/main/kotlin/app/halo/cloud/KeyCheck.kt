package app.halo.cloud

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * "A test record confirms it matches" (F-044 §7.1 step 4). A passphrase typed on the phone derives a key
 * that is either the Mac's key or garbage, and garbage is silent: AES-GCM only fails when it tries to
 * open something. So before trusting a freshly-typed passphrase, try to open a record the Mac already
 * wrote. There is no dedicated canary node (the desktop doesn't write one, and a wrong first guess
 * written as the canary would then poison every later pairing), so this probes real ciphertext.
 */
object KeyCheck {
    enum class Result {
        /** Opened a record written under this key — the passphrase is right. */
        MATCH,
        /** Found records, but none open — the passphrase (or the salt) is wrong. */
        MISMATCH,
        /** The database holds nothing encrypted yet, so there is nothing to test against. */
        NO_SAMPLE,
    }

    fun verify(rtdb: Rtdb, crypto: CryptoService): Result {
        val uid = rtdb.uid
        val samples = ArrayList<String>()

        // Cheapest first: a clipboard item, then a device's SIM-line number, then a message body.
        rtdb.shallowKeys("clipboard/$uid/items").take(3).forEach { k ->
            enc(rtdb.get("clipboard/$uid/items/$k"), "contentEnc")?.let(samples::add)
        }
        for (device in rtdb.shallowKeys("sms/$uid").take(3)) {
            for (line in rtdb.shallowKeys("sms/$uid/$device/lines").take(2)) enc(rtdb.get("sms/$uid/$device/lines/$line"), "ownNumberEnc")?.let(samples::add)
            for (m in rtdb.shallowKeys("sms/$uid/$device/messages").take(2)) enc(rtdb.get("sms/$uid/$device/messages/$m"), "bodyEnc")?.let(samples::add)
        }
        if (samples.isEmpty()) return Result.NO_SAMPLE
        return if (samples.any { runCatching { crypto.decrypt(it) }.isSuccess }) Result.MATCH else Result.MISMATCH
    }

    private fun enc(node: kotlinx.serialization.json.JsonElement?, field: String): String? =
        ((node as? JsonObject)?.get(field) as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
}
