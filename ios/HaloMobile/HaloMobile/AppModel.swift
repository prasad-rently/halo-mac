import SwiftUI
import UIKit
import PhotosUI
import HaloShareKit
import HaloShareStaging

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

/// What the person has lined up to send. Nothing leaves the phone until they pick a device and
/// tap Send (`AppModel.sendOutbox(to:)`); creating a selection never starts a transfer.
struct OutboxSelection: Identifiable {
    enum Source: Equatable {
        case files
        case photos
        case sharedFromApp(batchID: String)
        case debugTest
    }
    let id = UUID()
    let source: Source
    let files: [OutgoingFile]
    /// Security-scoped access held for the picker's URLs until the selection ends.
    let access: SecurityScopedAccess?
    /// Private temp copies (photos) deleted when the selection ends.
    let tempDirectories: [URL]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var title: String {
        switch source {
        case .sharedFromApp: return "Shared from another app"
        case .photos: return "Photos"
        case .files, .debugTest: return "Files"
        }
    }
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

    // Receive
    @Published private(set) var listenState: ListenState = .stopped
    @Published var pendingOffer: PendingOffer?
    @Published private(set) var inbox: [InboxItem] = []
    @Published var notice: String?

    // Send
    @Published private(set) var isScanning = false
    @Published var selectedPeerID: String?
    @Published private(set) var transfer: TransferState = .idle
    @Published var manualAddress = ""
    @Published private(set) var recentAddresses: [String] = []
    /// Bumped each time a *new* device is added by hand — the add sheet closes on it.
    @Published private(set) var manualAddCount = 0
    private var inboxSeenKey: String { "haloshare.inboxSeenAt" }
    /// Received files newer than the last time the person opened the inbox (Share tab badge).
    var unreadInboxCount: Int {
        let seen = defaults.object(forKey: inboxSeenKey) as? Date ?? .distantPast
        return inbox.filter { $0.date > seen }.count
    }
    func markInboxSeen() { defaults.set(Date(), forKey: inboxSeenKey); objectWillChange.send() }

    // Outbox (picker / photos / Share Extension) — F-050 D7
    @Published private(set) var outbox: OutboxSelection? { didSet { refreshStagedBatchCount() } }
    @Published var showSendSheet = false
    /// `nil` when the App Group isn't in effect (e.g. an unsigned device build): the Share
    /// Extension cannot hand anything over, and Settings says so.
    let staging: ShareStagingStore?

    // Local Network permission (MR-DI-5, MR-SH-4)
    @Published private(set) var localNetwork: LocalNetworkAccess = .undetermined
    @Published private(set) var localNetworkExplained: Bool
    private static let explainedKey = "haloshare.localNetworkExplained"

    // Peers
    private var directory: PeerDirectory

    private var server: HaloShareServer?
    private var eventsTask: Task<Void, Never>?
    private var consentContinuation: CheckedContinuation<ConsentDecision, Never>?
    private var sendTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Bumped whenever a scan starts or is stopped. A scan that finishes (or reports a peer) for an
    /// older generation is ignored — otherwise a scan cancelled by a network change would, a moment
    /// later, put the *old* network's devices back into the list it had just cleared.
    private var scanGeneration = 0
    private(set) var client: HaloShareClient

    let receiveDirectory: URL
    private let defaults: UserDefaults
    private let addressBook: ManualAddressBook

    // Background policy (D8)
    private let backgroundGuard: BackgroundTransferGuard
    private var isInBackground = false
    private var interruptedInBackground = false
    private var networkMonitor: NetworkChangeMonitor?

    init(defaults: UserDefaults = .standard,
         staging: ShareStagingStore? = ShareStagingStore.appGroup(),
         receiveDirectory: URL? = nil,
         backgroundTasks: BackgroundTaskProviding? = nil,
         notifier: InterruptionNotifying? = nil) {
        self.defaults = defaults
        let model = AppModel.hardwareModel()
        let id = DeviceIdentityStore.loadOrCreate(in: defaults,
                                                  defaultAlias: UIDevice.current.name,
                                                  deviceModel: model, deviceType: "mobile")
        identity = id
        client = HaloShareClient(identity: id)
        directory = PeerDirectory(ownFingerprint: id.fingerprint)
        self.staging = staging
        addressBook = ManualAddressBook(store: defaults)
        localNetworkExplained = defaults.bool(forKey: Self.explainedKey)
        backgroundGuard = BackgroundTransferGuard(provider: backgroundTasks ?? UIKitBackgroundTasks(),
                                                  notifier: notifier ?? InterruptionNotifier())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.receiveDirectory = receiveDirectory ?? docs.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.receiveDirectory, withIntermediateDirectories: true)
        recentAddresses = addressBook.addresses
        PickedMedia.purgeLeftovers()          // a selection never survives a relaunch; its temp copies shouldn't either
        refreshInbox()

