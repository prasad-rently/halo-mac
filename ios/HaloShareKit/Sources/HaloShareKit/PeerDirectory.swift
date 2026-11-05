import Foundation

// MARK: - PeerDirectory

/// The list of devices the UI shows. Pure value logic, so the rules are testable:
///
/// - **De-duplicated by fingerprint** (MR-DI-3) — the same phone found by both the scan and a
///   manual address is one row.
/// - **A fingerprint is a claim, not proof** (LocalSend v2 over HTTP has no authentication), so
///   the *first* host seen for a fingerprint keeps its row. Another host announcing the same
///   fingerprint cannot take the row over (and with it whatever the person then sends to
///   "Mac"); only the host that owns the row can refresh it. A genuine move to another address
///   (new Wi-Fi, hotspot) arrives as a network change, which clears the list — see
///   `AppModel.networkChanged` — and the device is simply found again.
/// - **Never ourselves.** Probing our own address (a manual `127.0.0.1`, a scan hitting our
///   own interface) answers with our own server.
/// - A *different* fingerprint at the **same host:port** replaces the old row — the device was
///   reinstalled or regenerated its identity, and the old entry can no longer be reached.
public struct PeerDirectory: Sendable, Equatable {
    public private(set) var peers: [Peer] = []
    public var ownFingerprint: String

    public init(ownFingerprint: String) { self.ownFingerprint = ownFingerprint }

    public enum MergeOutcome: Sendable, Equatable {
        case added, updated
        /// It is this device.
        case ignoredSelf
        /// The fingerprint is already listed at a different host; the existing row is kept.
        case ignoredConflict(existingHost: String)
    }

    /// Returns `false` when the peer was ignored (it is us, or another host claimed a
    /// fingerprint that is already listed). Use `mergeOutcome` to tell those apart.
    @discardableResult
    public mutating func merge(_ peer: Peer) -> Bool {
        switch mergeOutcome(peer) {
        case .added, .updated: return true
        case .ignoredSelf, .ignoredConflict: return false
        }
    }

    public mutating func mergeOutcome(_ peer: Peer) -> MergeOutcome {
        guard peer.id != ownFingerprint else { return .ignoredSelf }
        let outcome: MergeOutcome
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            // First sighting wins: a different host cannot take over this fingerprint's row.
            guard peers[i].host == peer.host else { return .ignoredConflict(existingHost: peers[i].host) }
            if peer.lastSeen >= peers[i].lastSeen { peers[i] = peer }
            outcome = .updated
        } else {
            // A *different* identity at the same host:port: the old one was reinstalled.
            peers.removeAll { $0.host == peer.host && $0.port == peer.port }
            peers.append(peer)
            outcome = .added
        }
        peers.sort {
            let c = $0.alias.localizedCaseInsensitiveCompare($1.alias)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        return outcome
    }

    public mutating func removeAll() { peers.removeAll() }
    public func peer(id: String?) -> Peer? { id.flatMap { id in peers.first { $0.id == id } } }
}

// MARK: - ManualAddressBook

/// Addresses the user typed in, remembered (MR-DI-2) so they are probed again on every scan —
/// networks that block discovery are exactly the ones that need them.
public struct ManualAddressBook {
    public static let key = "haloshare.manualAddresses"
    private let store: IdentityStore
    private let limit: Int

    public init(store: IdentityStore, limit: Int = 8) { self.store = store; self.limit = limit }

    public var addresses: [String] {
        guard let json = store.string(forKey: Self.key), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        // Whatever is on disk is re-validated: a hand-edited or corrupt entry never reaches a probe.
        return list.compactMap { Self.normalise($0) }
    }

    /// Most recent first, de-duplicated, capped. Returns the stored form, or `nil` if invalid.
    @discardableResult
    public func remember(_ text: String) -> String? {
        guard let normal = Self.normalise(text) else { return nil }
        var list = addresses.filter { $0 != normal }
        list.insert(normal, at: 0)
        save(Array(list.prefix(limit)))
        return normal
    }

    public func forget(_ address: String) { save(addresses.filter { $0 != address }) }

    public static func normalise(_ text: String) -> String? {
        guard let (host, port) = LocalNetwork.parseHostPort(text) else { return nil }
        // Only literals and plain hostnames: no whitespace, slashes or schemes smuggled through.
        guard host.range(of: #"^[A-Za-z0-9.\-:_]+$"#, options: .regularExpression) != nil else { return nil }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func save(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) {
            store.set(json, forKey: Self.key)
        }
    }
}
