import SwiftUI
import UIKit
import HaloCloudKit

/// A clip the user sent from this iPhone this session (in memory only — see CloudModel).
struct SentClip: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
    let result: String
}

/// The one object the cloud screens observe. Owns the pairing flow, the live session (SMS viewer + clipboard) and
/// the "Check my database" run.
///
/// Privacy rules enforced here:
///  - decrypted message bodies and clipboard text live **in memory only** — never written to disk, UserDefaults,
///    logs or notifications; on each launch they are re-streamed from the user's own database;
///  - sync runs only while the app is active (iOS cannot host a listener while suspended);
///  - the passphrase is held only for the duration of `connect` and is never stored — the derived key goes to
///    the Keychain (WhenUnlockedThisDeviceOnly, not iCloud-synced).
@MainActor
final class CloudModel: ObservableObject {

    enum Phase: Equatable { case unpaired, paired }

    // Pairing
    @Published private(set) var phase: Phase = .unpaired
    @Published var codeText = ""
    @Published private(set) var parsed: PairingPayload?
    @Published var passphrase = ""
    @Published var confirmation = ""
    @Published private(set) var needsConfirmation = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var pairedVerified: Bool?
    @Published private(set) var profileSummary: (host: String, email: String)?

    // Live data (memory only)
    @Published private(set) var sms = SmsSnapshot()
    @Published private(set) var threads: [SMSThread] = []
    @Published private(set) var remoteClips: [RemoteClip] = []
    @Published private(set) var sentClips: [SentClip] = []
    @Published private(set) var clipUndecryptable = 0
    @Published private(set) var clipConnection: SyncConnection = .connecting
    @Published var toast: String?

    // F-057
    @Published private(set) var report: DatabaseCheckReport?
    @Published private(set) var checking = false

    /// Set by empty states to ask the root view to switch to Settings → Cloud.
    @Published var wantsSetup = false

    static let loopbackHTTP: Bool = {
        #if DEBUG
        return true          // lets a debug build pair with the loopback stand-in; a release build never does
        #else
        return false
        #endif
    }()

    private let setup: CloudSetup
    private var session: CloudSession?
    private var smsTask: Task<Void, Never>?
    private var clipTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    init(secrets: SecretStore = KeychainSecretStore()) {
        setup = CloudSetup(secrets: secrets, allowLoopbackHTTP: Self.loopbackHTTP, deviceName: "iPhone")
        // Keychain items survive an app delete on iOS. A fresh install must not silently inherit a previous
        // install's pairing, so wipe once per install (the flag is not a secret).
        let fresh = !UserDefaults.standard.bool(forKey: "halo.cloud.installMarker")
        if fresh {
            try? setup.unpair()
            UserDefaults.standard.set(true, forKey: "halo.cloud.installMarker")
        }
        reloadPhase()
        #if DEBUG
        // Simulator convenience (no camera, awkward paste): `-HaloDebugPairingCode <code>` prefills the field only.
        if let code = UserDefaults.standard.string(forKey: "HaloDebugPairingCode"), phase == .unpaired { codeText = code }
        #endif
    }

    var isPaired: Bool { phase == .paired }

    private func reloadPhase() {
        if let p = (try? setup.store.load()) ?? nil {
            phase = .paired
            profileSummary = (URL(string: p.config.databaseURL)?.host.map { h in URL(string: p.config.databaseURL)?.port.map { "\(h):\($0)" } ?? h } ?? "database", p.auth.email)
        } else {
            phase = .unpaired; profileSummary = nil
        }
    }

    // MARK: Pairing

    func submitCode() {
        error = nil
        do { parsed = try setup.parse(codeText) } catch { parsed = nil; self.error = (error as? LocalizedError)?.errorDescription ?? "That code didn't work." }
    }

    func cancelPairing() {
        parsed = nil; passphrase = ""; confirmation = ""; needsConfirmation = false; error = nil
    }