        backgroundGuard.onExpired = { [weak self] works in self?.backgroundTimeExpired(works) }
        backgroundGuard.onIdleInBackground = { [weak self] in self?.stopServer() }
    }

    var peers: [Peer] { directory.peers }
    var selectedPeer: Peer? { directory.peer(id: selectedPeerID) }

    // MARK: Scene phase (D8: honest best-effort)

    /// Foreground: listen, look for staged shares, re-check permission, watch the network.
    func didBecomeActive() {
        isInBackground = false
        backgroundGuard.appDidBecomeActive()
        InterruptionNotifier.clearDelivered()
        startServer()
        loadStagedShares()
        refreshLocalNetwork()
        startNetworkMonitor()
    }

    /// Background: iOS can't host a listener, so this is *only* about not dropping a transfer
    /// that is already in flight. Whatever isn't finished when iOS runs out of patience is
    /// reported with a local notification — never silently lost.
    func didEnterBackground() {
        isInBackground = true
        networkMonitor?.stop(); networkMonitor = nil
        // Nobody can see a consent prompt from the background.
        if pendingOffer != nil { resolveConsent(.decline) }
        if !backgroundGuard.appDidEnterBackground() { stopServer() }
    }

    private func backgroundTimeExpired(_ works: Set<BackgroundTransferGuard.Work>) {
        if works.contains(.sending) {
            interruptedInBackground = true
            sendTask?.cancel()
        }
        stopServer()
    }

    // MARK: Identity

    func setAlias(_ alias: String) {
        DeviceIdentityStore.setAlias(alias, in: defaults)
        let updated = DeviceIdentityStore.loadOrCreate(in: defaults, defaultAlias: identity.alias,
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
                #if DEBUG
                // Several simulators share the Mac's network, so 53317 is often taken: `-debugPort 53320` on launch.
                let override = UInt16(clamping: UserDefaults.standard.integer(forKey: "debugPort"))
                let port = try await server.start(port: override == 0 ? HaloShare.defaultPort : override)
                #else
                let port = try await server.start(port: HaloShare.defaultPort)
                #endif
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
        backgroundGuard.setActive(.receiving, false)
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
            backgroundGuard.setActive(.receiving, false)
        case .sessionCancelled:
            refreshInbox()
            notice = "The sender cancelled the transfer."
            setIdleTimerDisabled(false)
            backgroundGuard.setActive(.receiving, false)
        case .offer:
            setIdleTimerDisabled(true)       // MR-OS-3: keep awake for the transfer
        case .declined:
            setIdleTimerDisabled(false)
            backgroundGuard.setActive(.receiving, false)
        case .progress, .listening:
            break
        }
    }

    /// The server's consent callback lands here. One prompt at a time: a second offer while
    /// one is open is declined rather than silently queued behind a sheet the user can't see.
    private func askConsent(_ offer: IncomingOffer) async -> ConsentDecision {
        guard pendingOffer == nil, !isInBackground else { return .decline }
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            pendingOffer = PendingOffer(offer: offer)
        }
    }

    func resolveConsent(_ decision: ConsentDecision) {
        // The transfer only counts as "in flight" (worth a background grace period) once accepted.
        if decision == .accept, consentContinuation != nil { backgroundGuard.setActive(.receiving, true) }
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

    /// Deletes one received file. The caller has already asked the person to confirm. Only a file
    /// *inside* the receive folder can be removed — nothing else is reachable from here.
    /// (`trashItem` is a macOS notion; an iOS app has no Trash, and these are the app's own files.)
    @discardableResult
    func deleteInboxItem(_ item: InboxItem) -> Bool {
        let root = receiveDirectory.standardizedFileURL.path + "/"
        guard item.url.standardizedFileURL.path.hasPrefix(root) else { return false }
        let ok = (try? FileManager.default.removeItem(at: item.url)) != nil
        refreshInbox()
        return ok
    }

    // MARK: Local Network permission

    /// MR-SH-4: the OS prompt is raised only after the person has read why. This is the button
    /// behind the explainer card.
    func continueLocalNetworkSetup() {
        localNetworkExplained = true
        defaults.set(true, forKey: Self.explainedKey)
        Task { [weak self] in
            // Long timeout: the check sits on the OS prompt until it is answered.
            let result = await LocalNetworkPermission.check(timeout: 120)
            self?.localNetwork = result
            if result == .granted { self?.scan() }
        }
    }

    /// Re-reads the permission (the person may have flipped it in Settings). Silent: it never
    /// runs before the explainer has been shown, so it cannot raise the prompt unannounced.
    func refreshLocalNetwork() {
        guard localNetworkExplained else { return }
        Task { [weak self] in
            let result = await LocalNetworkPermission.check(timeout: 3)
            if result != .undetermined { self?.localNetwork = result }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: Discovery

    /// HTTP /24 scan — the primary discovery path on iOS (requirements MD2) — plus every
    /// address the person has added by hand before.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        notice = nil
        scanGeneration += 1
        let generation = scanGeneration
        let client = self.client
        let remembered = addressBook.addresses
        scanTask = Task { [weak self] in
            async let manual: [Peer] = Self.probe(addresses: remembered, with: client)
            let found = await SubnetScanner(client: client).scan { peer in
                Task { @MainActor in if self?.scanGeneration == generation { self?.merge(peer) } }
            }
            let pinned = await manual
            guard let self, self.scanGeneration == generation else { return }
            for p in found + pinned { self.merge(p) }
            self.isScanning = false
            if self.peers.isEmpty {
                // MR-DI-5: an empty list always comes with a reason.
                await self.refreshLocalNetworkNow()
                self.notice = LocalNetworkPermission.explanationForEmptyScan(access: self.localNetwork)
                    ?? "No devices found on this Wi-Fi."
            }
        }
    }

    private func refreshLocalNetworkNow() async {
        let result = await LocalNetworkPermission.check(timeout: 2)
        if result != .undetermined { localNetwork = result }
    }

    private static func probe(addresses: [String], with client: HaloShareClient) async -> [Peer] {
        await withTaskGroup(of: Peer?.self) { group in
            for a in addresses {
                guard let (host, port) = LocalNetwork.parseHostPort(a) else { continue }
                group.addTask { await client.probe(host: host, port: port, timeout: 2) }
            }
            var out: [Peer] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
    }

    func stopScan() { scanGeneration += 1; scanTask?.cancel(); isScanning = false }

    private func merge(_ peer: Peer) { directory.merge(peer); objectWillChange.send() }   // a conflicting claim is dropped, never replaces a row

    /// The network changed (Wi-Fi switched, VPN toggled): rows found on the old one are stale.
    private func networkChanged(_ signature: NetworkSignature) {
        stopScan()
        directory.removeAll()
        objectWillChange.send()
        if signature.isOffline {
            notice = "No network connection."
        } else {
            scan()
        }
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NetworkChangeMonitor { [weak self] signature in
            Task { @MainActor in self?.networkChanged(signature) }
        }
        monitor.start()
        networkMonitor = monitor
    }

    /// MR-DI-2: manual `host[:port]`. A device found this way is remembered for next time.
    func addManualPeer() { addManualPeer(address: manualAddress) }

    func addManualPeer(address: String) {
        guard let normal = ManualAddressBook.normalise(address), let (host, port) = LocalNetwork.parseHostPort(normal) else {
            notice = "That doesn't look like an address. Try 192.168.1.20 or 192.168.1.20:53317."
            return
        }
        let client = self.client
        Task { [weak self] in
            if let peer = await client.probe(host: host, port: port, timeout: 4) {
                guard let self else { return }
                switch self.directory.mergeOutcome(peer) {
                case .added:
                    self.addressBook.remember(normal)
                    self.recentAddresses = self.addressBook.addresses
                    self.manualAddress = ""
                    self.notice = "Found \(peer.alias)."
                    self.manualAddCount += 1
                case .updated:
                    // Already in the list: say so, and leave the sheet open (it is not a new device).
                    self.addressBook.remember(normal)
                    self.recentAddresses = self.addressBook.addresses
                    self.notice = "\(peer.alias) is already in your list."
                case .ignoredSelf:
                    self.notice = "That's this device."
                case .ignoredConflict(let existingHost):
                    // Another host announced a fingerprint that is already listed: it does not replace the row.
                    self.notice = "A device with that identity is already listed at \(existingHost), so \(host) was not added."
                }
                self.objectWillChange.send()
            } else {
                await self?.refreshLocalNetworkNow()
                self?.notice = LocalNetworkPermission.explanationForEmptyScan(access: self?.localNetwork ?? .undetermined)
                    ?? "No HaloShare device answered at \(host):\(port)."
            }
        }
    }

    func forgetAddress(_ address: String) {
        addressBook.forget(address)
        recentAddresses = addressBook.addresses
    }

    // MARK: Outbox (what is lined up to send)

    /// Files from the system picker. They stay where they are (security-scoped, streamed from
    /// disk at send time) — nothing is copied, nothing is read into memory.
    func queue(pickedFiles urls: [URL]) {
        guard !urls.isEmpty else { return }
        // A selection can't be replaced under a running send: `present` cleans up the old one,
        // which deletes the very files (and ends the security scope) the upload is reading.
        guard !transfer.isBusy else { notice = "Wait for the current transfer to finish."; return }
        let access = SecurityScopedAccess()
        access.begin(urls)
        do {
            let files = try urls.map { try OutgoingFile(url: $0) }
            present(OutboxSelection(source: .files, files: files, access: access, tempDirectories: []))
        } catch {
            access.end()
            notice = error.localizedDescription
        }
    }

    /// Photos/videos from `PhotosPicker` (no permission needed). Each is copied *as a file* into
    /// a private temp folder; `PickedMedia` never builds a `Data`.
    func queue(photos items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        guard !transfer.isBusy else { notice = "Wait for the current transfer to finish."; return }
        Task { [weak self] in
            var files: [OutgoingFile] = []
            var dirs: [URL] = []
            var failed = 0
            for item in items {
                do {
                    guard let media = try await item.loadTransferable(type: PickedMedia.self) else { failed += 1; continue }
                    dirs.append(media.url.deletingLastPathComponent())
                    files.append(try OutgoingFile(url: media.url))
                } catch { failed += 1 }
            }
            guard let self else { return }
            // Loading a photo can take a while; a send may have started in the meantime.
            guard !self.transfer.isBusy else {
                dirs.forEach { try? FileManager.default.removeItem(at: $0) }
                self.notice = "Wait for the current transfer to finish."
                return
            }
            if files.isEmpty {
                self.notice = "Couldn't read the selected \(items.count == 1 ? "item" : "items")."
            } else {
                if failed > 0 { self.notice = "\(failed) of \(items.count) items couldn't be read." }
                self.present(OutboxSelection(source: .photos, files: files, access: nil, tempDirectories: dirs))
            }
        }
    }

    /// Foreground hook: pick up whatever the Share Extension staged. **Only lines it up** — the
    /// device picker opens, and nothing is sent until the person taps Send there.
    func loadStagedShares() {
        defer { refreshStagedBatchCount() }     // a batch may have arrived behind the one already in the outbox
        guard let staging, outbox == nil, !transfer.isBusy else { return }
        guard let batch = staging.pendingBatches().first else { return }
        let files = batch.items.compactMap { item -> OutgoingFile? in
            guard let url = staging.fileURL(for: item, in: batch) else { return nil }
            return try? OutgoingFile(url: url, name: item.fileName, size: item.size, mimeType: item.mimeType)
        }
        guard !files.isEmpty else { staging.remove(batchID: batch.id); return }
        present(OutboxSelection(source: .sharedFromApp(batchID: batch.id), files: files, access: nil, tempDirectories: []))
    }

    /// How many staged batches are waiting beyond the one in the outbox. **Cached**: this is read
    /// from SwiftUI bodies, and `pendingBatches()` lists a directory and decodes manifests, so it
    /// must never run during a render. Refreshed by `refreshStagedBatchCount()` whenever the staged
    /// set or the outbox changes.
    @Published private(set) var otherStagedBatchCount = 0

    func refreshStagedBatchCount() {
        guard let staging else { if otherStagedBatchCount != 0 { otherStagedBatchCount = 0 }; return }
        let current: String? = { if case .sharedFromApp(let id)? = outbox?.source { return id } else { return nil } }()
        let count = staging.pendingBatches().filter { $0.id != current }.count
        if count != otherStagedBatchCount { otherStagedBatchCount = count }
    }

    private func present(_ selection: OutboxSelection) {
        if let old = outbox { cleanUp(old) }
        outbox = selection
        // The device is chosen *for this selection*, by the person, in the picker.
        selectedPeerID = nil
        transfer = .idle
        showSendSheet = true
    }

    /// The person discards the selection (after a confirmation in the UI).
    func discardOutbox() {
        guard let selection = outbox, !transfer.isBusy else { return }
        cleanUp(selection)
        outbox = nil
        showSendSheet = false
        transfer = .idle
        loadStagedShares()                // a second shared batch may be waiting
    }

    private func cleanUp(_ selection: OutboxSelection) {
        selection.access?.end()
        selection.tempDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        if case .sharedFromApp(let id) = selection.source { staging?.remove(batchID: id) }
    }

    // MARK: Send

    /// The one place a send starts. The UI calls it from the Send button, with the device the
    /// person tapped in the picker; there is no other path (staged items, picked files and
    /// photos all only ever reach `outbox`).
    func sendOutbox(to peerID: String) {
        guard let selection = outbox else { return }
        guard let peer = directory.peer(id: peerID) else { notice = "Choose a device first."; return }
        guard !transfer.isBusy else { return }
        notice = nil
        selectedPeerID = peerID
        interruptedInBackground = false
        InterruptionNotifier.requestAuthorizationIfNeeded()

        let client = self.client
        let files = selection.files
        let selectionID = selection.id
        backgroundGuard.setActive(.sending, true)
        setIdleTimerDisabled(true)
        transfer = .sending(fileName: files.first?.name ?? "", sent: 0, total: files.first?.size ?? 0,
                            overallSent: 0, overallTotal: selection.totalBytes)
        sendTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.setIdleTimerDisabled(false)
                    self?.backgroundGuard.setActive(.sending, false)
                }
            }
            do {
                let outcome = try await client.send(files, to: peer) { p in
                    Task { @MainActor in
                        guard self?.transfer.isBusy == true else { return }
                        self?.transfer = .sending(fileName: p.fileName, sent: p.sent, total: p.total,
                                                  overallSent: p.overallSent, overallTotal: p.overallTotal)
                    }
                }
                switch outcome {
                case .completed:
                    self?.transfer = .finished("Sent \(files.count == 1 ? files[0].name : "\(files.count) files") to \(peer.alias).")
                    self?.finishOutbox(selectionID)               // sent: clean the staging copy
                case .declined:
                    self?.transfer = .finished("\(peer.alias) declined the transfer.")
                case .nothingToSend:
                    self?.transfer = .finished("Nothing needed sending.")
                    self?.finishOutbox(selectionID)
                }
            } catch HaloShareError.cancelled {
                if self?.interruptedInBackground == true {
                    self?.transfer = .failed("The transfer was interrupted when Halo went to the background. Choose a device and tap Send to try again.")
                } else {
                    self?.transfer = .finished("Cancelled.")
                }
            } catch {
                self?.transfer = .failed(error.localizedDescription)
            }
        }
    }

    private func finishOutbox(_ id: UUID) {
        guard let selection = outbox, selection.id == id else { return }
        cleanUp(selection)
        outbox = nil
    }

    func cancelSend() { sendTask?.cancel() }

    /// Dismisses a finished/failed result. If the send succeeded the outbox is already gone and
    /// the sheet closes; if it was declined or failed the selection stays so it can be retried.
    func dismissTransferResult() {
        guard !transfer.isBusy else { return }
        transfer = .idle
        if outbox == nil { showSendSheet = false; loadStagedShares() }
    }

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
    /// Developer aid for screenshots: forces the transfer card into a state (`-debugTransfer sending|finished|failed`).
    func debugSetTransfer(_ name: String) {
        switch name {
        case "sending": transfer = .sending(fileName: "quarterly-report.pdf", sent: 18_400_000, total: 41_000_000, overallSent: 18_400_000, overallTotal: 41_000_000)
        case "finished": transfer = .finished("Sent quarterly-report.pdf to Gokul's Mac.")
        case "failed": transfer = .failed("Couldn't reach Gokul's Mac. Check you're on the same Wi-Fi.")
        default: break
        }
    }

    /// Developer aid: lines up a throw-away file of `megabytes` of non-text bytes, so the device
    /// picker and send path can be exercised without driving the system file picker.
    func queueTestFile(megabytes: Int = 5) {
        guard !transfer.isBusy else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("halo-test-\(megabytes)MB.bin")
        var data = Data(count: megabytes << 20)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? data.write(to: url)
        if let file = try? OutgoingFile(url: url) {
            present(OutboxSelection(source: .debugTest, files: [file], access: nil, tempDirectories: [dir]))
        }
    }
    #endif
}
