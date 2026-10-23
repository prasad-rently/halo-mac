import Foundation
import Darwin

// MARK: - LocalNetwork

/// Finding out where we are on the network, and which hosts are worth probing.
public enum LocalNetwork {

    public struct Interface: Equatable, Sendable {
        public var name: String
        public var address: String
        public var netmask: String
    }

    /// Active, non-loopback IPv4 interfaces.
    public static func ipv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let mask = p.pointee.ifa_netmask else { continue }
            let name = String(cString: p.pointee.ifa_name)
            // Skip virtual/tunnel interfaces that never carry the LAN.
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("ap"), !name.hasPrefix("gif"), !name.hasPrefix("stf") else { continue }
            func string(_ s: UnsafePointer<sockaddr>) -> String {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(s, socklen_t(s.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                return String(cString: buf)
            }
            result.append(Interface(name: name, address: string(sa), netmask: string(mask)))
        }
        return result
    }

    /// Every other host on the interface's subnet, capped at a /22 (1022 hosts) so a
    /// misconfigured wide mask can't turn a scan into thousands of probes.
    public static func candidateHosts(address: String, netmask: String, maxHosts: Int = 1022) -> [String] {
        guard let ip = ipv4ToUInt32(address), let mask = ipv4ToUInt32(netmask), mask != 0 else { return [] }
        let network = ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }

        var hosts: [String] = []
        var candidate = network + 1
        // If the subnet is wider than the cap, scan a window centred on our own address.
        let total = Int(broadcast - network) - 1
        if total > maxHosts {
            let half = UInt32(maxHosts / 2)
            candidate = max(network + 1, ip > half ? ip - half : network + 1)
        }
        while candidate < broadcast, hosts.count < maxHosts {
            if candidate != ip { hosts.append(uint32ToIPv4(candidate)) }
            candidate += 1
        }
        return hosts
    }

    static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    static func uint32ToIPv4(_ v: UInt32) -> String {
        "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }

    /// Splits `host`, `host:port` and `[v6]:port`. Port defaults to 53317.
    public static func parseHostPort(_ text: String) -> (host: String, port: Int)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("[") {
            guard let close = t.firstIndex(of: "]") else { return nil }
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if rest.isEmpty { return (host, Int(HaloShare.defaultPort)) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        let pieces = t.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 1 { return (t, Int(HaloShare.defaultPort)) }
        guard pieces.count == 2, let port = Int(pieces[1]), (1...65535).contains(port), !pieces[0].isEmpty else { return nil }
        return (String(pieces[0]), port)
    }
}

// MARK: - SubnetScanner

/// The HTTP-scan discovery path (protocol doc §5.2): `GET /info` against every host in the
/// local subnet. This is the **primary** discovery path on iOS, which cannot do multicast
/// without Apple's restricted entitlement.
public struct SubnetScanner: Sendable {
    public var client: HaloShareClient
    public var port: Int
    public var concurrency: Int
    public var timeout: TimeInterval

    public init(client: HaloShareClient, port: Int = Int(HaloShare.defaultPort), concurrency: Int = 48, timeout: TimeInterval = 1.5) {
        self.client = client
        self.port = port
        self.concurrency = concurrency
        self.timeout = timeout
    }

    /// Scans the local interfaces' subnets.
    public func scan(onFound: @escaping @Sendable (Peer) -> Void = { _ in }) async -> [Peer] {
        var hosts: [String] = []
        for iface in LocalNetwork.ipv4Interfaces() {
            hosts.append(contentsOf: LocalNetwork.candidateHosts(address: iface.address, netmask: iface.netmask))
        }
        return await scan(hosts: Array(Set(hosts)).sorted(), onFound: onFound)
    }

    /// Probes an explicit host list, `concurrency` at a time. Cancellable. De-duplicated by
    /// fingerprint.
    public func scan(hosts: [String], onFound: @escaping @Sendable (Peer) -> Void = { _ in }) async -> [Peer] {
        var found: [String: Peer] = [:]
        await withTaskGroup(of: Peer?.self) { group in
            var iterator = hosts.makeIterator()
            var inFlight = 0
            func addNext() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask { await client.probe(host: host, port: port, timeout: timeout) }
                inFlight += 1
                return true
            }
            while inFlight < concurrency, addNext() {}
            for await result in group {
                inFlight -= 1
                if let peer = result, found[peer.id] == nil {
                    found[peer.id] = peer
                    onFound(peer)
                }
                if Task.isCancelled { group.cancelAll(); continue }
                _ = addNext()
            }
        }
        return found.values.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }
}
