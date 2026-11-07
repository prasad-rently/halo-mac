import Foundation

// MARK: - DatabaseCheck  (F-057 FR-S1 — "Check my database")
//
// Swift twin for iOS, PORTED from the Mac engine on PR #63 (branch feat/v2.6-f057-setup-assistant,
// Halo/Core/Cloud/DatabaseCheck.swift) — same item kinds, problem codes and fix wording. It does not depend on that
// branch: the engine is re-homed here over this package's HTTPTransport seam. When #63 merges, the Mac and
// the phone share behaviour but not code; keep wording changes in step.

//
// The v2.5 defect this exists for: a user published rules that covered `sms`, `devices` and `meta`
// but not `clipboard`. "Test connection" (which only touches meta/{uid}) said everything was fine,
// and clipboard sync then failed with a bare "permission denied" long after setup. This engine
// writes, reads back and deletes a probe under EACH path the apps use and says which one is
// refused, with the concrete fix.
//
// Shape: a pure engine (`DatabaseCheckEngine`) over a narrow seam (`DatabaseProbeTransport`) so
// every outcome — including the failure ones — is exercised by stubbed-network tests.
// `LiveDatabaseProbeTransport` is the one real implementation (URLSession; same REST contract as
// FirebaseRTDBClient). The Kotlin twin is android/halocloud/.../DatabaseCheck.kt; the item kinds,
// problem codes and fix wording are deliberately identical.
//
// What this file never does: log, or put into a report, a token, the password, the API key or any
// passphrase. Report text is built from fixed strings and path *templates* ("meta/{uid}"), never
// from an error's description — URLError descriptions can carry the request URL, and the URL
// carries `?auth=<token>`.
//
// NOT verified against real Firebase: the status codes (401/403 = denied, 404 = wrong URL or
// region) are what the REST documentation says; they are exercised only against stubs.

public enum DatabaseCheckKind: Int, CaseIterable, Sendable { case databaseURL, signIn, meta, devices, sms, clipboard, publicAccess }
public enum DatabaseCheckStatus: Sendable { case pass, warn, fail, skipped }
public enum DatabaseCheckProblem: Sendable, Equatable {
    case none, invalidURL, databaseNotFound, emailPasswordDisabled, badCredentials, badAPIKey, accountDisabled
    case rateLimited, network, permissionDenied, readDenied, readBackMismatch, cleanupFailed
    case openRules, unknownAccess, unexpected, notRun
}

/// One line of the report. `fix` is the concrete next step, nil when there is nothing to do.
public struct DatabaseCheckItem: Sendable, Equatable {
    public var kind: DatabaseCheckKind
    public var status: DatabaseCheckStatus
    public var problem: DatabaseCheckProblem
    public var title: String
    public var detail: String
    public var fix: String? = nil
    public init(kind: DatabaseCheckKind, status: DatabaseCheckStatus, problem: DatabaseCheckProblem, title: String, detail: String, fix: String? = nil) {
        self.kind = kind; self.status = status; self.problem = problem; self.title = title; self.detail = detail; self.fix = fix
    }
}

public struct DatabaseCheckReport: Sendable, Equatable {
    public let items: [DatabaseCheckItem]
    public init(items: [DatabaseCheckItem]) { self.items = items }
    public var overall: DatabaseCheckStatus {
        if items.contains(where: { $0.status == .fail }) { return .fail }
        if items.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }
    public func item(_ kind: DatabaseCheckKind) -> DatabaseCheckItem { items.first { $0.kind == kind }! }
}

public enum DatabaseCheckSignIn: Sendable, Equatable {
    case ok(uid: String)
    /// Identity Toolkit refused; `code` is Firebase's own error code ("OPERATION_NOT_ALLOWED", …) and nothing else.
    case rejected(code: String)
}

public struct DatabaseProbeResponse: Sendable {
    public var status: Int; public var body: String
    public init(status: Int, body: String) { self.status = status; self.body = body }
}

/// The network could not be reached at all. Deliberately carries no cause text (see file header).
public struct DatabaseProbeNetworkError: Error, Sendable { public init() {} }

/// What the engine needs from the network. `path` is relative to the database root, e.g. "meta/<uid>/_haloCheck_ab12".
public protocol DatabaseProbeTransport: Sendable {
    func signIn() async throws -> DatabaseCheckSignIn
    func request(method: String, path: String, body: String?) async throws -> DatabaseProbeResponse
    /// HTTP status of an UNAUTHENTICATED shallow read of `path` ("" = the database root). No credentials are sent.
    func unauthenticatedStatus(path: String) async throws -> Int
}

