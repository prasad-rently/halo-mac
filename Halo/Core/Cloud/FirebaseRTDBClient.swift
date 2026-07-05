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

    var isConfigured: Bool { app != nil }
    var uid: String? { auth?.currentUser?.uid }

    // MARK: Configure (runtime — no plist)

    func configure(_ config: FirebaseConfig) throws {
        guard app == nil else { return }
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
