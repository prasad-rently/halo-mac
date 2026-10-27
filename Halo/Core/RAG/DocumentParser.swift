import Foundation
import PDFKit
import AppKit

// MARK: - Document parsers  (F-047 D5 — pluggable per format)
//
// Each parser turns one file into plain-text *sections* (a PDF page, or the whole of a text
// file). Sections carry the locator the citation will show. Parsing is synchronous and
// CPU/IO-bound — callers run it off the main actor.

struct ParsedSection: Equatable, Sendable {
    let text: String
    /// "p. 3" for a page; nil for a flat file (the chunker then derives "lines a–b").
    let locator: String?
    /// True when `text` is a flat file whose chunks should be cited by line range.
    let trackLines: Bool

    init(text: String, locator: String? = nil, trackLines: Bool = false) {
        self.text = text; self.locator = locator; self.trackLines = trackLines
    }
}

struct ParsedDocument: Equatable, Sendable {
    let sections: [ParsedSection]
    var characterCount: Int { sections.reduce(0) { $0 + $1.text.count } }
}

protocol DocumentParser: Sendable {
    var extensions: Set<String> { get }
    func parse(_ url: URL) throws -> ParsedDocument
}

enum DocumentParsers {
    static let all: [DocumentParser] = [PlainTextParser(), HTMLTextParser(), PDFTextParser(), RichTextParser()]

    static func parser(forExtension ext: String) -> DocumentParser? {
        let e = ext.lowercased()
        return all.first { $0.extensions.contains(e) }
    }

    static var supportedExtensions: Set<String> { all.reduce(into: Set<String>()) { $0.formUnion($1.extensions) } }
}

// MARK: Plain text, markdown, CSV and source code

struct PlainTextParser: DocumentParser {
    let extensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "yaml", "yml", "xml", "ini", "toml",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "ts", "tsx", "jsx",
        "java", "kt", "sh", "zsh", "bash", "sql", "css", "tex", "rst"
    ]

    func parse(_ url: URL) throws -> ParsedDocument {
        let data = try readData(url)
        // A NUL byte in the first 8 KB means a binary file that merely has a text-y extension.
        if data.prefix(8192).contains(0) {
            throw RAGError.unreadable("it looks like a binary file, not text")
        }
        guard let text = Self.decode(data) else { throw RAGError.unreadable("its text encoding isn't recognised") }
        return ParsedDocument(sections: [ParsedSection(text: text, locator: nil, trackLines: true)])
    }

    /// UTF-8 first, then UTF-16 (only with a BOM — without one nearly any bytes "decode"),
    /// then the two legacy Western encodings an old export is most likely in.
    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman)
    }
}

// MARK: HTML (tag-stripped — NSAttributedString's HTML importer is main-thread/WebKit only)

struct HTMLTextParser: DocumentParser {
    let extensions: Set<String> = ["html", "htm"]

    func parse(_ url: URL) throws -> ParsedDocument {
        let data = try readData(url)
        guard let html = PlainTextParser.decode(data) else { throw RAGError.unreadable("its text encoding isn't recognised") }
        return ParsedDocument(sections: [ParsedSection(text: Self.stripTags(html))])
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?s)<!--.*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Block-level tags become paragraph breaks so the chunker still sees structure.
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|tr|section|article|br)\s*>|<br\s*/?>"#,
                                   with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: PDF — one section per page, so a citation can say "p. 3"

struct PDFTextParser: DocumentParser {
    let extensions: Set<String> = ["pdf"]

    func parse(_ url: URL) throws -> ParsedDocument {
        guard let pdf = PDFDocument(url: url) else { throw RAGError.unreadable("it isn't a valid PDF") }
        if pdf.isLocked { throw RAGError.unreadable("the PDF is password-protected") }
        var sections: [ParsedSection] = []
        for index in 0..<pdf.pageCount {
            guard let text = pdf.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            sections.append(ParsedSection(text: text, locator: "p. \(index + 1)"))
        }
        guard !sections.isEmpty else {
            throw RAGError.noText("The PDF has no extractable text — it may be a scan. (OCR isn't supported yet.)")
        }
        return ParsedDocument(sections: sections)
    }
}

// MARK: RTF, Word and OpenDocument — via AppKit's text importers (not HTML: see above)

struct RichTextParser: DocumentParser {
    let extensions: Set<String> = ["rtf", "docx", "doc", "odt"]

    func parse(_ url: URL) throws -> ParsedDocument {
        _ = try readData(url)      // size + readability guard before handing it to AppKit
        let type: NSAttributedString.DocumentType
        switch url.pathExtension.lowercased() {
        case "rtf":  type = .rtf
        case "docx": type = .officeOpenXML
        case "doc":  type = .docFormat
        default:     type = .openDocument
        }
        do {
            let attributed = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw RAGError.noText("The document has no text.") }
            return ParsedDocument(sections: [ParsedSection(text: text)])
        } catch let e as RAGError {
            throw e
        } catch {
            throw RAGError.unreadable("it isn't a valid \(url.pathExtension.uppercased()) document")
        }
    }
}

// MARK: Shared

/// Reads a file's bytes, refusing anything over `RAGLimits.maxFileBytes` *before* loading it.
func readData(_ url: URL) throws -> Data {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    if size > RAGLimits.maxFileBytes { throw RAGError.tooLarge(bytes: size) }
    do { return try Data(contentsOf: url, options: .mappedIfSafe) }
    catch { throw RAGError.unreadable(error.localizedDescription) }
}
