import Foundation

// MARK: - Device

struct ShareDevice: Identifiable, Codable, Equatable, Sendable {
    var id: String { fingerprint }
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: DeviceType?
    var fingerprint: String
    var port: Int
    var protocol_: TransportProtocol
    var download: Bool?
    var ipAddress: String
    var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, ipAddress, lastSeen
        case protocol_ = "protocol"
    }
}

enum DeviceType: String, Codable, Sendable {
    case mobile, desktop, web, headless, server
}

enum TransportProtocol: String, Codable, Sendable {
    case http, https
}

// MARK: - Transfer Session

struct ShareSession: Identifiable {
    enum Direction: String, Codable { case sending, receiving }
    enum State: Equatable {
        case waitingForConsent
        case active(filesCompleted: Int, filesTotal: Int)
        case paused
        case completed
        case failed(String)
        case cancelled

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.waitingForConsent, .waitingForConsent): return true
            case let (.active(a1, b1), .active(a2, b2)): return a1 == a2 && b1 == b2
            case (.paused, .paused): return true
            case (.completed, .completed): return true
            case let (.failed(a), .failed(b)): return a == b
            case (.cancelled, .cancelled): return true
            default: return false
            }
        }
    }

    var id: String
    var direction: Direction
    var peer: ShareDevice
    var files: [ShareFile]
    var state: State
    var startedAt: Date
    var completedAt: Date?
    var savedTo: URL?
}

// MARK: - File Entry

struct ShareFile: Identifiable, Codable, Sendable {
    var id: String
    var fileName: String
    var size: Int64
    var fileType: String
    var sha256: String?
    var preview: String?
    var metadata: FileMetadata?
    var sourceURL: URL?
    var destURL: URL?
    var token: String?
    var bytesTransferred: Int64 = 0
    var status: FileTransferStatus = .pending

    func with(token: String) -> ShareFile {
        var copy = self
        copy.token = token
        return copy
    }
}

enum FileTransferStatus: String, Codable, Sendable {
    case pending, transferring, completed, failed
}

struct FileMetadata: Codable, Sendable {
    var modified: String?
    var accessed: String?
}

// MARK: - Wire DTOs

struct DeviceInfoDTO: Codable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int
    var protocol_: String
    var download: Bool?
    var announce: Bool?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocol_ = "protocol"
    }
}

struct PrepareUploadRequest: Codable, Sendable {
    var info: DeviceInfoDTO
    var files: [String: FileDTOUpload]
}

struct FileDTOUpload: Codable, Sendable {
    var id: String
    var fileName: String
    var fileType: String
    var size: Int64
    var sha256: String?
    var preview: String?
    var metadata: FileMetadata?
}

struct PrepareUploadResponse: Codable, Sendable {
    var sessionId: String
    var files: [String: String]
}

struct MulticastAnnounce: Codable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int
    var protocol_: String
    var download: Bool?
    var announce: Bool

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocol_ = "protocol"
    }
}

// MARK: - Transfer History Record

struct TransferRecord: Identifiable, Codable {
    var id: String
    var peerAlias: String
    var peerFingerprint: String
    var direction: ShareSession.Direction
    var fileCount: Int
    var totalBytes: Int64
    var date: Date
    var status: TransferRecordStatus
    var fileNames: [String]
}

enum TransferRecordStatus: String, Codable {
    case completed, failed, cancelled
}

// MARK: - Persisted Session (for resume)

struct PersistedSession: Codable {
    var sessionId: String
    var peerDevice: ShareDevice
    var files: [ShareFile]
    var bytesTransferred: [String: Int64]
    var direction: String
    var createdAt: Date
    var destDirectory: URL?
}


// MARK: - DeviceInfoDTO leniency

extension DeviceInfoDTO {
    /// The official LocalSend protocol's `info` and `register` *responses* carry
    /// `alias`, `version`, `deviceModel`, `deviceType`, `fingerprint` and `download` — and
    /// **not** `port` or `protocol` (those travel in the multicast announcement and in the
    /// register *request*). The synthesized decoder required both, so decoding an official
    /// peer's `/info` threw, and the HTTP-scan fallback silently found no official peers.
    ///
    /// Defaults are what the caller already knew when it made the request: the standard
    /// port, and plain HTTP (the scheme the probe used). Declared in an extension so the
    /// memberwise initialiser is kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        version = try c.decode(String.self, forKey: .version)
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 53317
        protocol_ = try c.decodeIfPresent(String.self, forKey: .protocol_) ?? "http"
        download = try c.decodeIfPresent(Bool.self, forKey: .download)
        announce = try c.decodeIfPresent(Bool.self, forKey: .announce)
    }
}
