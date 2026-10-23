import SwiftUI
import UIKit
import HaloShareKit

// MARK: - Supporting types

struct PendingOffer: Identifiable {
    let id = UUID()
    let offer: IncomingOffer
}

struct InboxItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    let date: Date
    var name: String { url.lastPathComponent }
}

enum ListenState: Equatable {
    case stopped
    case starting
    case listening(port: Int)
    case failed(String)
}

enum TransferState: Equatable {
    case idle
    case sending(fileName: String, sent: Int64, total: Int64, overallSent: Int64, overallTotal: Int64)
    case finished(String)
    case failed(String)

    var isBusy: Bool { if case .sending = self { return true } else { return false } }
}

// MARK: - AppModel

/// The one object the UI observes. Owns the HaloShare server (receive), the client (send),
/// discovery, and the consent hand-off between the server and the screen.
@MainActor
final class AppModel: ObservableObject {

    // Identity
    @Published private(set) var identity: DeviceIdentity
    private let identityStore: IdentityStore = UserDefaults.standard

    // Receive
    @Published private(set) var listenState: ListenState = .stopped
    @Published var pendingOffer: PendingOffer?
    @Published private(set) var inbox: [InboxItem] = []
    @Published var notice: String?

    // Send
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var isScanning = false
    @Published var selectedPeerID: String?
    @Published private(set) var transfer: TransferState = .idle
    @Published var manualAddress = ""

    private var server: HaloShareServer?
    private var eventsTask: Task<Void, Never>?
    private var consentContinuation: CheckedContinuation<ConsentDecision, Never>?
    private var sendTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private(set) var client: HaloShareClient

    let receiveDirectory: URL

    init() {
        let model = AppModel.hardwareModel()
        let id = DeviceIdentityStore.loadOrCreate(in: UserDefaults.standard,
                                                  defaultAlias: UIDevice.current.name,
                                                  deviceModel: model, deviceType: "mobile")
        identity = id
        client = HaloShareClient(identity: id)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        receiveDirectory = docs.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
        refreshInbox()
    }

    var selectedPeer: Peer? { peers.first { $0.id == selectedPeerID } }

    // MARK: Identity

    func setAlias(_ alias: String) {
        DeviceIdentityStore.setAlias(alias, in: identityStore)
        let updated = DeviceIdentityStore.loadOrCreate(in: identityStore, defaultAlias: identity.alias,
                                                       deviceModel: identity.deviceModel, deviceType: "mobile")
        identity = updated
        client = HaloShareClient(identity: updated)
        // The server holds the identity it started with; restart so peers see the new name.
        if case .listening = listenState { restartServer() }
    }

    // MARK: Receive

    /// Starts listening. Called when the app becomes active (iOS cannot host a listener while
    /// suspended — requirements MR-OS-2).
    func startServer() {
        guard server == nil else { return }
        listenState = .starting
        let config = HaloShareServer.Configuration(identity: identity, receiveDirectory: receiveDirectory)
        let server = HaloShareServer(configuration: config) { [weak self] offer in
            guard let self else { return .decline }
            return await self.askConsent(offer)
        }
        self.server = server

        eventsTask = Task { [weak self] in
            for await event in server.events {
                await self?.handle(event)
            }
        }
        Task { [weak self] in
            do {
                let port = try await server.start(port: HaloShare.defaultPort)
                self?.listenState = .listening(port: Int(port))
            } catch {
                self?.server = nil
                self?.listenState = .failed(error.localizedDescription)
            }
        }
    }

    func stopServer() {
        eventsTask?.cancel(); eventsTask = nil
        if let server { Task { await server.stop() } }
        server = nil
        // A consent prompt that is still open cannot be answered after we stop.
        resolveConsent(.decline)
        listenState = .stopped
        setIdleTimerDisabled(false)
    }

