import Foundation

/// "A test record confirms it matches" (F-044 §7.1 step 4). A passphrase typed on the phone derives a key that is
/// either the Mac's key or garbage, and garbage is silent: AES-GCM only fails when it tries to open something.
/// So before trusting a freshly-typed passphrase, try to open a record the Mac/Android already wrote. There is
/// no dedicated canary node, so this probes real ciphertext. Mirrors KeyCheck.kt.
public enum KeyCheck {
    public enum Result: Equatable, Sendable {
        /// Opened a record written under this key — the passphrase is right.
        case match
        /// Found records, but none open — the passphrase (or the salt) is wrong.
        case mismatch
        /// The database holds nothing encrypted yet, so there is nothing to test against.
        case noSample
    }

    /// Throws on a network/permission failure — an unreachable database must not be reported as "no sample".
    public static func verify(db: RealtimeDatabase, crypto: CryptoService) async throws -> Result {
        let uid = try await db.uid()
        var samples: [String] = []

        func enc(_ node: JSONValue, _ field: String) -> String? { node[field]?.stringValue }

        for k in try await db.shallowKeys("clipboard/\(uid)/items").sorted().prefix(3) {
            if let s = enc(try await db.get("clipboard/\(uid)/items/\(k)"), "contentEnc") { samples.append(s) }
        }
        for device in try await db.shallowKeys("sms/\(uid)").filter({ !DatabaseCheckEngine.isProbeKey($0) }).sorted().prefix(3) {
            for line in try await db.shallowKeys("sms/\(uid)/\(device)/lines").sorted().prefix(2) {
                if let s = enc(try await db.get("sms/\(uid)/\(device)/lines/\(line)"), "ownNumberEnc") { samples.append(s) }
            }
            for m in try await db.shallowKeys("sms/\(uid)/\(device)/messages").sorted().prefix(2) {
                if let s = enc(try await db.get("sms/\(uid)/\(device)/messages/\(m)"), "bodyEnc") { samples.append(s) }
            }
        }
        if samples.isEmpty { return .noSample }
        return samples.contains { (try? crypto.decrypt($0)) != nil } ? .match : .mismatch
    }
}