    func connect() {
        guard let payload = parsed, !busy else { return }
        busy = true; error = nil
        let pass = passphrase, conf = needsConfirmation ? confirmation : nil
        Task {
            defer { busy = false }
            do {
                switch try await setup.connect(payload: payload, passphrase: pass, confirmation: conf) {
                case .needsConfirmation:
                    needsConfirmation = true
                case .paired(_, let verified):
                    pairedVerified = verified
                    codeText = ""; parsed = nil; passphrase = ""; confirmation = ""; needsConfirmation = false
                    reloadPhase()
                    startSync()
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't connect."
            }
        }
    }

    /// Unpair: stop everything, drop in-memory data, and erase the Keychain profile.
    func unpair() {
        stopSync()
        do { try setup.unpair() } catch { toast = "Couldn't remove the pairing from the Keychain. Try again." }
        session = nil
        sms = SmsSnapshot(); threads = []; remoteClips = []; sentClips = []; report = nil; pairedVerified = nil
        reloadPhase()
    }

    // MARK: Sync lifecycle (foreground only)

    func startSync() {
        // A launch while the device is locked cannot read the Keychain and would otherwise look "unpaired" forever.
        if phase == .unpaired { reloadPhase() }
        guard phase == .paired, smsTask == nil else { return }
        do { session = try session ?? setup.openSession() } catch { self.error = (error as? LocalizedError)?.errorDescription; return }
        guard let session else { return }
        smsTask = Task { [weak self] in
            for await snap in session.sms.snapshots() {
                guard let self else { return }
                self.sms = snap
                self.threads = snap.threads
            }
        }
        clipTask = Task { [weak self] in
            for await ev in session.clipboard.incoming() {
                guard let self else { return }
                switch ev {
                case .item(let clip): self.insert(clip)
                case .removed(let id): self.remoteClips.removeAll { $0.id == id }
                case .undecryptable: self.clipUndecryptable += 1
                case .connection(let c): self.clipConnection = c
                }
            }
        }
    }

    /// Called when the app leaves the foreground. In-memory data is dropped too: nothing decrypted outlives the session.
    func stopSync() {
        smsTask?.cancel(); smsTask = nil
        clipTask?.cancel(); clipTask = nil
        checkTask?.cancel()
        // sentClips holds plaintext the user chose to send (it may be a password), so it does not outlive the session either.
        sms = SmsSnapshot(); threads = []; remoteClips = []; sentClips = []; clipUndecryptable = 0
        clipConnection = .connecting
    }

    private func insert(_ clip: RemoteClip) {
        guard !remoteClips.contains(where: { $0.id == clip.id }) else { return }
        remoteClips.append(clip)
        remoteClips.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: Clipboard (explicit, foreground)

    func send(_ text: String) {
        guard let session else { toast = "Not connected."; return }
        Task {
            let result = await session.clipboard.publish(text)
            let label: String
            switch result {
            case .sent: label = "Sent"
            case .duplicate: label = "Already sent"
            case .empty: label = "Nothing to send"
            case .tooLarge: label = "Too large to send"
            case .failed(let why): label = why
            }
            sentClips.insert(SentClip(text: text, date: Date(), result: label), at: 0)
            toast = label
        }
    }

    /// Tap-to-copy. Local-only (no Universal Clipboard) and, for anything that looks like a secret, auto-expiring.
    func copy(_ clip: RemoteClip) {
        let sensitive = ClipboardSensitiveFilter.isSensitive(clip.text)
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if sensitive { options[.expirationDate] = Date().addingTimeInterval(60) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": clip.text]], options: options)
        if let session { Task { await session.clipboard.suppressEcho(clip.text) } }
        toast = sensitive ? "Copied — clears in 60 s" : "Copied"
    }

    /// Copy a plain string (an OTP). Local-only; secrets expire from the pasteboard after 60 s.
    func copyPlain(_ text: String, sensitive: Bool) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if sensitive { options[.expirationDate] = Date().addingTimeInterval(60) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: options)
        toast = sensitive ? "Copied — clears in 60 s" : "Copied"
    }

    func purgeCloudClipboard() {
        guard let session else { return }
        Task {
            do { try await session.clipboard.purge(); remoteClips = []; toast = "Cloud clipboard cleared" }
            catch { toast = (error as? LocalizedError)?.errorDescription ?? "Couldn't clear" }
        }
    }

    // MARK: F-057

    func runCheck() {
        guard let session, !checking else { return }
        checking = true; report = nil
        checkTask = Task {
            let r = await session.checkDatabase()
            report = r; checking = false
        }
    }

    // MARK: Message filtering

    var lines: [SMSLine] { sms.lines.values.sorted { ($0.deviceId, $0.subscriptionId) < ($1.deviceId, $1.subscriptionId) } }
    func line(_ id: String) -> SMSLine? { sms.lines[id] }
    func deviceName(_ id: String) -> String { sms.devices[id]?.name ?? id }
}
