import SwiftUI

// MARK: - DrawEntry

/// One name or item on the wheel.
///
/// Two independent ways an entry can be off the wheel, and they are deliberately
/// not the same flag:
///
/// - `isExcluded` — the user silenced it (someone is absent today). Reversible by
///   the user at any time, unaffected by drawing.
/// - `isRetired` — it already won this round. Set automatically when
///   `DrawRoster.autoRetireWinner` is on, cleared by **Put back** or **Reset draw**.
///
/// Neither ever deletes anything the user typed.
struct DrawEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var isExcluded: Bool
    var isRetired: Bool
    let addedAt: Date
    /// F-053. `nil` = none chosen, rendered as a derived monogram. **Never read by the draw.**
    var avatar: EntryAvatar?

    init(id: UUID = UUID(), label: String, isExcluded: Bool = false,
         isRetired: Bool = false, addedAt: Date = Date(), avatar: EntryAvatar? = nil) {
        self.id = id
        self.label = label
        self.isExcluded = isExcluded
        self.isRetired = isRetired
        self.addedAt = addedAt
        self.avatar = avatar
    }

    /// Tolerant of a missing, unknown or invalid `avatar`: those become "no avatar". A thrown
    /// error here would send the whole roster file to the corrupt backup (see `DrawRoster`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        isExcluded = try c.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
        isRetired = try c.decodeIfPresent(Bool.self, forKey: .isRetired) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        avatar = (try? c.decodeIfPresent(EntryAvatar.self, forKey: .avatar)) ?? nil
    }

    /// Eligible to be drawn — and, equivalently, to appear on the wheel.
    var isEligible: Bool { !isExcluded && !isRetired }
}

// MARK: - DrawResult

/// One row of the **Already drawn** log.
///
/// The log is a record of draws, *not* a mirror of the retired set. Putting a
/// winner back returns them to the wheel for the next round but leaves their row
/// here, flagged `wasReturned` — the draw still happened, and erasing it on put-back
/// would quietly rewrite the history of the round. Only **Reset draw** clears the log.
struct DrawResult: Identifiable, Codable, Hashable {
    let id: UUID
    let entryID: UUID
    /// Denormalised so the row survives the entry itself being deleted.
    let label: String
    let drawnAt: Date
    var wasReturned: Bool

    init(id: UUID = UUID(), entryID: UUID, label: String,
         drawnAt: Date = Date(), wasReturned: Bool = false) {
        self.id = id
        self.entryID = entryID
        self.label = label
        self.drawnAt = drawnAt
        self.wasReturned = wasReturned
    }
}

// MARK: - SpinDuration

enum SpinDuration: String, Codable, CaseIterable, Identifiable {
    case quick, standard, dramatic

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .quick:    return 3
        case .standard: return 5
        case .dramatic: return 8
        }
    }

    var title: String {
        switch self {
        case .quick:    return "3s"
        case .standard: return "5s"
        case .dramatic: return "8s"
        }
    }
}

// MARK: - DrawRoster

struct DrawRoster: Identifiable, Codable {
    let id: UUID
    var name: String
    var entries: [DrawEntry]
    /// Most recent first, capped at `historyCap`.
    var history: [DrawResult]
    var autoRetireWinner: Bool
    var spinDuration: SpinDuration
    /// D9 — off by default, and per roster. Halo had never made a sound before this
    /// feature, so audio is opt-in rather than something a user discovers by surprise.
    var soundEnabled: Bool
    /// F-053 — how the wheel shows entries. Defaults to `.auto`, which changes nothing until an
    /// avatar is chosen.
    var avatarDisplay: AvatarDisplayMode
    var modifiedAt: Date

    static let entryCap = 500
    static let historyCap = 200

    init(id: UUID = UUID(), name: String, entries: [DrawEntry] = [],
         history: [DrawResult] = [], autoRetireWinner: Bool = true,
         spinDuration: SpinDuration = .standard, soundEnabled: Bool = false,
         avatarDisplay: AvatarDisplayMode = .auto,
         modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.entries = entries
        self.history = history
        self.autoRetireWinner = autoRetireWinner
        self.spinDuration = spinDuration
        self.soundEnabled = soundEnabled
        self.avatarDisplay = avatarDisplay
        self.modifiedAt = modifiedAt
    }

    /// The pool a draw picks from, and exactly what the wheel renders.
    var eligible: [DrawEntry] { entries.filter(\.isEligible) }

    /// Entries the user hasn't deleted — retired ones included, since they are
    /// still part of the roster and come back on reset.
    var retiredCount: Int { entries.filter(\.isRetired).count }

    var canSpin: Bool { !eligible.isEmpty }

