import Foundation

// MARK: - Clipboard sync models  (F-045)
//
// The RTDB envelope for a synced clipboard item + the opt-in sensitive-content
// filter. Only text/url/code sync in v1 (D6); image/color are skipped. Content is
// AES-GCM ciphertext (D2); everything else is plaintext structure (D1 §7).

/// One synced clipboard item as stored at `clipboard/{uid}/items/{itemId}`.
struct ClipboardSyncEnvelope: Equatable, Sendable {
    let itemId: String
    let deviceId: String
    let deviceName: String
    let kind: String            // "text" | "url" | "code"
    let contentEnc: String      // AES-GCM ciphertext of the item's string content
    let language: String?       // for code (non-secret, plaintext)
    let createdAt: Double       // ms since epoch

    /// The RTDB dictionary to `setValue`. `contentEnc` is already encrypted.
    func node() -> [String: Any] {
        var d: [String: Any] = [
            "itemId": itemId,
            "deviceId": deviceId,
            "deviceName": deviceName,
            "kind": kind,
            "contentEnc": contentEnc,
            "createdAt": createdAt,
            "schema": 1
        ]
        if let language { d["language"] = language }
        return d
    }

    /// Parse a raw RTDB child value; `nil` if structurally invalid.
    static func from(_ value: Any?) -> ClipboardSyncEnvelope? {
        guard let d = value as? [String: Any],
              let itemId = d["itemId"] as? String,
              let deviceId = d["deviceId"] as? String,
              let kind = d["kind"] as? String,
              let contentEnc = d["contentEnc"] as? String else { return nil }
        let createdAt = (d["createdAt"] as? NSNumber)?.doubleValue ?? 0
        return ClipboardSyncEnvelope(
            itemId: itemId, deviceId: deviceId,
            deviceName: d["deviceName"] as? String ?? "Unknown device",
            kind: kind, contentEnc: contentEnc,
            language: d["language"] as? String, createdAt: createdAt)
    }
}

// MARK: - Sensitive-content filter (D5 — available but OFF by default)

/// Heuristics that flag likely secrets so the user *can* opt into excluding them
/// from sync. Nothing is filtered unless the user enables it (D5); privacy
/// otherwise rests on E2E encryption + purge (D10).
enum ClipboardSensitiveFilter {

    /// True if `text` looks like a credential/secret worth excluding.
    static func isSensitive(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Explicit "secret-ish" keywords near a value.
        let lower = t.lowercased()
        let keywords = ["password", "passwd", "secret", "api_key", "apikey",
                        "access_token", "bearer ", "private key", "-----begin"]
        if keywords.contains(where: { lower.contains($0) }) { return true }

        // Common token shapes (single-line, no spaces).
        if !t.contains(where: { $0 == " " || $0 == "\n" }) {
            // AWS access key id / secret patterns, GitHub tokens, JWTs, long hex/base64.
            let patterns = [
                #"^AKIA[0-9A-Z]{16}$"#,                    // AWS access key id
                #"^gh[pousr]_[A-Za-z0-9]{20,}$"#,          // GitHub token
                #"^xox[baprs]-[A-Za-z0-9-]{10,}$"#,        // Slack token
                #"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,  // JWT
                #"^sk-[A-Za-z0-9]{20,}$"#,                 // OpenAI-style key
                #"^[A-Fa-f0-9]{32,}$"#                      // long hex (hashes/keys)
            ]
            if patterns.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) {
                return true
            }
        }
        return false
    }
}
