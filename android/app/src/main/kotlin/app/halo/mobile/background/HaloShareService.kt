package app.halo.mobile.background

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import app.halo.mobile.cloud.ClipboardController

/**
 * F-055 FR-B1: the foreground service that keeps the HaloShare receiver and the clipboard stream alive while the app
 * is not on screen. Type `dataSync`. Started only from a user action (the Settings toggle, or the app being opened
 * with the toggle already on) — never from boot or from a background broadcast (Android 14 FGS rules).
 */
class HaloShareService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            BackgroundPrefs(this).enabled = false
            stopSelf(); return START_NOT_STICKY
        }
        if (!BackgroundPrefs(this).enabled) { stopSelf(); return START_NOT_STICKY }      // the user turned it off while we were starting
        try {
            val n = Notifications.serviceNotification(this)
            if (Build.VERSION.SDK_INT >= 29) startForeground(Notifications.ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(Notifications.ID_SERVICE, n)
        } catch (e: Exception) {
            // e.g. a sticky restart from the background that Android refuses: do not crash, just stand down.
            stopSelf(); return START_NOT_STICKY
        }
        BackgroundPrefs(this).pausedBySystem = false
        ReceiverHost.start(this)
        ClipboardController.start(this)          // no-op unless clipboard sync is on and the phone is paired
        return START_STICKY
    }

    /** Android 15+ ends a `dataSync` service after ~6 h in a 24 h window. Say so rather than dying silently. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        BackgroundPrefs(this).pausedBySystem = true
        stopSelf()
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (!ReceiverHost.uiVisible) ReceiverHost.stop(this)      // with the screen up the visible app keeps its own receiver
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "app.halo.mobile.STOP_BACKGROUND"
        /** Must be called from a visible context (a click, or the app coming to the front). */
        fun start(ctx: Context) { runCatching { ctx.startForegroundService(Intent(ctx, HaloShareService::class.java)) } }
        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, HaloShareService::class.java)) }
    }
}
