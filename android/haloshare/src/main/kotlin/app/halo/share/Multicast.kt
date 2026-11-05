package app.halo.share

import java.net.DatagramPacket
import java.net.InetAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException

// F-055 FR-B4. LocalSend/HaloShare multicast discovery (docs/HALOSHARE_PROTOCOL.md §5.1): a UDP datagram to
// 224.0.0.167:53317 carrying a DeviceInfo JSON with `announce:true`; a peer that hears it answers (here: a UDP
// reply with `announce:false`). Everything a datagram says is untrusted input from the LAN, so the codec is strict:
// it caps size, rejects our own echo and malformed/odd shapes, clamps the port and trims the alias.

object MulticastCodec {
    const val MAX_DATAGRAM = 4096
    const val MAX_ALIAS = 64
    /** Per discovery window. Fingerprints are attacker-chosen, so unique-per-datagram floods must not grow memory, the device list or our replies without bound. */
    const val MAX_PEERS = 64
    const val MAX_ANSWERS = 16

    fun encode(me: DeviceInfo, announce: Boolean, port: Int = me.port): ByteArray =
        HaloJson.encodeToString(DeviceInfo.serializer(), me.copy(announce = announce, download = false, port = port)).toByteArray(Charsets.UTF_8)

    /** The peer's DeviceInfo, or null for anything that is not a sane announcement from someone else. */
    fun decode(bytes: ByteArray, length: Int, ownFingerprint: String): DeviceInfo? {
        if (length <= 0 || length > MAX_DATAGRAM) return null
        val info = try { HaloJson.decodeFromString(DeviceInfo.serializer(), String(bytes, 0, length, Charsets.UTF_8)) } catch (e: Exception) { return null }
        if (info.fingerprint.isBlank() || info.fingerprint.length > 128 || info.fingerprint == ownFingerprint) return null
        if (info.port !in 1..65535) return null
        if (info.protocol != "http" && info.protocol != "https") return null
        val alias = Alias.clean(info.alias, MAX_ALIAS)
        if (alias.isEmpty()) return null
        return info.copy(alias = alias)
    }
}

/** The socket, abstracted so the discovery logic is unit-tested with no real multicast (which CI/emulators rarely route). */
interface DatagramTransport : AutoCloseable {
    fun send(bytes: ByteArray)
    /** Blocks up to [timeoutMs]; null on timeout. [Received.host] is the datagram's SOURCE address — never a host named inside the payload. */
    fun receive(timeoutMs: Int): Received?
    class Received(val bytes: ByteArray, val length: Int, val host: String)
}

/** What the interface chooser needs to know about one network interface (a plain value so the choice is testable without real NICs). */
data class IfaceCandidate(val name: String, val up: Boolean, val loopback: Boolean, val multicast: Boolean, val hasIpv4: Boolean)

object MulticastInterfaces {
    /**
     * The interface to pin multicast to, or null for "no pin — use the platform default" (the pre-F-055-follow-up
     * behaviour). [preferred] is the name the caller got from the OS for the Wi-Fi network (on Android,
     * `ConnectivityManager.getLinkProperties(wifiNetwork).interfaceName`). It is honoured only if that interface is
     * actually usable for IPv4 multicast; anything else falls back rather than failing discovery.
     */
    fun choose(candidates: List<IfaceCandidate>, preferred: String?): String? {
        if (preferred.isNullOrBlank()) return null
        return candidates.firstOrNull { it.name == preferred && it.up && !it.loopback && it.multicast && it.hasIpv4 }?.name
    }

    fun systemCandidates(): List<Pair<IfaceCandidate, NetworkInterface>> =
        runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull().orEmpty().mapNotNull { nif ->
            runCatching {
                IfaceCandidate(nif.name, nif.isUp, nif.isLoopback, nif.supportsMulticast(), nif.inetAddresses.toList().any { it is java.net.Inet4Address }) to nif
            }.getOrNull()
        }
}

/**
 * Real UDP multicast. The caller must hold Android's MulticastLock (see MulticastScope in :app).
 *
 * [preferredInterface] pins both the outgoing interface and the group membership to one NIC (the Wi-Fi one). Without
 * it, on a phone that is on Wi-Fi *and* has a VPN / mobile data / a tethering interface up, the announce can leave on
 * the wrong one and never reach the LAN. If the preferred interface is missing or unusable, or pinning throws, this
 * silently falls back to joining every usable IPv4 interface and the platform's default send interface.
 */
class UdpMulticastTransport(
    private val port: Int = HaloShare.DEFAULT_PORT,
    private val group: String = HaloShare.MULTICAST_GROUP,
    preferredInterface: String? = null,
) : DatagramTransport {
    private val addr = InetAddress.getByName(group)
    /** The interface name multicast is pinned to, or null when it is not (default routing). */
    val pinnedInterface: String?
    private val socket = MulticastSocket(port)

    init {
        socket.reuseAddress = true
        val all = MulticastInterfaces.systemCandidates()
        val pin = MulticastInterfaces.choose(all.map { it.first }, preferredInterface)
        val pinnedNif = pin?.let { name -> all.firstOrNull { it.first.name == name }?.second }
        var pinned: String? = null
        if (pinnedNif != null) {
            val ok = runCatching { socket.networkInterface = pinnedNif; socket.joinGroup(java.net.InetSocketAddress(addr, port), pinnedNif) }.isSuccess
            if (ok) pinned = pinnedNif.name
        }
        if (pinned == null) {
            for ((c, nif) in all) {
                if (!c.up || c.loopback || !c.multicast) continue
                runCatching { socket.joinGroup(java.net.InetSocketAddress(addr, port), nif) }
            }
        }
        pinnedInterface = pinned
    }

    override fun send(bytes: ByteArray) { socket.send(DatagramPacket(bytes, bytes.size, addr, port)) }
    override fun receive(timeoutMs: Int): DatagramTransport.Received? {
        val buf = ByteArray(MulticastCodec.MAX_DATAGRAM + 1)
        val p = DatagramPacket(buf, buf.size)
        socket.soTimeout = timeoutMs.coerceAtLeast(1)
        return try { socket.receive(p); DatagramTransport.Received(buf, p.length, p.address.hostAddress ?: return null) } catch (e: SocketTimeoutException) { null }
    }
    override fun close() { runCatching { socket.close() } }
}

