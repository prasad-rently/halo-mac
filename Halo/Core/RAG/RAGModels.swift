import Foundation

// MARK: - RAG models  (F-047 Phase 3 — local retrieval over the user's own files)
//
// Value types for the on-device retrieval index. Nothing here touches the network:
// documents are parsed, chunked, embedded and searched entirely on this Mac. What the
// *assistant* then does with a retrieved excerpt is a separate, opt-in decision — see
// `RAGSettings`.

struct RAGDocument: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
    var name: String
    var fileExtension: String
    var byteCount: Int64
    var modified: Date
    var indexedAt: Date
    /// SHA-256 (hex) of the file's bytes — what decides "unchanged" on re-index. The
    /// modification date alone is not enough (copies and restores reset it).
    var contentHash: String
    var chunkCount: Int
}

struct RAGChunk: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let documentId: UUID
    let ordinal: Int
    let text: String
    /// Where in the source this came from, for citations: "p. 3", "lines 40–58".
    let locator: String?
}

struct RAGHit: Identifiable, Sendable {
    var id: UUID { chunk.id }
    let chunk: RAGChunk
    let document: RAGDocument
    /// Cosine similarity plus a small lexical boost; comparable only within one search.
    let score: Float

    /// "Report.pdf · p. 3" — the label a citation shows.
    var citation: String {
        if let locator = chunk.locator { return "\(document.name) · \(locator)" }
        return document.name
    }
}

enum RAGError: LocalizedError, Equatable {
    case unsupportedType(String)
    case tooLarge(bytes: Int64)
    case unreadable(String)
    case noText(String)
    case limitReached(String)
    case embeddingUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return ext.isEmpty ? "That file has no type Halo can read."
                               : "Halo can't read “.\(ext)” files yet."
        case .tooLarge(let bytes):
            return "That file is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: RAGLimits.maxFileBytes, countStyle: .file))."
        case .unreadable(let why): return "Couldn't read the file: \(why)"
        case .noText(let why):     return why
        case .limitReached(let m): return m
        case .embeddingUnavailable: return "No on-device text embedding is available on this Mac."
        }
    }
}

/// Bounds that keep one stray drop from exhausting memory or disk. A name list is kilobytes;
/// a novel is a couple of megabytes of text; 25 MB of *file* is already a PDF with images.
enum RAGLimits {
    static let maxFileBytes: Int64 = 25_000_000
    static let maxCharactersPerDocument = 2_000_000
    static let maxDocuments = 500
    static let maxChunks = 50_000
}

/// The one opt-in the feature needs. Indexing and searching are always local; this decides
/// whether the **cloud** assistant may call the search tool, which would put excerpts of the
/// user's files into the conversation and therefore send them to the AI provider.
enum RAGSettings {
    static let assistantMaySearchKey = "ragAssistantMaySearch"

    static var assistantMaySearch: Bool {
        get { UserDefaults.standard.bool(forKey: assistantMaySearchKey) }   // default: false
        set { UserDefaults.standard.set(newValue, forKey: assistantMaySearchKey) }
    }
}
