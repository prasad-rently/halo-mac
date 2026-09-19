// ──────────────────────────────────────────────────────────────────────────────
// LetheManager.swift — F-052
//
// The @MainActor layer: owns rooms, unread counts, history, and the crypto that
// sits between the UI and the relay client. The relay client below it never
// holds a key; this is the only place plaintext exists.
//
// Singleton with a private init, matching AlertLog/AlertManager/ProcessMonitor
// beside it. One socket per app, one history store, one unread count.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation
import SwiftUI

@MainActor
final class LetheManager: ObservableObject {

    static let shared = LetheManager()

    // MARK: - Published state

    @Published private(set) var rooms: [LetheRoom] = []
    @Published private(set) var messagesByRoom: [String: [LetheMessage]] = [:]
    @Published private(set) var connection: LetheConnectionState = .offline
    @Published private(set) var lastRelayError: String?
    @Published var handle: String = ""

    var totalUnread: Int { rooms.reduce(0) { $0 + $1.unreadCount } }

    // MARK: - Defaults keys

    private static let handleKey = "letheHandle"
    private static let relayURLKey = "letheRelayURL"

    /// User-overridable so a self-hosted relay can be used — the claim that the
    /// relay is auditable only means something if you can point at your own
    /// (FR-L-32).
    var relayURLString: String {
        UserDefaults.standard.string(forKey: Self.relayURLKey) ?? LetheLimits.defaultRelayURL
    }

    // MARK: - Internals

    private var client: LetheRelayClient?
    /// Every msgId this device has already stored. The relay broadcasts to all
    /// sockets *including the sender*, and replays its buffer on JOIN, so the
    /// same message arrives more than once by design.
    private var seenMessageIds: Set<String> = []
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Called once from `HaloApp`. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        handle = UserDefaults.standard.string(forKey: Self.handleKey) ?? {
            let generated = LetheCrypto.generateHandle()
            UserDefaults.standard.set(generated, forKey: Self.handleKey)
            return generated
        }()

