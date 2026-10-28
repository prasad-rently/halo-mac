import Foundation

// MARK: - FirebaseRTDBClient  (F-044 cloud foundation)
//
// Email/Password auth + Realtime Database read/write/observe against the user's own
// Firebase (BYOB), configured **at runtime** from values the user supplies (no bundled
// GoogleService-Info.plist, no rebuild; docs/specs/firebase-setup.md §1). Shared by
// F-044/F-045/F-048.
//
// WHY THIS TALKS REST INSTEAD OF USING firebase-ios-sdk
// -----------------------------------------------------
// The July spike ("S1 passed") proved the SDK *builds and links* on macOS. It never
// proved sign-in *works* in the way Halo is actually distributed, and it does not:
// FirebaseAuth persists its session with `kSecUseDataProtectionKeychain = true`
// (AuthKeychainServices.swift), and macOS only grants the data-protection keychain to
// an app carrying `keychain-access-groups` — a *restricted* entitlement that needs a
// provisioning profile. Every Halo DMG is signed with a plain development certificate
// and no profile, and measured on this machine:
//   - SecItemAdd with the data-protection keychain  -> -34018 errSecMissingEntitlement
//   - the same binary + `keychain-access-groups`    -> SIGKILLed by macOS at launch
// So with the SDK, cloud sign-in cannot succeed in a shipped DMG, and the entitlement
// that would "fix" it makes the app unlaunchable. (docs/V2_5_PLAN.md, P3.)
//
// Speaking the two documented REST APIs directly removes the problem rather than
// working around it: nothing here touches the keychain (ID/refresh tokens live in
// memory; the credential is re-presented on launch), it needs only the
// `network.client` entitlement, and it drops ~60 MB of SDK. The surface is unchanged,
// so SMSSyncClient / ClipboardSyncService / ExpenditureViewModel are untouched
// beyond the observer-handle type.
//
//   Auth: Identity Toolkit  POST identitytoolkit.googleapis.com/v1/accounts:signInWithPassword
//         Refresh           POST securetoken.googleapis.com/v1/token
//   Data: RTDB REST         GET/PUT/DELETE  <databaseURL>/<path>.json?auth=<idToken>
//   Live: RTDB streaming    GET <databaseURL>/<path>.json  Accept: text/event-stream
//         (put / patch / keep-alive / cancel / auth_revoked)

enum RTDBError: LocalizedError, Equatable {
    case notConfigured
    case configureFailed
    case authFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:          return "Cloud is not configured yet."
        case .configureFailed:        return "Couldn't initialise the cloud connection with the provided config."
        case .authFailed(let m):      return m
        case .operationFailed(let m): return m
        }
    }
}

/// Opaque handle for a live `child_added` subscription.
struct RTDBObserverHandle: Hashable, Sendable {
    fileprivate let id = UUID()
}