public enum DatabaseCheckText {
    static let rulesFix = "Publish the owner-only rules from docs/specs/firebase-rules.json (Firebase console → Realtime Database → Rules → Publish)."
    static let urlFix = "Copy the database URL from Firebase console → Realtime Database (top of the Data tab). A database outside the US uses https://<name>.<region>.firebasedatabase.app, not …firebaseio.com."
    static let authFix = "Firebase console → Authentication → Sign-in method → enable Email/Password."

    static func title(_ kind: DatabaseCheckKind) -> String {
        switch kind {
        case .databaseURL: return "Database address"
        case .signIn: return "Sign-in"
        case .meta: return "Settings (meta)"
        case .devices: return "Devices"
        case .sms: return "SMS"
        case .clipboard: return "Clipboard"
        case .publicAccess: return "Open to the public?"
        }
    }
}

public struct DatabaseCheckEngine: Sendable {
    /// Every probe entry is named `_haloCheck_<nonce>` and lives directly under `{root}/{uid}`. The live
    /// sync observers watch exactly those nodes (child_added on `sms/{uid}` and `devices/{uid}`), so they MUST
    /// ignore this prefix — otherwise a probe shows up as a phantom device and gets its own observers.
    public static let probePrefix = "_haloCheck_"
    public static func isProbeKey(_ key: String) -> Bool { key.hasPrefix(probePrefix) }