    static func starter() -> DrawRoster {
        DrawRoster(name: "Standup order",
                   entries: ["Priya", "Marcus", "Yuki", "Amara", "Tomás", "Nadia"]
                       .map { DrawEntry(label: $0) })
    }
}

// MARK: - SegmentPalette

/// Segment fills for the wheel.
///
/// **Why not a rainbow.** The obvious thing — cycle the six Halo accent colours as pie
/// slices — reads as a toy chart inside a dark-only system utility, and it forces the
/// label colour to flip per segment (white on the blues, near-black on the amber)
/// because no single text colour clears 4.5:1 against both.
///
/// So the ring is one continuous sweep along the arc Halo's own accent gradient already
/// travels: `haloAccent` blue (≈210°) through indigo to `haloAccent2`/`haloPurple`
/// violet (≈276°). Neighbouring segments separate on **luminance parity** rather than
/// on hue, which keeps a 200-slice wheel legible without introducing a single colour
/// that isn't already in `DesignSystem.swift`.
///
/// **Brightness is the load-bearing number.** The first cut held these at 0.24/0.32 to
/// sit politely on `haloSurface`, and the result read as unfinished — near-black wedges
/// with no colour in them at all. 0.40/0.56 gives the wheel real presence while still
/// clearing 4.5:1 against one near-white label colour on every fill, which is what lets
/// a name stay readable while the wheel is moving. Cyan is deliberately outside the
/// range: it is the one Halo hue bright enough at these values to put the label
/// contrast at risk. `SegmentPaletteTests` fails the build if any of that stops holding.
enum SegmentPalette {
    private static let hueStart = 210.0 / 360.0
    private static let hueEnd   = 276.0 / 360.0

    /// The single label colour every segment is built to support.
    static let label = Color(hex: "#eef2fb")

    static func fill(for index: Int, of total: Int) -> Color {
        let (h, s, b) = components(for: index, of: total)
        return Color(hue: h, saturation: s, brightness: b)
    }

    /// Lifted variant for the rim band and the roster chip swatches, so the wheel has
    /// an edge — and the chips a matching one — without a second palette.
    static func rim(for index: Int, of total: Int) -> Color {
        let (h, s, b) = components(for: index, of: total)
        return Color(hue: h, saturation: min(s + 0.10, 1), brightness: min(b + 0.24, 1))
    }

    /// Darker companion used as the inner end of each segment's radial shading, which
    /// is what stops a flat fill from reading as construction paper.
    static func core(for index: Int, of total: Int) -> Color {
        let (h, s, b) = components(for: index, of: total)
        return Color(hue: h, saturation: min(s + 0.06, 1), brightness: b * 0.52)
    }

    private static func components(for index: Int, of total: Int) -> (Double, Double, Double) {
        let span = Double(max(total - 1, 1))
        let t = total <= 1 ? 0 : Double(index) / span
        let hue = hueStart + (hueEnd - hueStart) * t
        let saturation = 0.72 - 0.14 * t
        // Parity alternation is what separates adjacent slices once the hue sweep
        // between two neighbours becomes imperceptible (anything past ~15 entries).
        let brightness = index % 2 == 0 ? 0.56 : 0.40
        return (hue, saturation, brightness)
    }
}

// MARK: - DrawRoster mutations
//
// The draw rules live on the value type, not in the store, so they can be tested
// without going anywhere near Application Support — and so there is exactly one
// definition of what "put back" and "reset" mean.
extension DrawRoster {

    /// Logs a win, and retires the winner when this roster asks for it.
    mutating func recordWin(entryID: UUID, label: String, at date: Date = Date()) {
        history.insert(DrawResult(entryID: entryID, label: label, drawnAt: date), at: 0)
        if history.count > Self.historyCap {
            history.removeLast(history.count - Self.historyCap)
        }
        guard autoRetireWinner,
              let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[i].isRetired = true
    }

    /// Returns one drawn entry to the wheel.
    ///
    /// The **Already drawn** row stays, flagged `wasReturned`. The log is a record of
    /// draws, not a mirror of the retired set: the draw did happen, and the entry is
    /// now free to win again. Deleting the row on put-back would quietly rewrite the
    /// history of the round. Only `resetDraw()` clears the log.
    mutating func putBack(_ result: DrawResult) {
        if let h = history.firstIndex(where: { $0.id == result.id }) {
            history[h].wasReturned = true
        }
        guard let i = entries.firstIndex(where: { $0.id == result.entryID }) else { return }
        entries[i].isRetired = false
    }