        loadFromDisk()
        connectIfNeeded()
    }

    func setHandle(_ new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handle = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.handleKey)
    }

    func setRelayURL(_ new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.relayURLKey)
        // Rebuild the socket against the new host.
        Task { [client] in await client?.disconnect() }
        self.client = nil
        connectIfNeeded()
    }

    private func connectIfNeeded() {
        guard client == nil, !rooms.isEmpty || started else { return }
        guard let url = URL(string: relayURLString) else { return }

        let c = LetheRelayClient(relayURL: url)
        client = c
        Task {
            await c.setEventHandler { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            await c.connect()
            for room in self.rooms { await c.join(roomId: room.id) }
        }
    }

    // MARK: - Relay events

    private func handle(_ event: LetheRelayEvent) {
        switch event {
        case .state(let s):
            connection = s
            if s == .connected { lastRelayError = nil }

        case .message(let roomId, let payload, _):
            ingest(roomId: roomId, payload: payload)

        case .relayError(let code, let message):
            // Surfaced, never silently swallowed — but never with payload content.
            lastRelayError = "\(code): \(message)"
        }
    }

    /// Decrypt and store. A blob that fails authentication is dropped without a
    /// trace in the UI: it did not come from a key-holder, so rendering it —
    /// even as an error row — would be giving a stranger a line in the room.
    private func ingest(roomId: String, payload: String) {
        guard let key = RoomKeyStore.load(roomId: roomId) else { return }
        guard let decoded = try? LetheCrypto.decryptMessage(payload: payload, roomKey: key) else {
            return
        }
        guard !seenMessageIds.contains(decoded.msgId) else { return }
        seenMessageIds.insert(decoded.msgId)

        let isOwn = decoded.handle == handle
        let message = LetheMessage(id: decoded.msgId,
                                   roomId: roomId,
                                   handle: decoded.handle,
                                   text: decoded.text,
                                   ts: decoded.ts,
                                   isOwn: isOwn)

        var list = messagesByRoom[roomId] ?? []
        list.append(message)
        list.sort { $0.ts < $1.ts }
        if list.count > LetheLimits.historyCapPerRoom {
            list.removeFirst(list.count - LetheLimits.historyCapPerRoom)
        }
        messagesByRoom[roomId] = list

        if !isOwn {
            if let idx = rooms.firstIndex(where: { $0.id == roomId }), activeRoomId != roomId {
                rooms[idx].unreadCount += 1
                notify(room: rooms[idx], handle: decoded.handle)
            }
        }
        persist()
    }

    /// The room currently on screen — messages arriving here are read, not unread.
    var activeRoomId: String?

    func markRead(roomId: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }), rooms[idx].unreadCount != 0
        else { return }
        rooms[idx].unreadCount = 0
        persist()
    }

    /// Local notification only. Lethe's BRD rules out server push as
    /// incompatible with the anonymity model, and the body deliberately carries
    /// **no message text** — notification content is rendered by the OS and can
    /// be mirrored to other devices or shown on a lock screen (FR-L-28).
    private func notify(room: LetheRoom, handle: String) {
        AlertManager.shared.fireLetheMessage(roomName: room.name, handle: handle)
    }

    // MARK: - Rooms

    @discardableResult
    func createRoom(named name: String) -> LetheRoom? {
        let key = LetheCrypto.generateRoomKey()
        let roomId = LetheCrypto.deriveRoomId(from: key)
        guard RoomKeyStore.save(key, roomId: roomId) else { return nil }

        let room = LetheRoom(id: roomId, name: name.isEmpty ? "Untitled room" : name)
        rooms.append(room)
        persist()
        connectIfNeeded()
        Task { [client] in await client?.join(roomId: roomId) }
        return room
    }

    @discardableResult
    func join(inviteLink: String) throws -> LetheRoom {
        guard let invite = LetheInviteLink.parse(inviteLink) else {
            throw LetheError.badInviteLink
        }
        if let existing = rooms.first(where: { $0.id == invite.roomId }) {
            return existing   // Already a member; joining twice is a no-op.
        }
        _ = RoomKeyStore.save(invite.roomKey, roomId: invite.roomId)
        let room = LetheRoom(id: invite.roomId, name: invite.roomName)
        rooms.append(room)
        persist()
        connectIfNeeded()
        Task { [client] in await client?.join(roomId: invite.roomId) }
        return room
    }

    func inviteLink(for room: LetheRoom) -> String? {
        guard let key = RoomKeyStore.load(roomId: room.id) else { return nil }
        return try? LetheInviteLink.create(roomId: room.id, roomKey: key, roomName: room.name)
    }

    /// Destroys the key. There is no server copy and no recovery — the caller
    /// must have confirmed with the user first (CLAUDE.md destructive-action rule).
    func leave(room: LetheRoom) {
        rooms.removeAll { $0.id == room.id }
        messagesByRoom[room.id] = nil
        RoomKeyStore.delete(roomId: room.id)
        Task { [client] in await client?.leave(roomId: room.id) }
        if activeRoomId == room.id { activeRoomId = nil }
        persist()
    }

    func rename(room: LetheRoom, to newName: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rooms[idx].name = trimmed
        persist()
    }

    // MARK: - Sending

    func send(text: String, to room: LetheRoom) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= LetheLimits.maxMessageCharacters else {
            throw LetheError.messageTooLong(count: trimmed.count)
        }
        guard let key = RoomKeyStore.load(roomId: room.id) else {
            throw LetheError.keyNotFound(roomId: room.id)
        }

        let msgId = LetheCrypto.newMsgId()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = try LetheCrypto.encryptMessage(text: trimmed,
                                                     handle: handle,
                                                     roomKey: key,
                                                     ts: ts,
                                                     msgId: msgId)

        // Render immediately rather than waiting for the relay to echo it back.
        // The id is recorded as seen, so the echo is dropped as a duplicate and
        // the message doesn't appear twice.
        seenMessageIds.insert(msgId)
        var list = messagesByRoom[room.id] ?? []
        list.append(LetheMessage(id: msgId, roomId: room.id, handle: handle,
                                 text: trimmed, ts: ts, isOwn: true))
        messagesByRoom[room.id] = list
        persist()

        connectIfNeeded()
        Task { [client] in await client?.send(roomId: room.id, payload: payload) }
    }

    // MARK: - Persistence
    //
    // JSON in Application Support, following MemoryTrendTracker — this codebase
    // has no SQLite or CoreData dependency and one module is not the place to
    // introduce one. Keys are NOT here; they are in the Keychain.
    //
    // Known limitation, recorded in the spec as OQ-3: this is weaker at rest
    // than the mobile client's SQLCipher store.

    private struct Store: Codable {
        var rooms: [LetheRoom]
        var messages: [String: [LetheMessage]]
    }

    private var storeURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Halo/lethe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("rooms.json")
    }

    private func persist() {
        guard let url = storeURL else { return }
        let store = Store(rooms: rooms, messages: messagesByRoom)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func loadFromDisk() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }

        // Reconcile against the Keychain. A room whose key is gone cannot be
        // entered or decrypted, so listing it would be a lie.
        let haveKeys = RoomKeyStore.allRoomIds()
        rooms = store.rooms.filter { haveKeys.contains($0.id) }
        let liveIds = Set(rooms.map(\.id))
        messagesByRoom = store.messages.filter { liveIds.contains($0.key) }
        seenMessageIds = Set(messagesByRoom.values.flatMap { $0 }.map(\.id))
    }
}
