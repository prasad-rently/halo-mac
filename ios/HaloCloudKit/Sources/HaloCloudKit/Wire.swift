import Foundation

// Wire models for what the phones/Mac write to the user's database. Decoding mirrors
// Halo/Features/SMSConsole/SMSSyncClient.swift (merge*) and ClipboardSyncModels.swift; the fixtures in
// docs/specs/wire-contract/phone-nodes.v1.json were captured from the REAL Kotlin writers and are this
// package's conformance tests.

public struct SMSDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let lastSeen: Date?
}

public struct SMSLine: Identifiable, Hashable, Sendable {
    public let id: String             // "<deviceId>-<subscriptionId>"
    public let deviceId: String
    public let subscriptionId: Int
    public let label: String
    public let carrier: String
    public let ownNumber: String
    public let syncEnabled: Bool
}

public struct SMSMessage: Identifiable, Hashable, Sendable {
    public let id: String             // "<deviceId>/<msgKey>" — raw keys can repeat across devices
    public let deviceId: String
    public let lineId: String
    public let subscriptionId: Int
    public let address: String
    public let body: String
    public let date: Date
    public let read: Bool
    public let threadKey: String?
}

public enum SMSWire {
    public static func decodeDevice(id: String, node: JSONValue?) -> SMSDevice {
        let d = node?.objectValue ?? [:]
        let seen = d["lastSeen"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        return SMSDevice(id: id, name: d["name"]?.stringValue ?? id, platform: d["platform"]?.stringValue ?? "android", lastSeen: seen)
    }

    public static func decodeLine(deviceId: String, key: String, node: JSONValue?, crypto: CryptoService) -> SMSLine {
        let l = node?.objectValue ?? [:]
        let sub = Int(key) ?? l["subscriptionId"]?.intValue ?? -1
        let own = l["ownNumberEnc"]?.stringValue.flatMap { try? crypto.decrypt($0) } ?? l["ownNumber"]?.stringValue ?? "Unknown"
        return SMSLine(id: "\(deviceId)-\(sub)", deviceId: deviceId, subscriptionId: sub,
                       label: l["label"]?.stringValue ?? "SIM \(sub)", carrier: l["carrier"]?.stringValue ?? "—",
                       ownNumber: own, syncEnabled: l["syncEnabled"]?.boolValue ?? true)
    }

    public enum MessageDecode: Equatable, Sendable {
        case message(SMSMessage)
        /// Structurally fine but the ciphertext didn't open under our key (wrong passphrase / other key / tampered).
        case undecryptable
        case malformed
    }

    public static func decodeMessage(deviceId: String, key: String, node: JSONValue?, crypto: CryptoService) -> MessageDecode {
        guard let m = node?.objectValue, let aEnc = m["addressEnc"]?.stringValue, let bEnc = m["bodyEnc"]?.stringValue else { return .malformed }
        guard let address = try? crypto.decrypt(aEnc), let body = try? crypto.decrypt(bEnc) else { return .undecryptable }
        let sub = m["subscriptionId"]?.intValue ?? 0
        let ms = m["date"]?.doubleValue ?? 0
        return .message(SMSMessage(id: "\(deviceId)/\(key)", deviceId: deviceId, lineId: "\(deviceId)-\(sub)", subscriptionId: sub,
                                   address: address, body: body, date: Date(timeIntervalSince1970: ms / 1000),
                                   read: m["read"]?.boolValue ?? true, threadKey: m["threadKey"]?.stringValue))
    }

    /// Reduce a contact to a stable grouping key: keep a leading `+` and all digits, drop separators; text-only
    /// sender ids ("VM-HDFCBK") are kept verbatim. Same rule as the desktop console.
    public static func normalizeContact(_ raw: String) -> String {
        var out = ""
        for (i, ch) in raw.enumerated() {
            if ch.isNumber { out.append(ch) } else if ch == "+" && i == 0 { out.append(ch) }
        }
        return out.isEmpty ? raw : out
    }

    /// The Android writer's `threadKey` — HMAC under a sub-key of the data key (SmsWire.threadKey in Kotlin).
    public static func threadKey(crypto: CryptoService, deviceId: String, subscriptionId: Int, address: String) -> String {
        crypto.keyedHash(context: "halo.threadkey.v1", data: "\(deviceId)|\(subscriptionId)|\(normalizeNumber(address))")
    }

    /// SmsWire.normalizeNumber in Kotlin: alphanumeric senders lowercased, numbers reduced to digits (+ kept).
    public static func normalizeNumber(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains(where: { $0.isLetter }) { return t.lowercased() }
        let digits = t.filter { $0.isASCII && $0.isNumber }
        return t.hasPrefix("+") ? "+" + digits : digits
    }
}

public struct SMSThread: Identifiable, Hashable, Sendable {
    public let id: String
    public let lineId: String
    public let contact: String
    public let messages: [SMSMessage]   // oldest first
    public var last: SMSMessage { messages[messages.count - 1] }
    public var unreadCount: Int { messages.filter { !$0.read }.count }

