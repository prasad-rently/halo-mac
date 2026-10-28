package app.halo.mobile.background

import android.content.Context
import android.net.wifi.WifiManager
import app.halo.share.DeviceInfo
import app.halo.share.MulticastDiscovery
import app.halo.share.Peer
import app.halo.share.UdpMulticastTransport

/**
 * F-055 FR-B4. Android drops multicast datagrams unless the app holds a [WifiManager.MulticastLock], and the lock
 * keeps the Wi-Fi radio in a higher-power mode — so it is held for exactly one bounded discovery window and released
 * in `finally`, never kept for the service's lifetime. If multicast is unavailable (no Wi-Fi, a network that blocks it,
 * the lock refused) this returns nothing and the caller's /24 HTTP scan and manual entry carry on unchanged.
 */
object MulticastScope {
    fun run(ctx: Context, me: DeviceInfo, windowMs: Long = 4_000, onFound: (Peer) -> Unit, isCancelled: () -> Boolean): List<Peer> {
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return emptyList()
        val lock = wifi.createMulticastLock("halo.discovery").apply { setReferenceCounted(false) }
        return try {
            lock.acquire()
            UdpMulticastTransport().use { MulticastDiscovery(me, windowMs).run(it, onFound, isCancelled) }
        } catch (e: Exception) { emptyList() }
        finally { if (lock.isHeld) lock.release() }
    }
}
