import Foundation

// MARK: - HelperClient  (F-002)
//
// Main-app-side wrapper for the HaloHelper XPC service.
//
// The class is NOT globally isolated to @MainActor so that its public API
// is callable from any concurrency context (including the SPM test runner).
// SwiftUI-binding members (isConnected, connect, disconnect) are individually
// annotated @MainActor — callers from SwiftUI always run on main anyway.
//
// Test injection: pass a MockHelper to init(proxy:) — all API calls are then
// synchronous with no continuation or executor overhead.

final class HelperClient: ObservableObject {

    // MARK: - Shared singleton

    @MainActor static let shared = HelperClient()

    // MARK: - Published state  (SwiftUI binding — main actor only)

    @MainActor @Published var isConnected: Bool = false

    // MARK: - Private storage

    @MainActor private var connection: NSXPCConnection?

    // Immutable after init — safe to read from any context.
    // Uses HelperProxying (Swift-only) so test mocks don't need to be @objc,
    // avoiding ObjC completion-handler bridging that deadlocks SPM test runner.
    private let injectedProxy: (any HelperProxying)?

    // MARK: - Init

    /// Production init — uses real NSXPCConnection.
    init() {
        self.injectedProxy = nil
    }

    /// Test / preview init — injects a synchronous mock, bypassing XPC entirely.
    init(proxy: (any HelperProxying)?) {
        self.injectedProxy = proxy
    }

    // MARK: - Availability

    var isAvailable: Bool { injectedProxy != nil }

    // MARK: - Public API
    //
    // Mock path:  injectedProxy replies synchronously — no await, no executor hop.
    // Production: hops to @MainActor to access the XPC connection.

    func flushDNS() async -> Bool {
        if let proxy = injectedProxy {
            var result = false
            proxy.flushDNS { result = $0 }
            return result
        }
        return await _flushDNSXPC()
    }

    func purgeRAM() async -> Double {
        if let proxy = injectedProxy {
            var result = 0.0
            proxy.purgeRAM { result = $0 }
            return result
        }
        return await _purgeRAMXPC()
    }

    func rebuildSpotlightIndex() async -> Bool {
        if let proxy = injectedProxy {
            var result = false
            proxy.rebuildSpotlightIndex { result = $0 }
            return result
        }
        return await _rebuildSpotlightXPC()
    }

    func clearFontCache() async -> Bool {
        if let proxy = injectedProxy {
            var result = false
            proxy.clearFontCache { result = $0 }
            return result
        }
        return await _clearFontCacheXPC()
    }

    func helperVersion() async -> String? {
        guard isAvailable else { return nil }
        if let proxy = injectedProxy {
            var result: String?
            proxy.helperVersion { result = $0 }
            return result
        }
        return await _helperVersionXPC()
    }

    // MARK: - @MainActor XPC paths (production only)

    @MainActor private func _flushDNSXPC() async -> Bool {
        await withCheckedContinuation { cont in
            xpcProxy?.flushDNS { cont.resume(returning: $0) }
            ?? cont.resume(returning: false)
        }
    }

    @MainActor private func _purgeRAMXPC() async -> Double {
        await withCheckedContinuation { cont in
            xpcProxy?.purgeRAM { cont.resume(returning: $0) }
            ?? cont.resume(returning: 0.0)
        }
    }

    @MainActor private func _rebuildSpotlightXPC() async -> Bool {
        await withCheckedContinuation { cont in
            xpcProxy?.rebuildSpotlightIndex { cont.resume(returning: $0) }
            ?? cont.resume(returning: false)
        }
    }

    @MainActor private func _clearFontCacheXPC() async -> Bool {
        await withCheckedContinuation { cont in
            xpcProxy?.clearFontCache { cont.resume(returning: $0) }
            ?? cont.resume(returning: false)
        }
    }

    @MainActor private func _helperVersionXPC() async -> String? {
        await withCheckedContinuation { cont in
            xpcProxy?.helperVersion { cont.resume(returning: $0) }
            ?? cont.resume(returning: nil)
        }
    }

    // MARK: - Connection management  (@MainActor — used by SwiftUI views)

    @MainActor func connect() {
        guard injectedProxy == nil else { return }
        let conn = NSXPCConnection(serviceName: "com.halo.mac.helper")
        conn.remoteObjectInterface = NSXPCInterface(with: HaloHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.isConnected = false
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.isConnected = false
            }
        }
        conn.resume()
        connection = conn
        isConnected = true
    }

    @MainActor func disconnect() {
        connection?.invalidate()
        connection = nil
        isConnected = false
    }

    // MARK: - XPC proxy

    @MainActor private var xpcProxy: (any HaloHelperProtocol)? {
        if connection == nil { connect() }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isConnected = false
                self?.connection = nil
            }
        } as? any HaloHelperProtocol
    }
}