    /// Threads per (device, line, normalised contact) — newest first.
    public static func group(_ messages: [SMSMessage]) -> [SMSThread] {
        var grouped: [String: [SMSMessage]] = [:]
        for m in messages { grouped["\(m.lineId)|\(SMSWire.normalizeContact(m.address))", default: []].append(m) }
        return grouped.map { key, msgs in
            let sorted = msgs.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            return SMSThread(id: key, lineId: sorted[0].lineId, contact: sorted[sorted.count - 1].address, messages: sorted)
        }.sorted { ($0.last.date, $0.id) > ($1.last.date, $1.id) }
    }
}

// MARK: - Clipboard

public struct ClipboardEnvelope: Equatable, Sendable {
    public let itemId: String
    public let deviceId: String
    public let deviceName: String
    public let kind: String            // "text" | "url" | "code"
    public let contentEnc: String
    public let language: String?
    public let createdAtMs: Double

    public init(itemId: String, deviceId: String, deviceName: String, kind: String, contentEnc: String, language: String? = nil, createdAtMs: Double) {
        self.itemId = itemId; self.deviceId = deviceId; self.deviceName = deviceName; self.kind = kind
        self.contentEnc = contentEnc; self.language = language; self.createdAtMs = createdAtMs
    }

    public func node() -> JSONValue {
        var d: [String: JSONValue] = ["itemId": .string(itemId), "deviceId": .string(deviceId), "deviceName": .string(deviceName),
                                      "kind": .string(kind), "contentEnc": .string(contentEnc), "createdAt": .number(createdAtMs), "schema": .number(1)]
        if let language { d["language"] = .string(language) }
        return .object(d)
    }

    /// nil when structurally invalid — exactly as the desktop's parser.
    public static func from(_ value: JSONValue?) -> ClipboardEnvelope? {
        guard let d = value?.objectValue, let itemId = d["itemId"]?.stringValue, let deviceId = d["deviceId"]?.stringValue,
              let kind = d["kind"]?.stringValue, let enc = d["contentEnc"]?.stringValue else { return nil }
        return ClipboardEnvelope(itemId: itemId, deviceId: deviceId, deviceName: d["deviceName"]?.stringValue ?? "Unknown device",
                                 kind: kind, contentEnc: enc, language: d["language"]?.stringValue, createdAtMs: d["createdAt"]?.doubleValue ?? 0)
    }
}

/// A remote copy, decrypted — history only, never the live pasteboard (D9).
public struct RemoteClip: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let kind: String
    public let language: String?
    public let deviceId: String
    public let deviceName: String
    public let createdAt: Date
}

/// Mirror of the desktop's `ClipboardSensitiveFilter` (and Kotlin's), rule for rule. On iOS it only drives a
/// warning before an explicit Send — the user's tap is the decision.
public enum ClipboardSensitiveFilter {
    private static let keywords = ["password", "passwd", "secret", "api_key", "apikey", "access_token", "bearer ", "private key", "-----begin"]
    private static let shapes: [NSRegularExpression] = [
        #"^AKIA[0-9A-Z]{16}$"#, #"^gh[pousr]_[A-Za-z0-9]{20,}$"#, #"^xox[baprs]-[A-Za-z0-9-]{10,}$"#,
        #"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, #"^sk-[A-Za-z0-9]{20,}$"#, #"^[A-Fa-f0-9]{64,}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func isSensitive(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if keywords.contains(where: { lower.contains($0) }) { return true }
        if !t.contains(where: { $0 == " " || $0 == "\n" }) {
            let range = NSRange(t.startIndex..., in: t)
            return shapes.contains { $0.firstMatch(in: t, range: range) != nil }
        }
        return false
    }
}
