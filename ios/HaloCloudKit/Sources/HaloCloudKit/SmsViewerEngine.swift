import Foundation

// The READ side of the SMS console on iOS. iOS has no API to read the SMS inbox, so the iPhone can only show
// messages an Android phone synced to the user's database (F-044). This engine observes
// `devices/{uid}` + `sms/{uid}/{device}/{lines,messages}`, decrypts address/body with the data key and keeps
// an in-memory model. It never writes, and never persists a decrypted body.
//
// Offline-tolerant: the RTDB observers reconnect with backoff; the model keeps what it has. Cancellable:
// stop iterating `snapshots()` (or cancel the consuming Task) and every observer ends.

public enum SyncConnection: Equatable, Sendable { case connecting, live, offline, failed(String) }

public struct SmsSnapshot: Sendable {
    public var devices: [String: SMSDevice] = [:]
    public var lines: [String: SMSLine] = [:]
    public var messages: [String: SMSMessage] = [:]
    /// Rows whose ciphertext did not open under our key (wrong passphrase / a different key / tampered).
    public var undecryptableCount = 0
    public var connection: SyncConnection = .connecting

    public var threads: [SMSThread] { SMSThread.group(Array(messages.values)) }
}

public actor SmsViewerEngine {
    private let db: RealtimeDatabase
    private let crypto: CryptoService
    private let discoveryInterval: TimeInterval

    private var snap = SmsSnapshot()
    private var undecryptable: Set<String> = []

    public init(db: RealtimeDatabase, crypto: CryptoService, discoveryInterval: TimeInterval = 30) {
        self.db = db; self.crypto = crypto; self.discoveryInterval = discoveryInterval
    }

    /// The current model, then every change. Only the newest snapshot is buffered (a slow consumer skips
    /// intermediate ones, never falls behind).
    public nonisolated func snapshots() -> AsyncStream<SmsSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            let task = Task { await self.run { cont.yield($0) }; cont.finish() }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func run(emit: @escaping @Sendable (SmsSnapshot) -> Void) async {
        snap = SmsSnapshot(); undecryptable = []
        emit(snap)
        let uid: String
        do { uid = try await db.uid() } catch {
            snap.connection = .failed((error as? CloudError)?.errorDescription ?? "Couldn't sign in.")
            emit(snap); return
        }
        let (deviceIds, deviceCont) = AsyncStream.makeStream(of: String.self)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.watchRegistry(uid: uid, ids: deviceCont, emit: emit) }
            group.addTask { await self.discover(uid: uid, ids: deviceCont) }
            var started = Set<String>()
            for await id in deviceIds {
                guard started.insert(id).inserted else { continue }
                group.addTask { await self.watchDevice(uid: uid, id: id, emit: emit) }
            }
            deviceCont.finish()
            group.cancelAll()
        }
    }

    private func watchRegistry(uid: String, ids: AsyncStream<String>.Continuation, emit: @Sendable (SmsSnapshot) -> Void) async {
        for await ev in db.observeChildren("devices/\(uid)") {
            switch ev {
            case .added(let key, let value):
                guard !DatabaseCheckEngine.isProbeKey(key) else { continue }
                snap.devices[key] = SMSWire.decodeDevice(id: key, node: value)
                ids.yield(key)
            case .removed(let key): snap.devices[key] = nil
            case .connected: snap.connection = .live
            case .disconnected: snap.connection = .offline
            }
            emit(snap)
        }
    }

    /// A device can have synced SMS without a registry entry; list `sms/{uid}` keys (keys only — never the
    /// whole subtree) now and periodically.
    private func discover(uid: String, ids: AsyncStream<String>.Continuation) async {
        while !Task.isCancelled {
            if let keys = try? await db.shallowKeys("sms/\(uid)") {
                for k in keys where !DatabaseCheckEngine.isProbeKey(k) { ids.yield(k) }
            }
            try? await Task.sleep(nanoseconds: UInt64(discoveryInterval * 1_000_000_000))
        }
    }

    private func watchDevice(uid: String, id: String, emit: @escaping @Sendable (SmsSnapshot) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await ev in self.db.observeChildren("sms/\(uid)/\(id)/lines") {
                    await self.applyLine(id, ev); await self.publish(emit)
                }
            }
            group.addTask {
                for await ev in self.db.observeChildren("sms/\(uid)/\(id)/messages") {
                    await self.applyMessage(id, ev); await self.publish(emit)
                }
            }
        }
    }

    private func publish(_ emit: @Sendable (SmsSnapshot) -> Void) { snap.undecryptableCount = undecryptable.count; emit(snap) }

    private func applyLine(_ device: String, _ ev: ChildEvent) {
        switch ev {
        case .added(let key, let value):
            let l = SMSWire.decodeLine(deviceId: device, key: key, node: value, crypto: crypto)
            snap.lines[l.id] = l
        case .removed(let key):
            let sub = Int(key) ?? -1
            snap.lines["\(device)-\(sub)"] = nil
        default: break
        }
    }

    private func applyMessage(_ device: String, _ ev: ChildEvent) {
        switch ev {
        case .added(let key, let value):
            let uid = "\(device)/\(key)"
            switch SMSWire.decodeMessage(deviceId: device, key: key, node: value, crypto: crypto) {
            case .message(let m): snap.messages[uid] = m; undecryptable.remove(uid)
            case .undecryptable: snap.messages[uid] = nil; undecryptable.insert(uid)
            case .malformed: break
            }
        case .removed(let key):
            snap.messages["\(device)/\(key)"] = nil; undecryptable.remove("\(device)/\(key)")
        default: break
        }
    }
}