    func restartServer() { stopServer(); startServer() }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .fileReceived(_, _, let url):
            refreshInbox()
            notice = "Received \(url.lastPathComponent)"
        case .sessionCompleted:
            refreshInbox()
            setIdleTimerDisabled(false)
        case .sessionCancelled:
            refreshInbox()
            notice = "The sender cancelled the transfer."
            setIdleTimerDisabled(false)
        case .offer:
            setIdleTimerDisabled(true)       // MR-OS-3: keep awake for the transfer
        case .declined:
            setIdleTimerDisabled(false)
        case .progress, .listening:
            break
        }
    }

    /// The server's consent callback lands here. One prompt at a time: a second offer while
    /// one is open is declined rather than silently queued behind a sheet the user can't see.
    private func askConsent(_ offer: IncomingOffer) async -> ConsentDecision {
        guard pendingOffer == nil else { return .decline }
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            pendingOffer = PendingOffer(offer: offer)
        }
    }

    func resolveConsent(_ decision: ConsentDecision) {
        pendingOffer = nil
        consentContinuation?.resume(returning: decision)
        consentContinuation = nil
    }

    func refreshInbox() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let e = FileManager.default.enumerator(at: receiveDirectory, includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles])
        var items: [InboxItem] = []
        while let url = e?.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            items.append(InboxItem(url: url, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? .distantPast))
        }
        inbox = items.sorted { $0.date > $1.date }
    }

    func deleteInboxItem(_ item: InboxItem) {
        try? FileManager.default.removeItem(at: item.url)
        refreshInbox()
    }

    // MARK: Discovery

    /// HTTP /24 scan — the primary discovery path on iOS (requirements MD2).
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        notice = nil
        let client = self.client
        scanTask = Task { [weak self] in
            let found = await SubnetScanner(client: client).scan { peer in
                Task { @MainActor in self?.merge(peer) }
            }
            guard let self else { return }
            for p in found { self.merge(p) }
            self.isScanning = false
            if self.peers.isEmpty {
                self.notice = "No devices found. Make sure the other device has HaloShare or LocalSend open on the same Wi-Fi — or add its address below."
            }
        }
    }

    func stopScan() { scanTask?.cancel(); isScanning = false }

    private func merge(_ peer: Peer) {
        if let i = peers.firstIndex(where: { $0.id == peer.id }) { peers[i] = peer } else { peers.append(peer) }
        peers.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if selectedPeerID == nil { selectedPeerID = peer.id }
    }

    /// MR-DI-2: manual `host[:port]`.
    func addManualPeer() {
        guard let (host, port) = LocalNetwork.parseHostPort(manualAddress) else {
            notice = "That doesn't look like an address. Try 192.168.1.20 or 192.168.1.20:53317."
            return
        }
        let client = self.client
        Task { [weak self] in
            if let peer = await client.probe(host: host, port: port, timeout: 4) {
                self?.merge(peer)
                self?.selectedPeerID = peer.id
                self?.manualAddress = ""
                self?.notice = "Found \(peer.alias)."
            } else {
                self?.notice = "No HaloShare device answered at \(host):\(port)."
            }
        }
    }

    // MARK: Send

    func send(_ fileURLs: [URL]) {
        guard let peer = selectedPeer else { notice = "Choose a device first."; return }
        guard !transfer.isBusy else { return }
        notice = nil

        // Files from the picker are security-scoped; hold access until the upload is over.
        let scoped = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
        let client = self.client
        setIdleTimerDisabled(true)
        sendTask = Task { [weak self] in
            defer {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                Task { @MainActor in self?.setIdleTimerDisabled(false) }
            }
            do {
                let files = try fileURLs.map { try OutgoingFile(url: $0) }
                let outcome = try await client.send(files, to: peer) { p in
                    Task { @MainActor in
                        self?.transfer = .sending(fileName: p.fileName, sent: p.sent, total: p.total,
                                                  overallSent: p.overallSent, overallTotal: p.overallTotal)
                    }
                }
                switch outcome {
                case .completed:
                    self?.transfer = .finished("Sent \(files.count == 1 ? files[0].name : "\(files.count) files") to \(peer.alias).")
                case .declined:
                    self?.transfer = .finished("\(peer.alias) declined the transfer.")
                case .nothingToSend:
                    self?.transfer = .finished("Nothing needed sending.")
                }
            } catch HaloShareError.cancelled {
                self?.transfer = .finished("Cancelled.")
            } catch {
                self?.transfer = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSend() { sendTask?.cancel() }
    func dismissTransferResult() { if !transfer.isBusy { transfer = .idle } }

    // MARK: Helpers

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    #if DEBUG
    /// Developer aid: makes a throw-away file of `megabytes` of non-text bytes and sends it to the
    /// selected peer, so the send path can be exercised without driving the system file picker.
    func sendTestFile(megabytes: Int = 5) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("halo-test-\(megabytes)MB.bin")
        var data = Data(count: megabytes << 20)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? data.write(to: url)
        send([url])
    }
    #endif
}
