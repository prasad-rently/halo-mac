package app.halo.mobile.background

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build

/** The OS's "default network changed" signal, abstracted so the restart rule is JVM-testable. Ids are opaque (Android's `Network.toString()`). */
interface NetworkEvents {
    /** The id of the current default network, or null when offline. */
    fun currentNetworkId(): String?
    /** Start delivering events; returns the handle that unregisters. */
    fun register(listener: Listener): () -> Unit
    interface Listener { fun onAvailable(networkId: String); fun onLost(networkId: String) }
}

/**
 * Restarts the clipboard stream and the receiver when the device moves to a different network (Wi-Fi ⇄ mobile, a new
 * Wi-Fi, back online after being offline) instead of waiting for the stream's own backoff to notice a dead socket.
 *
 * Registered only while the service runs ([start]) and unregistered in [stop] (the service's `onDestroy`). Rules:
 *  - the callback Android fires at registration for the network we are already on is NOT a change;
 *  - a different network id, or the same network returning after a loss, is;
 *  - bursts (Android often reports several events for one switch) collapse to one restart per [minGapMs].
 */
class NetworkChangeRestarter(
    private val events: NetworkEvents,
    private val onChange: () -> Unit,
    private val minGapMs: Long = 3_000,
    private val clock: () -> Long = System::currentTimeMillis,
) : NetworkEvents.Listener {
    private var unregister: (() -> Unit)? = null
    private var current: String? = null
    private var lostSinceLast = false
    private var lastFiredAt = Long.MIN_VALUE / 2
    @Volatile var registered = false; private set
    var restarts = 0; private set

    @Synchronized fun start() {
        if (unregister != null) return
        current = events.currentNetworkId()
        lostSinceLast = current == null            // started offline: the first network to appear is a change
        unregister = events.register(this); registered = true
    }

    @Synchronized fun stop() { unregister?.invoke(); unregister = null; registered = false }

    override fun onAvailable(networkId: String) {
        val fire = synchronized(this) {
            if (unregister == null) return
            val changed = networkId != current || lostSinceLast
            current = networkId; lostSinceLast = false
            changed && clock() - lastFiredAt >= minGapMs && run { lastFiredAt = clock(); restarts++; true }
        }
        if (fire) onChange()
    }

    override fun onLost(networkId: String) {
        synchronized(this) { if (networkId == current) { current = null; lostSinceLast = true } }
    }
}

/** [NetworkEvents] over `ConnectivityManager.registerDefaultNetworkCallback` (API 24+; minSdk is 26). Needs ACCESS_NETWORK_STATE, already declared. */
class AndroidNetworkEvents(ctx: Context) : NetworkEvents {
    private val cm = ctx.applicationContext.getSystemService(ConnectivityManager::class.java)
    override fun currentNetworkId(): String? = runCatching { cm?.activeNetwork?.toString() }.getOrNull()
    override fun register(listener: NetworkEvents.Listener): () -> Unit {
        val manager = cm ?: return {}
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = listener.onAvailable(network.toString())
            override fun onLost(network: Network) = listener.onLost(network.toString())
        }
        runCatching { manager.registerDefaultNetworkCallback(cb) }.onFailure { return {} }
        return { runCatching { manager.unregisterNetworkCallback(cb) } }
    }
}
