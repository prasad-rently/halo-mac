import Foundation

// MARK: - NetworkTrafficMonitor (F-017)
//
// Read-only, per-process network visibility. Sampled on a 2 s cadence by the
// view layer — this actor does no polling of its own.
//
// ============================================================================
// HONESTY / FEASIBILITY NOTE — read before touching this file.
// ============================================================================
// There is NO public macOS API available to a sandboxed or unsandboxed
// third-party app (without a Network Extension / `NEFilterDataProvider`
// entitlement, which Halo does NOT have and which requires special Apple
// approval) that reveals the actual DNS hostname or TLS SNI a process
// requested. `lsof` / `proc_pidinfo` only expose the raw remote IP address
// and port of each open socket — never the domain name the app "meant" to
// connect to. So what this monitor honestly delivers is:
//
//   1. Real open sockets per-process, via `lsof -i -n -P` — accurate,
//      no faking. We only surface entries with a remote peer
//      ("local->remote"), i.e. outbound/established connections.
//   2. Best-effort reverse DNS (PTR record) on the remote IP, via
//      `getaddrinfo` + `getnameinfo(..., NI_NAMEREQD)`. Many IPs — especially
//      behind CDNs/load balancers — either don't reverse-resolve at all, or
//      resolve to a generic infrastructure name (e.g.
//      `server-13-227-180-4.kix82.r.cloudfront.net`, NOT the domain the user
//      would recognize such as the app's actual backend). When resolution
//      fails, `resolvedHost` is left `nil` — we never guess or fabricate a
//      hostname. Results are cached (capped dictionary, oldest-evicted) so
//      the same IP is never re-resolved every tick.
//   3. Real, per-app cumulative byte totals via `nettop -P -L 1 -J
//      bytes_in,bytes_out` — this IS real and accurate at the per-process
//      granularity. `lsof` cannot give cumulative bytes per socket, and
//      neither can any other public API, so per-connection byte counts are
//      intentionally NOT shown — only the honest per-app aggregate.
//
// Tracker-domain flagging (`isSuspicious`) is matched ONLY against a
// hostname that actually resolved — an unresolved IP is never flagged, to
// avoid implying domain-level accuracy we don't have.
// ============================================================================

