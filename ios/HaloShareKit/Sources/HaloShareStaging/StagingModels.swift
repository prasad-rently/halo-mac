import Foundation

// MARK: - Limits

/// What the Share Extension is willing to stage. The extension runs under a tight memory
/// ceiling and copies user data onto disk, so every dimension is capped.
public struct StagingLimits: Equatable, Sendable {
    public var maxItems: Int
    public var maxItemBytes: Int64
    public var maxBatchBytes: Int64
    public var maxTextBytes: Int
    /// A staged batch nobody sent within this long is deleted (it is only a *copy*; the
    /// original is still where the user shared it from).
    public var batchLifetime: TimeInterval
    public var maxNameLength: Int

    public init(maxItems: Int = 25, maxItemBytes: Int64 = 2 << 30, maxBatchBytes: Int64 = 4 << 30,
                maxTextBytes: Int = 1 << 20, batchLifetime: TimeInterval = 24 * 3600, maxNameLength: Int = 120) {
        self.maxItems = maxItems
        self.maxItemBytes = maxItemBytes
        self.maxBatchBytes = maxBatchBytes
        self.maxTextBytes = maxTextBytes
        self.batchLifetime = batchLifetime
        self.maxNameLength = maxNameLength
    }

    public static let `default` = StagingLimits()
}

// MARK: - Manifest

public enum StagedItemKind: String, Codable, Sendable { case file, text, link }

public struct StagedItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var mimeType: String
    public var kind: StagedItemKind

    public init(id: String, fileName: String, size: Int64, mimeType: String, kind: StagedItemKind) {
        self.id = id; self.fileName = fileName; self.size = size; self.mimeType = mimeType; self.kind = kind
    }
}

public struct StagedBatch: Codable, Identifiable, Equatable, Sendable {
    public var version: Int
    /// Always the batch *directory name*, never trusted from the manifest body.
    public var id: String
    public var createdAt: Date
    public var items: [StagedItem]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(id: String, createdAt: Date, items: [StagedItem], version: Int = 1) {
        self.version = version; self.id = id; self.createdAt = createdAt; self.items = items
    }
}

// MARK: - Rejections

/// Why one shared item was not staged. Shown to the user by the extension.
public enum StagingRejection: Error, Equatable, LocalizedError, Sendable {
    case tooManyItems(max: Int)
    case itemTooLarge(name: String, maxBytes: Int64)
    case batchTooLarge(maxBytes: Int64)
    case unsupportedType(String)
    case folder(name: String)
    case unreadable(String)
    case emptyText
    case textTooLong(maxBytes: Int)
    case badLink(String)
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .tooManyItems(let max): return "HaloShare takes up to \(max) items at a time."
        case .itemTooLarge(let name, let max): return "\(name) is larger than \(Self.size(max)) — too big to hand over from the share sheet."
        case .batchTooLarge(let max): return "That's more than \(Self.size(max)) in one go."
        case .unsupportedType(let what): return "HaloShare can't send \(what)."
        case .folder(let name): return "\(name) is a folder. Share its files instead."
        case .unreadable(let name): return "Couldn't read \(name)."
        case .emptyText: return "There was no text to send."
        case .textTooLong(let max): return "That text is longer than \(Self.size(Int64(max)))."
        case .badLink(let why): return "That link can't be sent: \(why)."
        case .storageUnavailable: return "HaloShare's shared storage isn't available. Open Halo once, then try again."
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
