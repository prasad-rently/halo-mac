import Foundation
import Darwin
import Network

actor MulticastDiscovery {
    private let multicastGroup = "224.0.0.167"
    private let port: UInt16 = 53317
    private var socket: Int32 = -1
    private var isListening = false
    private var broadcastTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var onDeviceDiscovered: ((ShareDevice, String) -> Void)?

    func startListening(onDevice: @escaping (ShareDevice, String) -> Void) async throws {
        onDeviceDiscovered = onDevice
        try setupSocket()
        isListening = true

        listenTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        broadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.broadcastAnnounce()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    func broadcastAnnounce() async {
        let info = TLSManager.shared.deviceInfoDTO()
        let announce = MulticastAnnounce(
            alias: info.alias,
            version: info.version,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            port: info.port,
            protocol_: info.protocol_,
            download: info.download,
            announce: true
        )
        guard let data = try? JSONEncoder().encode(announce) else { return }
        sendUDP(data: data, to: multicastGroup, port: port)
    }

    func replyTo(ip: String, port replyPort: UInt16) async {
        let info = TLSManager.shared.deviceInfoDTO()
        let announce = MulticastAnnounce(
            alias: info.alias,
            version: info.version,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            port: info.port,
            protocol_: info.protocol_,
            download: info.download,
            announce: false
        )
        guard let data = try? JSONEncoder().encode(announce) else { return }
        sendUDP(data: data, to: ip, port: replyPort)
    }

    func stop() {
        isListening = false
        listenTask?.cancel()
        broadcastTask?.cancel()
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
    }

    // MARK: - Subnet Scan Fallback

    func scanSubnet(port: UInt16 = 53317) async -> [ShareDevice] {
        guard let localIP = getLocalIPAddress() else { return [] }
        let components = localIP.split(separator: ".")
        guard components.count == 4, let subnet = components.dropLast().joined(separator: ".") as String? else { return [] }

        var devices: [ShareDevice] = []
        await withTaskGroup(of: ShareDevice?.self) { group in
            for i in 1...254 {
                let ip = "\(subnet).\(i)"
                if ip == localIP { continue }
                group.addTask {
                    await self.probeDevice(ip: ip, port: port)
                }
            }
            for await device in group {
                if let device { devices.append(device) }
            }
        }
        return devices
    }

    // MARK: - Private

    private func setupSocket() throws {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw LocalShareError.serverStartFailed("Failed to create UDP socket") }

        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LocalShareError.serverStartFailed("Bind failed on port \(port)") }

        // Join multicast group
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(multicastGroup)
        mreq.imr_interface.s_addr = INADDR_ANY.bigEndian
        setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        // Don't receive our own packets
        var loop: UInt8 = 0
        setsockopt(socket, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))

        // TTL = 1 (local subnet only)
        var ttl: UInt8 = 1
        setsockopt(socket, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var senderAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while isListening && !Task.isCancelled {
            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(socket, &buffer, buffer.count, 0, sockPtr, &addrLen)
                }
            }
            guard bytesRead > 0 else { continue }

            let data = Data(bytes: buffer, count: bytesRead)
            let senderIP = String(cString: inet_ntoa(senderAddr.sin_addr))

            // Skip our own fingerprint
            if let announce = try? JSONDecoder().decode(MulticastAnnounce.self, from: data),
               announce.fingerprint != TLSManager.shared.fingerprint {
                let device = ShareDevice(
                    alias: announce.alias,
                    version: announce.version,
                    deviceModel: announce.deviceModel,
                    deviceType: announce.deviceType.flatMap { DeviceType(rawValue: $0) },
                    fingerprint: announce.fingerprint,
                    port: announce.port,
                    protocol_: TransportProtocol(rawValue: announce.protocol_) ?? .http,
                    download: announce.download,
                    ipAddress: senderIP,
                    lastSeen: Date()
                )
                onDeviceDiscovered?(device, senderIP)
            }
        }
    }

    private func sendUDP(data: Data, to ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)

        data.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(socket, rawBuffer.baseAddress, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func probeDevice(ip: String, port: UInt16) async -> ShareDevice? {
        guard let url = URL(string: "http://\(ip):\(port)/api/localsend/v2/info") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let dto = try JSONDecoder().decode(DeviceInfoDTO.self, from: data)
            return ShareDevice(
                alias: dto.alias,
                version: dto.version,
                deviceModel: dto.deviceModel,
                deviceType: dto.deviceType.flatMap { DeviceType(rawValue: $0) },
                fingerprint: dto.fingerprint,
                port: dto.port,
                protocol_: TransportProtocol(rawValue: dto.protocol_) ?? .http,
                download: dto.download,
                ipAddress: ip,
                lastSeen: Date()
            )
        } catch {
            return nil
        }
    }

    private func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }
}