    let transport: DatabaseProbeTransport
    let databaseURL: String
    let allowLoopbackHTTP: Bool
    var nonce: @Sendable () -> String = { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) }

    public init(transport: DatabaseProbeTransport, databaseURL: String, allowLoopbackHTTP: Bool = false,
                nonce: (@Sendable () -> String)? = nil) {
        self.transport = transport; self.databaseURL = databaseURL; self.allowLoopbackHTTP = allowLoopbackHTTP
        if let nonce { self.nonce = nonce }
    }

    /// Every top-level path the apps use, in the order they are checked.
    private static let paths: [(DatabaseCheckKind, String)] = [(.meta, "meta"), (.devices, "devices"), (.sms, "sms"), (.clipboard, "clipboard")]

    public func run() async -> DatabaseCheckReport {
        var out: [DatabaseCheckKind: DatabaseCheckItem] = [:]
        func skipped(_ k: DatabaseCheckKind, _ why: String) -> DatabaseCheckItem {
            DatabaseCheckItem(kind: k, status: .skipped, problem: .notRun, title: DatabaseCheckText.title(k), detail: why)
        }
        func finish() -> DatabaseCheckReport { DatabaseCheckReport(items: DatabaseCheckKind.allCases.map { out[$0] ?? skipped($0, "Skipped.") }) }

        // 1. The address itself.
        guard DatabaseURLPolicy.normalized(databaseURL, allowLoopbackHTTP: allowLoopbackHTTP) != nil else {
            out[.databaseURL] = DatabaseCheckItem(kind: .databaseURL, status: .fail, problem: .invalidURL, title: DatabaseCheckText.title(.databaseURL),
                                                  detail: "The database URL isn't a valid https:// address.", fix: DatabaseCheckText.urlFix)
            for k in DatabaseCheckKind.allCases where k != .databaseURL { out[k] = skipped(k, "Needs a valid database address.") }
            return finish()
        }
        out[.databaseURL] = DatabaseCheckItem(kind: .databaseURL, status: .pass, problem: .none, title: DatabaseCheckText.title(.databaseURL), detail: "The address is well-formed.")

        // 2. Sign-in (also the Email/Password-disabled and bad-key checks).
        var uid: String?
        var offline = false
        do {
            switch try await transport.signIn() {
            case .ok(let u) where u.isEmpty || u.contains("/"):
                // An empty uid would collapse "meta//x" to "meta/x" — a probe outside the user's own node.
                out[.signIn] = Self.signInFailure("MALFORMED_RESPONSE")
            case .ok(let u):
                uid = u
                out[.signIn] = DatabaseCheckItem(kind: .signIn, status: .pass, problem: .none, title: DatabaseCheckText.title(.signIn), detail: "Signed in.")
            case .rejected(let code):
                out[.signIn] = Self.signInFailure(code)
            }
        } catch {
            offline = true
            out[.signIn] = DatabaseCheckItem(kind: .signIn, status: .fail, problem: .network, title: DatabaseCheckText.title(.signIn),
                                             detail: "Couldn't reach Google to sign in.", fix: "Check this device's internet connection and try again.")
        }

        // 3. A probe under each path.
        var urlWrong = false
        for (kind, root) in Self.paths {
            guard let uid else { out[kind] = skipped(kind, "Needs a successful sign-in."); continue }
            if urlWrong { out[kind] = skipped(kind, "The database address looks wrong — fix that first."); continue }
            if offline { out[kind] = skipped(kind, "The network went away — try again."); continue }
            let item = await probe(kind: kind, root: root, uid: uid)
            if item.problem == .databaseNotFound {
                urlWrong = true
                var u = item; u.kind = .databaseURL; u.title = DatabaseCheckText.title(.databaseURL)
                out[.databaseURL] = u
                out[kind] = skipped(kind, "The database address looks wrong — see above.")
            } else {
                out[kind] = item
            }
            if item.problem == .network { offline = true }
        }

        // 4. Is the database open to the whole internet? Independent of sign-in.
        out[.publicAccess] = (urlWrong || offline) ? skipped(.publicAccess, "Skipped.") : await publicAccess()
        return finish()
    }

    private func probe(kind: DatabaseCheckKind, root: String, uid: String) async -> DatabaseCheckItem {
        let template = "\(root)/{uid}"
        let name = "\(Self.probePrefix)\(nonce())"
        let path = "\(root)/\(uid)/\(name)"
        let token = nonce() + nonce()
        let title = DatabaseCheckText.title(kind)
        func fail(_ p: DatabaseCheckProblem, _ detail: String, _ fix: String?) -> DatabaseCheckItem {
            DatabaseCheckItem(kind: kind, status: .fail, problem: p, title: title, detail: detail, fix: fix)
        }
        let body = "\"\(token)\""      // the token is hex: nothing to escape

        // WRITE. Only a write that may have landed needs cleaning up: a refused one left nothing behind.
        let put: DatabaseProbeResponse
        do { put = try await transport.request(method: "PUT", path: path, body: body) } catch {
            // The request may have reached the server before the connection dropped. If the delete cannot get
            // through either, the entry may exist — say where, rather than silently leaving junk.
            let cleaned = await cleanUp(path)
            return fail(.network, "The connection dropped while writing to \(template).\(Self.maybeLeftover(cleaned, template, name))", "Check the internet connection and run the check again.")
        }
        guard (200..<300).contains(put.status) else { return Self.refused(kind, template, put.status, "write") }

        // READ BACK. From here on the probe exists, so every exit path removes it.
        let read: DatabaseProbeResponse
        do { read = try await transport.request(method: "GET", path: path, body: nil) } catch {
            let cleaned = await cleanUp(path)
            return fail(.network, "The connection dropped while reading from \(template).\(Self.leftover(cleaned, template, name))", "Check the internet connection and run the check again.")
        }
        guard (200..<300).contains(read.status) else {
            let cleaned = await cleanUp(path)
            if read.status == 401 || read.status == 403 {
                return fail(.readDenied, "Writing to \(template) works but reading it back is refused.\(Self.leftover(cleaned, template, name))", DatabaseCheckText.rulesFix)
            }
            return fail(.unexpected, "Reading back from \(template) failed (HTTP \(read.status)).\(Self.leftover(cleaned, template, name))", nil)
        }
        let readBack = (try? JSONSerialization.jsonObject(with: Data(read.body.utf8), options: [.fragmentsAllowed])) as? String
        guard readBack == token else {
            let cleaned = await cleanUp(path)
            return fail(.readBackMismatch, "What was read back from \(template) wasn't what was written.\(Self.leftover(cleaned, template, name))", DatabaseCheckText.rulesFix)
        }

        // DELETE. Writing and reading were allowed; if the probe can't be removed, say where it is.
        if await cleanUp(path) {
            return DatabaseCheckItem(kind: kind, status: .pass, problem: .none, title: title, detail: "Write, read and delete all work under \(template).")
        }
        return DatabaseCheckItem(kind: kind, status: .warn, problem: .cleanupFailed, title: title,
                                 detail: "Read and write work under \(template), but the test entry \"\(name)\" couldn't be deleted.",
                                 fix: "Delete \"\(name)\" under \(template) in the Firebase console (Realtime Database → Data), and check your rules allow deleting.")
    }

    private static func refused(_ kind: DatabaseCheckKind, _ template: String, _ status: Int, _ what: String) -> DatabaseCheckItem {
        let t = DatabaseCheckText.title(kind)
        switch status {
        case 401, 403: return DatabaseCheckItem(kind: kind, status: .fail, problem: .permissionDenied, title: t, detail: "Your database rules refuse to \(what) under \(template).", fix: DatabaseCheckText.rulesFix)
        case 404: return DatabaseCheckItem(kind: kind, status: .fail, problem: .databaseNotFound, title: t, detail: "There is no database at this address.", fix: DatabaseCheckText.urlFix)
        case 429, 503: return DatabaseCheckItem(kind: kind, status: .fail, problem: .rateLimited, title: t, detail: "The database is rate-limiting or unavailable.", fix: "Wait a minute and run the check again.")
        default: return DatabaseCheckItem(kind: kind, status: .fail, problem: .unexpected, title: t, detail: "The database answered the \(what) to \(template) with HTTP \(status).", fix: nil)
        }
    }

    private static func leftover(_ cleaned: Bool, _ template: String, _ name: String) -> String {
        cleaned ? "" : " The test entry \"\(name)\" under \(template) couldn't be removed — delete it in the Firebase console."
    }

    private static func maybeLeftover(_ cleaned: Bool, _ template: String, _ name: String) -> String {
        cleaned ? "" : " A test entry \"\(name)\" may have been left under \(template) — if you see it in the Firebase console, delete it."
    }

    /// One best-effort delete. True only when the server confirmed it. Runs detached so that cancelling the
    /// check (the parent Task) cannot abort the very delete that removes the probe: a cancelled task's
    /// URLSession call throws immediately, which would leave the entry behind.
    private func cleanUp(_ path: String) async -> Bool {
        let transport = self.transport
        return await Task.detached {
            guard let r = try? await transport.request(method: "DELETE", path: path, body: nil) else { return false }
            return (200..<300).contains(r.status)
        }.value
    }

    /// Anonymous reads, no credentials. The root first (test-mode rules open everything); if the root is locked,
    /// each folder the apps use — rules that open only `clipboard` would otherwise pass as "refused".
    private func publicAccess() async -> DatabaseCheckItem {
        let t = DatabaseCheckText.title(.publicAccess)
        let rootStatus = (try? await transport.unauthenticatedStatus(path: "")) ?? -1
        if rootStatus == 200 {
            return DatabaseCheckItem(kind: .publicAccess, status: .warn, problem: .openRules, title: t,
                                     detail: "Your database answers anyone on the internet without signing in (test-mode rules). Message text stays encrypted, but device names, labels and timestamps are readable, and a stranger could write to it.",
                                     fix: DatabaseCheckText.rulesFix)
        }
        var open: [String] = []
        var undetermined = rootStatus != 401 && rootStatus != 403
        if !undetermined {
            for (_, root) in Self.paths {
                switch (try? await transport.unauthenticatedStatus(path: root)) ?? -1 {
                case 200: open.append(root)
                case 401, 403: break
                default: undetermined = true
                }
            }
        }
        if !open.isEmpty {
            return DatabaseCheckItem(kind: .publicAccess, status: .warn, problem: .openRules, title: t,
                                     detail: "Part of your database (\(open.map { "\($0)/" }.joined(separator: ", "))) answers anyone on the internet without signing in. Message text stays encrypted, but names, labels and timestamps are readable, and a stranger could write there.",
                                     fix: DatabaseCheckText.rulesFix)
        }
        if undetermined {
            return DatabaseCheckItem(kind: .publicAccess, status: .warn, problem: .unknownAccess, title: t, detail: "Couldn't tell whether the database is open to the public.", fix: nil)
        }
        return DatabaseCheckItem(kind: .publicAccess, status: .pass, problem: .none, title: t, detail: "Anonymous access is refused.")
    }

    private static func signInFailure(_ code: String) -> DatabaseCheckItem {
        func f(_ p: DatabaseCheckProblem, _ d: String, _ fix: String?) -> DatabaseCheckItem {
            DatabaseCheckItem(kind: .signIn, status: .fail, problem: p, title: DatabaseCheckText.title(.signIn), detail: d, fix: fix)
        }
        switch code {
        case "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED":
            return f(.emailPasswordDisabled, "Email/Password sign-in is turned off for this Firebase project.", DatabaseCheckText.authFix)
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
            return f(.badCredentials, "The email or password doesn't match a user in this Firebase project.", "Firebase console → Authentication → Users: check the user exists, or set the cloud up again.")
        case "API_KEY_INVALID", "INVALID_API_KEY", "API_KEY_NOT_VALID":
            return f(.badAPIKey, "The API key isn't valid for this Firebase project.", "Copy the Web API key from Firebase console → Project settings.")
        case "USER_DISABLED":
            return f(.accountDisabled, "That Firebase user has been disabled.", "Firebase console → Authentication → Users → enable the user.")
        case "TOO_MANY_ATTEMPTS_TRY_LATER":
            return f(.rateLimited, "Too many sign-in attempts.", "Wait a few minutes and run the check again.")
        default:
            return f(.unexpected, "Sign-in was refused.", nil)          // the code is deliberately not echoed
        }
    }
}

