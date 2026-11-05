import Foundation

// Email/Password auth + Realtime Database over the two documented REST APIs — a port of
// Halo/Core/Cloud/FirebaseRTDBClient.swift (and its Kotlin twin Rtdb.kt). No Firebase SDK: nothing here
// touches the Keychain for tokens (they live in memory), and the only credentials ever sent are the
// sign-in body (to the fixed Google hosts) and the `?auth=<idToken>` query on database calls.
//
//   Auth: POST identitytoolkit.googleapis.com/v1/accounts:signInWithPassword
//   Renew: POST securetoken.googleapis.com/v1/token
//   Data: GET/PUT/DELETE <databaseURL>/<path>.json?auth=<idToken>
//   Live: GET <databaseURL>/<path>.json  Accept: text/event-stream
//
// This file never logs and never builds an error from a response/URL (see CloudError).

public enum ChildEvent: Sendable, Equatable {
    /// A child appeared OR its value changed (an upsert — callers key by `key`).
    case added(key: String, value: JSONValue)
    case removed(key: String)
    /// The live connection came up / went away (it reconnects by itself with backoff).
    case connected
    case disconnected
}

public protocol RealtimeDatabase: Sendable {
    func uid() async throws -> String
    func get(_ path: String) async throws -> JSONValue
    func put(_ path: String, _ value: JSONValue) async throws
    func delete(_ path: String) async throws
    /// Child keys without their values (`?shallow=true`).
    func shallowKeys(_ path: String) async throws -> Set<String>
    /// Existing children first, then changes. Cancel the consuming task (or stop iterating) to stop it.
    func observeChildren(_ path: String) -> AsyncStream<ChildEvent>
}

public struct AuthEndpoints: Sendable, Equatable {
    public var identityToolkit: URL
    public var secureToken: URL
    public static let google = AuthEndpoints(identityToolkit: URL(string: "https://identitytoolkit.googleapis.com/v1")!,
                                             secureToken: URL(string: "https://securetoken.googleapis.com/v1")!)
    public init(identityToolkit: URL, secureToken: URL) { self.identityToolkit = identityToolkit; self.secureToken = secureToken }

    /// Debug/test only: a loopback stand-in (android/tools/fake-firebase.py) serves the auth endpoints from
    /// the same origin as the database. Applies only to a plain-http loopback database URL; anything else
    /// (every real database) gets Google.
    public static func forDatabase(_ databaseURL: String, allowLoopbackHTTP: Bool) -> AuthEndpoints {
        guard allowLoopbackHTTP, let u = DatabaseURLPolicy.normalized(databaseURL, allowLoopbackHTTP: true),
              u.scheme == "http", let host = u.host, let origin = URL(string: "http://\(host)\(u.port.map { ":\($0)" } ?? "")") else { return .google }
        return AuthEndpoints(identityToolkit: origin.appendingPathComponent("identitytoolkit/v1"),
                             secureToken: origin.appendingPathComponent("securetoken/v1"))
    }
}

