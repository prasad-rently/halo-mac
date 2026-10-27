package app.halo.mobile.cloud

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Telephony
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import app.halo.cloud.SimLine
import app.halo.cloud.SmsRecord
import app.halo.cloud.SmsSource

/**
 * The device inbox through the SMS content provider. Inbox only (D23). Throws `SecurityException` when
 * READ_SMS isn't granted, which the engine reports instead of crashing a background worker.
 */
class AndroidSmsSource(private val ctx: Context, private val prefs: CloudPrefs) : SmsSource {

    private fun has(p: String) = ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED

    private data class Sim(val id: Int, val slot: Int, val carrier: String, val number: String)

    private fun activeSims(): List<Sim> {
        if (!has(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        val sm = ctx.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        return try {
            (sm.activeSubscriptionInfoList ?: emptyList()).map { info ->
                // SubscriptionInfo.number is routinely empty (carriers don't provision it) — the user labels it then (D20).
                val number = try {
                    if (Build.VERSION.SDK_INT >= 33 && has(Manifest.permission.READ_PHONE_NUMBERS)) sm.getPhoneNumber(info.subscriptionId) else @Suppress("DEPRECATION") (info.number ?: "")
                } catch (e: Exception) { "" }
                Sim(info.subscriptionId, info.simSlotIndex, (info.carrierName ?: info.displayName)?.toString().orEmpty().ifBlank { "SIM" }, number)
            }
        } catch (e: SecurityException) { emptyList() }
    }

    override fun lines(): List<SimLine> {
        requireSms()
        val sims = activeSims()
        if (sims.isEmpty()) {
            // No SIM list available (no phone-state permission, or a single-SIM provider that reports -1): one line for the phone.
            return listOf(SimLine(-1, "Unknown", prefs.lineNumber(-1).orEmpty(), prefs.lineLabel(-1) ?: "This phone"))
        }
        return sims.map { s ->
            SimLine(s.id, s.carrier, prefs.lineNumber(s.id)?.ifBlank { null } ?: s.number, prefs.lineLabel(s.id)?.ifBlank { null } ?: "SIM ${s.slot + 1}")
        }
    }

    private fun requireSms() { if (!has(Manifest.permission.READ_SMS)) throw SecurityException("READ_SMS not granted") }

    private val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.THREAD_ID,
        Telephony.Sms.READ, Telephony.Sms.SEEN, Telephony.Sms.SERVICE_CENTER, "sub_id")

    override fun inbox(subscriptionId: Int, sinceMs: Long): List<SmsRecord> {
        requireSms()
        val known = activeSims().map { it.id }.toSet()
        val out = ArrayList<SmsRecord>()
        ctx.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI, projection, "${Telephony.Sms.DATE} >= ?", arrayOf(sinceMs.toString()), "${Telephony.Sms.DATE} ASC")?.use { c ->
            val sub = c.getColumnIndex("sub_id")
            while (c.moveToNext()) {
                val rowSub = if (sub >= 0 && !c.isNull(sub)) c.getInt(sub) else -1
                // The synthetic "-1" line also owns rows whose SIM isn't one we can name.
                val belongs = rowSub == subscriptionId || (subscriptionId == -1 && rowSub !in known)
                if (!belongs) continue
                out.add(record(c, rowSub))
            }
        }
        return out
    }

    override fun allMessageIds(): Set<String> {
        requireSms()
        val ids = HashSet<String>()
        ctx.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf(Telephony.Sms._ID, Telephony.Sms.DATE), null, null, null)?.use { c ->
            while (c.moveToNext()) ids.add("${c.getLong(0)}_${c.getLong(1)}")
        }
        return ids
    }

    private fun record(c: android.database.Cursor, rowSub: Int) = SmsRecord(
        smsId = c.getLong(c.getColumnIndexOrThrow(Telephony.Sms._ID)),
        address = c.getString(c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)).orEmpty(),
        body = c.getString(c.getColumnIndexOrThrow(Telephony.Sms.BODY)).orEmpty(),
        dateMs = c.getLong(c.getColumnIndexOrThrow(Telephony.Sms.DATE)),
        threadId = c.getLong(c.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)),
        subscriptionId = rowSub,
        read = c.getInt(c.getColumnIndexOrThrow(Telephony.Sms.READ)) != 0,
        seen = c.getInt(c.getColumnIndexOrThrow(Telephony.Sms.SEEN)) != 0,
        serviceCenter = c.getString(c.getColumnIndexOrThrow(Telephony.Sms.SERVICE_CENTER)),
    )
}
