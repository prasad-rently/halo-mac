package app.halo.mobile.cloud

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Wakes the sync when a message arrives. It deliberately reads NOTHING from the broadcast — not the PDU, not
 * the sender — it only schedules a sync, because the SMS provider is the single source of truth and a
 * message must reach the cloud the same way whether it arrived live or was found by the periodic pass.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "android.provider.Telephony.SMS_RECEIVED") return
        if (!CloudPrefs(context).smsEnabled) return
        SyncScheduler.enqueueSoon(context)
    }
}
