import Foundation

// MARK: - Constants

public enum HaloShare {
    /// TCP (HTTP) and UDP (multicast) port.
    public static let defaultPort: UInt16 = 53317
    /// The protocol version string Halo announces.
    public static let protocolVersion = "2.1"
    public static let multicastGroup = "224.0.0.167"
    public static let apiPrefix = "/api/localsend/v2"
}

// MARK: - TransportScheme

public enum TransportScheme: String, Codable, Sendable {
    case http, https

    /// Unknown values decode as `.http` — the scheme a probe used to reach the peer — rather
    /// than failing the whole message.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransportScheme(rawValue: raw.lowercased()) ?? .http
    }
}

// MARK: - DeviceInfo

/// A peer's identity. Used for the multicast announcement, the `register` request, and the
/// `info` field of `prepare-upload`.
///
/// **Decoding is lenient on purpose** (protocol doc §2): the `info` and `register`
/// *responses* of the official apps carry no `port` or `protocol`, so those default to the
/// standard port and plain HTTP instead of failing. Unknown fields are ignored.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    /// `mobile | desktop | web | headless | server`. A string, not an enum, so a new value
    /// from a newer peer cannot break decoding.
    public var deviceType: String?
    public var fingerprint: String
    public var port: Int
    public var `protocol`: TransportScheme
    public var download: Bool?
    public var announce: Bool?

    public init(alias: String, version: String = HaloShare.protocolVersion,
                deviceModel: String? = nil, deviceType: String? = nil,
                fingerprint: String, port: Int = Int(HaloShare.defaultPort),
                protocol: TransportScheme = .http, download: Bool? = false, announce: Bool? = nil) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocol = `protocol`
        self.download = download
        self.announce = announce
    }

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, `protocol`, download, announce
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? HaloShare.protocolVersion
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Int(HaloShare.defaultPort)
        `protocol` = try c.decodeIfPresent(TransportScheme.self, forKey: .protocol) ?? .http
        download = try c.decodeIfPresent(Bool.self, forKey: .download)
        announce = try c.decodeIfPresent(Bool.self, forKey: .announce)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encode(version, forKey: .version)
        // Explicit nulls for nullable fields, as the reference clients emit them.
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(port, forKey: .port)
        try c.encode(`protocol`, forKey: .protocol)
        try c.encodeIfPresent(download, forKey: .download)
        try c.encodeIfPresent(announce, forKey: .announce)
    }
}

// MARK: - Peer

/// A device found on the network: its identity plus where we reached it.
public struct Peer: Identifiable, Equatable, Sendable {
    public var info: DeviceInfo
    public var host: String
    public var lastSeen: Date

    public var id: String { info.fingerprint }
    public var alias: String { info.alias }
    public var port: Int { info.port }
    public var scheme: TransportScheme { info.protocol }

    public init(info: DeviceInfo, host: String, lastSeen: Date = Date()) {
        self.info = info
        self.host = host
        self.lastSeen = lastSeen
    }

    /// `http://host:port` with IPv6 literals bracketed.
    public var baseURL: URL {
        var c = URLComponents()
        c.scheme = scheme.rawValue
        c.host = host
        c.port = port
        return c.url!
    }
}

// MARK: - Files

public struct FileTimestamps: Codable, Equatable, Sendable {
    public var modified: String?
    public var accessed: String?
    public init(modified: String? = nil, accessed: String? = nil) {
        self.modified = modified
        self.accessed = accessed
    }
}

/// The protocol's `FileMetadata`: one entry of a `prepare-upload` request.
public struct FileDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var fileType: String
    public var sha256: String?
    public var preview: String?
    public var metadata: FileTimestamps?

    public init(id: String, fileName: String, size: Int64, fileType: String,
                sha256: String? = nil, preview: String? = nil, metadata: FileTimestamps? = nil) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey { case id, fileName, size, fileType, sha256, preview, metadata }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        size = try c.decode(Int64.self, forKey: .size)
        fileType = try c.decodeIfPresent(String.self, forKey: .fileType) ?? "application/octet-stream"
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        metadata = try c.decodeIfPresent(FileTimestamps.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(size, forKey: .size)
        try c.encode(fileType, forKey: .fileType)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(preview, forKey: .preview)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

public struct PrepareUploadRequest: Codable, Equatable, Sendable {
    public var info: DeviceInfo
    public var files: [String: FileDescriptor]
    public init(info: DeviceInfo, files: [String: FileDescriptor]) {
        self.info = info
        self.files = files
    }
}

public struct PrepareUploadResponse: Codable, Equatable, Sendable {
    public var sessionId: String
    /// file id → token
    public var files: [String: String]
    public init(sessionId: String, files: [String: String]) {
        self.sessionId = sessionId
        self.files = files
    }
}

// MARK: - Errors

public enum HaloShareError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case http(status: Int)
    case receiverBusy              // 409 / 429
    case checksumMismatch          // 422
    case unreachable(String)
    case trustFailure(String)
    case fileUnreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:          return "The other device sent a reply HaloShare couldn't understand."
        case .http(let s):              return "The other device answered with an error (HTTP \(s))."
        case .receiverBusy:             return "The other device is busy with another transfer. Try again in a moment."
        case .checksumMismatch:         return "The file arrived damaged (checksum mismatch)."
        case .unreachable(let why):     return "Couldn't reach the other device: \(why)"
        case .trustFailure(let why):    return "The other device's identity didn't check out: \(why)"
        case .fileUnreadable(let name): return "Couldn't read \(name)."
        case .cancelled:                return "Cancelled."
        }
    }
}
