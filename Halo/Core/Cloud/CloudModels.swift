import Foundation
import CryptoKit

// MARK: - Cloud models  (F-044 cloud foundation)
//
// Value types for the BYOB Firebase config + pairing (docs/specs/00-foundations.md,
// F-044 §7.1). Runtime config — no bundled GoogleService-Info.plist; these are
// injected into the live app and stored in the Keychain.

/// The user's Firebase project config, provided at runtime (no rebuild).
/// Mirrors the fields `FirebaseOptions` needs for Realtime Database + Auth.
struct FirebaseConfig: Codable, Equatable, Sendable {
    var apiKey: String
    var projectID: String
    var googleAppID: String       // FirebaseOptions.googleAppID
    var gcmSenderID: String       // messagingSenderID
    var databaseURL: String       // the user's RTDB, e.g. https://<proj>-default-rtdb.firebaseio.com
    var storageBucket: String?    // optional (only if a feature needs blobs)

    var isComplete: Bool {
        !apiKey.isEmpty && !projectID.isEmpty && !googleAppID.isEmpty
            && !gcmSenderID.isEmpty && !databaseURL.isEmpty
    }
}

/// The app's Firebase Auth credential (Email/Password, F-044 D12). Auto-created
/// during assisted provisioning; the *connection* secret — carried in the pairing
/// QR. Distinct from the E2E passphrase (the *data* secret, never in the QR).
struct CloudAuthCredential: Codable, Equatable, Sendable {
    var email: String
    var password: String
}

/// The payload encoded into the desktop→mobile pairing QR (F-044 §7.1, D11).
/// Carries everything needed to CONNECT (config + auth + salt + KDF cost) but NOT the
/// E2E passphrase. A leaked QR exposes only ciphertext.
///
/// Schema history:
///   1 — original; no iteration count (implicitly `CryptoService.legacyIterations`).
///   2 — adds `iterations`, so the phone derives with the same cost the desktop used
///       and raising the default later never orphans an existing key.
struct CloudPairingPayload: Codable, Equatable, Sendable {
    static let currentSchema = 2

    var firebaseConfig: FirebaseConfig
    var auth: CloudAuthCredential
    var saltBase64: String        // non-secret KDF salt
    var schema: Int
    var iterations: Int           // PBKDF2 rounds; schema 1 payloads decode as 200 000
    var checksum: String          // integrity check over the fields

    /// Build a payload, computing the checksum.
    init(firebaseConfig: FirebaseConfig, auth: CloudAuthCredential, salt: Data,
         iterations: Int = CryptoService.defaultIterations) {
        self.firebaseConfig = firebaseConfig
        self.auth = auth
        self.saltBase64 = salt.base64EncodedString()
        self.schema = Self.currentSchema
        self.iterations = iterations
        self.checksum = CloudPairingPayload.checksum(
            config: firebaseConfig, auth: auth, saltBase64: saltBase64,
            schema: Self.currentSchema, iterations: iterations)
    }

    private enum CodingKeys: String, CodingKey {
        case firebaseConfig, auth, saltBase64, schema, iterations, checksum
    }

    /// Lenient on the fields that did not exist in schema 1, strict on the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firebaseConfig = try c.decode(FirebaseConfig.self, forKey: .firebaseConfig)
        auth = try c.decode(CloudAuthCredential.self, forKey: .auth)
        saltBase64 = try c.decode(String.self, forKey: .saltBase64)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? CryptoService.legacyIterations
        checksum = try c.decode(String.self, forKey: .checksum)
    }

    var isValid: Bool {
        checksum == CloudPairingPayload.checksum(
            config: firebaseConfig, auth: auth, saltBase64: saltBase64,
            schema: schema, iterations: iterations)
    }

    var salt: Data? { Data(base64Encoded: saltBase64) }

    /// SHA-256 over the `|`-joined fields. Schema 1 never covered `iterations`, so
    /// its formula is preserved byte-for-byte to keep validating old payloads; from
    /// schema 2 the count is covered, so it cannot be downgraded in transit.
    static func checksum(config: FirebaseConfig, auth: CloudAuthCredential,
                         saltBase64: String, schema: Int, iterations: Int) -> String {
        var fields = [
            config.apiKey, config.projectID, config.googleAppID, config.gcmSenderID,
            config.databaseURL, config.storageBucket ?? "",
            auth.email, auth.password, saltBase64, String(schema)
        ]
        if schema >= 2 { fields.append(String(iterations)) }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: JSON <-> QR string

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }

    static func decode(_ base64: String) throws -> CloudPairingPayload {
        guard let data = Data(base64Encoded: base64) else {
            throw CryptoError.badCiphertext
        }
        return try JSONDecoder().decode(CloudPairingPayload.self, from: data)
    }
}


// MARK: - CloudTelemetryScrubber

/// The cloud client authenticates with an ID token carried in the URL query
/// (`…/path.json?auth=<token>` — that is how the RTDB REST API takes it), and sign-in
/// bodies carry the account password. Sentry is opt-in, but *even when a user has opted
/// in* none of that may reach a report: its automatic network breadcrumbs record request
/// URLs, and an error string can be built from a response body.
///
/// Matched by **shape**, not from a registry, so it also catches a token Halo never
/// registered. Pure string work with no Sentry import; the hooks that call it live in
/// `HaloApp.configureSentry()` beside `LetheTelemetryScrubber`.
enum CloudTelemetryScrubber {

    static let redaction = "[cloud-redacted]"

    private static let rules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // ?auth=…  &key=…  &access_token=…  — keep the parameter name, drop the value.
            (#"([?&](?:auth|key|access_token|id_token|refresh_token|token)=)[^&\s"'<>]+"#, "$1\(redaction)"),
            // Compact JWTs (Firebase ID tokens) wherever they appear.
            (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#, redaction),
            // JSON credential fields: "password": "…", "idToken": "…", "refresh_token": "…"
            (#"("(?:password|idToken|refreshToken|id_token|refresh_token)"\s*:\s*")[^"]*(")"#, "$1\(redaction)$2"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    static func scrub(_ text: String) -> String {
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// Recurses through nested dictionaries/arrays, scrubbing every string.
    static func scrub(_ value: Any) -> Any {
        switch value {
        case let s as String:          return scrub(s)
        case let d as [String: Any]:   return d.mapValues { scrub($0) }
        case let a as [Any]:           return a.map { scrub($0) }
        default:                       return value
        }
    }
}
