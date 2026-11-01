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
        val alias = info.alias.filter { !it.isISOControl() }.trim().take(MAX_ALIAS)
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

/** Real UDP multicast on every usable IPv4 interface. The caller must hold Android's MulticastLock (see MulticastScope in :app). */
class UdpMulticastTransport(private val port: Int = HaloShare.DEFAULT_PORT, private val group: String = HaloShare.MULTICAST_GROUP) : DatagramTransport {
    private val addr = InetAddress.getByName(group)
    private val socket = MulticastSocket(port).apply {
        reuseAddress = true
        for (nif in runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull().orEmpty()) {
            if (!nif.isUp || nif.isLoopback || !nif.supportsMulticast()) continue
            runCatching { joinGroup(java.net.InetSocketAddress(addr, port), nif) }
        }
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