    /// Starts a fresh round: everyone back on the wheel, the log cleared. Entries
    /// themselves — including exclusions, which are a separate user choice — are
    /// untouched.
    mutating func resetDraw() {
        for i in entries.indices {
            entries[i].isRetired = false
        }
        history.removeAll()
    }

    /// True when there is something for Reset to actually undo.
    var canReset: Bool { !history.isEmpty || retiredCount > 0 }
}


// MARK: - DrawRoster decoding

extension DrawRoster {

    /// Every field added after the first release decodes with `decodeIfPresent`.
    ///
    /// This is not tidiness. The synthesized decoder throws `keyNotFound` for a missing
    /// key, and `LuckyDrawStore.loadFromDisk()` answers *any* decode failure by moving the
    /// whole file to `luckyDraw.corrupt.json` and starting empty — so adding
    /// `soundEnabled` with the synthesized decoder would have made every existing user's
    /// rosters vanish into the corrupt backup on first launch of the update.
    /// `LuckyDrawTests` decodes a file written *before* the field existed to keep it so.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        entries = try c.decodeIfPresent([DrawEntry].self, forKey: .entries) ?? []
        history = try c.decodeIfPresent([DrawResult].self, forKey: .history) ?? []
        autoRetireWinner = try c.decodeIfPresent(Bool.self, forKey: .autoRetireWinner) ?? true
        spinDuration = try c.decodeIfPresent(SpinDuration.self, forKey: .spinDuration) ?? .standard
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        avatarDisplay = (try? c.decodeIfPresent(AvatarDisplayMode.self, forKey: .avatarDisplay)) ?? .auto
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    /// FR-13 "duplicate": same entries and settings, fresh ids, an empty draw log and
    /// nobody retired — a copy is a new round, not a clone of the old one's history.
    func duplicated(named newName: String) -> DrawRoster {
        DrawRoster(name: newName,
                   // Photos stay behind: a copy's photo files belong to the *new* roster's folder, so
                   // `LuckyDrawStore.duplicateSelected` copies and re-points those; other kinds carry over.
                   entries: entries.map { DrawEntry(label: $0.label, isExcluded: $0.isExcluded,
                                                    avatar: $0.avatar?.isPhoto == true ? nil : $0.avatar) },
                   history: [],
                   autoRetireWinner: autoRetireWinner,
                   spinDuration: spinDuration,
                   soundEnabled: soundEnabled,
                   avatarDisplay: avatarDisplay)
    }
}

// MARK: - DrawSequence

/// **Draw N in a row** (FR-10): the state of one multi-winner run.
///
/// Winners within a run are drawn **without replacement**, whatever the roster's
/// Retire-winners setting says. "Draw 3" that can name the same person three times is
/// not drawing three winners. With auto-retire on, the roster already removes each
/// winner; with it off, this is what stops a repeat inside the run — and it does so
/// without touching the roster, so a later run starts from the full wheel again.
struct DrawSequence: Equatable {
    static let allowedRange = 2...10

    /// How many winners this run will produce: the request, clamped to 2…10 and to the
    /// number of entries actually eligible (a run of 5 over 3 entries can only be 3).
    let total: Int
    /// What was asked for, before clamping — kept so the UI can say so.
    let requested: Int
    private(set) var winners: [DrawEntry] = []
    /// Set by **Stop**. Deliberately does not abort the spin in flight (FR-18 forbids
    /// interrupting a draw once it has started — that would invite "re-roll until I like
    /// it"); it only prevents the *next* one.
    private(set) var stopRequested = false

    /// `nil` when nothing is eligible, so there is no run to start.
    init?(requested: Int, eligibleCount: Int) {
        guard eligibleCount > 0 else { return nil }
        let clamped = min(max(requested, Self.allowedRange.lowerBound), Self.allowedRange.upperBound)
        self.requested = requested
        self.total = min(clamped, eligibleCount)
    }

    var remaining: Int { max(0, total - winners.count) }
    var isComplete: Bool { winners.count >= total }
    var wasReducedToFit: Bool { total < min(max(requested, Self.allowedRange.lowerBound), Self.allowedRange.upperBound) }
    var shouldContinue: Bool { !isComplete && !stopRequested }
    /// 1-based position of the spin that is next to run (or currently running).
    var position: Int { min(winners.count + 1, total) }

    mutating func record(_ entry: DrawEntry) { winners.append(entry) }
    mutating func requestStop() { stopRequested = true }

    /// The pool the next spin draws from: everyone eligible who hasn't already won
    /// *in this run*.
    func pool(from eligible: [DrawEntry]) -> [DrawEntry] {
        let won = Set(winners.map(\.id))
        return eligible.filter { !won.contains($0.id) }
    }
}
