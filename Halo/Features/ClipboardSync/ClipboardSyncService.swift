import Foundation
import FirebaseDatabase   // DatabaseHandle

// MARK: - ClipboardSyncService  (F-045)
//
// Cross-device clipboard sync on the user's own Firebase, reusing the F-044 cloud
// core (FirebaseRTDBClient, CryptoService, CloudConfigStore). Publishes local
// copies (encrypted) to `clipboard/{uid}/items` and observes remote items,
// decrypting and handing them to AppState for **history-only** insertion (D9 — the
// active pasteboard is never auto-overwritten). Echo suppression is by `deviceId`
// (D3) plus an itemId dedup set for reconnect re-delivery.

@MainActor
final class ClipboardSyncService: ObservableObject {

    enum State: Equatable {
        case unconfigured, connecting, connected(uid: String), error(String)
    }

    @Published private(set) var state: State = .unconfigured
    @Published private(set) var syncEnabled: Bool =
        UserDefaults.standard.bool(forKey: ClipboardSyncService.enabledKey)
    @Published var filterSensitive: Bool =
        UserDefaults.standard.bool(forKey: ClipboardSyncService.filterKey) {
        didSet { UserDefaults.standard.set(filterSensitive, forKey: Self.filterKey) }
    }

    /// Remote item ready to enter local history (history-only, D9).
    var onRemoteItem: ((ClipboardItem) -> Void)?
    /// Cloud purge finished — clear synced items from local history.
    var onPurge: (() -> Void)?

    static let enabledKey = "clipboardSyncEnabled"
    static let filterKey = "clipboardSyncFilterSensitive"
    private static let deviceIdKey = "haloCloudDeviceId"

    private let store = CloudConfigStore.shared
    private let rtdb = FirebaseRTDBClient.shared
    private var crypto: CryptoService?
    private var observer: (path: String, handle: DatabaseHandle)?
    private var seenItemIds: Set<String> = []
    private var lastSweep = Date.distantPast

    /// Stable per-device id (persisted) + a human name for provenance badges.
    let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }()
    let deviceName: String = Host.current().localizedName ?? "Mac"

    var isConfigured: Bool { store.isConfigured }

    // MARK: Lifecycle

    /// Connect using the shared F-044 config/auth + a passphrase (from the user or
    /// the Keychain cache), then subscribe to remote items.
    func connect(passphrase: String) async {
        guard let config = store.firebaseConfig, let auth = store.authCredential else {
            state = .unconfigured; return
        }
        state = .connecting
        do {
            try await rtdb.configure(config)
            let uid = try await rtdb.signIn(email: auth.email, password: auth.password)
            crypto = try store.makeCryptoService(passphrase: passphrase)
            state = .connected(uid: uid)
            await subscribe(uid: uid)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func setEnabled(_ on: Bool) {
        syncEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { Task { await teardown() } }
    }

    private func subscribe(uid: String) async {
        await teardown()
        do {
            let path = "clipboard/\(uid)/items"
            let handle = try await rtdb.observeChildAdded(at: path) { [weak self] _, value in
                Task { @MainActor in self?.handleRemote(value) }
            }
            observer = (path: path, handle: handle)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func teardown() async {
        if let o = observer {
            try? await rtdb.removeObserver(at: o.path, handle: o.handle)
            observer = nil
        }
    }

    // MARK: Publish (local copy → cloud)

    /// Publish a locally-copied item. No-ops for received items (echo), non-syncable
    /// kinds (image/color, D6), and — when the opt-in filter is on — likely secrets.
    func publishLocal(_ item: ClipboardItem) {
        guard syncEnabled, case let .connected(uid) = state, let crypto else { return }
        guard item.syncedFrom == nil else { return }                 // never re-publish (echo, D3)
        guard let s = Self.serialize(item.content) else { return }   // text/url/code only (D6)
        if filterSensitive && ClipboardSensitiveFilter.isSensitive(s.text) { return }

        let itemId = item.id.uuidString
        seenItemIds.insert(itemId)
        Task {
            do {
                let env = ClipboardSyncEnvelope(
                    itemId: itemId, deviceId: deviceId, deviceName: deviceName,
                    kind: s.kind, contentEnc: try crypto.encrypt(s.text), language: s.lang,
                    createdAt: item.copiedDate.timeIntervalSince1970 * 1000)
                try await rtdb.setValue(env.node(), at: "clipboard/\(uid)/items/\(itemId)")
                await sweepCloudCap(uid: uid)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Receive (cloud → local history)

    private func handleRemote(_ value: Any?) {
        guard let crypto, let env = ClipboardSyncEnvelope.from(value) else { return }
        guard env.deviceId != deviceId else { return }                // our own copy (echo, D3)
        guard seenItemIds.insert(env.itemId).inserted else { return }  // dedup re-delivery (D8)
        guard let text = try? crypto.decrypt(env.contentEnc) else { return }
        onRemoteItem?(Self.makeItem(env, text: text))
    }

    // MARK: Purge (primary privacy control, D10)

    func purge() async {
        if case let .connected(uid) = state {
            try? await rtdb.removeValue(at: "clipboard/\(uid)/items")
        }
        seenItemIds.removeAll()
        onPurge?()
    }

    // MARK: Cloud rolling-cap eviction (D4 — 500-item window, no time TTL)

    private func sweepCloudCap(uid: String) async {
        guard Date().timeIntervalSince(lastSweep) > 30 else { return }   // opportunistic
        lastSweep = Date()
        guard let raw = (try? await rtdb.getValue(at: "clipboard/\(uid)/items")) as? [String: Any],
              raw.count > 500 else { return }
        let byAge = raw.compactMap { key, v -> (String, Double)? in
            guard let d = v as? [String: Any] else { return nil }
            return (key, (d["createdAt"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.1 < $1.1 }
        for (key, _) in byAge.prefix(raw.count - 500) {
            try? await rtdb.removeValue(at: "clipboard/\(uid)/items/\(key)")
        }
    }

    // MARK: Serialize / deserialize

    static func serialize(_ content: ClipboardContent) -> (kind: String, text: String, lang: String?)? {
        switch content {
        case .text(let s):          return ("text", s, nil)
        case .url(let u):           return ("url", u.absoluteString, nil)
        case .code(let c, let l):   return ("code", c, l)
        case .image, .color:        return nil   // v1: not synced (D6)
        }
    }

    static func makeItem(_ env: ClipboardSyncEnvelope, text: String) -> ClipboardItem {
        let content: ClipboardContent
        switch env.kind {
        case "url":  content = URL(string: text).map { ClipboardContent.url($0) } ?? .text(text)
        case "code": content = .code(text, language: env.language)
        default:     content = .text(text)
        }
        return ClipboardItem(
            id: UUID(uuidString: env.itemId) ?? UUID(),
            content: content,
            copiedDate: Date(timeIntervalSince1970: env.createdAt / 1000),
            sourceApp: env.deviceName,
            syncedFrom: env.deviceName)
    }
}
