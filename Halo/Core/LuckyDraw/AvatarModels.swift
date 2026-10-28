import Foundation

// MARK: - F-053 Lucky Draw avatars — model
//
// UI-free on purpose: everything here is a value type or a pure function, so the rules that
// protect the user (what counts as an emoji, what a stored file name may look like, how a
// folder of photos is matched to names) are unit-tested without a window or a disk.
//
// The rule that does not change from F-051: **an avatar never influences a draw.** Nothing in
// `DrawEngine` or `SpinnerAnimator` reads these types, and `DrawFairnessWithAvatarsTests`
// breaks if that ever stops being true.

// MARK: - EntryAvatar

/// What an entry looks like, beyond its label. `nil` on the entry means "no avatar chosen" and
/// is rendered as a derived monogram, so existing rosters need no migration.
///
/// Photos are referenced by a **file name Halo generated** (a UUID + ".jpg" inside the roster's
/// avatars folder) — never by a path. A roster file can be hand-edited, so the name is treated
/// as untrusted input and validated at decode and again at every resolve.
enum EntryAvatar: Hashable, Sendable {
    case emoji(String)
    /// A looping animation from a bundled pack. No pack ships yet (the art is commissioned) —
    /// the case exists so the file format is settled before the art arrives.
    case animated(pack: String, item: String)
    /// A bundled caricature / character image. Same status as `.animated`.
    case character(pack: String, item: String)
    case photo(fileName: String)

    var isPhoto: Bool { if case .photo = self { return true } else { return false } }
    var photoFileName: String? { if case .photo(let f) = self { return f } else { return nil } }
}

extension EntryAvatar: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, pack, item, file }
    private enum Kind: String { case emoji, animated, character, photo }

    /// Throws for an unknown kind or an invalid payload. `DrawEntry.init(from:)` turns that into
    /// "no avatar" — a roster must never be sent to the corrupt-file backup because one avatar
    /// in it was written by a newer build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "Unknown avatar kind \(raw)")
        }
        func bad(_ key: CodingKeys, _ why: String) -> DecodingError {
            .dataCorruptedError(forKey: key, in: c, debugDescription: why)
        }
        switch kind {
        case .emoji:
            let v = try c.decode(String.self, forKey: .value)
            guard EmojiValidation.isSingleEmoji(v) else { throw bad(.value, "Not a single emoji") }
            self = .emoji(v)
        case .animated, .character:
            let pack = try c.decode(String.self, forKey: .pack)
            let item = try c.decode(String.self, forKey: .item)
            guard AvatarIdentifier.isValid(pack) else { throw bad(.pack, "Invalid pack id") }
            guard AvatarIdentifier.isValid(item) else { throw bad(.item, "Invalid item id") }
            self = kind == .animated ? .animated(pack: pack, item: item) : .character(pack: pack, item: item)
        case .photo:
            let file = try c.decode(String.self, forKey: .file)
            guard let canonical = AvatarFileName.normalized(file) else { throw bad(.file, "Invalid photo file name") }
            self = .photo(fileName: canonical)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let v):
            try c.encode(Kind.emoji.rawValue, forKey: .kind); try c.encode(v, forKey: .value)
        case .animated(let pack, let item):
            try c.encode(Kind.animated.rawValue, forKey: .kind)
            try c.encode(pack, forKey: .pack); try c.encode(item, forKey: .item)
        case .character(let pack, let item):
            try c.encode(Kind.character.rawValue, forKey: .kind)
            try c.encode(pack, forKey: .pack); try c.encode(item, forKey: .item)
        case .photo(let file):
            try c.encode(Kind.photo.rawValue, forKey: .kind); try c.encode(file, forKey: .file)
        }
    }
}

// MARK: - Display mode

/// Per-roster choice of how entries are shown on the wheel.
enum AvatarDisplayMode: String, Codable, CaseIterable, Identifiable {
    /// Avatar where the entry has one, name otherwise — an existing roster looks exactly as it
    /// did until an avatar is added.
    case auto
    case avatarAndName
    case avatarOnly
    /// F-051's original wheel, regardless of avatars.
    case nameOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .avatarAndName: return "Avatar + name"
        case .avatarOnly: return "Avatar only"
        case .nameOnly: return "Name only"
        }
    }
}

// MARK: - Validation

/// Identifiers that end up in a path (pack and item names) — letters, digits, `.`, `_`, `-`
/// only, never a leading dot, so `..` and absolute paths are impossible by construction.
enum AvatarIdentifier {
    static func isValid(_ s: String) -> Bool {
        guard (1...64).contains(s.count), !s.hasPrefix(".") else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }
}

/// The only file name a stored photo may have: `<UUID>.jpg`.
enum AvatarFileName {
    static func make() -> String { "\(UUID().uuidString).jpg" }

    static func isValid(_ s: String) -> Bool { normalized(s) != nil }

    /// The one spelling of a valid name — UPPER-case UUID, lower-case `.jpg` — or nil (H-10).
    ///
    /// `UUID(uuidString:)` accepts either case, and the default APFS volume is case-insensitive,
    /// so a hand-edited roster naming `abc….jpg` really does point at the file Halo wrote as
    /// `ABC….jpg`. Anything that *compares* names (the orphan sweep's keep-set, the image cache's
    /// keys, an equality check on avatars) must therefore compare this form: compared raw, a
    /// referenced photo looks unreferenced and the sweep deletes it.
    static func normalized(_ s: String) -> String? {
        guard s.hasSuffix(".jpg"), let id = UUID(uuidString: String(s.dropLast(4))) else { return nil }
        return "\(id.uuidString).jpg"
    }
}