actor NetworkTrafficMonitor {

    // MARK: - Reverse DNS cache (capped dictionary, oldest-evicted)

    private var dnsCache: [String: String?] = [:]   // ip -> hostname (nil = confirmed unresolved)
    private var dnsCacheOrder: [String] = []
    private let dnsCacheLimit = 500

    /// Test hook — mirrors `SignatureDatabase.signatureCount`. Lets a unit
    /// test assert the cache doesn't grow on a repeated lookup of the same IP.
    var cachedIPCount: Int { dnsCache.count }

    // MARK: - Tracker domain list (bundle-loaded once, same pattern as SignatureDatabase)

    private var trackerDomains: Set<String> = []
    private var trackerListLoaded = false

    private struct TrackerDomainFile: Decodable {
        let version: Int
        let updated: String
        let domains: [String]
    }

    // MARK: - Public API

    /// Full snapshot: open outbound connections (via lsof) + per-app byte totals (via nettop).
    func snapshot() async -> NetworkTrafficSnapshot {
        if !trackerListLoaded { loadTrackerDomains() }

        async let connectionsTask = fetchConnections()
        async let totalsTask = fetchAppTotals()

        var connections = await connectionsTask
        let totals = await totalsTask

        // Best-effort reverse DNS, cached, per unique remote IP in this snapshot.
        var resolvedForIP: [String: String?] = [:]
        for entry in connections {
            if resolvedForIP[entry.remoteIP] == nil {
                resolvedForIP[entry.remoteIP] = await resolveHost(ip: entry.remoteIP)
            }
        }

        for i in connections.indices {
            let host = resolvedForIP[connections[i].remoteIP] ?? nil
            connections[i].resolvedHost = host
            if let host, isTrackerDomain(host) {
                connections[i].isSuspicious = true
            }
        }

        let topTalker = totals.max { $0.totalBytes < $1.totalBytes }

        return NetworkTrafficSnapshot(connections: connections, appTotals: totals, topTalker: topTalker)
    }

    // MARK: - Tracker domain list

    private func loadTrackerDomains() {
        trackerListLoaded = true
        guard let url = Bundle.main.url(forResource: "tracker-domains", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(TrackerDomainFile.self, from: data) else {
            return
        }
        trackerDomains = Set(file.domains.map { $0.lowercased() })
    }

    private func isTrackerDomain(_ host: String) -> Bool {
        Self.matchesTrackerDomain(host, domains: trackerDomains)
    }

    /// Pure matching logic, extracted so it's testable without needing to
    /// spin up the actor or load the bundle resource. A host matches if it
    /// equals a listed domain exactly, or is a subdomain of one (e.g.
    /// `www.doubleclick.net` matches `doubleclick.net`, but
    /// `notdoubleclick.net` does not).
    static func matchesTrackerDomain(_ host: String, domains: Set<String>) -> Bool {
        let lower = host.lowercased()
        return domains.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    // MARK: - lsof-based outbound connection enumeration
    //
    // Parsing note: rather than assuming a fixed trailing-field position (as
    // `PortScanner` does for LISTEN-only queries), we anchor on the literal
    // "TCP"/"UDP" token because `lsof -i -n -P` output width varies — some
    // rows end with a "(STATE)" suffix, some don't (e.g. many UDP sockets).
    // Anchoring on the protocol token keeps parsing correct in both cases.

    private func fetchConnections() async -> [NetworkConnectionEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "-n", "-P"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // suppress stderr (permission-denied lines for other users' sockets)

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return Self.parseLsofOutput(output)
    }

    /// Pure parser for `lsof -i -n -P` output — extracted so it's testable
    /// with captured sample text, no subprocess required. See the parsing
    /// note above `fetchConnections` for why we anchor on the "TCP"/"UDP"
    /// token rather than a fixed column position.
    static func parseLsofOutput(_ output: String, now: Date = Date()) -> [NetworkConnectionEntry] {
        var entries: [NetworkConnectionEntry] = []

        for line in output.components(separatedBy: "\n").dropFirst() where !line.isEmpty {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            guard let protoIndex = parts.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }),
                  protoIndex + 1 < parts.count else { continue }
            let protocolType = parts[protoIndex]
            let addressField = parts[protoIndex + 1]

            // Only outbound/established sockets carry "local->remote" — this
            // is what makes a row "phoning home". LISTEN sockets (*:port)
            // and connectionless UDP sockets with no peer are skipped.
            guard addressField.contains("->") else { continue }
            let sides = addressField.components(separatedBy: "->")
            guard sides.count == 2, let (ip, port) = Self.splitHostPort(sides[1]) else { continue }

            var state = "ACTIVE"
            if protoIndex + 2 < parts.count {
                let maybeState = parts[protoIndex + 2]
                if maybeState.hasPrefix("(") && maybeState.hasSuffix(")") {
                    state = String(maybeState.dropFirst().dropLast())
                }
            }

            entries.append(NetworkConnectionEntry(
                id: UUID(),
                pid: pid,
                processName: processName,
                remoteIP: ip,
                remotePort: port,
                protocolType: protocolType,
                state: state,
                resolvedHost: nil,
                isSuspicious: false,
                lastSeen: now
            ))
        }

        // Dedup identical (pid, remoteIP, remotePort, protocol) sockets.
        var seen = Set<String>()
        var deduped: [NetworkConnectionEntry] = []
        for e in entries {
            let key = "\(e.pid):\(e.remoteIP):\(e.remotePort):\(e.protocolType)"
            if seen.insert(key).inserted { deduped.append(e) }
        }
        return deduped
    }

    /// Splits "ip:port" or "[ipv6]:port" into (host, port).
    static func splitHostPort(_ field: String) -> (String, Int)? {
        if field.hasPrefix("[") {
            guard let closeBracket = field.firstIndex(of: "]") else { return nil }
            let host = String(field[field.index(after: field.startIndex)..<closeBracket])
            let rest = field[field.index(after: closeBracket)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        } else {
            guard let colonIndex = field.lastIndex(of: ":"),
                  let port = Int(field[field.index(after: colonIndex)...]) else { return nil }
            return (String(field[..<colonIndex]), port)
        }
    }

    // MARK: - nettop-based real per-app byte totals
    //
    // `nettop -P -L 1 -J bytes_in,bytes_out` samples once and exits. CSV rows
    // are "process.pid,bytes_in,bytes_out," — verified against real output on
    // this machine. This is a real, accurate per-process aggregate (unlike
    // lsof, which has no byte-counter concept at all).
    //
    // Parsing note: cols[0]'s process-name portion is truncated to a
    // *different* length than lsof's COMMAND column (e.g. nettop shows
    // "Google Chrome H" for the same pid lsof reports as "Google"). Only the
    // trailing ".pid" suffix is trustworthy for joining against lsof rows —
    // see `AppNetworkTotal`'s doc comment. We still keep nettop's (fuller)
    // name for display purposes.

    private func fetchAppTotals() async -> [AppNetworkTotal] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return Self.parseNettopOutput(output)
    }

    /// Pure parser for `nettop -P -L 1 -J bytes_in,bytes_out` CSV output —
    /// extracted so it's testable with captured sample text, no subprocess
    /// required. See the parsing note above `fetchAppTotals` for why the pid
    /// is taken from the trailing ".pid" suffix rather than a delimiter split.
    static func parseNettopOutput(_ output: String) -> [AppNetworkTotal] {
        var totals: [Int32: (name: String, bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for line in output.components(separatedBy: "\n").dropFirst() where !line.isEmpty {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 3 else { continue }

            // cols[0] = "processname.pid" — the pid is everything after the
            // LAST "." (process names never contain a literal "."; nettop
            // appends the pid this way).
            let procField = cols[0]
            guard let dotIndex = procField.lastIndex(of: "."),
                  let pid = Int32(procField[procField.index(after: dotIndex)...]) else { continue }
            let processName = String(procField[..<dotIndex])
            guard !processName.isEmpty else { continue }

            let bytesIn = UInt64(cols[1]) ?? 0
            let bytesOut = UInt64(cols[2]) ?? 0
            guard bytesIn > 0 || bytesOut > 0 else { continue }

            var existing = totals[pid] ?? (processName, 0, 0)
            existing.bytesIn += bytesIn
            existing.bytesOut += bytesOut
            totals[pid] = existing
        }

        return totals
            .map { AppNetworkTotal(pid: $0.key, processName: $0.value.name, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - Reverse DNS (best-effort, cached)

    func resolveHost(ip: String) async -> String? {
        if let cached = dnsCache[ip] {
            return cached
        }
        let host = await Self.performReverseDNS(ip: ip)
        cacheResult(ip: ip, host: host)
        return host
    }

    private func cacheResult(ip: String, host: String?) {
        dnsCache[ip] = host
        dnsCacheOrder.append(ip)
        if dnsCacheOrder.count > dnsCacheLimit {
            let evicted = dnsCacheOrder.removeFirst()
            dnsCache.removeValue(forKey: evicted)
        }
    }

    /// Reverse DNS lookup: IP -> PTR hostname, or nil if none exists.
    /// `NI_NAMEREQD` makes `getnameinfo` fail (rather than echo the numeric
    /// IP back) when there's no PTR record, so a nil here is a genuine "no
    /// hostname available" — never a fabricated fallback.
    private static func performReverseDNS(ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                                      ai_socktype: 0, ai_protocol: 0,
                                      ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let addr = res else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(res) }

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ret = getnameinfo(addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                                       &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
                guard ret == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = String(cString: host)
                continuation.resume(returning: name.isEmpty ? nil : name)
            }
        }
    }
}
