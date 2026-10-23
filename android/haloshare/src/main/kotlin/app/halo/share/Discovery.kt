package app.halo.share

import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** Finding out where we are on the network, and which hosts are worth probing. */
object LocalNetwork {

    data class Interface(val name: String, val address: String, val prefixLength: Int)

    /** Up, non-loopback IPv4 interfaces (skipping tunnels that never carry the LAN). */
    fun ipv4Interfaces(): List<Interface> {
        val result = ArrayList<Interface>()
        val all = runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull().orEmpty()
        for (nif in all) {
            if (!nif.isUp || nif.isLoopback || nif.isVirtual) continue
            val name = nif.name
            if (name.startsWith("tun") || name.startsWith("utun") || name.startsWith("awdl") || name.startsWith("llw")) continue
            for (ia in nif.interfaceAddresses) {
                val a = ia.address as? Inet4Address ?: continue
                result.add(Interface(name, a.hostAddress ?: continue, ia.networkPrefixLength.toInt()))
            }
        }
        return result
    }

    /**
     * Every other host on the subnet, capped at a /22 (1022 hosts) so a misconfigured wide mask
     * can't turn a scan into thousands of probes; a wider subnet is scanned in a window around us.
     */
    fun candidateHosts(address: String, prefixLength: Int, maxHosts: Int = 1022): List<String> {
        val ip = ipv4ToLong(address) ?: return emptyList()
        if (prefixLength !in 1..30) return emptyList()
        val mask = (0xFFFFFFFFL shl (32 - prefixLength)) and 0xFFFFFFFFL
        val network = ip and mask
        val broadcast = network or (mask.inv() and 0xFFFFFFFFL)
        if (broadcast <= network + 1) return emptyList()

        var candidate = network + 1
        val total = (broadcast - network - 1).toInt()
        if (total > maxHosts) candidate = maxOf(network + 1, ip - maxHosts / 2)
        val hosts = ArrayList<String>()
        while (candidate < broadcast && hosts.size < maxHosts) {
            if (candidate != ip) hosts.add(longToIpv4(candidate))
            candidate++
        }
        return hosts
    }

    /** Dotted-quad netmask → prefix length (`255.255.255.0` → 24); null if it isn't contiguous. */
    fun prefixLength(netmask: String): Int? {
        val m = ipv4ToLong(netmask) ?: return null
        val bits = java.lang.Long.bitCount(m)
        val expected = if (bits == 0) 0L else (0xFFFFFFFFL shl (32 - bits)) and 0xFFFFFFFFL
        return if (m == expected) bits else null
    }

    internal fun ipv4ToLong(s: String): Long? {
        val parts = s.split('.').map { it.toLongOrNull() ?: return null }
        if (parts.size != 4 || parts.any { it !in 0..255 }) return null
        return (parts[0] shl 24) or (parts[1] shl 16) or (parts[2] shl 8) or parts[3]
    }

    internal fun longToIpv4(v: Long) = "${(v shr 24) and 255}.${(v shr 16) and 255}.${(v shr 8) and 255}.${v and 255}"

    /** Splits `host`, `host:port` and `[v6]:port`. Port defaults to 53317. */
    fun parseHostPort(text: String): Pair<String, Int>? {
        val t = text.trim()
        if (t.isEmpty()) return null
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close < 0) return null
            val host = t.substring(1, close)
            val rest = t.substring(close + 1)
            if (rest.isEmpty()) return host to HaloShare.DEFAULT_PORT
            if (!rest.startsWith(":")) return null
            val port = rest.drop(1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            return host to port
        }
        val pieces = t.split(':')
        if (pieces.size == 1) return t to HaloShare.DEFAULT_PORT
        if (pieces.size != 2 || pieces[0].isEmpty()) return null
        val port = pieces[1].toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
        return pieces[0] to port
    }
}

/**
 * The HTTP-scan discovery path (protocol doc §5.2): `GET /info` against every host in the local
 * subnet. On Android this complements multicast, and is the only path on networks that block it.
 */
class SubnetScanner(
    private val client: HaloShareClient,
    private val port: Int = HaloShare.DEFAULT_PORT,
    private val concurrency: Int = 48,
    private val timeoutMs: Int = 1500,
) {
    /** Scans the local interfaces' subnets. */
    fun scan(onFound: (Peer) -> Unit = {}, isCancelled: () -> Boolean = { false }): List<Peer> {
        val hosts = LocalNetwork.ipv4Interfaces()
            .flatMap { LocalNetwork.candidateHosts(it.address, it.prefixLength) }
            .distinct().sorted()
        return scan(hosts, onFound, isCancelled)
    }

    /** Probes an explicit host list, [concurrency] at a time; de-duplicated by fingerprint. */
    fun scan(hosts: List<String>, onFound: (Peer) -> Unit = {}, isCancelled: () -> Boolean = { false }): List<Peer> {
        val pool = Executors.newFixedThreadPool(concurrency.coerceAtLeast(1)) { r -> Thread(r, "haloshare-scan").apply { isDaemon = true } }
        try {
            val found = LinkedHashMap<String, Peer>()
            val futures = hosts.map { host ->
                pool.submit(Callable { if (isCancelled()) null else client.probe(host, port, timeoutMs = timeoutMs) })
            }
            for (f in futures) {
                val peer = runCatching { f.get() }.getOrNull() ?: continue
                synchronized(found) {
                    if (peer.id !in found) { found[peer.id] = peer; onFound(peer) }
                }
            }
            return found.values.sortedBy { it.alias.lowercase() }
        } finally { pool.shutdownNow() }
    }
}