enum EmojiValidation {
    static let maxScalars = 16

    /// Exactly one user-perceived character that is an emoji: a pictograph, a ZWJ family or
    /// profession, a flag, a keycap, a skin-toned hand. Rejects plain letters and digits
    /// (which carry the Emoji property as keycap bases), text such as "ab", and two emoji.
    static func isSingleEmoji(_ s: String) -> Bool {
        // `count == 1` counts grapheme clusters, and a cluster can be unboundedly long: an emoji
        // followed by hundreds of combining marks is still "one character" to Swift. The longest real
        // sequences (a ZWJ family or couple with two skin tones, a subdivision flag) are about ten
        // scalars, so cap well above that — otherwise a hand-edited roster could hand the wheel's
        // `Canvas` a multi-kilobyte "emoji" to lay out every frame.
        guard s.count == 1, s.unicodeScalars.count <= maxScalars,
              let first = s.unicodeScalars.first else { return false }
        let scalars = s.unicodeScalars
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && scalars.count > 1)
    }
}

// MARK: - Monogram

/// The derived default avatar: initials, grapheme-aware, so "Åsa Lindqvist" is "ÅL", a CJK name
/// is its first character, and an emoji-led label keeps the emoji whole instead of splitting it.
enum Monogram {
    static func initials(for label: String) -> String {
        let words = label.split(whereSeparator: \.isWhitespace).prefix(2)
        guard !words.isEmpty else { return "?" }
        let letters: [String] = words.compactMap { word in
            let pick = word.first(where: { $0.isLetter || $0.isNumber || isEmoji($0) }) ?? word.first
            return pick.map { String($0).uppercased() }
        }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private static func isEmoji(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return s.properties.isEmojiPresentation || (s.properties.isEmoji && c.unicodeScalars.count > 1)
    }
}

// MARK: - Folder matching (FR-B1)

/// Matches a folder of image files to roster entries by name: case-, diacritic-, width- and
/// punctuation-insensitive ("anna_maria.JPG" ↔ "Anna Maria"). Pure — nothing is applied until
/// the user confirms the result.
enum AvatarFolderMatcher {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp"]

    struct Match: Equatable { let entryID: UUID; let file: URL }

    struct Result: Equatable {
        var matches: [Match] = []
        /// Image files that named nobody (or named someone ambiguous / already matched).
        var unmatchedFiles: [URL] = []
        /// Entries still without a photo after matching.
        var entriesWithoutPhoto: [UUID] = []
        /// Labels shared by more than one entry — never auto-matched, because guessing which
        /// "Alex" a photo belongs to is worse than asking.
        var ambiguousLabels: [String] = []
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func match(files: [URL], entries: [DrawEntry]) -> Result {
        var byKey: [String: [DrawEntry]] = [:]
        for e in entries { byKey[normalize(e.label), default: []].append(e) }

        var result = Result()
        var claimed = Set<UUID>()
        let images = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for file in images {
            let key = normalize(file.deletingPathExtension().lastPathComponent)
            guard let candidates = byKey[key] else { result.unmatchedFiles.append(file); continue }
            if candidates.count > 1 {
                if !result.ambiguousLabels.contains(candidates[0].label) { result.ambiguousLabels.append(candidates[0].label) }
                result.unmatchedFiles.append(file)
            } else if let entry = candidates.first, claimed.insert(entry.id).inserted {
                result.matches.append(Match(entryID: entry.id, file: file))
            } else {
                result.unmatchedFiles.append(file)
            }
        }
        result.entriesWithoutPhoto = entries.map(\.id).filter { !claimed.contains($0) }
        return result
    }
}

// MARK: - Photo crop geometry

/// Where to cut the square. Pure so the clamping — the part that goes wrong at image edges —
/// is tested without Vision or a photo.
enum AvatarCrop {
    /// - Parameter face: the detected face in **top-left-origin pixel coordinates**, or nil.
    /// - Returns: a square inside `0..<width × 0..<height`, in the same coordinate space.
    static func squareRect(imageWidth w: CGFloat, imageHeight h: CGFloat, face: CGRect?) -> CGRect {
        let maxSide = min(w, h)
        guard maxSide > 0 else { return .zero }
        guard let face, face.width > 0, face.height > 0 else {
            return CGRect(x: (w - maxSide) / 2, y: (h - maxSide) / 2, width: maxSide, height: maxSide)
        }
        // Room around the face for hair and shoulders, never more than the image allows.
        let side = min(maxSide, max(face.width, face.height) * 2.2)
        var x = face.midX - side / 2
        var y = face.midY - side / 2
        x = min(max(0, x), w - side)
        y = min(max(0, y), h - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

// MARK: - Emoji shortlist

/// The quick-pick grid in the avatar picker. Every entry must pass `EmojiValidation` (a test
/// enforces it), including the ZWJ ones — a shortlist the validator rejects would be a button that
/// silently does nothing.
enum AvatarEmojiCatalog {
    static let common: [String] = [
        "😀", "😄", "😎", "🤩", "🥳", "😇", "🤠", "🧐", "🤓", "🥸",
        "🦊", "🐼", "🐸", "🦄", "🐯", "🦁", "🐵", "🐶", "🐱", "🐰",
        "🐨", "🦉", "🐢", "🐙", "🦋", "🐉", "🌟", "🔥", "🌈", "🍀",
        "🌻", "🍕", "🍩", "🎸", "🎮", "🚀", "⚽", "🏀", "🎯", "🏆",
        "👑", "💎", "🎩", "🧙‍♂️", "🧑‍🚀", "🦸‍♀️", "🥷", "🤖", "👾", "👻"
    ]
}