actor FirebaseRTDBClient {

    static let shared = FirebaseRTDBClient()

    /// Fixed Google hosts. The password is only ever sent to these — never to the
    /// user-supplied `databaseURL`.
    static let identityToolkitBase = URL(string: "https://identitytoolkit.googleapis.com/v1")!
    static let secureTokenBase = URL(string: "https://securetoken.googleapis.com/v1")!

    /// Renew this long before an ID token's stated expiry.
    private static let refreshSkew: TimeInterval = 120

    private struct Tokens {
        var idToken: String
        var refreshToken: String
        var expiresAt: Date
        var uid: String
    }

    private let session: URLSession
    private let streamSession: URLSession

    private var config: FirebaseConfig?
    private var databaseBase: URL?
    private var tokens: Tokens?
    /// Kept in memory so an expired/revoked session can be re-established without
    /// asking the user again. Never persisted by this type.
    private var credential: (email: String, password: String)?
    private var observers: [RTDBObserverHandle: Task<Void, Never>] = [:]

    var isConfigured: Bool { config != nil }
    var uid: String? { tokens?.uid }

    init(session: URLSession? = nil, streamSession: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.waitsForConnectivity = false
            self.session = URLSession(configuration: c)
        }
        if let streamSession {
            self.streamSession = streamSession
        } else {
            // A live stream is idle between events; the server sends keep-alives, but
            // do not let URLSession's request timeout end a healthy connection.
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 120
            c.timeoutIntervalForResource = .infinity
            self.streamSession = URLSession(configuration: c)
        }
    }

    // MARK: Configure (runtime — no plist)

    /// Point the client at `config`. Safe to call repeatedly:
    /// - Same config as the live session → no-op (signed-in session and live
    ///   observers are kept; SMSSyncClient and ClipboardSyncService both call this).
    /// - Different config → the old session, tokens and observers are dropped so the
    ///   client really talks to the new project.
    func configure(_ config: FirebaseConfig) async throws {
        if let current = self.config, current == config, databaseBase != nil { return }
        teardown()

        guard !config.apiKey.isEmpty,
              let base = Self.normalizedDatabaseURL(config.databaseURL) else {
            throw RTDBError.configureFailed
        }
        self.config = config
        self.databaseBase = base
    }

    /// `https://…` only, no query/fragment, trailing slash stripped. A plain-http (or
    /// scheme-less) URL is refused: tokens ride in the query string.
    static func normalizedDatabaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed),
              c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.query = nil; c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url
    }

    // MARK: Auth (Email/Password — F-044 D12)

    @discardableResult
    func signIn(email: String, password: String) async throws -> String {
        guard let config else { throw RTDBError.notConfigured }
        let tokens = try await Self.requestTokens(
            session: session, apiKey: config.apiKey, email: email, password: password)
        self.tokens = tokens
        self.credential = (email, password)
        return tokens.uid
    }

    /// Forget the session and stop every live subscription.
    func signOut() {
        teardown(keepConfig: true)
    }

    private func teardown(keepConfig: Bool = false) {
        for task in observers.values { task.cancel() }
        observers.removeAll()
        tokens = nil
        credential = nil
        if !keepConfig { config = nil; databaseBase = nil }
    }

    // MARK: Test connection (F-044 — validate before saving config)

    /// End-to-end validation of a config + credential **without** touching the live
    /// session or the Keychain: a throwaway client signs in, then writes and reads back
    /// a `meta/{uid}` token to prove the database URL + rules let the account read and
    /// write its own subtree. Throws a descriptive `RTDBError` at the first failing step
    /// (bad config → configureFailed, bad credentials → authFailed, URL/rules problem →
    /// operationFailed on the round-trip).
    func testConnection(_ config: FirebaseConfig, email: String, password: String) async throws {
        let probe = FirebaseRTDBClient(session: session, streamSession: streamSession)
        try await probe.configure(config)
        let uid = try await probe.signIn(email: email, password: password)

        let path = "meta/\(uid)/_haloTest"
        let token = UUID().uuidString
        do {
            try await probe.setValue(token, at: path)
            let readBack = try await probe.getValue(at: path)
            guard (readBack as? String) == token else {
                throw RTDBError.operationFailed("Round-trip mismatch — check your database rules allow the signed-in account to read/write meta/$uid.")
            }
        } catch {
            await probe.signOut()
            throw error
        }
        try? await probe.removeValue(at: path)     // best-effort cleanup of the probe node
        await probe.signOut()
    }

    // MARK: Exposure check

    enum PublicAccess: Equatable, Sendable {
        /// An unauthenticated read was refused — the rules require sign-in. What we want.
        case locked
        /// An unauthenticated read **succeeded**: the database is open to the internet.
        case open
        /// Couldn't tell (network error, bad URL, an unexpected status).
        case unknown
    }

    /// Does this database answer an **unauthenticated** read? A Realtime Database left in Firebase's
    /// "test mode" does, for anyone who knows or guesses the URL. The cloud features encrypt the
    /// payloads end to end, so message text stays unreadable — but device names, line labels,
    /// timestamps and message counts are plaintext metadata, and open rules also let a stranger
    /// *write*, so this is worth surfacing during "Test connection" rather than discovering later.
    ///
    /// Read-only and token-free by construction (`shallow=true` returns keys only, never values),
    /// so it neither sends credentials to the URL being probed nor transfers any data.
    func checkPublicAccess(_ config: FirebaseConfig) async -> PublicAccess {
        guard let base = Self.normalizedDatabaseURL(config.databaseURL),
              var c = URLComponents(string: base.absoluteString + "/.json") else { return .unknown }
        c.queryItems = [URLQueryItem(name: "shallow", value: "true")]
        guard let url = c.url else { return .unknown }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unknown }
        switch http.statusCode {
        case 200:        return .open
        case 401, 403:   return .locked
        default:         return .unknown
        }
    }

    // MARK: RTDB operations

    /// `PUT` (idempotent overwrite) at a path relative to the DB root.
    func setValue(_ value: Any, at path: String) async throws {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) }
        catch { throw RTDBError.operationFailed("Value can't be encoded as JSON.") }
        _ = try await send("PUT", path: path, body: body)
    }

    /// One-shot read of a path's value (`nil` when the node doesn't exist).
    func getValue(at path: String) async throws -> Any? {
        let data = try await send("GET", path: path, body: nil)
        return try Self.decodeJSON(data)
    }

    /// Remove a path (used by wipe / re-key / delete-sync).
    func removeValue(at path: String) async throws {
        _ = try await send("DELETE", path: path, body: nil)
    }

    // MARK: Live observation (child_added)

    /// Observe `child_added` under a path. Existing children are delivered first, then
    /// new ones as they appear — the same contract the SDK gave, so callers dedupe by
    /// id exactly as before. Survives dropped connections (re-attaches with backoff and
    /// does **not** re-deliver children it already reported).
    @discardableResult
    func observeChildAdded(at path: String,
                           _ onChild: @escaping @Sendable (String, Any?) -> Void) throws -> RTDBObserverHandle {
        try startObserver(at: path, includeChanges: false, onChild)
    }

    /// Like `observeChildAdded`, but a child that is **rewritten after it was first delivered** is
    /// delivered again with its new value (H-21a). `child_added` alone reports a child exactly once,
    /// so a value the phone changes later — a renamed SIM, a different carrier — never reached a
    /// Mac that was already running; only a relaunch showed it. Callers must treat the callback as
    /// "upsert this child" (it is idempotent), not "a new child appeared".
    @discardableResult
    func observeChildAddedOrChanged(at path: String,
                                    _ onChild: @escaping @Sendable (String, Any?) -> Void) throws -> RTDBObserverHandle {
        try startObserver(at: path, includeChanges: true, onChild)
    }

    private func startObserver(at path: String, includeChanges: Bool,
                               _ onChild: @escaping @Sendable (String, Any?) -> Void) throws -> RTDBObserverHandle {
        guard config != nil, databaseBase != nil else { throw RTDBError.notConfigured }
        let handle = RTDBObserverHandle()
        observers[handle] = Task { [weak self] in
            await self?.runStream(path: path, includeChanges: includeChanges, onChild: onChild)
        }
        return handle
    }

    func removeObserver(at path: String, handle: RTDBObserverHandle) {
        observers[handle]?.cancel()
        observers[handle] = nil
    }

    // MARK: - Streaming internals

    private func runStream(path: String, includeChanges: Bool, onChild: @Sendable (String, Any?) -> Void) async {
        var delivery = ChildDelivery()
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            do {
                var request = try await authorizedRequest(method: "GET", path: path, body: nil)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 120

                let (bytes, response) = try await streamSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw RTDBError.operationFailed("No HTTP response.") }
                guard http.statusCode == 200 else {
                    if http.statusCode == 401 || http.statusCode == 403 { await invalidateToken() }
                    throw RTDBError.operationFailed("Live connection refused (HTTP \(http.statusCode)).")
                }
                backoff = 1

                var model: [String: Any] = [:]
                var event = ""
                // `lines` omits blank lines, so don't rely on SSE's blank-line framing:
                // RTDB sends each event as one `event:` line + one single-line `data:`.
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        switch Self.apply(event: event, payload: payload, to: &model) {
                        case .changed:
                            for (key, value) in delivery.pending(in: model, includeChanges: includeChanges) {
                                onChild(key, value)
                            }
                        case .unchanged:
                            break
                        case .reauthenticate:
                            await invalidateToken()
                            throw RTDBError.authFailed("Session expired — reconnecting.")
                        case .cancelled:
                            throw RTDBError.operationFailed("The server cancelled the stream (check database rules).")
                        }
                    }
                }
                // Server closed the stream cleanly → reconnect.
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    /// What a stream observer has already reported, so each event delivers only what is new — or,
    /// with `includeChanges`, only what is new **or different** (H-21a). Pure, so the delivery rule
    /// is tested without a socket.
    struct ChildDelivery {
        /// key → fingerprint of the value last delivered for it.
        private var delivered: [String: String] = [:]

        mutating func pending(in model: [String: Any], includeChanges: Bool) -> [(key: String, value: Any?)] {
            var out: [(key: String, value: Any?)] = []
            for key in model.keys.sorted() {
                let value = model[key]
                let print = Self.fingerprint(value)
                if let last = delivered[key] {
                    guard includeChanges, last != print else { continue }
                }
                delivered[key] = print
                out.append((key, value))
            }
            // A removed child that comes back must fire again.
            delivered = delivered.filter { model.keys.contains($0.key) }
            return out
        }

        /// Order-independent canonical form: two dictionaries with the same content print the same.
        static func fingerprint(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "null" }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }

    enum StreamOutcome: Equatable { case changed, unchanged, reauthenticate, cancelled }

    /// Fold one RTDB streaming event into the local copy of the observed node.
    /// `put` replaces the value at `path`; `patch` merges its keys under `path`.
    static func apply(event: String, payload: String, to model: inout [String: Any]) -> StreamOutcome {
        switch event {
        case "keep-alive": return .unchanged
        case "cancel": return .cancelled
        case "auth_revoked": return .reauthenticate
        case "put", "patch":
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
                  let path = obj["path"] as? String else { return .unchanged }
            let components = path.split(separator: "/").map(String.init)
            let value = obj["data"]
            if event == "put" {
                set(&model, at: components, to: value)
            } else if let patch = value as? [String: Any] {
                for (k, v) in patch { set(&model, at: components + k.split(separator: "/").map(String.init), to: v) }
            }
            return .changed
        default:
            return .unchanged
        }
    }

    /// Set (or, for null, delete) `value` at `path` inside a nested-dictionary model.
    private static func set(_ model: inout [String: Any], at path: [String], to value: Any?) {
        let isNull = value == nil || value is NSNull
        guard let head = path.first else {
            // Root replaced: the model becomes the new root map (or empty for null).
            model = (value as? [String: Any]) ?? [:]
            return
        }
        if path.count == 1 {
            if isNull { model.removeValue(forKey: head) } else { model[head] = value }
            return
        }
        var child = (model[head] as? [String: Any]) ?? [:]
        set(&child, at: Array(path.dropFirst()), to: value)
        if child.isEmpty { model.removeValue(forKey: head) } else { model[head] = child }
    }

    // MARK: - Requests

    private func send(_ method: String, path: String, body: Data?) async throws -> Data {
        var attempt = 0
        while true {
            let request = try await authorizedRequest(method: method, path: path, body: body)
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch let urlError as URLError {
                throw RTDBError.operationFailed("Network error: \(urlError.localizedDescription)")
            }
            guard let http = response as? HTTPURLResponse else { throw RTDBError.operationFailed("No HTTP response.") }

            if http.statusCode == 401, attempt == 0 {       // token raced its expiry → renew once and retry
                attempt += 1
                await invalidateToken()
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RTDBError.operationFailed(Self.message(forStatus: http.statusCode, body: data))
            }
            return data
        }
    }

    private func authorizedRequest(method: String, path: String, body: Data?) async throws -> URLRequest {
        guard let base = databaseBase else { throw RTDBError.notConfigured }
        let token = try await validIDToken()

        guard let final = Self.requestURL(base: base, path: path, token: token) else {
            throw RTDBError.configureFailed
        }

        var req = URLRequest(url: final)
        req.httpMethod = method
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    /// `<base>/<path>.json?auth=<token>`. Each path component is percent-encoded on its
    /// own (so a `/` inside a key can never be introduced by encoding), and an empty
    /// path addresses the root as `<base>/.json`.
    static func requestURL(base: URL, path: String, token: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let components = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
        }
        let tail = components.isEmpty ? ".json" : components.joined(separator: "/") + ".json"
        guard var c = URLComponents(string: base.absoluteString + "/" + tail) else { return nil }
        c.queryItems = [URLQueryItem(name: "auth", value: token)]
        return c.url
    }

    // MARK: - Token lifecycle

    private func validIDToken() async throws -> String {
        guard let t = tokens else { throw RTDBError.notConfigured }
        if t.expiresAt.timeIntervalSinceNow > Self.refreshSkew { return t.idToken }
        try await renew()
        guard let fresh = tokens else { throw RTDBError.notConfigured }
        return fresh.idToken
    }

    /// Mark the current ID token unusable so the next request renews it.
    private func invalidateToken() async {
        guard tokens != nil else { return }
        tokens?.expiresAt = .distantPast
    }

    /// Refresh with the refresh token; if that is refused, sign in again from the
    /// in-memory credential.
    private func renew() async throws {
        guard let config, let current = tokens else { throw RTDBError.notConfigured }
        do {
            tokens = try await Self.refreshTokens(session: session, apiKey: config.apiKey,
                                                  refreshToken: current.refreshToken)
        } catch {
            guard let credential else { throw error }
            tokens = try await Self.requestTokens(session: session, apiKey: config.apiKey,
                                                  email: credential.email, password: credential.password)
        }
    }

    // MARK: Identity Toolkit / Secure Token

    private static func requestTokens(session: URLSession, apiKey: String,
                                      email: String, password: String) async throws -> Tokens {
        var c = URLComponents(url: identityToolkitBase.appendingPathComponent("accounts:signInWithPassword"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "returnSecureToken": true])

        let (data, response) = try await post(session, req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RTDBError.authFailed("Unexpected sign-in response.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RTDBError.authFailed(authMessage(from: json))
        }
        guard let idToken = json["idToken"] as? String,
              let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String else {
            throw RTDBError.authFailed("Sign-in response was missing a token.")
        }
        let seconds = Double(json["expiresIn"] as? String ?? "") ?? 3600
        return Tokens(idToken: idToken, refreshToken: refresh,
                      expiresAt: Date().addingTimeInterval(seconds), uid: uid)
    }

    private static func refreshTokens(session: URLSession, apiKey: String,
                                      refreshToken: String) async throws -> Tokens {
        var c = URLComponents(url: secureTokenBase.appendingPathComponent("token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let rt = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(rt)".utf8)

        let (data, response) = try await post(session, req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (response as? HTTPURLResponse)?.statusCode == 200,
              let idToken = json["id_token"] as? String,
              let newRefresh = json["refresh_token"] as? String,
              let uid = json["user_id"] as? String else {
            throw RTDBError.authFailed("Couldn't renew the session.")
        }
        let seconds = Double(json["expires_in"] as? String ?? "") ?? 3600
        return Tokens(idToken: idToken, refreshToken: newRefresh,
                      expiresAt: Date().addingTimeInterval(seconds), uid: uid)
    }

    private static func post(_ session: URLSession, _ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch let e as URLError { throw RTDBError.authFailed("Network error: \(e.localizedDescription)") }
    }

    // MARK: Error mapping

    /// Identity Toolkit reports `{"error":{"message":"INVALID_LOGIN_CREDENTIALS", …}}`.
    static func authMessage(from json: [String: Any]) -> String {
        let raw = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
        let code = raw.split(separator: " ").first.map(String.init) ?? raw   // "WEAK_PASSWORD : …"
        switch code {
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
            return "Wrong email or password for this Firebase project."
        case "USER_DISABLED":
            return "That Firebase account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER":
            return "Too many sign-in attempts — wait a few minutes and try again."
        case "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED":
            return "Email/Password sign-in isn't enabled for this Firebase project (Authentication → Sign-in method)."
        case "API_KEY_INVALID", "INVALID_API_KEY":
            return "The API key isn't valid for this Firebase project."
        case "":
            return "Sign-in failed."
        default:
            return "Sign-in failed (\(code))."
        }
    }

    /// RTDB errors arrive as `{"error":"Permission denied"}`.
    static func message(forStatus status: Int, body: Data) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        switch status {
        case 401, 403:
            return "Permission denied — check your database rules allow this account to read/write its own data."
        case 404:
            return "Database not found — check the Realtime Database URL (it must match your database's region)."
        case 400:
            return "Request rejected\(detail.map { ": \($0)" } ?? "")."
        case 429, 503:
            return "The database is rate-limiting or unavailable — try again shortly."
        default:
            return "Database request failed (HTTP \(status))\(detail.map { ": \($0)" } ?? "")."
        }
    }

    static func decodeJSON(_ data: Data) throws -> Any? {
        guard !data.isEmpty else { return nil }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }
}
