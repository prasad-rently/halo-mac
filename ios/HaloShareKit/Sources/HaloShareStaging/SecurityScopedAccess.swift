import Foundation

/// Holds security-scoped access (document picker / Files URLs) for exactly as long as a send
/// needs it, and releases **only what it actually acquired, exactly once**.
///
/// `stopAccessingSecurityScopedResource()` must be balanced against a `start…` that returned
/// `true`; calling it for a URL that was never scoped (e.g. one the app owns) or twice is a
/// bug that can drop another holder's access. The closures are injectable so this is testable
/// without a real sandbox.
public final class SecurityScopedAccess: @unchecked Sendable {
    public typealias Start = @Sendable (URL) -> Bool
    public typealias Stop = @Sendable (URL) -> Void

    private let start: Start
    private let stop: Stop
    private let lock = NSLock()
    private var held: [URL] = []

    public init(start: @escaping Start = { $0.startAccessingSecurityScopedResource() },
                stop: @escaping Stop = { $0.stopAccessingSecurityScopedResource() }) {
        self.start = start
        self.stop = stop
    }

    /// Starts access for each URL; remembers the ones that were granted.
    public func begin(_ urls: [URL]) {
        for url in urls where start(url) {
            lock.withLock { held.append(url) }
        }
    }

    public var heldCount: Int { lock.withLock { held.count } }

    /// Releases everything held. Safe to call any number of times.
    public func end() {
        let toStop = lock.withLock { () -> [URL] in
            defer { held.removeAll() }
            return held
        }
        toStop.forEach(stop)
    }

    deinit { end() }
}