/**
 * One bounded discovery window: announce, listen, answer announcements, report each peer once. The window is the
 * lifetime of the Android MulticastLock, so the lock is never held longer than [windowMs].
 */
class MulticastDiscovery(private val me: DeviceInfo, private val windowMs: Long = 4_000, private val clock: () -> Long = System::currentTimeMillis) {
    /** @return peers found, in discovery order, each fingerprint once. */
    fun run(transport: DatagramTransport, onFound: (Peer) -> Unit = {}, isCancelled: () -> Boolean = { false }): List<Peer> {
        val found = LinkedHashMap<String, Peer>()
        val answered = HashSet<String>()
        val end = clock() + windowMs
        var nextAnnounce = 0L
        while (clock() < end && !isCancelled()) {
            if (clock() >= nextAnnounce) { runCatching { transport.send(MulticastCodec.encode(me, announce = true)) }; nextAnnounce = clock() + windowMs / 2 }
            val r = transport.receive(minOf(250L, maxOf(1L, end - clock())).toInt()) ?: continue
            val info = MulticastCodec.decode(r.bytes, r.length, me.fingerprint) ?: continue
            if (info.announce == true && answered.size < MulticastCodec.MAX_ANSWERS && answered.add(info.fingerprint)) runCatching { transport.send(MulticastCodec.encode(me, announce = false)) }
            if (info.fingerprint !in found && found.size < MulticastCodec.MAX_PEERS) { val peer = Peer(info, r.host); found[info.fingerprint] = peer; onFound(peer) }
        }
        return found.values.toList()
    }
}

/** The Android MulticastLock, abstracted so "held only while a window runs" is testable on the JVM. */
interface MulticastLockHandle {
    fun acquire()
    fun release()
    val isHeld: Boolean
}

object MulticastWindow {
    /**
     * One bounded window: take the lock, announce / listen / answer, release the lock in `finally` — whatever happens
     * (the transport failing to open, an exception mid-window). Never throws: if multicast is unavailable the caller
     * gets an empty list and its other discovery paths carry on.
     */
    fun run(me: DeviceInfo, windowMs: Long, lock: MulticastLockHandle, transport: () -> DatagramTransport,
            onFound: (Peer) -> Unit = {}, isCancelled: () -> Boolean = { false }): List<Peer> =
        try {
            lock.acquire()
            transport().use { MulticastDiscovery(me, windowMs).run(it, onFound, isCancelled) }
        } catch (e: Exception) { emptyList() }
        finally { if (lock.isHeld) runCatching { lock.release() } }
}

/**
 * Re-announces this device on the multicast group every [intervalMs] while it is idle, so a peer that joined the network
 * after our last announcement (or missed it) can still find a phone that has been sitting in the background service.
 *
 * Bounded by construction: one window at a time (fixed *delay*, never a backlog), each window itself bounded by
 * [MulticastWindow]'s `windowMs` and holding the lock only for that long, skipped while a transfer or consent prompt is
 * active ([isIdle]), and [runNow] is rate-limited to [minGapMs]. [announce] is the whole window (lock + discovery).
 */
class PeriodicAnnouncer(
    private val intervalMs: Long,
    private val isIdle: () -> Boolean,
    private val announce: () -> Unit,
    private val minGapMs: Long = 10_000,
    private val clock: () -> Long = System::currentTimeMillis,
    private val newExecutor: () -> java.util.concurrent.ScheduledExecutorService = {
        java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "haloshare-announce").apply { isDaemon = true } }
    },
) {
    private val lock = Any()
    private var executor: java.util.concurrent.ScheduledExecutorService? = null
    private var stopped = true
    private var lastRunAt = Long.MIN_VALUE / 2
    private var windows = 0
    /** How many windows have actually run. For tests / diagnostics. */
    val windowsRun: Int get() = synchronized(lock) { windows }

    fun start() {
        synchronized(lock) {
            if (!stopped) return
            stopped = false
            val ex = newExecutor(); executor = ex
            ex.scheduleWithFixedDelay({ tick() }, intervalMs, intervalMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
    }

    fun stop() { synchronized(lock) { stopped = true; executor?.shutdownNow(); executor = null } }

    /** An extra window now (e.g. the network changed), subject to the idle rule and [minGapMs]. */
    fun runNow() {
        val ex = synchronized(lock) { if (stopped) return; executor } ?: return
        try { ex.execute { tick(requireGap = true) } } catch (e: java.util.concurrent.RejectedExecutionException) { /* stopped meanwhile */ }
    }

    /** One scheduling decision. @return true if a window ran. */
    internal fun tick(requireGap: Boolean = false): Boolean {
        synchronized(lock) {
            if (stopped) return false
            if (requireGap && clock() - lastRunAt < minGapMs) return false
        }
        if (!isIdle()) return false
        synchronized(lock) { if (stopped) return false; lastRunAt = clock(); windows++ }
        try { announce() } catch (e: Exception) { /* a failed window is just a missed window */ }
        return true
    }
}