// MARK: - Live transport

/// The real network, over the package's `HTTPTransport`. One token, no refresh (a check is seconds long). The
/// password goes only to the sign-in endpoint (Google, or the loopback stand-in in a debug build) — never to the
/// user-supplied database URL.
public final class LiveDatabaseProbeTransport: DatabaseProbeTransport, @unchecked Sendable {
    private let config: FirebaseConfig
    private let email: String
    private let password: String
    private let http: HTTPTransport
    private let endpoints: AuthEndpoints
    private let base: URL?
    private let lock = NSLock()
    private var idToken: String?

    public init(config: FirebaseConfig, credential: CloudAuthCredential, http: HTTPTransport? = nil, allowLoopbackHTTP: Bool = false) {
        self.config = config
        self.email = credential.email
        self.password = credential.password
        if let http { self.http = http } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15      // idle gap between packets…
            c.timeoutIntervalForResource = 25     // …and a hard ceiling per request, so a trickling server cannot hold the check open
            c.waitsForConnectivity = false
            self.http = URLSessionTransport(session: URLSession(configuration: c))
        }
        self.endpoints = AuthEndpoints.forDatabase(config.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP)
        self.base = DatabaseURLPolicy.normalized(config.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP)
    }

    public func signIn() async throws -> DatabaseCheckSignIn {
        var c = URLComponents(url: endpoints.identityToolkit.appendingPathComponent("accounts:signInWithPassword"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password, "returnSecureToken": true])
        let (data, status) = try await send(req)
        let json = (try? JSONValue.parse(data))?.objectValue
        if status == 200 {
            if let token = json?["idToken"]?.stringValue, let uid = json?["localId"]?.stringValue {
                lock.withLock { idToken = token }
                return .ok(uid: uid)
            }
            return .rejected(code: "MALFORMED_RESPONSE")
        }
        return .rejected(code: Self.signInErrorCode(json))
    }

    /// Identity Toolkit reports most refusals as `error.message = "CODE"` or `"CODE : text"`, but a bad API key
    /// comes back as the prose "API key not valid. Please pass a valid API key." with the code only in
    /// `error.details[].reason` — so the first word of the message ("API") is not a code.
    public static func signInErrorCode(_ json: [String: JSONValue]?) -> String {
        let err = json?["error"]
        let message = err?["message"]?.stringValue ?? ""
        if message.lowercased().hasPrefix("api key not valid") { return "API_KEY_INVALID" }
        if case .array(let details)? = err?["details"],
           details.compactMap({ $0["reason"]?.stringValue }).contains("API_KEY_INVALID") { return "API_KEY_INVALID" }
        return message.split(separator: " ").first.map(String.init) ?? ""
    }

    public func request(method: String, path: String, body: String?) async throws -> DatabaseProbeResponse {
        let token = lock.withLock { idToken }
        guard let base, let token, let url = FirebaseRTDB.requestURL(base: base, path: path, token: token) else { throw DatabaseProbeNetworkError() }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body { req.httpBody = Data(body.utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, status) = try await send(req)
        return DatabaseProbeResponse(status: status, body: String(decoding: data, as: UTF8.self))
    }

    public func unauthenticatedStatus(path: String) async throws -> Int {
        let tail = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }.joined(separator: "/")
        guard let base, var c = URLComponents(string: base.absoluteString + "/" + (tail.isEmpty ? "" : tail) + ".json") else { throw DatabaseProbeNetworkError() }
        c.queryItems = [URLQueryItem(name: "shallow", value: "true")]
        guard let url = c.url else { throw DatabaseProbeNetworkError() }
        return try await send(URLRequest(url: url)).1
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do { let r = try await http.send(req); return (r.data, r.status) }
        catch { throw DatabaseProbeNetworkError() }   // never the underlying error: its text can contain the URL, and the URL contains the token
    }
}
