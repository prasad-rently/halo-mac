import Foundation
import NaturalLanguage

// MARK: - Chunker  (F-047 FR-6)
//
// Splits parsed text into overlapping, roughly-fixed-size passages for embedding, keeping
// enough provenance to cite them ("p. 3", "lines 40–58").
//
// Splitting respects structure, from coarse to fine, so a passage never starts mid-thought
// when it doesn't have to:
//   paragraph  (a run of non-blank lines)           — kept whole if it fits
//   line       (so code and CSV rows stay intact, and line numbers stay accurate)
//   sentence   (NLTokenizer, language-aware)         — for a single over-long line
//   hard wrap  (at whitespace, then mid-word)        — a sentence longer than a whole chunk
// Units are then packed up to `targetCharacters`, and each new chunk is seeded with the tail
// of the previous one (up to `overlapCharacters`) so a fact straddling a boundary is still
// retrievable from either side. Pure and deterministic: same input, same chunks.

struct TextChunk: Equatable, Sendable {
    let text: String
    let locator: String?
}

enum Chunker {

    /// ~200 tokens. Large enough to carry context, small enough that a top-5 fits a prompt.
    static let targetCharacters = 900
    static let overlapCharacters = 150
    /// A trailing scrap shorter than this is dropped — it is almost always seed text again.
    static let minimumCharacters = 40

    private struct Unit {
        let text: String
        let paragraph: Int
        let firstLine: Int
        let lastLine: Int
        /// What to put before this unit when it follows another in the same paragraph.
        let separator: String
    }

    static func chunks(for document: ParsedDocument) -> [TextChunk] {
        document.sections.flatMap { chunks(for: $0) }
    }

    static func chunks(for section: ParsedSection) -> [TextChunk] {
        let units = makeUnits(from: section.text)
        guard !units.isEmpty else { return [] }

        var out: [TextChunk] = []
        var current: [Unit] = []
        var seedCount = 0          // leading units that are overlap copied from the previous chunk
        var length = 0

        func render(_ units: [Unit]) -> String {
            var s = ""
            for (i, u) in units.enumerated() {
                if i > 0 { s += units[i - 1].paragraph == u.paragraph ? u.separator : "\n\n" }
                s += u.text
            }
            return s
        }

        func locator(_ units: [Unit]) -> String? {
            if let fixed = section.locator { return fixed }
            guard section.trackLines, let first = units.map(\.firstLine).min(),
                  let last = units.map(\.lastLine).max() else { return nil }
            return first == last ? "line \(first)" : "lines \(first)–\(last)"
        }

        func flush() {
            let text = render(current)
            out.append(TextChunk(text: text, locator: locator(current)))
            // Seed the next chunk with whole trailing units that fit in the overlap budget.
            var seed: [Unit] = []
            var seedLength = 0
            for unit in current.reversed() {
                if seedLength + unit.text.count > overlapCharacters { break }
                seed.insert(unit, at: 0)
                seedLength += unit.text.count
            }
            // Never seed the entire chunk: the next chunk must make progress.
            if seed.count == current.count { seed.removeFirst() }
            current = seed
            seedCount = seed.count
            length = seed.reduce(0) { $0 + $1.text.count }
        }

        for unit in units {
            let wouldBe = length + unit.text.count + (current.isEmpty ? 0 : 2)
            // Flush only when there is *new* content to flush: a chunk that is nothing but
            // seed must keep growing, or the overlap would be emitted as a duplicate chunk.
            if wouldBe > targetCharacters, current.count > seedCount {
                flush()
            }
            current.append(unit)
            length += unit.text.count + (current.count > 1 ? 2 : 0)
        }

        if current.count > seedCount {
            let text = render(current)
            let isOnlyChunk = out.isEmpty
            if isOnlyChunk || text.count >= minimumCharacters {
                out.append(TextChunk(text: text, locator: locator(current)))
            }
        }
        return out
    }

    // MARK: Units

    private static func makeUnits(from raw: String) -> [Unit] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        // Group consecutive non-blank lines into paragraphs, remembering line numbers (1-based).
        var paragraphs: [[(line: Int, text: String)]] = []
        var open: [(Int, String)] = []
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !open.isEmpty { paragraphs.append(open); open = [] }
            } else {
                open.append((i + 1, line.trimmingCharacters(in: .whitespaces)))
            }
        }
        if !open.isEmpty { paragraphs.append(open) }

        var units: [Unit] = []
        for (p, paragraph) in paragraphs.enumerated() {
            let whole = paragraph.map(\.text).joined(separator: "\n")
            if whole.count <= targetCharacters {
                units.append(Unit(text: whole, paragraph: p, firstLine: paragraph.first!.line,
                                  lastLine: paragraph.last!.line, separator: "\n"))
                continue
            }
            // Too big for one chunk: go line by line, so code/CSV rows survive and line
            // numbers stay exact; only a single over-long line is split further.
            for (index, entry) in paragraph.enumerated() {
                let separator = index == 0 ? "\n" : "\n"
                if entry.text.count <= targetCharacters {
                    units.append(Unit(text: entry.text, paragraph: p, firstLine: entry.line,
                                      lastLine: entry.line, separator: separator))
                } else {
                    for (n, piece) in splitLongLine(entry.text).enumerated() {
                        units.append(Unit(text: piece, paragraph: p, firstLine: entry.line, lastLine: entry.line,
                                          separator: n == 0 ? separator : " "))
                    }
                }
            }
        }
        return units
    }

    /// Sentences first (language-aware); a sentence still over the target is hard-wrapped.
    private static func splitLongLine(_ line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            let s = line[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        if sentences.isEmpty { sentences = [line] }
        return sentences.flatMap { $0.count <= targetCharacters ? [$0] : hardWrap($0) }
    }

    private static func hardWrap(_ s: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(s)
        while rest.count > targetCharacters {
            let window = rest.prefix(targetCharacters)
            // Prefer the last whitespace in the second half of the window; else cut mid-word.
            let cut: String.Index
            if let space = window.lastIndex(where: { $0 == " " || $0 == "\t" }),
               window.distance(from: window.startIndex, to: space) > targetCharacters / 2 {
                cut = space
            } else {
                cut = window.endIndex
            }
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: { $0 == " " || $0 == "\t" })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
