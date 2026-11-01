package app.halo.mobile.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import app.halo.mobile.ListenState
import app.halo.share.ConsentDecision
import app.halo.share.ConsentGate
import app.halo.share.ConsentHandler
import app.halo.share.DeviceIdentity
import app.halo.share.DeviceIdentityStore
import app.halo.share.HaloShare
import app.halo.share.HaloShareServer
import app.halo.share.IncomingOffer
import app.halo.share.KeyValueStore
import app.halo.share.ServerListener
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

/** F-055: user choices for background receiving. Default OFF — nothing runs in the background until the user says so (FR-B2). */
class BackgroundPrefs(ctx: Context) {
    private val p = ctx.applicationContext.getSharedPreferences("halo.background", Context.MODE_PRIVATE)
    var enabled: Boolean get() = p.getBoolean("keepReceiving", false); set(v) { p.edit().putBoolean("keepReceiving", v).apply() }
    /** Set when Android ended the service (e.g. the Android 15 six-hour `dataSync` limit) so the UI can say so. */
    var pausedBySystem: Boolean get() = p.getBoolean("pausedBySystem", false); set(v) { p.edit().putBoolean("pausedBySystem", v).apply() }
}

/** The identity store HaloShare uses, reachable without a ViewModel (the service has none). */
object HaloIdentity {
    fun store(ctx: Context): KeyValueStore {
        val prefs = ctx.applicationContext.getSharedPreferences("haloshare", Context.MODE_PRIVATE)
        return object : KeyValueStore {
            override fun get(key: String): String? = prefs.getString(key, null)
            override fun put(key: String, value: String) { prefs.edit().putString(key, value).apply() }
        }
    }
    fun load(ctx: Context): DeviceIdentity =
        DeviceIdentityStore.loadOrCreate(store(ctx), defaultAlias = Build.MODEL ?: "Android", deviceModel = Build.MODEL, deviceType = "mobile")
}

/**
 * The one HaloShare receiver for the process. Before F-055 the ViewModel owned the server and stopped it whenever the
 * screen did; now the visible app and the foreground service share this host, so "receive with the app backgrounded"
 * is the same server, the same consent rule and the same inbox — not a second implementation.
 *
 * Consent is unchanged: nothing is saved until a person accepts. When the app is not visible the prompt is a
 * notification (Accept / Decline), and an unanswered prompt is declined after [BACKGROUND_CONSENT_MS].
 */
object ReceiverHost {
    const val BACKGROUND_CONSENT_MS = 90_000L

    private val _listen = MutableStateFlow<ListenState>(ListenState.Stopped)
    val listen: StateFlow<ListenState> = _listen
    private val _offer = MutableStateFlow<IncomingOffer?>(null)
    val offer: StateFlow<IncomingOffer?> = _offer
    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 16)
    val events: SharedFlow<Event> = _events

    sealed interface Event { data class Received(val name: String) : Event; object InboxChanged : Event; object SenderCancelled : Event }

    @Volatile var uiVisible = false
    /** True from the moment [HaloShareService] is in the foreground until it is destroyed. The screen only hands the
     *  receiver over to the service while this is true — not merely because the toggle says "on". */
    @Volatile var serviceActive = false
    @Volatile private var server: HaloShareServer? = null
    private val gate = ConsentGate(BACKGROUND_CONSENT_MS)
    private val lock = Any()

    fun receiveDirectory(ctx: Context): File = (ctx.applicationContext.getExternalFilesDir("Received") ?: File(ctx.applicationContext.filesDir, "Received")).also { it.mkdirs() }

    /** Idempotent. Safe to call from the UI and from the service. */
    fun start(ctx: Context, identity: DeviceIdentity = HaloIdentity.load(ctx)) {
        val app = ctx.applicationContext
        synchronized(lock) {
            if (server != null) return
            _listen.value = ListenState.Starting
            val listener = object : ServerListener {
                override fun onFileReceived(sessionId: String, fileId: String, file: File) { _events.tryEmit(Event.InboxChanged); _events.tryEmit(Event.Received(file.name)) }
                override fun onSessionCompleted(sessionId: String) { _events.tryEmit(Event.InboxChanged) }
                override fun onSessionCancelled(sessionId: String) { _events.tryEmit(Event.InboxChanged); _events.tryEmit(Event.SenderCancelled); Notifications.clearOffer(app) }
            }
            val s = HaloShareServer(identity, receiveDirectory(app), ConsentHandler { askConsent(app, it) }, listener)
            server = s
            Thread({
                try {
                    synchronized(lock) { if (server !== s) return@Thread }          // stopped before we even got going
                    val port = s.start(HaloShare.DEFAULT_PORT)
                    // stop() ran while the socket was binding and could not see it: close it rather than leave a port
                    // open that nothing owns (and that Stop can no longer reach).
                    synchronized(lock) { if (server !== s) { s.stop(); return@Thread }; _listen.value = ListenState.Listening(port) }
                } catch (e: Exception) {
                    synchronized(lock) { if (server === s) { server = null; _listen.value = ListenState.Failed(e.message ?: "couldn't listen") } }
                }
            }, "haloshare-start").apply { isDaemon = true; start() }
        }
    }

    fun stop(ctx: Context? = null) {
        gate.resolve(ConsentDecision.DECLINE)       // a prompt left open can't be answered once we stop
        synchronized(lock) { server?.stop(); server = null; _listen.value = ListenState.Stopped }
        ctx?.let { Notifications.clearOffer(it) }
    }

    fun restart(ctx: Context, identity: DeviceIdentity) { if (_listen.value is ListenState.Listening) { stop(ctx); start(ctx, identity) } }

    /** Called on a server thread; blocks until the person answers. One prompt at a time — see [ConsentGate]. */
    private fun askConsent(app: Context, offer: IncomingOffer): ConsentDecision =
        gate.ask(offer, isVisible = { uiVisible }, onPending = { _offer.value = it },
            showPrompt = { id -> Notifications.showOffer(app, offer, id) }, clearPrompt = { Notifications.clearOffer(app) })

    /** [id] (from a notification button) makes a stale tap on an old prompt a no-op rather than an answer to a newer one. */
    fun resolve(decision: ConsentDecision, id: Long? = null) { gate.resolve(decision, id) }
}

