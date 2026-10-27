import Foundation
import Accelerate

// MARK: - RAGVectorStore  (F-047 D4 — local vector index)
//
// A brute-force cosine index. At Halo's ceiling (`RAGLimits.maxChunks` = 50 000 chunks x 512
// floats) a query is one pass over ~100 MB of floats — single-digit milliseconds with vDSP — so
// an approximate-nearest-neighbour structure would add complexity and recall loss for no
// measurable gain. No SQLite: this codebase has no database dependency (see AlertLog,
// MemoryTrendTracker for the same precedent).
//
// On disk, in `directory`:
//   index.json    embedder id, dimension, documents, chunks (text + provenance)
//   vectors.bin   chunks.count x dimension Float32, little-endian, in chunk order
// Both are written atomically. A mismatched embedder or a truncated vectors file is *not*
// trusted: the index loads empty and reports `needsReindex`, because vectors from different
// spaces compare as confident nonsense.

actor RAGVectorStore {

    struct Snapshot: Codable {
        var version = 1
        var embedderId: String
        var dimension: Int
        var documents: [RAGDocument]
        var chunks: [RAGChunk]
    }

    let directory: URL
    let embedderId: String
    let dimension: Int

    private(set) var documents: [UUID: RAGDocument] = [:]
    private var chunks: [RAGChunk] = []
    private var vectors: [Float] = []          // chunks.count * dimension, row-major
    /// True when a persisted index existed but was discarded (different embedder, damaged).
    private(set) var needsReindex = false

    init(directory: URL, embedderId: String, dimension: Int) {
        self.directory = directory
        self.embedderId = embedderId
        self.dimension = dimension
    }

    var chunkCount: Int { chunks.count }
    var allDocuments: [RAGDocument] { documents.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var vectorsURL: URL { directory.appendingPathComponent("vectors.bin") }

    // MARK: Persistence

    func load() {
        documents = [:]; chunks = []; vectors = []; needsReindex = false
        guard let data = try? Data(contentsOf: indexURL) else { return }          // first run: nothing to load
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.embedderId == embedderId, snap.dimension == dimension,
              let raw = try? Data(contentsOf: vectorsURL),
              raw.count == snap.chunks.count * dimension * MemoryLayout<Float>.size
        else { needsReindex = true; return }

        var floats = [Float](repeating: 0, count: raw.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        guard floats.allSatisfy({ $0.isFinite }) else { needsReindex = true; return }

        documents = Dictionary(uniqueKeysWithValues: snap.documents.map { ($0.id, $0) })
        chunks = snap.chunks
        vectors = floats
    }

    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snap = Snapshot(embedderId: embedderId, dimension: dimension,
                            documents: Array(documents.values), chunks: chunks)
        let json = try JSONEncoder().encode(snap)
        let bin = vectors.withUnsafeBytes { Data($0) }
        // Vectors first: if we die between the two writes the old index.json no longer matches
        // the new vectors.bin's size, which `load()` detects and treats as "re-index".
        try bin.write(to: vectorsURL, options: .atomic)
        try json.write(to: indexURL, options: .atomic)
    }

    // MARK: Mutation

    func add(_ document: RAGDocument, chunks newChunks: [RAGChunk], vectors newVectors: [[Float]]) {
        precondition(newChunks.count == newVectors.count, "one vector per chunk")
        precondition(newVectors.allSatisfy { $0.count == dimension }, "vector dimension mismatch")
        documents[document.id] = document
        chunks.append(contentsOf: newChunks)
        for v in newVectors { vectors.append(contentsOf: v) }
    }

    func remove(documentId: UUID) {
        guard documents.removeValue(forKey: documentId) != nil else { return }
        var keptChunks: [RAGChunk] = []
        var keptVectors: [Float] = []
        keptChunks.reserveCapacity(chunks.count)
        keptVectors.reserveCapacity(vectors.count)
        for (i, chunk) in chunks.enumerated() where chunk.documentId != documentId {
            keptChunks.append(chunk)
            keptVectors.append(contentsOf: vectors[(i * dimension)..<((i + 1) * dimension)])
        }
        chunks = keptChunks
        vectors = keptVectors
    }

    func clear() {
        documents = [:]; chunks = []; vectors = []
        try? FileManager.default.removeItem(at: indexURL)       // the index's own data; not user content
        try? FileManager.default.removeItem(at: vectorsURL)
        needsReindex = false
    }

    func document(forPath path: String) -> RAGDocument? {
        documents.values.first { $0.path == path }
    }

    // MARK: Search

    /// Cosine similarity (vectors are unit-length, so a dot product) plus a small lexical
    /// boost for exact term matches. The boost earns its place with the semantic embedder:
    /// sentence embeddings blur a rare identifier ("INV-20431", a surname) that a literal
    /// match nails. It is capped at `lexicalWeight`, so it re-orders near-ties and cannot
    /// promote an unrelated chunk over a genuinely similar one.
    static let lexicalWeight: Float = 0.15

    func search(_ query: [Float], terms: [String], k: Int, minimumScore: Float = 0.05) -> [RAGHit] {
        guard query.count == dimension, !chunks.isEmpty, k > 0 else { return [] }
        var scores = [Float](repeating: 0, count: chunks.count)
        vectors.withUnsafeBufferPointer { base in
            query.withUnsafeBufferPointer { q in
                for i in 0..<chunks.count {
                    vDSP_dotpr(base.baseAddress! + i * dimension, 1, q.baseAddress!, 1, &scores[i], vDSP_Length(dimension))
                }
            }
        }
        if !terms.isEmpty {
            let uniqueTerms = Array(Set(terms))
            for i in 0..<chunks.count {
                let lower = chunks[i].text.lowercased()
                let present = uniqueTerms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                scores[i] += Self.lexicalWeight * Float(present) / Float(uniqueTerms.count)
            }
        }
        return scores.indices
            .filter { scores[$0] >= minimumScore }
            .sorted { scores[$0] > scores[$1] }
            .prefix(k)
            .compactMap { i in
                documents[chunks[i].documentId].map { RAGHit(chunk: chunks[i], document: $0, score: scores[i]) }
            }
    }
}
