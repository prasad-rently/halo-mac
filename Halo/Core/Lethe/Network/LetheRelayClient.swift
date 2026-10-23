// ──────────────────────────────────────────────────────────────────────────────
// LetheRelayClient.swift — F-052
//
// One WebSocket to the relay, multiplexing every room over it — the protocol
// carries `roomId` on every frame, so a socket per room would be pure waste.
//
// Uses `URLSessionWebSocketTask` rather than a third-party library: native since
// macOS 10.15 (Halo targets 13.0), and the protocol is five message types.
//
// This is an `actor`, so all socket state is serialised. It hands decrypted-
// nothing upward — it deals only in opaque base64 — and the manager above it
// does the crypto. That split is deliberate: the network layer never holds a key.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation

/// What the client reports upward. Deliberately not `LetheServerEvent`: the
/// manager also needs connection transitions, which are not wire events.
enum LetheRelayEvent: Sendable {
    case state(LetheConnectionState)
    case message(roomId: String, payload: String, ts: Int64)
    case relayError(code: String, message: String)
}

actor LetheRelayClient {

    // MARK: - Config

    private let relayURL: URL
    private let session: URLSession

    // MARK: - State

    private var task: URLSessionWebSocketTask?
    private var joinedRooms: Set<String> = []
    /// Frames composed while offline. Sent in order on reconnect (BRD F-21).
    private var outbox: [(roomId: String, payload: String)] = []
    private var reconnectAttempt = 0
    private var isRunning = false
    private var receiveLoop: Task<Void, Never>?

    private var onEvent: (@Sendable (LetheRelayEvent) -> Void)?

    /// Client-side rate limiting so we never trip the relay's 10/sec and get an
    /// `ERROR RATE_LIMIT` the user can't interpret.
    private var sendTimestamps: [Date] = []

    // MARK: - Init

    init(relayURL: URL, session: URLSession = .shared) {
        self.relayURL = relayURL
        self.session = session
    }

    func setEventHandler(_ handler: @escaping @Sendable (LetheRelayEvent) -> Void) {
        self.onEvent = handler
    }

    // MARK: - Lifecycle

    func connect() {
        guard !isRunning else { return }
        isRunning = true
        openSocket(isFirstAttempt: true)
    }

    func disconnect() {
        isRunning = false
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        joinedRooms.removeAll()
        emit(.state(.offline))
    }

    private func openSocket(isFirstAttempt: Bool) {
        guard isRunning else { return }

        // Render's free tier spins down after ~15 min idle and cold-starts in
        // ~50s. That is expected, not a fault, so it gets its own state rather
        // than an indefinite spinner (FR-L-25).
        emit(.state(isFirstAttempt ? .connecting : .reconnecting(attempt: reconnectAttempt)))

        let ws = session.webSocketTask(with: relayURL)
        task = ws
        ws.resume()

        // If the handshake hasn't completed quickly on a first attempt, the
        // relay is almost certainly cold-starting — say so.
        if isFirstAttempt {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.reportWakingIfStillConnecting()
            }
        }

        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.receiveForever(on: ws)
        }
    }

    private func reportWakingIfStillConnecting() {
        guard isRunning, task != nil, joinedRooms.isEmpty || !hasSeenConnected else { return }
        if !hasSeenConnected { emit(.state(.waking)) }
    }

    private var hasSeenConnected = false

    // MARK: - Receive

    private func receiveForever(on ws: URLSessionWebSocketTask) async {
        while isRunning && !Task.isCancelled {
            do {
                let frame = try await ws.receive()
                let raw: String?
                switch frame {
                case .string(let s): raw = s
                case .data(let d):   raw = String(data: d, encoding: .utf8)
                @unknown default:    raw = nil
                }
                guard let raw else { continue }
                handle(LetheServerEvent.parse(raw))
            } catch {
                // Any receive error means the socket is gone. Don't distinguish
                // causes — reconnect covers all of them.
                if isRunning { await scheduleReconnect() }
                return
            }
        }
    }

    private func handle(_ event: LetheServerEvent) {
        switch event {
        case .connected:
            hasSeenConnected = true
            reconnectAttempt = 0
            emit(.state(.connected))
            // Rejoin everything and drain whatever was typed offline (F-22/F-21).
            for roomId in joinedRooms { sendFrame(.join(roomId: roomId)) }
            flushOutbox()

        case .message(let roomId, let payload, let ts):
            emit(.message(roomId: roomId, payload: payload, ts: ts))

        case .error(let code, let message):
            emit(.relayError(code: code, message: message))

        case .unknown:
            break   // Forward-compatible: a frame we don't know is not fatal.
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() async {
        guard isRunning else { return }
        hasSeenConnected = false
        reconnectAttempt += 1
        emit(.state(.reconnecting(attempt: reconnectAttempt)))

        // Exponential backoff, capped at 30s, with jitter so a relay restart
        // doesn't get a thundering herd of every client at the same instant.
        let base = min(pow(2.0, Double(min(reconnectAttempt, 5))), 30.0)
        let jitter = Double.random(in: 0...(base * 0.3))
        let delay = base + jitter

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard isRunning else { return }
        openSocket(isFirstAttempt: false)
    }

    // MARK: - Rooms

    func join(roomId: String) {
        joinedRooms.insert(roomId)
        if hasSeenConnected { sendFrame(.join(roomId: roomId)) }
    }

    func leave(roomId: String) {
        joinedRooms.remove(roomId)
        // The relay has no LEAVE frame; it drops us when the socket closes and
        // GCs the room. Forgetting it locally is all we can and need to do.
        outbox.removeAll { $0.roomId == roomId }
    }

    // MARK: - Send

    /// Enqueue an already-encrypted payload. Returns false only if the payload
    /// exceeds the relay's hard limit — offline is not a failure, it queues.
    @discardableResult
    func send(roomId: String, payload: String) -> Bool {
        guard payload.utf8.count <= LetheLimits.maxPayloadBytes else { return false }
        if hasSeenConnected && withinRateLimit() {
            sendFrame(.send(roomId: roomId, payload: payload))
        } else {
            outbox.append((roomId, payload))
        }
        return true
    }

    private func flushOutbox() {
        guard hasSeenConnected, !outbox.isEmpty else { return }
        let pending = outbox
        outbox.removeAll()
        for item in pending {
            guard withinRateLimit() else {
                // Put the rest back rather than dropping it.
                outbox.append(item)
                continue
            }
            sendFrame(.send(roomId: item.roomId, payload: item.payload))
        }
    }

    private func withinRateLimit() -> Bool {
        let now = Date()
        sendTimestamps.removeAll { now.timeIntervalSince($0) > 1.0 }
        guard sendTimestamps.count < LetheLimits.maxMessagesPerSecond else { return false }
        sendTimestamps.append(now)
        return true
    }

    private func sendFrame(_ frame: LetheClientFrame) {
        guard let encoded = frame.encoded(), let task else { return }
        task.send(.string(encoded)) { _ in
            // A send error surfaces as a receive failure on the same socket,
            // which the receive loop already turns into a reconnect. Handling
            // it here too would double-schedule.
        }
    }

    // MARK: - Emit

    private func emit(_ event: LetheRelayEvent) {
        onEvent?(event)
    }

    // MARK: - Test seams

    /// Visible for tests: queue depth without exposing contents.
    var queuedCount: Int { outbox.count }
    var joinedRoomIds: Set<String> { joinedRooms }
}
