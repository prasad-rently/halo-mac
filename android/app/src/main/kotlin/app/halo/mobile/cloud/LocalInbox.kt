package app.halo.mobile.cloud

import android.content.Context
import android.provider.Telephony

/** A message as shown in the in-app inbox. Held in memory only; never logged or persisted by the UI. */
data class LocalMessage(val id: Long, val address: String, val body: String, val dateMs: Long, val read: Boolean, val subId: Int)

/**
 * Read-only peek at the phone's own SMS inbox for the Messages screen (newest first). Same provider and permission the
 * sync already uses; the UI never writes to it. Returns empty without READ_SMS (the caller shows the permission state).
 */
object LocalInbox {
    fun recent(ctx: Context, limit: Int = 40, countOnlySinceMs: Long? = null): List<LocalMessage> = try {
        val out = ArrayList<LocalMessage>()
        ctx.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.READ, "sub_id"),
            countOnlySinceMs?.let { "${Telephony.Sms.DATE} >= ?" }, countOnlySinceMs?.let { arrayOf(it.toString()) },
            "${Telephony.Sms.DATE} DESC")?.use { c ->
            val sub = c.getColumnIndex("sub_id")
            while (out.size < limit && c.moveToNext()) out.add(LocalMessage(
                c.getLong(0), c.getString(1).orEmpty(), c.getString(2).orEmpty(), c.getLong(3), c.getInt(4) == 1, if (sub >= 0) c.getInt(sub) else -1))
        }
        out
    } catch (_: SecurityException) { emptyList() } catch (_: RuntimeException) { emptyList() }
}
