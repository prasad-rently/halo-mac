package app.halo.mobile.background

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import app.halo.share.DeviceInfo
import app.halo.share.MulticastLockHandle
import app.halo.share.MulticastWindow
import app.halo.share.Peer
import app.halo.share.UdpMulticastTransport

/**
 * F-055 FR-B4. Android drops multicast datagrams unless the app holds a [WifiManager.MulticastLock], and the lock
 * keeps the Wi-Fi radio in a higher-power mode — so it is held for exactly one bounded discovery window and released
 * in `finally` ([MulticastWindow]), never kept for the service's lifetime. If multicast is unavailable (no Wi-Fi, a
 * network that blocks it, the lock refused) this returns nothing and the caller's /24 HTTP scan and manual entry carry
 * on unchanged.
 *
 * The announce is pinned to the Wi-Fi interface (see [wifiInterfaceName]); if that cannot be determined the transport
 * falls back to the platform default.
 */
object MulticastScope {
    fun run(ctx: Context, me: DeviceInfo, windowMs: Long = 4_000, onFound: (Peer) -> Unit = {}, isCancelled: () -> Boolean = { false }): List<Peer> {
        val app = ctx.applicationContext
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return emptyList()
        val lock = wifi.createMulticastLock("halo.discovery").apply { setReferenceCounted(false) }
        val handle = object : MulticastLockHandle {
            override fun acquire() = lock.acquire()
            override fun release() = lock.release()
            override val isHeld: Boolean get() = lock.isHeld
        }
        val nic = wifiInterfaceName(app)
        return MulticastWindow.run(me, windowMs, handle, { UdpMulticastTransport(preferredInterface = nic) }, onFound, isCancelled)
    }

    /** The interface of the Wi-Fi network (preferring the active one), or null when there is none / it can't be read. */
    fun wifiInterfaceName(ctx: Context): String? = runCatching {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return@runCatching null
        fun isWifi(n: android.net.Network?) = n != null && cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val net = cm.activeNetwork?.takeIf(::isWifi) ?: cm.allNetworks.firstOrNull(::isWifi)
        net?.let { cm.getLinkProperties(it)?.interfaceName }
    }.getOrNull()
}
