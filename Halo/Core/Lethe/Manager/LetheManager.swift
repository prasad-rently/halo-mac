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
    /// An invite that arrived from *outside* the app (a `lethe://` link opened in
    /// the browser, Messages, …). It is only ever **staged** here: nothing is
    /// written to the Keychain, no room is added and no socket joins until the
    /// user confirms in `LetheView` (`confirmPendingInvite()`).
    @Published private(set) var pendingInvite: LetheInvite?
    /// Shown when an incoming link could not be used, so a bad link is not silent either.
    @Published var inviteNotice: String?

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

    /// Where history is written. `nil` means the real Application Support
    /// folder; tests pass a scratch directory so they never touch a user's rooms.
    private let storeDirectory: URL?
    /// Key for the history file. Tests inject one so they never touch the real
    /// Keychain item; the shared instance resolves it lazily (see `historyKey()`).
    private let injectedHistoryKey: Data?
    /// Off in tests — `connectIfNeeded()` would otherwise open a socket to the
    /// production relay from a unit test.
    private let connectsToRelay: Bool

    private init() {
        storeDirectory = nil
        injectedHistoryKey = nil
        connectsToRelay = true
    }

    /// Test seam. The directory argument is required (no default) so a bare
    /// `LetheManager()` still cannot compile and a second live instance cannot
    /// appear by accident — `shared` remains the only one the app uses.
    init(storeDirectory: URL, connectsToRelay: Bool = false,
         historyKey: Data = LetheCrypto.generateRoomKey()) {
        self.storeDirectory = storeDirectory
        self.injectedHistoryKey = historyKey
        self.connectsToRelay = connectsToRelay
    }

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
        observeTermination()
        connectIfNeeded()
    }

    func setHandle(_ new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handle = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.handleKey)
        refreshTelemetrySnapshot()
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
        guard connectsToRelay else { return }
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
    /// Internal (not private) so tests can feed a payload without a socket.
    func ingest(roomId: String, payload: String) {
        guard let key = RoomKeyStore.load(roomId: roomId) else { return }
        guard let decoded = try? LetheCrypto.decryptMessage(payload: payload, roomKey: key) else {
            return
        }
        guard !seenMessageIds.contains(decoded.msgId) else { return }
        seenMessageIds.insert(decoded.msgId)

        // Anything not already stored under a msgId this device generated is *not* ours, whatever
        // handle it carries: a handle is a free-text label, so anyone holding the room key can
        // send as "my" handle. (Our own sends are inserted — and their msgId recorded — in
        // `send`, so the relay's echo of them is dropped as a duplicate above and never reaches here.)
        let message = LetheMessage(id: decoded.msgId,
                                   roomId: roomId,
                                   handle: decoded.handle,
                                   text: decoded.text,
                                   ts: decoded.ts,
                                   isOwn: false)

        var list = messagesByRoom[roomId] ?? []
        list.append(message)
        list.sort { $0.ts < $1.ts }
        if list.count > LetheLimits.historyCapPerRoom {
            list.removeFirst(list.count - LetheLimits.historyCapPerRoom)
        }
        messagesByRoom[roomId] = list

        if let idx = rooms.firstIndex(where: { $0.id == roomId }), activeRoomId != roomId {
            rooms[idx].unreadCount += 1
            notify(room: rooms[idx], handle: decoded.handle)
        }
        persistSoon()
    }

    /// The room currently on screen — messages arriving here are read, not unread.
    var activeRoomId: String?

    func markRead(roomId: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }), rooms[idx].unreadCount != 0
        else { return }
        rooms[idx].unreadCount = 0
        persistSoon()
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

    /// Joins straight from a link the user typed or pasted into the Join sheet —
    /// an explicit action, so no further confirmation. Links that arrive from
    /// outside the app go through `handleIncomingURL` instead.
    @discardableResult
    func join(inviteLink: String) throws -> LetheRoom {
        guard let invite = LetheInviteLink.parse(inviteLink) else {
            throw LetheError.badInviteLink
        }
        return try join(invite)
    }

    @discardableResult
    func join(_ invite: LetheInvite) throws -> LetheRoom {
        if let existing = rooms.first(where: { $0.id == invite.roomId }) {
            return existing   // Already a member; joining twice is a no-op.
        }
        // A room whose key was not stored could never be decrypted, so do not add it.
        guard RoomKeyStore.save(invite.roomKey, roomId: invite.roomId) else {
            throw LetheError.keyStoreFailed
        }
        let room = LetheRoom(id: invite.roomId, name: invite.roomName)
        rooms.append(room)
        persist()
        connectIfNeeded()
        Task { [client] in await client?.join(roomId: invite.roomId) }
        return room
    }

    // MARK: - Invites from outside the app

    enum IncomingInvite: Equatable {
        /// Valid and new: waiting for the user's confirmation.
        case staged(LetheInvite)
        /// Valid, but this Mac is already in the room — nothing to confirm.
        case alreadyMember(roomId: String)
        case invalid
    }

    /// Entry point for a `lethe://` URL opened by something other than the user
    /// typing in this app. **Never joins.** Any web page or app can open such a
    /// URL, and joining stores a key chosen by whoever made the link and connects
    /// this Mac to the room, so the user must see what they are joining first.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> IncomingInvite {
        guard let invite = LetheInviteLink.parse(url.absoluteString) else {
            pendingInvite = nil
            inviteNotice = "That doesn't look like a Lethe invite link, so nothing was joined."
            return .invalid
        }
        inviteNotice = nil
        if rooms.contains(where: { $0.id == invite.roomId }) {
            pendingInvite = nil
            return .alreadyMember(roomId: invite.roomId)
        }
        pendingInvite = invite
        return .staged(invite)
    }

    /// The user said yes. Throws if the key could not be stored.
    @discardableResult
    func confirmPendingInvite() throws -> LetheRoom? {
        guard let invite = pendingInvite else { return nil }
        pendingInvite = nil
        return try join(invite)
    }

    /// The user said no (or dismissed the sheet). Leaves no trace.
    func cancelPendingInvite() {
        pendingInvite = nil
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
        persistSoon()

        connectIfNeeded()
        Task { [client] in await client?.send(roomId: room.id, payload: payload) }
    }

    /// Only the real instance feeds the scrubber's process-wide snapshot. A
    /// test instance (non-nil `storeDirectory`) must not overwrite it, or
    /// parallel tests would see each other's rooms.
    private func refreshTelemetrySnapshot() {
        guard storeDirectory == nil else { return }
        LetheTelemetryScrubber.update(roomIds: rooms.map(\.id),
                                      roomNames: rooms.map(\.name),
                                      handle: handle)
    }

    // MARK: - Persistence
    //
    // Rooms and history live in Application Support, **encrypted** with AES-256-GCM
    // under a per-install key held in the Keychain (`HistoryKeyStore`). Room keys are
    // not in this file; they have their own Keychain items. This closes spec OQ-3:
    // before, the file was plain JSON, readable by anything with file access and
    // swept into backups.
    //
    // File: `rooms.enc` = magic "HLT1" ‖ AES-GCM combined box (nonce ‖ ct ‖ tag) of
    // the JSON `Store`. A pre-encryption `rooms.json` is migrated on first load and
    // then removed. If no key is available nothing is written (fail closed).

    private struct Store: Codable {
        var rooms: [LetheRoom]
        var messages: [String: [LetheMessage]]
    }

    nonisolated static let encryptedFileName = "rooms.enc"
    nonisolated static let legacyFileName = "rooms.json"
    private nonisolated static let fileMagic = Data("HLT1".utf8)

    private var storeFolder: URL? {
        let folder: URL
        if let storeDirectory {
            folder = storeDirectory
        } else {
            guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
            folder = dir.appendingPathComponent("Halo/lethe", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var cachedHistoryKey: Data?
    /// `nil` when the Keychain is unavailable; history is then neither read nor written.
    private func historyKey() -> Data? {
        if let injectedHistoryKey { return injectedHistoryKey }
        if let cachedHistoryKey { return cachedHistoryKey }
        cachedHistoryKey = HistoryKeyStore.loadOrCreate()
        return cachedHistoryKey
    }

    private let writeQueue = DispatchQueue(label: "com.halo.lethe.history", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    /// Debounce for message traffic. Every message used to re-encode, re-encrypt and rewrite the
    /// whole store (up to 1,000 messages per room) synchronously on the main actor.
    private static let writeDelay: TimeInterval = 0.5

    /// Structural changes — create, join, leave, rename, legacy migration — are written **now**
    /// and synchronously: "leave" must have removed the room's history from disk by the time it
    /// returns (AC-6), and a joined room must survive a crash.
    private func persist() {
        pendingWrite?.cancel(); pendingWrite = nil
        refreshTelemetrySnapshot()
        writeNow(synchronously: true)
    }

    /// Message traffic: coalesced, and the encode/encrypt/write happens off the main actor.
    private func persistSoon() {
        refreshTelemetrySnapshot()
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingWrite = nil
                self.writeNow(synchronously: false)
            }
        }
        pendingWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: item)
    }

    /// Writes any debounced change immediately. Called when the app terminates; tests call it too.
    func flushPendingWrites() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel(); pendingWrite = nil
        writeNow(synchronously: true)
    }

    /// Without this a message received in the last half second before ⌘Q would be lost.
    func observeTermination(on center: NotificationCenter = .default) {
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
    }

    private func writeNow(synchronously: Bool) {
        guard let folder = storeFolder, let key = historyKey() else { return }
        let store = Store(rooms: rooms, messages: messagesByRoom)   // value snapshot taken on the main actor
        let job = { Self.write(store, key: key, folder: folder) }
        // One serial queue for both paths keeps writes in the order they were requested.
        if synchronously { writeQueue.sync(execute: job) } else { writeQueue.async(execute: job) }
    }

    private nonisolated static func write(_ store: Store, key: Data, folder: URL) {
        guard let json = try? JSONEncoder().encode(store),
              let sealed = try? LetheCrypto.seal(json, key: key) else { return }
        let url = folder.appendingPathComponent(encryptedFileName)
        guard (try? (fileMagic + sealed).write(to: url, options: [.atomic])) != nil else { return }
        // The encrypted copy is safely on disk, so a leftover plaintext one must go.
        removeLegacyFile(in: folder)
    }

    /// Best-effort: overwrite then unlink. (An SSD or APFS snapshot may still hold old
    /// blocks; this narrows the window, it does not guarantee erasure.)
    private nonisolated static func removeLegacyFile(in folder: URL) {
        let legacy = folder.appendingPathComponent(Self.legacyFileName)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: legacy.path)[.size]) as? Int
        else { return }
        if let handle = try? FileHandle(forWritingTo: legacy) {
            try? handle.write(contentsOf: Data(count: size))
            try? handle.synchronize()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Unreadable history (wrong/lost key, truncated or tampered file) is moved aside,
    /// never overwritten and never shown.
    private func quarantine(_ url: URL) {
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private func readStore() -> (store: Store, wasLegacy: Bool)? {
        guard let folder = storeFolder else { return nil }
        let enc = folder.appendingPathComponent(Self.encryptedFileName)
        let legacy = folder.appendingPathComponent(Self.legacyFileName)

        if let blob = try? Data(contentsOf: enc) {
            // No key at all (Keychain unavailable this launch) is not evidence the file is
            // bad: leave it exactly where it is rather than set it aside.
            guard let key = historyKey() else { return nil }
            guard blob.starts(with: Self.fileMagic),
                  let json = try? LetheCrypto.open(Data(blob.dropFirst(Self.fileMagic.count)), key: key),
                  let store = try? JSONDecoder().decode(Store.self, from: json)
            else { quarantine(enc); return nil }
            return (store, false)
        }
        // Pre-encryption file: read once; the caller re-saves it encrypted, which also
        // removes the plaintext copy.
        if let data = try? Data(contentsOf: legacy) {
            guard let store = try? JSONDecoder().decode(Store.self, from: data) else {
                quarantine(legacy); return nil
            }
            return (store, true)
        }
        return nil
    }

    /// Internal (not private) so tests can reload a scratch store without `start()`,
    /// which touches the user's real UserDefaults and relay.
    func loadFromDisk() {
        guard let loaded = readStore() else { return }
        let store = loaded.store

        // Reconcile against the Keychain. A room whose key is gone cannot be
        // entered or decrypted, so listing it would be a lie.
        let haveKeys = RoomKeyStore.allRoomIds()
        rooms = store.rooms.filter { haveKeys.contains($0.id) }
        let liveIds = Set(rooms.map(\.id))
        messagesByRoom = store.messages.filter { liveIds.contains($0.key) }
        seenMessageIds = Set(messagesByRoom.values.flatMap { $0 }.map(\.id))
        refreshTelemetrySnapshot()
        if loaded.wasLegacy { persist() }   // encrypt now; don't leave plaintext until the next message
    }
}
