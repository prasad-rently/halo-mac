import Foundation

// Pairing + opening a session. The flow the Settings screen drives:
//   1. `PairingCode.parse(text)`            — validate the code the user pasted/scanned (no network, no secrets stored)
//   2. `CloudSetup.connect(payload:passphrase:confirmation:)`
//        derive key → sign in → KeyCheck against real ciphertext
//          match      -> paired (verified)
//          mismatch   -> refused: nothing is stored
//          noSample   -> the passphrase CANNOT be verified: ask for it twice (D-01), say so, then pair (unverified)
//   3. `CloudSetup.openSession()`           — rebuild engines from the stored profile on each launch
//   4. `CloudSetup.unpair()`                — wipe the Keychain
//
// The passphrase is never stored: only the derived key, in the Keychain.

public enum PairingOutcome: Equatable, Sendable {
    /// `verified`: the key opened real ciphertext. false: nothing to check against, the user typed it twice.
    case paired(deviceName: String, verified: Bool)
    /// The database holds nothing encrypted: show `PairingConfirmation.notice` and ask for the passphrase again.
    case needsConfirmation
}

public enum PairingFailure: LocalizedError, Equatable, Sendable {
    case passphraseMismatch
    case confirmationDoesNotMatch
    case emptyPassphrase

    public var errorDescription: String? {
        switch self {
        case .passphraseMismatch: return "That passphrase doesn't open the data already in this database. Re-enter the exact passphrase from your Mac (or re-key on the Mac)."
        case .confirmationDoesNotMatch: return "The two passphrases don't match. Nothing was saved."
        case .emptyPassphrase: return "Enter the encryption passphrase."
        }
    }
}

public struct CloudSetup: Sendable {
    public let store: CloudProfileStore
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private let allowLoopbackHTTP: Bool
    private let defaultDeviceName: String
    private let minBackoff: TimeInterval

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                allowLoopbackHTTP: Bool = false, deviceName: String = "iPhone", minBackoff: TimeInterval = 1) {
        self.secrets = secrets; self.store = CloudProfileStore(secrets: secrets)
        self.transport = transport; self.allowLoopbackHTTP = allowLoopbackHTTP; self.defaultDeviceName = deviceName
        self.minBackoff = minBackoff
    }

    public func parse(_ code: String) throws -> PairingPayload { try PairingCode.parse(code, allowLoopbackHTTP: allowLoopbackHTTP) }

    public func isPaired() -> Bool { ((try? store.load()) ?? nil) != nil }

    public func connect(payload: PairingPayload, passphrase: String, confirmation: String?) async throws -> PairingOutcome {
        guard !passphrase.isEmpty else { throw PairingFailure.emptyPassphrase }
        guard let salt = payload.salt else { throw CloudError.malformedPairingCode }

        // PBKDF2 at 600 000 rounds is ~0.3–1 s of pure CPU: keep it off the caller's (main) actor.
        let iterations = payload.iterations
        let crypto = try await Task.detached(priority: .userInitiated) {
            try CryptoService(passphrase: passphrase, salt: salt, iterations: iterations)
        }.value

        let db = try FirebaseRTDB(config: payload.firebaseConfig, credential: payload.auth, transport: transport,
                                  allowLoopbackHTTP: allowLoopbackHTTP, minBackoff: minBackoff)
        try await db.signIn()

        var verified = false
        switch try await KeyCheck.verify(db: db, crypto: crypto) {
        case .match: verified = true
        case .mismatch: throw PairingFailure.passphraseMismatch
        case .noSample:
            guard let confirmation else { return .needsConfirmation }
            guard PairingConfirmation.matches(passphrase, confirmation) else { throw PairingFailure.confirmationDoesNotMatch }
        }

        let name = defaultDeviceName
        let profile = CloudProfile(config: payload.firebaseConfig, auth: payload.auth, saltBase64: payload.saltBase64,
                                   iterations: payload.iterations, keyBase64: crypto.exportKey().base64EncodedString(),
                                   deviceId: UUID().uuidString, deviceName: name)
        try store.save(profile)
        return .paired(deviceName: name, verified: verified)
    }

    /// Rebuild a live session from the stored profile, or nil when not paired.
    public func openSession() throws -> CloudSession? {
        guard let p = try store.load() else { return nil }
        return try CloudSession(profile: p, transport: transport, allowLoopbackHTTP: allowLoopbackHTTP, minBackoff: minBackoff)
    }

    /// Unpair: erase the Keychain profile. (Data already in the cloud is untouched — that is the Mac's to wipe.)
    public func unpair() throws { try store.wipe() }
}

/// A signed-in connection plus the data key and the two engines.
public final class CloudSession: Sendable {
    public let profile: CloudProfile
    public let db: FirebaseRTDB
    public let crypto: CryptoService
    public let sms: SmsViewerEngine
    public let clipboard: ClipboardSyncEngine
    private let transport: HTTPTransport
    private let allowLoopbackHTTP: Bool

    public init(profile: CloudProfile, transport: HTTPTransport, allowLoopbackHTTP: Bool, minBackoff: TimeInterval = 1) throws {
        guard let key = Data(base64Encoded: profile.keyBase64) else { throw CloudError.badCiphertext }
        self.profile = profile
        self.crypto = try CryptoService(keyData: key)
        self.db = try FirebaseRTDB(config: profile.config, credential: profile.auth, transport: transport,
                                   allowLoopbackHTTP: allowLoopbackHTTP, minBackoff: minBackoff)
        self.sms = SmsViewerEngine(db: db, crypto: crypto)
        self.clipboard = ClipboardSyncEngine(db: db, crypto: crypto, deviceId: profile.deviceId, deviceName: profile.deviceName)
        self.transport = transport
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }

    /// F-057 "Check my database" against this session's database.
    public func checkDatabase() async -> DatabaseCheckReport {
        let live = LiveDatabaseProbeTransport(config: profile.config, credential: profile.auth, http: transport, allowLoopbackHTTP: allowLoopbackHTTP)
        return await DatabaseCheckEngine(transport: live, databaseURL: profile.config.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP).run()
    }
}
