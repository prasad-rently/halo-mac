import Foundation
import NaturalLanguage
import Accelerate

// MARK: - Text embedders  (F-047 D4 — local embeddings, no model download)
//
// Two interchangeable embedders behind one protocol. Both return **L2-normalised** vectors, so
// cosine similarity is a plain dot product.
//
//  - `SentenceEmbedder` — Apple's on-device `NLEmbedding` sentence model. Real semantic
//    similarity ("car" ~ "automobile") with no download and nothing leaving the Mac. English
//    only, and it needs the system asset to be present.
//  - `HashingEmbedder`  — feature-hashed bag of words + bigrams. Lexical, not semantic, but
//    deterministic, dependency-free and always available, which is exactly what the retrieval
//    tests need and what the index falls back to.
//
// The index records which embedder built it; switching embedders means re-indexing, never
// comparing vectors across spaces.

protocol TextEmbedder: Sendable {
    /// Stable id persisted with the index. Change it whenever the vector space changes.
    var identifier: String { get }
    var dimension: Int { get }
    /// `nil` when the text has nothing embeddable (punctuation only, an unsupported language).
    func embed(_ text: String) -> [Float]?
}

extension TextEmbedder {
    static func normalised(_ v: [Float]) -> [Float]? {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        guard sumSquares > 0, sumSquares.isFinite else { return nil }
        var scale = 1 / sumSquares.squareRoot()
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }
}

// MARK: Hashing

struct HashingEmbedder: TextEmbedder {
    let dimension: Int
    var identifier: String { "hash-v1-\(dimension)" }

    init(dimension: Int = 512) { self.dimension = dimension }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "and", "or", "is", "are", "was", "were", "for", "on", "at",
        "by", "with", "this", "that", "it", "as", "be", "from", "has", "have", "had", "not", "but"
    ]

    func embed(_ text: String) -> [Float]? {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return nil }

        var counts: [Int: Float] = [:]          // dimension index -> signed weight
        func add(_ feature: String, weight: Float) {
            let h = Self.fnv1a(feature)
            let index = Int(h % UInt64(dimension))
            let sign: Float = (h >> 63) & 1 == 0 ? 1 : -1      // sign trick: collisions cancel instead of stacking
            counts[index, default: 0] += sign * weight
        }
        var termFrequency: [String: Int] = [:]
        for t in tokens { termFrequency[t, default: 0] += 1 }
        for (term, n) in termFrequency { add(term, weight: 1 + Float(log(Double(n)))) }   // sublinear TF
        for pair in zip(tokens, tokens.dropFirst()) { add(pair.0 + " " + pair.1, weight: 0.5) }

        var v = [Float](repeating: 0, count: dimension)
        for (i, w) in counts { v[i] = w }
        return Self.normalised(v)
    }

    /// Lower-cased alphanumeric words, stop words dropped, light suffix stripping so that
    /// "invoices"/"invoice" and "billing"/"billed" land together.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let w = stem(word)
            if w.count >= 2 || w.allSatisfy(\.isNumber), !stopWords.contains(w) { out.append(w) }
            word = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { word.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// A deliberately small suffix stripper — not a linguistic stemmer. The goal is only that the
    /// common inflections of one word land on one token: invoice / invoices / invoiced -> "invoic",
    /// bill / billing / billed / bills -> "bill". Order matters: plurals, then -ing/-ed, then a
    /// trailing "e" (so "invoice" and the stripped "invoic" meet). Words that are not all letters
    /// (codes, numbers, "inv-20431" halves) are left exactly as written.
    static func stem(_ w: String) -> String {
        guard w.count > 3, w.allSatisfy(\.isLetter) else { return w }
        var s = w

        // 1. plurals
        if s.hasSuffix("ies"), s.count > 4 { s = String(s.dropLast(3)) + "y" }
        else if ["sses", "xes", "ches", "shes", "zes"].contains(where: { s.hasSuffix($0) }) { s = String(s.dropLast(2)) }
        else if s.hasSuffix("s"), !s.hasSuffix("ss"), !s.hasSuffix("us"), !s.hasSuffix("is") { s = String(s.dropLast()) }

        // 2. -ing / -ed, only when a real stem (>= 3 letters) is left
        for suffix in ["ing", "ed"] where s.hasSuffix(suffix) && s.count - suffix.count >= 3 {
            s = String(s.dropLast(suffix.count)); break
        }

        // 3. trailing "e" — only on longer words, so "bike"/"tone" survive intact enough to match
        //    themselves while "invoice"/"invoiced" still meet.
        if s.count > 4, s.hasSuffix("e") { s = String(s.dropLast()) }
        return s
    }

    /// FNV-1a, 64-bit. Not Swift's `hashValue`: that is seeded per process and would give a
    /// different vector space on every launch, silently invalidating a persisted index.
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
}

// MARK: Apple's on-device sentence embedding

final class SentenceEmbedder: TextEmbedder, @unchecked Sendable {
    private let model: NLEmbedding
    /// NLEmbedding's thread-safety is undocumented; one embed at a time costs nothing next
    /// to the parse and is cheaper than a crash.
    private let lock = NSLock()
    let dimension: Int
    let identifier: String

    static var isAvailable: Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil }

    init?() {
        guard let m = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        model = m
        dimension = m.dimension
        identifier = "nl-sentence-en-r\(m.revision)-\(m.dimension)"
    }

    func embed(_ text: String) -> [Float]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let v = model.vector(for: t), v.count == dimension else { return nil }
        return Self.normalised(v.map(Float.init))
    }
}

enum EmbedderFactory {
    /// Semantic when the system model is present, lexical otherwise.
    static func preferred() -> any TextEmbedder {
        SentenceEmbedder() ?? HashingEmbedder()
    }
}
