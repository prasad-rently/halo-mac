import Foundation

// MARK: - RosterImport

/// Turning pasted text or a dropped file into roster labels, and deciding which of them
/// are duplicates (FR-2, FR-3, FR-4).
///
/// Pure value logic with no store, view or file-system dependency beyond `read(fileAt:)`,
/// so every rule here — what a CSV row means, what counts as the same name — is tested
/// directly rather than through the roster panel.
enum RosterImport {

    /// Labels are stored truncated to this, so duplicate detection has to compare the
    /// *stored* form: two 80-character names that only differ after character 60 are,
    /// as far as the wheel is concerned, the same name.
    static let labelLimit = 60

    /// A dropped file larger than this is refused rather than half-read. A name list is
    /// kilobytes; a megabyte is already something other than a name list.
    static let maxFileBytes = 1_000_000

    // MARK: - Parsing

    /// Pasted text, and `.txt` files. Newlines split into one entry per line; a single
    /// line with commas and no newline splits on the commas — the two shapes a pasted
    /// list actually arrives in. Blank pieces are dropped.
    static func labels(fromPasted raw: String) -> [String] {
        let separators: CharacterSet = raw.contains(where: \.isNewline)
            ? .newlines
            : CharacterSet(charactersIn: ",")
        return raw.components(separatedBy: separators).compactMap(clean)
    }

    /// `.csv` files.
    ///
    /// A multi-row file contributes the **first column** of each row — the column a name
    /// list is in — so `Anna,Sales` yields "Anna", not "Anna,Sales". Quoted cells are
    /// honoured (`"Doe, Jane",Sales` → "Doe, Jane"). A file that is a single row is
    /// treated like a pasted comma list, since `Anna,Marcus,Yuki` is a list of names.
    ///
    /// No header row is detected or dropped: guessing that "name" is a header would mean
    /// silently discarding something the user may really have meant as an entry, and
    /// one chip to delete is a cheaper failure than a name that vanished.
    static func labels(fromCSV raw: String) -> [String] {
        let rows = raw.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard rows.count > 1 else { return labels(fromPasted: raw) }
        return rows.compactMap { clean(firstCSVCell(of: $0)) }
    }

    /// Dispatches on a file extension (without the dot, any case).
    static func labels(fromFileContents raw: String, fileExtension: String) -> [String] {
        fileExtension.lowercased() == "csv" ? labels(fromCSV: raw) : labels(fromPasted: raw)
    }

    static let supportedExtensions: Set<String> = ["txt", "csv", "text"]

    enum ReadError: Error, Equatable {
        case unsupportedType(String)
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// Reads a dropped file into labels. UTF-8 first, then Mac Roman — the encoding an
    /// older Excel "CSV (Macintosh)" export is in — so accented names survive either way.
    static func read(fileAt url: URL) throws -> [String] {
        let (text, ext) = try readText(fileAt: url)
        return labels(fromFileContents: text, fileExtension: ext)
    }

    /// The size/type/encoding checks shared by `read(fileAt:)` and `readRows(fileAt:)`.
    static func readText(fileAt url: URL) throws -> (text: String, ext: String) {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ReadError.unsupportedType(ext) }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maxFileBytes { throw ReadError.tooLarge(bytes: size) }

        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        if data.count > maxFileBytes { throw ReadError.tooLarge(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .macOSRoman) else { throw ReadError.unreadable }
        return (text, ext)
    }

    // MARK: - Duplicates

    /// The comparison key: what makes two labels "the same name". Case, accents and
    /// runs of whitespace are ignored — "anna", "Anna" and "  ANNA " are one name —
    /// because the question the user is being asked is "did you mean to add this person
    /// twice?", and a typo-level difference should still prompt it.
    static func key(for label: String) -> String {
        label.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    enum DuplicatePolicy: Equatable {
        /// Two people can share a name, so adding both is a legitimate answer.
        case keepBoth
        case skipDuplicates
    }

    struct Item: Equatable {
        let label: String
        /// v2.6 C-4: the avatar a CSV row asked for — only ever `.emoji` or nil (see `RosterAvatarCSV`).
        var avatar: EntryAvatar? = nil
        /// True when the same name is already on the roster, or appears earlier in this
        /// same batch. The *first* of two identical incoming labels is not a duplicate
        /// of the second — only the repeat is.
        let isDuplicate: Bool
    }

    struct Plan: Equatable {
        let items: [Item]

        var hasDuplicates: Bool { items.contains(where: \.isDuplicate) }
        var duplicateLabels: [String] { items.filter(\.isDuplicate).map(\.label) }
        var duplicateCount: Int { items.filter(\.isDuplicate).count }

        /// The labels to actually add under a policy, in the order they arrived.
        func labels(for policy: DuplicatePolicy) -> [String] {
            switch policy {
            case .keepBoth:        return items.map(\.label)
            case .skipDuplicates:  return items.filter { !$0.isDuplicate }.map(\.label)
            }
        }

        /// Avatars parallel to `labels(for:)`.
        func avatars(for policy: DuplicatePolicy) -> [EntryAvatar?] {
            switch policy {
            case .keepBoth:        return items.map(\.avatar)
            case .skipDuplicates:  return items.filter { !$0.isDuplicate }.map(\.avatar)
            }
        }
    }

    /// Never merges silently (FR-4): this only *classifies*; the caller asks the user.
    static func plan(incoming: [String], existing: [String], avatars: [EntryAvatar?] = []) -> Plan {
        var seen = Set(existing.map(key(for:)))
        var items: [Item] = []
        items.reserveCapacity(incoming.count)
        for (i, label) in incoming.enumerated() {
            let k = key(for: label)
            items.append(Item(label: label, avatar: i < avatars.count ? avatars[i] : nil,
                              isDuplicate: seen.contains(k)))
            seen.insert(k)
        }
        return Plan(items: items)
    }

    // MARK: - Helpers

    /// Trim, truncate to what will be stored, and drop empties.
    static func clean(_ piece: String) -> String? {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(labelLimit))
    }

    /// First cell of one CSV row, quote-aware (`""` is an escaped quote).
    private static func firstCSVCell(of row: String) -> String {
        let chars = Array(row.trimmingCharacters(in: .whitespaces))
        guard let first = chars.first else { return "" }
        guard first == "\"" else {
            return String(chars.prefix { $0 != "," })
        }
        var out = ""
        var i = 1
        while i < chars.count {
            if chars[i] == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" { out.append("\""); i += 2; continue }
                break
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