public actor FirebaseRTDB: RealtimeDatabase {

    private struct Tokens { var idToken: String; var refreshToken: String; var expiresAt: Date; var uid: String }

    private static let refreshSkew: TimeInterval = 120

    private let config: FirebaseConfig
    private let credential: CloudAuthCredential
    private let transport: HTTPTransport
    private let endpoints: AuthEndpoints
    private let base: URL
    private let minBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var tokens: Tokens?

    public init(config: FirebaseConfig, credential: CloudAuthCredential,
                transport: HTTPTransport = URLSessionTransport(),
                allowLoopbackHTTP: Bool = false,
                endpoints: AuthEndpoints? = nil,
                minBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 30) throws {
        guard !config.apiKey.isEmpty,
              let base = DatabaseURLPolicy.normalized(config.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP) else { throw CloudError.configureFailed }
        self.config = config
        self.credential = credential
        self.transport = transport
        self.base = base
        self.endpoints = endpoints ?? AuthEndpoints.forDatabase(config.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP)
        self.minBackoff = minBackoff
        self.maxBackoff = maxBackoff
    }

    // MARK: Auth

    @discardableResult
    public func signIn() async throws -> String {
        let t = try await Self.requestTokens(transport: transport, endpoints: endpoints, apiKey: config.apiKey, credential: credential)
        tokens = t
        return t.uid
    }

    public func uid() async throws -> String {
        if let t = tokens { return t.uid }
        return try await signIn()
    }

    /// Forget the session (tokens are memory-only).
    public func signOut() { tokens = nil }

    // MARK: Operations

    public func get(_ path: String) async throws -> JSONValue {
        try JSONValue.parse(try await send("GET", path: path))
    }

    public func put(_ path: String, _ value: JSONValue) async throws {
        _ = try await send("PUT", path: path, body: try value.serialized())
    }

    public func delete(_ path: String) async throws { _ = try await send("DELETE", path: path) }

    public func shallowKeys(_ path: String) async throws -> Set<String> {
        let v = try JSONValue.parse(try await send("GET", path: path, query: [URLQueryItem(name: "shallow", value: "true")]))
        return Set(v.children?.keys.map { $0 } ?? [])
    }

    // MARK: Live observation

    public nonisolated func observeChildren(_ path: String) -> AsyncStream<ChildEvent> {
        AsyncStream { cont in
            let task = Task { await self.runStream(path: path, emit: { cont.yield($0) }) ; cont.finish() }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(path: String, emit: @Sendable (ChildEvent) -> Void) async {
        var delivered: [String: JSONValue] = [:]
        var backoff = minBackoff
        var wasConnected = false
        while !Task.isCancelled {
            do {
                var request = try await authorizedRequest("GET", path: path)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 120
                let (status, lines) = try await transport.openLines(request)
                guard status == 200 else {
                    if status == 401 || status == 403 { invalidateToken() }
                    throw CloudError.operationFailed("Live connection refused.")
                }
                backoff = minBackoff
                wasConnected = true
                emit(.connected)

                var model: [String: JSONValue] = [:]
                var event = ""
                for try await line in lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        switch Self.apply(event: event, payload: payload, to: &model) {
                        case .changed:
                            for key in model.keys.sorted() where delivered[key] != model[key] {
                                delivered[key] = model[key]
                                emit(.added(key: key, value: model[key]!))
                            }
                            for key in delivered.keys.sorted() where model[key] == nil {
                                delivered[key] = nil
                                emit(.removed(key: key))
                            }
                        case .unchanged: break
                        case .reauthenticate:
                            invalidateToken()
                            throw CloudError.authFailed("Session expired — reconnecting.")
                        case .cancelled:
                            throw CloudError.operationFailed("The server cancelled the stream (check database rules).")
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            if wasConnected { emit(.disconnected); wasConnected = false }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, maxBackoff)
        }
    }

    public enum StreamOutcome: Equatable, Sendable { case changed, unchanged, reauthenticate, cancelled }

    /// Fold one RTDB streaming event into the local copy of the observed node (`put` replaces the value at
    /// `path`; `patch` merges its keys under `path`). Public for the conformance tests.
    public static func apply(event: String, payload: String, to model: inout [String: JSONValue]) -> StreamOutcome {
        switch event {
        case "keep-alive": return .unchanged
        case "cancel": return .cancelled
        case "auth_revoked": return .reauthenticate
        case "put", "patch":
            guard let data = payload.data(using: .utf8),
                  let obj = (try? JSONValue.parse(data))?.objectValue,
                  let path = obj["path"]?.stringValue else { return .unchanged }
            let components = path.split(separator: "/").map(String.init)
            let value = obj["data"] ?? .null
            if event == "put" {
                set(&model, at: components, to: value)
            } else if let patch = value.objectValue {
                for (k, v) in patch { set(&model, at: components + k.split(separator: "/").map(String.init), to: v) }
            }
            return .changed
        default: return .unchanged
        }
    }

    private static func set(_ model: inout [String: JSONValue], at path: [String], to value: JSONValue) {
        guard let head = path.first else { model = value.children ?? [:]; return }
        if path.count == 1 {
            if value.isNull { model.removeValue(forKey: head) } else { model[head] = value }
            return
        }
        var child = model[head]?.children ?? [:]
        set(&child, at: Array(path.dropFirst()), to: value)
        if child.isEmpty { model.removeValue(forKey: head) } else { model[head] = .object(child) }
    }

    // MARK: Requests

    private func send(_ method: String, path: String, body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        var attempt = 0
        while true {
            let request = try await authorizedRequest(method, path: path, body: body, query: query)
            let (data, status) = try await transport.send(request)
            if status == 401, attempt == 0 { attempt += 1; invalidateToken(); continue }   // token raced its expiry
            guard (200..<300).contains(status) else { throw CloudError.operationFailed(Self.message(forStatus: status)) }
            return data
        }
    }

    private func authorizedRequest(_ method: String, path: String, body: Data? = nil, query: [URLQueryItem] = []) async throws -> URLRequest {
        let token = try await validIDToken()
        guard let url = Self.requestURL(base: base, path: path, token: token, extra: query) else { throw CloudError.configureFailed }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    /// `<base>/<path>.json?auth=<token>`; each component percent-encoded on its own.
    public static func requestURL(base: URL, path: String, token: String, extra: [URLQueryItem] = []) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let comps = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        let tail = comps.isEmpty ? ".json" : comps.joined(separator: "/") + ".json"
        guard var c = URLComponents(string: base.absoluteString + "/" + tail) else { return nil }
        c.queryItems = [URLQueryItem(name: "auth", value: token)] + extra
        return c.url
    }

    // MARK: Token lifecycle

    private func validIDToken() async throws -> String {
        if tokens == nil { try await signInIfNeeded() }
        guard let t = tokens else { throw CloudError.notConfigured }
        if t.expiresAt.timeIntervalSinceNow > Self.refreshSkew { return t.idToken }
        try await renew()
        guard let fresh = tokens else { throw CloudError.notConfigured }
        return fresh.idToken
    }

    private func signInIfNeeded() async throws { _ = try await signIn() }

    private func invalidateToken() { tokens?.expiresAt = .distantPast }

    private func renew() async throws {
        guard let current = tokens else { throw CloudError.notConfigured }
        do {
            tokens = try await Self.refreshTokens(transport: transport, endpoints: endpoints, apiKey: config.apiKey, refreshToken: current.refreshToken)
        } catch is CancellationError { throw CancellationError() }
        catch {
            tokens = try await Self.requestTokens(transport: transport, endpoints: endpoints, apiKey: config.apiKey, credential: credential)
        }
    }

    private static func requestTokens(transport: HTTPTransport, endpoints: AuthEndpoints, apiKey: String, credential: CloudAuthCredential) async throws -> Tokens {
        var c = URLComponents(url: endpoints.identityToolkit.appendingPathComponent("accounts:signInWithPassword"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": credential.email, "password": credential.password, "returnSecureToken": true])
        let (data, status): (Data, Int)
        do { (data, status) = try await transport.send(req) } catch let e as CloudError { throw e.isNetwork ? CloudError.authFailed("Couldn't reach Google to sign in.") : e }
        let json = (try? JSONValue.parse(data))?.objectValue
        guard status == 200 else { throw CloudError.authFailed(authMessage(from: json)) }
        guard let idToken = json?["idToken"]?.stringValue, let refresh = json?["refreshToken"]?.stringValue,
              let uid = json?["localId"]?.stringValue, !uid.isEmpty, !uid.contains("/") else {
            throw CloudError.authFailed("Sign-in response was missing a token.")
        }
        let seconds = Double(json?["expiresIn"]?.stringValue ?? "") ?? 3600
        return Tokens(idToken: idToken, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds), uid: uid)
    }

    private static func refreshTokens(transport: HTTPTransport, endpoints: AuthEndpoints, apiKey: String, refreshToken: String) async throws -> Tokens {
        var c = URLComponents(url: endpoints.secureToken.appendingPathComponent("token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let rt = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(rt)".utf8)
        let (data, status) = try await transport.send(req)
        guard status == 200, let json = (try? JSONValue.parse(data))?.objectValue,
              let idToken = json["id_token"]?.stringValue, let newRefresh = json["refresh_token"]?.stringValue,
              let uid = json["user_id"]?.stringValue else { throw CloudError.authFailed("Couldn't renew the session.") }
        let seconds = Double(json["expires_in"]?.stringValue ?? "") ?? 3600
        return Tokens(idToken: idToken, refreshToken: newRefresh, expiresAt: Date().addingTimeInterval(seconds), uid: uid)
    }

    // MARK: Error mapping

    /// Identity Toolkit reports `{"error":{"message":"INVALID_LOGIN_CREDENTIALS", …}}`.
    public static func authMessage(from json: [String: JSONValue]?) -> String {
        let raw = json?["error"]?["message"]?.stringValue ?? ""
        let code = raw.split(separator: " ").first.map(String.init) ?? raw
        switch code {
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS": return "Wrong email or password for this Firebase project."
        case "USER_DISABLED": return "That Firebase account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many sign-in attempts — wait a few minutes and try again."
        case "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED": return "Email/Password sign-in isn't enabled for this Firebase project (Authentication → Sign-in method)."
        case "API_KEY_INVALID", "INVALID_API_KEY": return "The API key isn't valid for this Firebase project."
        case "": return "Sign-in failed."
        default: return "Sign-in failed (\(code))."
        }
    }

    public static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403: return "Permission denied — check your database rules allow this account to read/write its own data."
        case 404: return "Database not found — check the Realtime Database URL (it must match your database's region)."
        case 400: return "Request rejected by the database."
        case 429, 503: return "The database is rate-limiting or unavailable — try again shortly."
        default: return "Database request failed (HTTP \(status))."
        }
    }
}

extension CloudError {
    fileprivate var isNetwork: Bool { if case .network = self { return true } else { return false } }
}
