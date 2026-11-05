import Foundation
import Network

/// A fingerprint of "which networks am I on" — the IPv4 interfaces and their masks. A scan is
/// only worth repeating when this changes (joined another Wi-Fi, came off a VPN, plugged in),
/// not on every path-status flutter.
public struct NetworkSignature: Equatable, Sendable {
    public let value: String

    public init(value: String) { self.value = value }

    public static func make(from interfaces: [LocalNetwork.Interface]) -> NetworkSignature {
        NetworkSignature(value: interfaces.map { "\($0.name)=\($0.address)/\($0.netmask)" }.sorted().joined(separator: ","))
    }

    public static func current() -> NetworkSignature { make(from: LocalNetwork.ipv4Interfaces()) }
    public var isOffline: Bool { value.isEmpty }
}

/// Decides, from a stream of signatures, when to say "the network changed".
public struct NetworkChangeDetector: Sendable {
    private var last: NetworkSignature?
    public init() {}

    /// The first observation only records a baseline. After that, any different signature —
    /// including going offline — is a change.
    public mutating func observe(_ signature: NetworkSignature) -> Bool {
        defer { last = signature }
        guard let last else { return false }
        return last != signature
    }
}

/// `NWPathMonitor` + `NetworkChangeDetector`, debounced (a Wi-Fi roam produces a burst of path
/// updates; the interface table is stable only after they settle).
public final class NetworkChangeMonitor: @unchecked Sendable {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "halo.share.netchange")
    private let debounce: TimeInterval
    private let signature: @Sendable () -> NetworkSignature
    private let onChange: @Sendable (NetworkSignature) -> Void
    private var detector = NetworkChangeDetector()
    private var pending: DispatchWorkItem?
    private var running = false

    public init(debounce: TimeInterval = 1.5,
                signature: @escaping @Sendable () -> NetworkSignature = { NetworkSignature.current() },
                onChange: @escaping @Sendable (NetworkSignature) -> Void) {
        self.debounce = debounce; self.signature = signature; self.onChange = onChange
    }

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            detector = NetworkChangeDetector()
            _ = detector.observe(signature())                 // baseline
        }
        // An NWPathMonitor cannot be restarted once cancelled, so each start makes a fresh one.
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.pathChanged() }
        queue.sync { monitor = m }
        m.start(queue: queue)
    }

    public func stop() {
        queue.sync { monitor?.cancel(); monitor = nil; running = false; pending?.cancel(); pending = nil }
    }

    private func pathChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            let sig = self.signature()
            if self.detector.observe(sig) { self.onChange(sig) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
