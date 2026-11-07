package app.halo.mobile.background

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import app.halo.mobile.cloud.ClipboardController
import app.halo.mobile.cloud.ClipboardOwner

/**
 * F-055 FR-B1: the foreground service that keeps the HaloShare receiver and the clipboard stream alive while the app
 * is not on screen. Type `dataSync`. Started only from a user action (the Settings toggle, or the app being opened
 * with the toggle already on) — never from boot or from a background broadcast (Android 14 FGS rules).
 *
 * The rules for whether it may run (the persistent notification must be showable) live in [BackgroundController].
 */
class HaloShareService : Service() {
    private var network: NetworkChangeRestarter? = null
    private var announcer: app.halo.share.PeriodicAnnouncer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = BackgroundController(BackgroundSettings.get(this))
        if (intent?.action == ACTION_STOP) {          // from the notification's Stop button (a plain startService, so no startForeground owed)
            controller.stopRequested()                // through the observable settings, so the Settings switch flips at once
            stopSelf(); return START_NOT_STICKY
        }
        // startForegroundService() obliges us to call startForeground() promptly on EVERY path — including the ones that
        // then stop straight away — or Android kills the app with ForegroundServiceDidNotStartInTimeException.
        try {
            val n = Notifications.serviceNotification(this)
            if (Build.VERSION.SDK_INT >= 29) startForeground(Notifications.ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(Notifications.ID_SERVICE, n)
        } catch (e: Exception) {
            // e.g. a sticky restart from the background that Android refuses: do not crash, just stand down.
            stopSelf(); return START_NOT_STICKY
        }
        // The user turned it off while we were starting, or the persistent notice can't be shown (permission revoked since the switch
        // was turned on): stand down. The latter also switches the setting off and records why, so the screen explains it.
        if (!controller.onServiceStarting(AndroidNotificationGate(this))) { stopSelf(); return START_NOT_STICKY }
        ReceiverHost.serviceActive = true
        ReceiverHost.start(this)
        ClipboardController.start(this, ClipboardOwner.SERVICE)          // no-op unless clipboard sync is on and the phone is paired
        startWatchers()
        return START_STICKY
    }

    /** Network-change restarts and the periodic multicast re-announce exist only while the service runs. */
    private fun startWatchers() {
        val ctx = applicationContext
        if (announcer == null) announcer = app.halo.share.PeriodicAnnouncer(
            intervalMs = REANNOUNCE_MS, isIdle = { ReceiverHost.isIdle() },
            announce = { MulticastScope.run(ctx, HaloIdentity.load(ctx).deviceInfo()) },
        ).also { it.start() }
        if (network == null) network = NetworkChangeRestarter(AndroidNetworkEvents(ctx), onChange = {
            ClipboardController.refresh()
            ReceiverHost.restartIfIdle(ctx)
            announcer?.runNow()
        }).also { it.start() }
    }

    /** Android 15+ ends a `dataSync` service after ~6 h in a 24 h window. Say so rather than dying silently. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        BackgroundSettings.get(this).setPausedBySystem(true)
        stopSelf()
    }

    override fun onDestroy() {
        ReceiverHost.serviceActive = false
        network?.stop(); network = null
        announcer?.stop(); announcer = null
        // Let go of OUR claim on the clipboard stream only. If the user's own switch or the accessibility service also
        // holds it, it keeps running; if the service alone started it, it stops with the service.
        ClipboardController.release(ClipboardOwner.SERVICE)
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (!ReceiverHost.uiVisible) ReceiverHost.stop(this)      // with the screen up the visible app keeps its own receiver
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "app.halo.mobile.STOP_BACKGROUND"
        /** While idle in the background, announce on the multicast group this often (each announce is one ~4 s window holding the MulticastLock). */
        const val REANNOUNCE_MS = 5 * 60_000L
        /** Must be called from a visible context (a click, or the app coming to the front). */
        fun start(ctx: Context) { runCatching { ctx.startForegroundService(Intent(ctx, HaloShareService::class.java)) } }
        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, HaloShareService::class.java)) }
    }
}