/** Notification plumbing for the service and the background consent prompt. */
object Notifications {
    const val CHANNEL_SERVICE = "halo.background"
    const val CHANNEL_OFFER = "halo.offer"
    const val ID_SERVICE = 5501
    const val ID_OFFER = 5502

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL_SERVICE, "Receiving in the background", NotificationManager.IMPORTANCE_LOW)
            .apply { description = "Shown while Halo keeps listening for files and clipboard copies. Stop it any time." })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_OFFER, "Incoming files", NotificationManager.IMPORTANCE_HIGH)
            .apply { description = "Asks before anything is saved." })
    }

    private fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(ctx, 0,
        Intent().setComponent(ComponentName(ctx, "app.halo.mobile.MainActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun serviceNotification(ctx: Context): Notification {
        ensureChannels(ctx)
        val stop = PendingIntent.getService(ctx, 1, Intent(ctx, HaloShareService::class.java).setAction(HaloShareService.ACTION_STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(ctx, CHANNEL_SERVICE)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Halo is listening")
            .setContentText("Ready to receive files and your Mac's clipboard on this network.")
            .setContentIntent(openApp(ctx)).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    /** The sender's self-chosen name is untrusted text from the LAN: strip control characters and bound it. */
    internal fun safeAlias(alias: String): String = alias.filter { !it.isISOControl() }.trim().take(40).ifEmpty { "A device" }

    /**
     * Sender and size only — never file names: a notification can be mirrored or shown on a lock screen. The lock-screen
     * version names nothing at all, and Accept / Decline ask for the device to be unlocked first. [id] ties the buttons
     * to THIS offer so a tap on a stale notification can't answer a later one.
     */
    fun showOffer(ctx: Context, o: IncomingOffer, id: Long) {
        ensureChannels(ctx)
        fun act(code: Int, a: String) = PendingIntent.getBroadcast(ctx, code, Intent(ctx, ConsentActionReceiver::class.java).setAction(a).putExtra(ConsentActionReceiver.EXTRA_ID, id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        fun button(title: String, pi: PendingIntent) = Notification.Action.Builder(null, title, pi).apply { if (Build.VERSION.SDK_INT >= 31) setAuthenticationRequired(true) }.build()
        val public = Notification.Builder(ctx, CHANNEL_OFFER).setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("Incoming file").setContentText("Unlock to respond.").build()
        val n = Notification.Builder(ctx, CHANNEL_OFFER)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("${safeAlias(o.sender.alias)} wants to send ${if (o.files.size == 1) "a file" else "${o.files.size} files"}")
            .setContentText("${android.text.format.Formatter.formatShortFileSize(ctx, o.totalBytes)} — nothing is saved unless you accept.")
            .setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(public)
            .setContentIntent(openApp(ctx)).setAutoCancel(true)
            .setTimeoutAfter(ReceiverHost.BACKGROUND_CONSENT_MS)
            .addAction(button("Accept", act(1, ConsentActionReceiver.ACTION_ACCEPT)))
            .addAction(button("Decline", act(2, ConsentActionReceiver.ACTION_DECLINE)))
            .build()
        runCatching { ctx.getSystemService(NotificationManager::class.java)?.notify(ID_OFFER, n) }
    }

    fun clearOffer(ctx: Context) { runCatching { ctx.getSystemService(NotificationManager::class.java)?.cancel(ID_OFFER) } }
}

/** Accept / Decline from the notification. Not exported: only this app's own PendingIntents reach it. */
class ConsentActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getLongExtra(EXTRA_ID, -1L).takeIf { it >= 0 } ?: return       // no id ⇒ not one of ours
        when (intent.action) {
            ACTION_ACCEPT -> ReceiverHost.resolve(ConsentDecision.ACCEPT, id)
            ACTION_DECLINE -> ReceiverHost.resolve(ConsentDecision.DECLINE, id)
        }
    }
    companion object { const val ACTION_ACCEPT = "app.halo.mobile.CONSENT_ACCEPT"; const val ACTION_DECLINE = "app.halo.mobile.CONSENT_DECLINE"; const val EXTRA_ID = "offerId" }
}
