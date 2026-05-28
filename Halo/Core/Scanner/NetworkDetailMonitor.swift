import Foundation
import Network
import SystemConfiguration

// MARK: - NetworkDetailMonitor  (P3-05)
//
// Two modes:
//   • VPN detection — event-driven NWPathMonitor, always-background, zero polling cost
//   • Detail fetch  — foreground, one-shot per session open (public IP)

actor NetworkDetailMonitor {

    // MARK: - Public model

    struct InterfaceInfo: Identifiable, Sendable {
        let id: String          // interface name e.g. "en0"
        let type: String        // "Wi-Fi", "Ethernet", "VPN", "Other"
        let ipv4: String?
        let ipv6: String?
        let isActive: Bool
    }

    struct NetworkDetail: Sendable {
        var localIPv4: String?
        var localIPv6: String?
        var wifiSSID: String?
        var wifiSignalDBm: Int?
        var publicIP: String?        // nil until fetched
        var isVPN: Bool
        var activeInterface: String?
        var interfaces: [InterfaceInfo]
    }

    // MARK: - Private state

    private var pathMonitor: NWPathMonitor?
    private var cachedPublicIP: String?
    private var vpnChangeCallback: (@Sendable (Bool) -> Void)?
    private var currentPath: NWPath?

    // MARK: - VPN monitoring (always-background, event-driven)

    func startVPNMonitoring(onChange: @Sendable @escaping (Bool) -> Void) {
        vpnChangeCallback = onChange
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "halo.network.monitor", qos: .utility))
    }

    private func handlePathUpdate(_ path: NWPath) {
        currentPath = path
        let isVPN = detectVPN(path: path)
        vpnChangeCallback?(isVPN)
    }

    // MARK: - Detail fetch (foreground, one-shot)

    func fetchDetail() async -> NetworkDetail {
        let path = currentPath
        let isVPN = path.map { detectVPN(path: $0) } ?? false
        let ifaces = readInterfaces()
        let activeIface = ifaces.first(where: { $0.isActive })

        return NetworkDetail(
            localIPv4: activeIface?.ipv4 ?? ifaces.first(where: { $0.ipv4 != nil })?.ipv4,
            localIPv6: activeIface?.ipv6 ?? ifaces.first(where: { $0.ipv6 != nil })?.ipv6,
            wifiSSID: readSSID(),
            wifiSignalDBm: nil,   // requires CoreWLAN entitlement; shown as "—" in UI
            publicIP: cachedPublicIP,
            isVPN: isVPN,
            activeInterface: activeIface?.id,
            interfaces: ifaces
        )
    }

    /// Fetches public IP from api.ipify.org — one-shot, result cached for session.
    func fetchPublicIP() async -> String? {
        if let cached = cachedPublicIP { return cached }
        let url = URL(string: "https://api.ipify.org?format=json")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let ip = json["ip"] else { return nil }
        cachedPublicIP = ip
        return ip
    }

    // MARK: - VPN detection

    private func detectVPN(path: NWPath) -> Bool {
        if path.usesInterfaceType(.other) { return true }
        // Check interface names for VPN prefixes
        return readInterfaces().contains { iface in
            let n = iface.id
            return n.hasPrefix("utun") || n.hasPrefix("ppp") ||
                   n.hasPrefix("ipsec") || n.hasPrefix("tun") ||
                   n.hasPrefix("tap")
        }
    }

    // MARK: - Interface enumeration

    private func readInterfaces() -> [InterfaceInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var seen: [String: (ipv4: String?, ipv6: String?)] = [:]
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            let family = current.pointee.ifa_addr?.pointee.sa_family

            if family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr!.pointee.sa_len),
                            &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                var existing = seen[name] ?? (nil, nil)
                existing.0 = ip
                seen[name] = existing
            } else if family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr!.pointee.sa_len),
                            &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                var existing = seen[name] ?? (nil, nil)
                existing.1 = ip
                seen[name] = existing
            }
        }

        return seen.map { (name, ips) in
            let type: String
            if name.hasPrefix("en")    { type = name == "en0" ? "Wi-Fi" : "Ethernet" }
            else if name.hasPrefix("utun") || name.hasPrefix("ppp") ||
                    name.hasPrefix("ipsec") { type = "VPN" }
            else if name == "lo0"      { type = "Loopback" }
            else                       { type = "Other" }

            let isActive = ips.0 != nil && ips.0 != "127.0.0.1"
            return InterfaceInfo(id: name, type: type, ipv4: ips.0, ipv6: ips.1, isActive: isActive)
        }
        .filter { $0.id != "lo0" }
        .sorted { $0.id < $1.id }
    }

    // MARK: - WiFi SSID
    // Note: CNCopyCurrentNetworkInfo requires com.apple.developer.networking.wifi-info
    // entitlement on macOS 12+. We read the SSID via CoreWLAN interface name lookup instead.

    private func readSSID() -> String? {
        // CNCopyCurrentNetworkInfo requires com.apple.developer.networking.wifi-info
        // on macOS 12+. We use `networksetup -getairportnetwork en0` instead,
        // which works without entitlements in non-sandboxed debug builds.
        return readSSIDViaWiFiInterface()
    }

    private func readSSIDViaWiFiInterface() -> String? {
        // Read current SSID via networksetup if available (no entitlement needed in debug)
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = ["-getairportnetwork", "en0"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // Output format: "Current Wi-Fi Network: SSID Name"
        if let range = output.range(of: "Current Wi-Fi Network: ") {
            let ssid = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ssid.isEmpty ? nil : ssid
        }
        return nil
    }
}
