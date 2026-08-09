import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase

// MARK: - FirebaseRTDBClient  (F-044 cloud foundation)
//
// Actor wrapping the user's own Firebase (BYOB) — configured **at runtime** from
// values the user supplies (no bundled GoogleService-Info.plist, no rebuild;
// docs/specs/firebase-setup.md §1). Provides Email/Password auth + Realtime
// Database read/write/observe. Shared by F-044/F-045/F-048.
//
// Uses a **named** Firebase app ("HaloCloud") so it never collides with a
// default app and needs no plist.

enum RTDBError: LocalizedError {
    case notConfigured
    case configureFailed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:       return "Cloud is not configured yet."
        case .configureFailed:     return "Couldn't initialise Firebase with the provided config."
        case .operationFailed(let m): return m
        }
    }
}

actor FirebaseRTDBClient {

    static let shared = FirebaseRTDBClient()

    private let appName = "HaloCloud"
    private var app: FirebaseApp?
    private var auth: Auth?
    private var root: DatabaseReference?
    /// The config the live `app`/`auth`/`root` were built from, so a later
    /// `configure(_:)` call can tell a genuine reconfigure (different project,
    /// or a corrected value) apart from a redundant call with the same config —
    /// SMSSyncClient and ClipboardSyncService each call `configure(_:)`
    /// independently on connect, and both normally supply the same stored config.
    private var currentConfig: FirebaseConfig?

    var isConfigured: Bool { app != nil }
    var uid: String? { auth?.currentUser?.uid }

    // MARK: Configure (runtime — no plist)

    /// Configure the shared app for `config`. Safe to call repeatedly:
    /// - Same config as the live session → no-op, the existing app/auth/root
    ///   (and any signed-in session or live observers) are reused as-is.
    /// - Different config (switching projects, or the user corrected a mistake
    ///   after `disconnect()` + re-pairing) → the previous named app is deleted
    ///   and a fresh one configured, so the client actually points at the new
    ///   project instead of silently continuing to use the old one.
    func configure(_ config: FirebaseConfig) async throws {
        if let currentConfig, currentConfig == config, app != nil { return }
        if let existing = app { await deleteApp(existing) }
        app = nil
        auth = nil
        root = nil

        let options = FirebaseOptions(googleAppID: config.googleAppID,
                                      gcmSenderID: config.gcmSenderID)
        options.apiKey = config.apiKey
        options.projectID = config.projectID
        options.databaseURL = config.databaseURL
        if let bucket = config.storageBucket { options.storageBucket = bucket }

        FirebaseApp.configure(name: appName, options: options)
        guard let configured = FirebaseApp.app(name: appName) else {
            throw RTDBError.configureFailed
        }
        app = configured
        auth = Auth.auth(app: configured)
        root = Database.database(app: configured, url: config.databaseURL).reference()
        currentConfig = config
    }

    // MARK: Test connection (F-044 — validate before saving config)

    /// End-to-end validation of a config + credential **without** touching the live
    /// app or the Keychain: configures a throwaway named app, signs in, then writes
    /// and reads back a `meta/{uid}` token to prove the database URL + rules allow
    /// the account to read/write its own subtree. Tears the throwaway app down on
    /// every exit so it can be retried after the user corrects the config.
    ///
    /// Throws a descriptive `RTDBError`/auth error on the first failing step
    /// (bad config → configureFailed, bad credentials → auth error, rules/URL
    /// problem → operationFailed on the round-trip).
    func testConnection(_ config: FirebaseConfig, email: String, password: String) async throws {
        let testName = "HaloCloudTest"
        // A prior aborted test may have left the throwaway app around.
        if let leftover = FirebaseApp.app(name: testName) { await deleteApp(leftover) }

        let options = FirebaseOptions(googleAppID: config.googleAppID,
                                      gcmSenderID: config.gcmSenderID)
        options.apiKey = config.apiKey
        options.projectID = config.projectID
        options.databaseURL = config.databaseURL
        if let bucket = config.storageBucket { options.storageBucket = bucket }

        FirebaseApp.configure(name: testName, options: options)
        guard let testApp = FirebaseApp.app(name: testName) else {
            throw RTDBError.configureFailed
        }

        do {
            let testAuth = Auth.auth(app: testApp)
            let result = try await testAuth.signIn(withEmail: email, password: password)
            let uid = result.user.uid

            let ref = Database.database(app: testApp, url: config.databaseURL)
                .reference().child("meta/\(uid)/_haloTest")
            let token = UUID().uuidString

            // write
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ref.setValue(token) { error, _ in
                    if let error { cont.resume(throwing: RTDBError.operationFailed(error.localizedDescription)) }
                    else { cont.resume() }
                }
            }
            // read back
            let readBack = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                ref.getData { error, snapshot in
                    if let error { cont.resume(throwing: RTDBError.operationFailed(error.localizedDescription)) }
                    else { cont.resume(returning: snapshot?.value) }
                }
            }
            guard (readBack as? String) == token else {
                throw RTDBError.operationFailed("Round-trip mismatch — check your database rules allow the signed-in account to read/write meta/$uid.")
            }
            // best-effort cleanup of the probe node
            try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ref.removeValue { _, _ in cont.resume() }
            }
        } catch {
            await deleteApp(testApp)
            throw error
        }
        await deleteApp(testApp)
    }

    private func deleteApp(_ app: FirebaseApp) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            app.delete { _ in cont.resume() }
        }
    }

    // MARK: Auth (Email/Password — F-044 D12)

    @discardableResult
    func signIn(email: String, password: String) async throws -> String {
        guard let auth else { throw RTDBError.notConfigured }
        let result = try await auth.signIn(withEmail: email, password: password)
        return result.user.uid
    }

    func signOut() throws {
        try auth?.signOut()
    }

    // MARK: RTDB operations

    /// `setValue` (idempotent overwrite) at a path relative to the DB root.
    func setValue(_ value: Any, at path: String) async throws {
        let ref = try child(path)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.setValue(value) { error, _ in
                if let error { cont.resume(throwing: RTDBError.operationFailed(error.localizedDescription)) }
                else { cont.resume() }
            }
        }
    }

    /// One-shot read of a path's value.
    func getValue(at path: String) async throws -> Any? {
        let ref = try child(path)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            ref.getData { error, snapshot in
                if let error { cont.resume(throwing: RTDBError.operationFailed(error.localizedDescription)) }
                else { cont.resume(returning: snapshot?.value) }
            }
        }
    }

    /// Remove a path (used by wipe / re-key / delete-sync).
    func removeValue(at path: String) async throws {
        let ref = try child(path)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.removeValue { error, _ in
                if let error { cont.resume(throwing: RTDBError.operationFailed(error.localizedDescription)) }
                else { cont.resume() }
            }
        }
    }

    /// Observe `child_added` under a path; returns the observer handle so the
    /// caller can remove it. The callback delivers (key, value) per child.
    @discardableResult
    func observeChildAdded(at path: String,
                           _ onChild: @escaping @Sendable (String, Any?) -> Void) throws -> DatabaseHandle {
        let ref = try child(path)
        return ref.observe(.childAdded) { snapshot in
            onChild(snapshot.key, snapshot.value)
        }
    }

    func removeObserver(at path: String, handle: DatabaseHandle) throws {
        try child(path).removeObserver(withHandle: handle)
    }

    // MARK: Helpers

    private func child(_ path: String) throws -> DatabaseReference {
        guard let root else { throw RTDBError.notConfigured }
        return root.child(path)
    }
}
