import SwiftUI
import CoreGraphics

// MARK: - AvatarImageCache (F-053)

/// Decoded photos at on-screen size, shared by every avatar on screen.
///
/// The wheel draws inside a `Canvas`, where nothing may block — so a photo that isn't decoded
/// yet is simply *not drawn* (the caller falls back to the monogram) while a background task
/// loads it; when it lands, `revision` changes and the views that observe it redraw. That is the
/// whole reason this is a thread-safe class rather than something `@MainActor`: `Canvas`'s
/// renderer closure is not main-actor isolated.
///
/// Sizes are bucketed (64 / 128 / 256 px) so a window resize doesn't decode a photo again, and the
/// cache is capped, so a 500-entry roster is a bounded amount of memory (~37 KB per 96-px image).
final class AvatarImageCache: ObservableObject, @unchecked Sendable {
    static let shared = AvatarImageCache()

    /// Set by `LuckyDrawStore.shared`. Nil ⇒ photos are never resolved (monogram fallback).
    var store: AvatarStore? {
        get { lock.lock(); defer { lock.unlock() }; return _store }
        set { lock.lock(); _store = newValue; images.removeAll(); order.removeAll(); failed.removeAll(); lock.unlock() }
    }

    @Published private(set) var revision = 0

    private let lock = NSLock()
    private var _store: AvatarStore?
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var inFlight = Set<String>()
    /// Keys whose load came back empty (file missing or unreadable). Without this a missing photo was
    /// re-read from disk on every frame the wheel drew: 60 dispatches a second per entry.
    private var failed = Set<String>()
    private var bumpScheduled = false
    private let capacity = 600
    private var _loadAttempts = 0

    /// How many disk loads this cache has started. Exposed so a test can prove a missing photo is
    /// not re-read on every frame.
    var loadAttempts: Int { lock.lock(); defer { lock.unlock() }; return _loadAttempts }
    /// How many decoded images it currently holds.
    var decodedCount: Int { lock.lock(); defer { lock.unlock() }; return images.count }

    static func bucket(forPoints points: CGFloat) -> Int {
        let px = points * 2
        return px <= 64 ? 64 : (px <= 128 ? 128 : 256)
    }

    /// The decoded photo if it is ready; otherwise a load is started and — if the same photo is
    /// already decoded at another size — that is returned meanwhile, so a card that asks for a larger
    /// avatar than the roster list did shows the picture at once rather than flashing initials.
    /// Nil only when nothing of this photo is decoded yet.
    func photo(fileName: String, rosterID: UUID, points: CGFloat) -> CGImage? {
        let px = Self.bucket(forPoints: points)
        let base = "\(rosterID.uuidString)/\(fileName)@"
        let key = base + String(px)
        lock.lock()
        if let hit = images[key] { lock.unlock(); return hit }
        let standIn = [256, 128, 64].lazy.filter { $0 != px }.compactMap { self.images[base + String($0)] }.first
        let store = _store
        let shouldLoad = store != nil && !failed.contains(key) && inFlight.insert(key).inserted
        if shouldLoad { _loadAttempts += 1 }
        lock.unlock()
        guard shouldLoad, let store else { return standIn }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = store.loadImage(fileName: fileName, rosterID: rosterID, maxPixel: px)
            self?.finish(key: key, image: image)
        }
        return standIn
    }

    private func finish(key: String, image: CGImage?) {
        lock.lock()
        inFlight.remove(key)
        var scheduleBump = false
        if let image {
            images[key] = image
            order.append(key)
            while order.count > capacity { images.removeValue(forKey: order.removeFirst()) }
            // Every avatar on screen observes `revision`, so one bump per photo is O(n^2) redraws while a
            // 500-entry roster fills in. Batch: the first photo to land arms a short timer; the rest
            // ride along on the same bump.
            if !bumpScheduled { bumpScheduled = true; scheduleBump = true }
        } else {
            failed.insert(key)
        }
        lock.unlock()
        if scheduleBump {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.bumpScheduled = false; self.lock.unlock()
                self.revision &+= 1
            }
        }
    }

    /// Forget everything cached for a roster (its photos were deleted).
    func forget(rosterID: UUID) {
        lock.lock()
        let prefix = rosterID.uuidString + "/"
        for key in images.keys where key.hasPrefix(prefix) { images.removeValue(forKey: key) }
        failed = failed.filter { !$0.hasPrefix(prefix) }
        order.removeAll { $0.hasPrefix(prefix) }
        lock.unlock()
        DispatchQueue.main.async { self.revision &+= 1 }
    }
}

// MARK: - AvatarView

/// One avatar: content (photo / emoji / monogram) in a circle, with a ring.
///
/// Used by the roster chips, the draw log, the winner popup and the winners strip; the wheel
/// draws its own into a `Canvas` with the same ingredients.
struct AvatarView: View {
    let avatar: EntryAvatar?
    let label: String
    var rosterID: UUID? = nil
    var diameter: CGFloat = 28
    var ringColor: Color = .haloAccent
    /// Overrides `ringColor` — e.g. the winner's gold conic ring.
    var ringStyle: AnyShapeStyle? = nil
    var ringFraction: CGFloat = 0.07
    /// Retired / excluded entries are shown desaturated, as the rest of their row is dimmed.
    var dimmed = false

    @ObservedObject private var cache = AvatarImageCache.shared

    var body: some View {
        let ringWidth = max(1.5, diameter * ringFraction)
        ZStack {
            content
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            Circle().strokeBorder(ringStyle ?? AnyShapeStyle(ringColor), lineWidth: ringWidth)
            // A hairline between the ring and any photo, so a bright picture never bleeds into it.
            Circle().inset(by: ringWidth).strokeBorder(Color.haloBackground.opacity(0.55), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .saturation(dimmed ? 0.2 : 1)
        .opacity(dimmed ? 0.6 : 1)
        // The row/card this sits in already says the name; the picture adds nothing for VoiceOver.
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch avatar {
        case .emoji(let e)?:
            ZStack {
                Color.haloSurface2
                Text(e).font(.system(size: diameter * 0.56))
            }
        case .photo(let file)?:
            if let rosterID, let image = cache.photo(fileName: file, rosterID: rosterID, points: diameter) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                monogram
            }
        default:
            // nil, and `.animated` / `.character`, whose packs do not ship yet.
            monogram
        }
    }

    private var monogram: some View {
        ZStack {
            Color.haloBackground
            LinearGradient(colors: [ringColor.opacity(0.55), ringColor.opacity(0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(Monogram.initials(for: label))
                .font(.system(size: diameter * 0.4, weight: .bold, design: .rounded))
                .foregroundColor(SegmentPalette.label)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }
}

extension AvatarView {
    /// The winner's ring: a gold-to-accent sweep, the same colours `ConicHalo` uses behind the card.
    static let winnerRing = AnyShapeStyle(
        AngularGradient(colors: [Color(hex: "#ffd36b"), Color.haloAccent, Color(hex: "#ffd36b"),
                                 Color.haloAccent2, Color(hex: "#ffd36b")],
                        center: .center))
}

// MARK: - When avatars show

extension AvatarDisplayMode {
    /// Whether an entry shows its avatar (rather than only its name) under this mode.
    /// `.auto` keeps an existing roster looking exactly as it did until an avatar is chosen.
    func showsAvatar(for entry: DrawEntry) -> Bool {
        switch self {
        case .nameOnly: return false
        case .auto: return entry.avatar != nil
        case .avatarAndName, .avatarOnly: return true
        }
    }
}
