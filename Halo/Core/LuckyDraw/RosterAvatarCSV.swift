import Foundation

// MARK: - RosterAvatarCSV (F-053 / v2.6 C-4)
//
// An avatar column for roster CSVs: `name,avatar_kind,avatar_value`.
//
// EXPORT writes the kind and the emoji / monogram text only. A photo is exported as kind `photo`
// with an EMPTY value — never its bytes, never its stored file name, never a path. A roster CSV
// is the thing people e-mail around; a participant's face must not ride along in it.
//
// IMPORT is the opposite half of the same rule: a CSV is untrusted input, so the only avatar it
// can ever produce is a validated single emoji (`EmojiValidation.isSingleEmoji`). Every other
// kind — `photo`, `animated`, `character`, a path-looking value, `../x.jpg`, a 10 MB string, a
// formula — yields NO avatar (the entry gets its derived monogram). The importer never touches
// the avatars folder and never constructs `.photo(...)`, so there is nothing a hostile file can
// point at.

extension RosterImport {

    static let csvAvatarHeader = "name,avatar_kind,avatar_value"
    /// Cells longer than this are not even looked at as an avatar value (a real emoji is < 16 scalars).
    static let avatarCellLimit = 64
    /// A roster holds 500 entries; reading far more rows than that is only ever hostile input.
    static let maxCSVRows = 5_000

    struct Row: Equatable {
        let label: String
        let avatar: EntryAvatar?
    }

    // MARK: Export

    static func rosterCSV(entries: [DrawEntry]) -> String {
        var lines = [csvAvatarHeader]
        for e in entries {
            let (kind, value): (String, String)
            switch e.avatar {
            case .emoji(let v)?: (kind, value) = ("emoji", v)
            case .photo?:        (kind, value) = ("photo", "")          // never the file name
            default:             (kind, value) = ("monogram", Monogram.initials(for: e.label))
            }
            lines.append([csvQuote(e.label), kind, csvQuote(value)].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Quote + neutralise: newlines flattened, a leading `= + - @` made inert (same rule as the
    /// history export), embedded quotes doubled.
    private static func csvQuote(_ field: String) -> String {
        let flat = field.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        // One leading apostrophe is added to any name that is (apostrophes then) a formula character,
        // and import strips exactly one — so a name that genuinely starts `'=` round-trips too.
        let guarded = formulaShaped(flat) ? "'" + flat : flat
        let safe = guarded.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(safe)\""
    }

    // MARK: Import

    /// Rows of a roster CSV, with the optional avatar columns honoured. A single-row file is a
    /// comma list of names, exactly as `labels(fromCSV:)` treats it (so no avatars there). Our own
    /// header row is dropped; no other header is guessed at.
    static func rows(fromCSV raw: String) -> [Row] {
        let lines = raw.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { return labels(fromCSV: raw).map { Row(label: $0, avatar: nil) } }

        var rows: [Row] = []
        for (i, line) in lines.prefix(maxCSVRows).enumerated() {
            let cells = splitCSVRow(line)
            if i == 0, isAvatarHeader(cells) { continue }
            guard let first = cells.first, let label = clean(unSafe(first)) else { continue }
            let avatar = cells.count >= 3 ? avatar(kind: cells[1], value: cells[2]) : nil
            rows.append(Row(label: label, avatar: avatar))
        }
        return rows
    }

    static func readRows(fileAt url: URL) throws -> [Row] {
        let (text, ext) = try readText(fileAt: url)
        return ext == "csv" ? rows(fromCSV: text)
                            : labels(fromFileContents: text, fileExtension: ext).map { Row(label: $0, avatar: nil) }
    }

    /// The ONLY avatar a CSV can request: a validated single emoji. Everything else is nil.
    static func avatar(kind: String, value: String) -> EntryAvatar? {
        guard kind.trimmingCharacters(in: .whitespaces).lowercased() == "emoji" else { return nil }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count <= avatarCellLimit, EmojiValidation.isSingleEmoji(v) else { return nil }
        return .emoji(v)
    }

    private static func isAvatarHeader(_ cells: [String]) -> Bool {
        cells.count >= 2
            && cells[0].trimmingCharacters(in: .whitespaces).lowercased() == "name"
            && cells[1].trimmingCharacters(in: .whitespaces).lowercased() == "avatar_kind"
    }

    /// Reverses the apostrophe `csvSafe` puts in front of `= + - @` on export, so a name survives
    /// a round trip. Only that exact shape is undone.
    private static func unSafe(_ cell: String) -> String {
        if cell.first == "'", formulaShaped(String(cell.dropFirst())) { return String(cell.dropFirst()) }
        return cell
    }

    /// Zero or more apostrophes followed by `= + - @ TAB CR` — the shape export guards with one more
    /// apostrophe (a superset of `LuckyDrawStore.csvSafe`'s rule, so exports stay reversible).
    private static func formulaShaped(_ s: String) -> Bool {
        guard let first = s.drop(while: { $0 == "'" }).first else { return false }
        return "=+-@\t\r".contains(first)
    }

    /// All cells of one CSV row, quote-aware (`""` is an escaped quote).
    static func splitCSVRow(_ row: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inQuotes = false
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { cell.append(c) }
            } else if c == "\"" , cell.trimmingCharacters(in: .whitespaces).isEmpty {
                inQuotes = true; cell = ""
            } else if c == "," {
                cells.append(cell); cell = ""
            } else { cell.append(c) }
            i += 1
        }
        cells.append(cell)
        return cells
    }
}
