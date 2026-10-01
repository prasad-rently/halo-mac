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
/// Carries everything needed to CONNECT (config + auth + salt) but NOT the E2E
/// passphrase. A leaked QR exposes only ciphertext.
struct CloudPairingPayload: Codable, Equatable, Sendable {
    var firebaseConfig: FirebaseConfig
    var auth: CloudAuthCredential
    var saltBase64: String        // non-secret KDF salt
    var schema: Int = 1
    var checksum: String          // integrity check over the fields

    /// Build a payload, computing the checksum.
    init(firebaseConfig: FirebaseConfig, auth: CloudAuthCredential, salt: Data) {
        self.firebaseConfig = firebaseConfig
        self.auth = auth
        self.saltBase64 = salt.base64EncodedString()
        self.schema = 1
        self.checksum = CloudPairingPayload.checksum(
            config: firebaseConfig, auth: auth, saltBase64: saltBase64, schema: 1)
    }

    var isValid: Bool {
        checksum == CloudPairingPayload.checksum(
            config: firebaseConfig, auth: auth, saltBase64: saltBase64, schema: schema)
    }

    var salt: Data? { Data(base64Encoded: saltBase64) }

    static func checksum(config: FirebaseConfig, auth: CloudAuthCredential,
                         saltBase64: String, schema: Int) -> String {
        let material = [
            config.apiKey, config.projectID, config.googleAppID, config.gcmSenderID,
            config.databaseURL, config.storageBucket ?? "",
            auth.email, auth.password, saltBase64, String(schema)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
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
