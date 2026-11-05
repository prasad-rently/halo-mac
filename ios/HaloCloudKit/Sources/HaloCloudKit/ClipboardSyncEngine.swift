import Foundation
import CryptoKit

// F-045 on the iPhone. Foreground / manual only: iOS gives no background clipboard access, so the app
// publishes ONLY when the user explicitly sends the current pasteboard, and shows remote items as a history the
// user copies from by tapping. It never overwrites the live pasteboard on its own (D9).
//
// Wire: `clipboard/{uid}/items/{itemId}` -> ClipboardEnvelope (same as Halo/Features/ClipboardSync and
// ClipboardSyncEngine.kt), content AES-GCM under the shared key.

public enum ClipEvent: Equatable, Sendable {
    case item(RemoteClip)
    case removed(id: String)
    case undecryptable(id: String)
    case connection(SyncConnection)
}

public actor ClipboardSyncEngine {
    public enum PublishResult: Equatable, Sendable {
        case sent(itemId: String)
        case duplicate
        case empty
        case tooLarge
        case failed(String)
    }

    /// Sanity bound, not a product limit: an RTDB write is capped at 16 MB, and a pasteboard can hold a book.
    public static let maxCharacters = 200_000
    public static let cap = 500
    private static let sweepInterval: TimeInterval = 30

    private let db: RealtimeDatabase
    private let crypto: CryptoService
    private let deviceId: String
    private let deviceName: String
    private let clock: @Sendable () -> Date

    private var seenItemIds: Set<String> = []
    private var lastHash: String?
    private var lastSweep = Date.distantPast

    public init(db: RealtimeDatabase, crypto: CryptoService, deviceId: String, deviceName: String,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.crypto = crypto; self.deviceId = deviceId; self.deviceName = deviceName; self.clock = clock
    }

    /// `url` for a single-line http(s) address, else `text` (code detection is a desktop nicety).
    public static func kind(of text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("\n"), !t.contains(" "), t.hasPrefix("http://") || t.hasPrefix("https://"),
           URL(string: t)?.host?.isEmpty == false { return "url" }
        return "text"
    }

    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Publish what the user chose to send. Encrypt (D2) → put → cap-sweep (D4).
    public func publish(_ text: String) async -> PublishResult {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.count > Self.maxCharacters { return .tooLarge }
        let h = Self.sha256(text)
        if h == lastHash { return .duplicate }
        lastHash = h
        do {
            let uid = try await db.uid()
            let id = UUID().uuidString               // uppercase, like the desktop's UUID().uuidString
            seenItemIds.insert(id)
            let env = ClipboardEnvelope(itemId: id, deviceId: deviceId, deviceName: deviceName, kind: Self.kind(of: text),
                                        contentEnc: try crypto.encrypt(text), createdAtMs: (clock().timeIntervalSince1970 * 1000).rounded())
            try await db.put("clipboard/\(uid)/items/\(id)", env.node())
            await sweepCap(uid: uid)
            return .sent(itemId: id)
        } catch {
            lastHash = nil                           // let the same text be retried
            return .failed((error as? CloudError)?.errorDescription ?? "Upload failed.")
        }
    }

    /// Existing items first, then new ones. Our own copies and re-deliveries are dropped (D3, D8).
    public nonisolated func incoming() -> AsyncStream<ClipEvent> {
        AsyncStream { cont in
            let task = Task {
                guard let uid = try? await self.db.uid() else { cont.yield(.connection(.failed("Couldn't sign in."))); cont.finish(); return }
                for await ev in self.db.observeChildren("clipboard/\(uid)/items") {
                    switch ev {
                    case .connected: cont.yield(.connection(.live))
                    case .disconnected: cont.yield(.connection(.offline))
                    case .removed(let key): await self.forget(key); cont.yield(.removed(id: key))
                    case .added(let key, let value): if let out = await self.receive(key: key, value: value) { cont.yield(out) }
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func forget(_ id: String) { seenItemIds.remove(id) }

    private func receive(key: String, value: JSONValue) -> ClipEvent? {
        guard let env = ClipboardEnvelope.from(value) else { return nil }
        guard env.deviceId != deviceId else { return nil }                     // our own copy (echo)
        guard seenItemIds.insert(env.itemId).inserted else { return nil }      // re-delivery on reconnect
        guard let text = try? crypto.decrypt(env.contentEnc) else { return .undecryptable(id: env.itemId) }
        return .item(RemoteClip(id: env.itemId, text: text, kind: env.kind, language: env.language, deviceId: env.deviceId,
                                deviceName: env.deviceName, createdAt: Date(timeIntervalSince1970: env.createdAtMs / 1000)))
    }

    /// A remote clip the user explicitly copied locally: it must not be re-sent as if it were new.
    public func suppressEcho(_ text: String) { lastHash = Self.sha256(text) }

    /// The primary privacy control (D10): remove every synced item from the cloud.
    public func purge() async throws {
        let uid = try await db.uid()
        try await db.delete("clipboard/\(uid)/items")
        seenItemIds.removeAll()
    }

    private func sweepCap(uid: String) async {
        let now = clock()
        guard now.timeIntervalSince(lastSweep) >= Self.sweepInterval else { return }
        lastSweep = now
        guard let items = try? await db.get("clipboard/\(uid)/items").children, items.count > Self.cap else { return }
        let oldest = items.map { ($0.key, $0.value["createdAt"]?.doubleValue ?? 0) }.sorted { $0.1 < $1.1 }
        for (k, _) in oldest.prefix(items.count - Self.cap) { try? await db.delete("clipboard/\(uid)/items/\(k)") }
    }
}
