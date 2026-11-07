import Foundation
import CryptoKit

// The desktop -> phone pairing payload (mirrors CloudPairingPayload in Halo/Core/Cloud/CloudModels.swift and
// PairingPayload.kt). Carries everything needed to CONNECT (config + auth + salt + KDF cost) but NOT the E2E
// passphrase: a leaked pairing code exposes only ciphertext (and lets the holder sign in to the database).

public struct FirebaseConfig: Codable, Equatable, Sendable {
    public var apiKey: String
    public var projectID: String
    public var googleAppID: String
    public var gcmSenderID: String
    public var databaseURL: String
    public var storageBucket: String?
    public init(apiKey: String, projectID: String, googleAppID: String, gcmSenderID: String, databaseURL: String, storageBucket: String? = nil) {
        self.apiKey = apiKey; self.projectID = projectID; self.googleAppID = googleAppID
        self.gcmSenderID = gcmSenderID; self.databaseURL = databaseURL; self.storageBucket = storageBucket
    }
}

public struct CloudAuthCredential: Codable, Equatable, Sendable {
    public var email: String
    public var password: String
    public init(email: String, password: String) { self.email = email; self.password = password }
}

public struct PairingPayload: Codable, Equatable, Sendable {
    public static let currentSchema = 2
    public var firebaseConfig: FirebaseConfig
    public var auth: CloudAuthCredential
    public var saltBase64: String
    public var schema: Int
    public var iterations: Int
    public var checksum: String

    public init(firebaseConfig: FirebaseConfig, auth: CloudAuthCredential, salt: Data, iterations: Int = CryptoService.defaultIterations) {
        self.firebaseConfig = firebaseConfig
        self.auth = auth
        self.saltBase64 = salt.base64EncodedString()
        self.schema = Self.currentSchema
        self.iterations = iterations
        self.checksum = Self.checksum(config: firebaseConfig, auth: auth, saltBase64: saltBase64, schema: Self.currentSchema, iterations: iterations)
    }

    private enum CodingKeys: String, CodingKey { case firebaseConfig, auth, saltBase64, schema, iterations, checksum }

    /// Lenient on the fields that did not exist in schema 1, strict on the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firebaseConfig = try c.decode(FirebaseConfig.self, forKey: .firebaseConfig)
        auth = try c.decode(CloudAuthCredential.self, forKey: .auth)
        saltBase64 = try c.decode(String.self, forKey: .saltBase64)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? CryptoService.legacyIterations
        checksum = try c.decode(String.self, forKey: .checksum)
    }

    public var salt: Data? { Data(base64Encoded: saltBase64) }

    /// Constant-time compare of the stored checksum with the recomputed one.
    public var isValid: Bool {
        let expected = Self.checksum(config: firebaseConfig, auth: auth, saltBase64: saltBase64, schema: schema, iterations: iterations)
        let a = Array(checksum.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// SHA-256 over the `|`-joined fields; schema 1 never covered `iterations` (frozen), schema ≥ 2 does.
    public static func checksum(config: FirebaseConfig, auth: CloudAuthCredential, saltBase64: String, schema: Int, iterations: Int) -> String {
        var f = [config.apiKey, config.projectID, config.googleAppID, config.gcmSenderID, config.databaseURL,
                 config.storageBucket ?? "", auth.email, auth.password, saltBase64, String(schema)]
        if schema >= 2 { f.append(String(iterations)) }
        return SHA256.hash(data: Data(f.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
}

/// Where a database URL may point. Production: https only. The stand-in used in tests/debug is
/// plain-http loopback — allowed only when the caller explicitly opts in (a DEBUG build), and only for
/// 127.0.0.1 / localhost / ::1, never for a LAN or public host.
public enum DatabaseURLPolicy {
    public static func normalized(_ raw: String, allowLoopbackHTTP: Bool = false) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), let host = c.host, !host.isEmpty else { return nil }
        switch c.scheme?.lowercased() {
        case "https": break
        case "http" where allowLoopbackHTTP && isLoopback(host): break
        default: return nil
        }
        c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url
    }
    /// True for the hosts Google serves Realtime Databases from (`<name>.firebaseio.com`, `<name>.<region>.firebasedatabase.app`).
    /// Not a security gate (a desktop/Android-issued code may legitimately name another host) — the UI uses it to warn
    /// when a pairing code points the phone at a database that is NOT a Firebase one, before a passphrase is typed.
    public static func isFirebaseHosted(_ rawURL: String) -> Bool {
        guard let host = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host.hasSuffix(".firebaseio.com") || host.hasSuffix(".firebasedatabase.app")
    }
    public static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
}

/// Parse + validate what the user pastes or scans.
public enum PairingCode {
    /// A real pairing code is ~600–900 characters; refuse anything absurd before decoding it.
    public static let maxLength = 8_192

    public static func parse(_ raw: String, allowLoopbackHTTP: Bool = false) throws -> PairingPayload {
        // A code is base64; pasted text is often hard-wrapped or has stray whitespace/newlines. Also tolerate
        // a surrounding pair of quotes (some apps add them when copying).
        var text = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !text.isEmpty, text.count <= maxLength, let data = Data(base64Encoded: text) else { throw CloudError.malformedPairingCode }
        let payload: PairingPayload
        do { payload = try JSONDecoder().decode(PairingPayload.self, from: data) } catch { throw CloudError.malformedPairingCode }

        guard payload.schema >= 1 else { throw CloudError.malformedPairingCode }
        guard payload.schema <= PairingPayload.currentSchema else { throw CloudError.unsupportedPairingSchema(payload.schema) }
        guard payload.isValid else { throw CloudError.pairingChecksumMismatch }
        let c = payload.firebaseConfig
        guard !c.apiKey.isEmpty, !payload.auth.email.isEmpty, !payload.auth.password.isEmpty else { throw CloudError.malformedPairingCode }
        guard DatabaseURLPolicy.normalized(c.databaseURL, allowLoopbackHTTP: allowLoopbackHTTP) != nil else { throw CloudError.configureFailed }
        guard let salt = payload.salt, salt.count >= CryptoService.minimumSaltBytes else {
            throw CloudError.invalidParameters("the salt is too short")
        }
        guard (CryptoService.minimumIterations...CryptoService.maximumIterations).contains(payload.iterations) else {
            throw CloudError.invalidParameters("\(payload.iterations) iterations is outside the accepted range")
        }
        return payload
    }
}

/// The "type it twice" decision for first pairing (D-01 / H-12). `KeyCheck` can only vouch for a passphrase
/// when the database already holds something encrypted; on an empty database a typo is accepted, the phone
/// uploads under the wrong key, and the Mac silently drops every undecryptable row.
public enum PairingConfirmation {
    public static let notice = "This database has no encrypted data yet, so the passphrase could not be verified. Use exactly the passphrase you set on your Mac."
    public static func required(for result: KeyCheck.Result) -> Bool { result == .noSample }
    /// Same passphrase *as the key derivation sees it*: NFC, otherwise exact (case/whitespace matter).
    public static func matches(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }
}
