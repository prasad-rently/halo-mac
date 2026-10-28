import Testing
import SwiftUI
import AppKit
import Foundation
@testable import Halo

// MARK: - v2.6 F-053 completion (C-1 … C-4, H-11)

private enum CompletionFixtures {
    static func png(width: Int = 400, height: Int = 400) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    final class Scratch {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-draw-c-\(UUID().uuidString)", isDirectory: true)
        var file: URL { dir.appendingPathComponent("luckyDraw.json") }
        init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: dir) }
        @MainActor func store() -> LuckyDrawStore {
            LuckyDrawStore(fileURL: file, notificationCenter: NotificationCenter(), detectFaces: false)
        }
    }

    @MainActor static func addPhoto(_ store: LuckyDrawStore, to entry: DrawEntry) async throws {
        try await store.setPhoto(data: png(), for: entry)
    }
}

// MARK: - C-3 storage readout

@Suite("Avatar storage readout (C-3)")
@MainActor
struct AvatarStorageReadoutTests {

    @Test("Per-roster bytes count only that roster's files and sum to the total")
    func perRosterAccounting() async throws {
        let s = CompletionFixtures.Scratch(); let store = s.store()
        let first = store.selected!.id
        let e0 = store.selected!.entries[0], e1 = store.selected!.entries[1]
        try await CompletionFixtures.addPhoto(store, to: e0)
        try await CompletionFixtures.addPhoto(store, to: e1)

        store.addRoster(named: "Second")
        let second = store.selected!.id
        store.addEntries(from: "Zed")
        try await CompletionFixtures.addPhoto(store, to: store.selected!.entries[0])

        let a = store.avatarStore!
        let b1 = a.bytes(forRoster: first), b2 = a.bytes(forRoster: second)
        #expect(b1 > 0 && b2 > 0)
        #expect(b1 > b2, "two photos outweigh one")

        let usage = store.avatarStorageUsage()
        #expect(usage.totalBytes == b1 + b2)
        #expect(usage.rosters.map(\.rosterID) == [first, second], "largest first")
        #expect(usage.rosters.first { $0.rosterID == second }?.name == "Second")
        #expect(a.bytes(forRoster: UUID()) == 0)
    }

    @Test("A roster with no photos is not listed")
    func emptyRosterOmitted() {
        let s = CompletionFixtures.Scratch(); let store = s.store()
        #expect(store.avatarStorageUsage().rosters.isEmpty)
        #expect(store.avatarStorageUsage().totalBytes == 0)
    }

    @Test("Clearing one roster's photos leaves other rosters' photos and emoji avatars alone")
    func clearIsScopedToOneRoster() async throws {
        let s = CompletionFixtures.Scratch(); let store = s.store()
        let first = store.selected!.id
        let e0 = store.selected!.entries[0], e1 = store.selected!.entries[1]
        try await CompletionFixtures.addPhoto(store, to: e0)
        store.setAvatar(.emoji("🦊"), for: e1)

        store.addRoster(named: "Second")
        let second = store.selected!.id
        store.addEntries(from: "Zed")
        try await CompletionFixtures.addPhoto(store, to: store.selected!.entries[0])
        let secondBytes = store.avatarStore!.bytes(forRoster: second)

        #expect(store.clearPhotos(inRoster: first) == 1)

        let r1 = store.rosters.first { $0.id == first }!
        #expect(store.avatarStore!.bytes(forRoster: first) == 0)
        #expect(r1.entries.allSatisfy { $0.avatar?.isPhoto != true })
        #expect(r1.entries[1].avatar == .emoji("🦊"), "emoji avatars are not photos")
        #expect(store.avatarStore!.bytes(forRoster: second) == secondBytes, "the other roster is untouched")
        #expect(store.rosters.first { $0.id == second }!.entries[0].avatar?.isPhoto == true)
        #expect(store.clearPhotos(inRoster: UUID()) == 0)
    }

    @Test("A symlinked roster folder is not counted")
    func symlinkedFolderNotCounted() throws {
        let s = CompletionFixtures.Scratch(); let store = s.store()
        let a = store.avatarStore!
        let outside = s.dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5_000).write(to: outside.appendingPathComponent("\(UUID().uuidString).jpg"))
        let id = UUID()
        try FileManager.default.createDirectory(at: a.rootURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: a.directory(for: id), withDestinationURL: outside)
        #expect(a.bytes(forRoster: id) == 0)
    }
}

// MARK: - C-4 CSV avatar column

@Suite("Roster CSV avatar column (C-4)")
@MainActor
struct RosterAvatarCSVTests {

    private func entries() -> [DrawEntry] {
        [DrawEntry(label: "Priya Nair", avatar: .emoji("🦊")),
         DrawEntry(label: "Marcus"),
         DrawEntry(label: "Yuki Tanaka", avatar: .photo(fileName: "\(UUID().uuidString).jpg"))]
    }

    @Test("Export: kind + emoji/monogram only — a photo is a bare kind, never a name, path or bytes")
    func exportContent() {
        let es = entries()
        guard case .photo(let file)? = es[2].avatar else { Issue.record("fixture"); return }
        let csv = RosterImport.rosterCSV(entries: es)
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[0] == "name,avatar_kind,avatar_value")
        #expect(lines[1] == "\"Priya Nair\",emoji,\"🦊\"")
        #expect(lines[2] == "\"Marcus\",monogram,\"M\"")
        #expect(lines[3] == "\"Yuki Tanaka\",photo,\"\"")
        #expect(!csv.contains(file), "the stored photo file name must never be exported")
        #expect(!csv.contains(".jpg") && !csv.contains("/"), "no file name or path of any kind")
    }

    @Test("Round trip: names survive; emoji survives; photo and monogram come back as 'no avatar'")
    func roundTrip() {
        let names = ["Doe, Jane", "He said \"hi\"", "=SUM(1+1)", "'=x", "-5 Bob", "@home", "Zoë", "  spaced  "]
        let es = names.enumerated().map { i, n in
            DrawEntry(label: n, avatar: i == 0 ? .emoji("🌈") : (i == 1 ? .photo(fileName: AvatarFileName.make()) : nil))
        }
        let rows = RosterImport.rows(fromCSV: RosterImport.rosterCSV(entries: es))
        #expect(rows.map(\.label) == names.map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(rows[0].avatar == .emoji("🌈"))
        #expect(rows.dropFirst().allSatisfy { $0.avatar == nil })
    }

    @Test("Newlines in a name cannot break the row structure")
    func newlineInName() {
        let rows = RosterImport.rows(fromCSV: RosterImport.rosterCSV(entries:
            [DrawEntry(label: "Two\nLines", avatar: .emoji("🚀")), DrawEntry(label: "Next")]))
        #expect(rows.count == 2)
        #expect(rows[0].avatar == .emoji("🚀"))
        #expect(rows[1].label == "Next")
    }

    @Test("A CSV without our header, or without avatar columns, still imports names (as before)")
    func legacyShapes() {
        let plain = RosterImport.rows(fromCSV: "Anna,Sales\nMarcus,Ops")
        #expect(plain.map(\.label) == ["Anna", "Marcus"])
        #expect(plain.allSatisfy { $0.avatar == nil })
        // An ordinary first row that merely starts with "name" is not our header and is kept.
        #expect(RosterImport.rows(fromCSV: "name,Sales\nAnna,Ops").map(\.label) == ["name", "Anna"])
    }

    @Test("Import: a hostile CSV can only ever produce a validated single emoji")
    func hostileValuesYieldNoAvatar() {
        let uuidJPG = "\(UUID().uuidString).jpg"
        let bad: [(String, String)] = [
            ("photo", uuidJPG), ("photo", "../../../etc/passwd"), ("photo", "/Users/x/Pictures/me.jpg"),
            ("photo", ""), ("animated", "🦊"), ("character", "fox"),
            ("emoji", uuidJPG), ("emoji", "../x.jpg"), ("emoji", "ab"), ("emoji", "🦊🦊"), ("emoji", "7"),
            ("emoji", "=cmd|' /C calc'!A0"), ("emoji", ""), ("emoji", String(repeating: "🦊", count: 500)),
            ("emoji", "🦊" + String(repeating: "\u{0301}", count: 5_000)),
            ("monogram", "PN"), ("", "🦊"), ("../", "🦊"),
        ]
        for (kind, value) in bad {
            #expect(RosterImport.avatar(kind: kind, value: value) == nil, "kind=\(kind) value=\(value.prefix(24))")
        }
        #expect(RosterImport.avatar(kind: "emoji", value: "🦊") == .emoji("🦊"))
        #expect(RosterImport.avatar(kind: " EMOJI ", value: " 👩🏽‍🚀 ") == .emoji("👩🏽‍🚀"))
    }

    @Test("Path traversal: importing a hostile roster CSV file creates no avatar and touches no file")
    func traversalImportCreatesNothing() async throws {
        let s = CompletionFixtures.Scratch()
        let store = s.store()
        let victim = s.dir.appendingPathComponent("victim.txt")
        try "keep me".write(to: victim, atomically: true, encoding: .utf8)
        let csv = """
        name,avatar_kind,avatar_value
        "Eve",photo,"../../victim.txt"
        "Mallory",photo,"\(UUID().uuidString).jpg"
        "Trent",emoji,"../victim.txt"
        "Ok",emoji,"🦊"
        """
        let file = s.dir.appendingPathComponent("hostile.csv")
        try csv.write(to: file, atomically: true, encoding: .utf8)

        let rows = try RosterImport.readRows(fileAt: file)
        #expect(rows.map(\.label) == ["Eve", "Mallory", "Trent", "Ok"])
        let plan = store.prepareImport(rows.map(\.label), avatars: rows.map(\.avatar))
        let added = store.commitImport(plan.labels(for: .keepBoth), avatars: plan.avatars(for: .keepBoth))
        #expect(added == 4)

        let imported = store.selected!.entries.suffix(4)
        #expect(imported.map(\.avatar) == [nil, nil, nil, .emoji("🦊")])
        #expect(imported.allSatisfy { $0.avatar?.isPhoto != true })
        #expect(store.avatarStore!.totalBytes() == 0, "an import never writes to the avatars folder")
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me")
    }

    @Test("The store re-validates avatars itself: a .photo or a non-emoji handed to commitImport is dropped")
    func storeRefusesNonEmojiAvatars() {
        let s = CompletionFixtures.Scratch(); let store = s.store()
        let before = store.selected!.entries.count
        store.commitImport(["A", "B", "C", "D"], avatars: [.photo(fileName: AvatarFileName.make()),
                                                              .emoji("not an emoji"), .emoji("🚀"), nil])
        let added = Array(store.selected!.entries.dropFirst(before))
        #expect(added.map(\.avatar) == [nil, nil, .emoji("🚀"), nil])
    }

    @Test("Row cap: a million-row file is read only up to the cap")
    func rowCap() {
        let csv = (0..<(RosterImport.maxCSVRows + 500)).map { "\"N\($0)\",emoji,\"🦊\"" }.joined(separator: "\n")
        #expect(RosterImport.rows(fromCSV: csv).count == RosterImport.maxCSVRows)
    }

    @Test("Skip-duplicates keeps each remaining name's own avatar (arrays stay parallel)")
    func avatarsStayParallelWhenSkippingDuplicates() {
        let plan = RosterImport.plan(incoming: ["Anna", "Bob", "Cy"], existing: ["Bob"],
                                     avatars: [.emoji("🦊"), .emoji("🚀"), .emoji("🌈")])
        #expect(plan.labels(for: .skipDuplicates) == ["Anna", "Cy"])
        #expect(plan.avatars(for: .skipDuplicates) == [.emoji("🦊"), .emoji("🌈")])
        #expect(plan.avatars(for: .keepBoth).count == 3)
    }
}

// MARK: - C-1 / C-2 geometry, hub, fairness

@Suite("Wheel geometry, hero travel and hub (C-1, C-2)")
@MainActor
struct WheelHeroGeometryTests {

    @Test("The winner's segment sits at 12 o'clock, 80% of the radius out")
    func winnerAtPointer() {
        let count = 8, index = 3
        let rest = 360.0 - (Double(index) * 45 + 22.5)            // what DrawEngine lands on
        let c = CGPoint(x: 200, y: 200), r: CGFloat = 150
        let p = WheelGeometry.avatarCentre(index: index, count: count, angle: rest, wheelCentre: c, radius: r)
        #expect(abs(p.x - 200) < 0.001)
        #expect(abs(p.y - (200 - 0.8 * 150)) < 0.001)
    }

    @Test("Geometry agrees with where DrawEngine says the winner stopped, for any seed")
    func agreesWithEngine() {
        var rng = DrawEngineTests.SeededGenerator(seed: 42)
        for count in [3, 9, 26, 40] {
            let ids = (0..<count).map { _ in UUID() }
            for _ in 0..<50 {
                let start = Double.random(in: 0..<720, using: &rng)
                guard let plan = DrawEngine.plan(eligibleCount: count, currentAngle: start,
                                                 duration: 5, idForIndex: { ids[$0] }, using: &rng) else { Issue.record("no plan"); return }
                let p = WheelGeometry.avatarCentre(index: plan.winnerIndex, count: count, angle: plan.targetAngle,
                                                   wheelCentre: .zero, radius: 100)
                // Straight up (within the engine's jitter of <= 0.38 of half a segment).
                let off = atan2(Double(p.x), Double(-p.y)) * 180 / .pi
                #expect(abs(off) <= 0.38 * (360.0 / Double(count)) / 2 + 0.001, "count \(count) index \(plan.winnerIndex)")
                #expect(p.y < 0)
            }
        }
    }

    @Test("start(): the view rests at the target and is offset/scaled back onto the wheel avatar")
    func startTransform() {
        let s = HeroTravel.start(origin: CGPoint(x: 310, y: 90), originDiameter: 44,
                                 target: CGPoint(x: 400, y: 300), targetDiameter: 132)
        #expect(s.offset == CGSize(width: -90, height: -210))
        #expect(abs(s.scale - 44.0 / 132.0) < 1e-9)
        // Applying it to the resting centre lands on the origin.
        #expect(CGPoint(x: 400 + s.offset.width, y: 300 + s.offset.height) == CGPoint(x: 310, y: 90))
        #expect(HeroTravel.start(origin: .zero, originDiameter: 10, target: .zero, targetDiameter: 0).scale == 1)
    }

    @Test("Reduced Motion, or no avatar on the wheel, is a cross-fade; otherwise it travels")
    func style() {
        #expect(HeroTravel.style(reducedMotion: true, hasOrigin: true) == .crossfade)
        #expect(HeroTravel.style(reducedMotion: false, hasOrigin: false) == .crossfade)
        #expect(HeroTravel.style(reducedMotion: false, hasOrigin: true) == .travel)
        #expect(HeroTravel.duration == 0.45)
    }

    @Test("wheelOrigin: nil wherever the wheel draws no avatar; lifted size where it does")
    func wheelOrigin() {
        let c = CGPoint(x: 240, y: 240)
        func origin(_ mode: AvatarDisplayMode, count: Int = 12, side: CGFloat = 480) -> (centre: CGPoint, diameter: CGFloat)? {
            HeroTravel.wheelOrigin(WheelHeroOrigin(index: 2, count: count, angle: 0), mode: mode, side: side,
                                   wheelCentre: c, avatarLimit: SpinnerWheelView.avatarLimit)
        }
        #expect(origin(.nameOnly) == nil)
        #expect(origin(.avatarAndName, count: SpinnerWheelView.avatarLimit + 1) == nil)
        #expect(origin(.avatarAndName, side: 260) == nil)
        let hit = origin(.avatarAndName)
        let r = WheelGeometry.radius(side: 480)
        let d = WheelGeometry.fittedAvatarDiameter(count: 12, radius: r, side: 480)
        #expect(hit != nil)
        #expect(abs((hit?.diameter ?? 0) - d * 1.15) < 0.001)
    }

    @Test("Hub model: the last winner's entry, or nil when there is none or it was deleted")
    func lastWinnerEntry() {
        var roster = DrawRoster(name: "R", entries: [DrawEntry(label: "A", avatar: .emoji("🦊")), DrawEntry(label: "B")])
        #expect(roster.lastWinnerEntry == nil)
        roster.recordWin(entryID: roster.entries[0].id, label: "A")
        #expect(roster.lastWinnerEntry?.label == "A")
        roster.recordWin(entryID: roster.entries[1].id, label: "B")
        #expect(roster.lastWinnerEntry?.label == "B", "most recent")
        roster.entries.removeAll { $0.label == "B" }
        #expect(roster.lastWinnerEntry == nil, "a deleted entry is not shown")
    }

    @Test("Fairness: no avatar or display state can change who wins")
    func avatarsNeverInfluenceTheDraw() {
        let plain = (0..<20).map { DrawEntry(label: "E\($0)") }
        let dressed = plain.map { DrawEntry(id: $0.id, label: $0.label, avatar: .emoji("🦊")) }
        for seed in UInt64(1)...200 {
            var a = DrawEngineTests.SeededGenerator(seed: seed), b = DrawEngineTests.SeededGenerator(seed: seed)
            let p = DrawEngine.plan(eligibleCount: plain.count, currentAngle: 17, duration: 5,
                                    idForIndex: { plain[$0].id }, using: &a)
            let q = DrawEngine.plan(eligibleCount: dressed.count, currentAngle: 17, duration: 5,
                                    idForIndex: { dressed[$0].id }, using: &b)
            #expect(p == q)
        }
    }
}

// MARK: - C-1 / C-2 rendered

@Suite("Wheel rendering: avatar geometry and hub (C-1, C-2)", .serialized)
@MainActor
struct WheelHeroRenderTests {

    struct Pixels {
        let w: Int, h: Int, scale: CGFloat
        let data: [UInt8]                      // RGBA
        func differs(_ other: Pixels, in rect: CGRect, circle: Bool = true) -> Double {
            var total = 0, diff = 0
            let cx = rect.midX * scale, cy = rect.midY * scale, rad = rect.width * scale / 2
            for y in Int(max(0, (rect.minY * scale).rounded(.down)))..<min(h, Int((rect.maxY * scale).rounded(.up))) {
                for x in Int(max(0, (rect.minX * scale).rounded(.down)))..<min(w, Int((rect.maxX * scale).rounded(.up))) {
                    if circle, hypot(Double(x) - cx, Double(y) - cy) > rad { continue }
                    total += 1
                    let i = (y * w + x) * 4
                    if abs(Int(data[i]) - Int(other.data[i])) + abs(Int(data[i + 1]) - Int(other.data[i + 1]))
                        + abs(Int(data[i + 2]) - Int(other.data[i + 2])) > 24 { diff += 1 }
                }
            }
            return total == 0 ? 0 : Double(diff) / Double(total)
        }
    }

    private func render<V: View>(_ view: V, size: CGSize) throws -> Pixels {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color.haloBackground).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let img = try #require(rep.cgImage)
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try #require(CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                         bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, scale: CGFloat(img.width) / size.width, data: buf)
    }

    private let side: CGFloat = 480

    private func wheel(_ entries: [DrawEntry], mode: AvatarDisplayMode, highlight: UUID? = nil,
                       restAngle: Double = 0, hub: DrawEntry? = nil, plan: SpinPlan? = nil, start: Date? = nil) -> some View {
        SpinnerWheelView(entries: entries, plan: plan, spinStart: start, restAngle: restAngle, highlightID: highlight,
                         reducedMotion: true, rosterID: UUID(), avatarMode: mode, hubEntry: hub)
            .frame(width: side, height: side)
    }

    @Test("The hero's origin is exactly where the wheel draws the winner's avatar")
    func originMatchesDrawnAvatar() throws {
        // 30 entries: past the label limit (no labels), inside the avatar limit, so the ONLY difference
        // between avatar-only and name-only is the avatars themselves.
        let es = (0..<30).map { DrawEntry(label: "Person \($0)", avatar: .emoji(["🦊", "🚀", "🌈"][$0 % 3])) }
        let winner = 11
        let rest = 360.0 - (Double(winner) * 12 + 6)
        let withAvatars = try render(wheel(es, mode: .avatarOnly, highlight: es[winner].id, restAngle: rest), size: CGSize(width: side, height: side))
        let plain = try render(wheel(es, mode: .nameOnly, highlight: es[winner].id, restAngle: rest), size: CGSize(width: side, height: side))

        let o = try #require(HeroTravel.wheelOrigin(WheelHeroOrigin(index: winner, count: 30, angle: rest), mode: .avatarOnly,
                                                    side: side, wheelCentre: CGPoint(x: side / 2, y: side / 2),
                                                    avatarLimit: SpinnerWheelView.avatarLimit))
        let atOrigin = CGRect(x: o.centre.x - o.diameter * 0.4, y: o.centre.y - o.diameter * 0.4,
                              width: o.diameter * 0.8, height: o.diameter * 0.8)
        #expect(withAvatars.differs(plain, in: atOrigin) > 0.8, "an avatar must be drawn where HeroTravel says it is")

        // Same direction, halfway to the hub: no avatar there, so the two renders agree.
        let mid = CGPoint(x: side / 2, y: side / 2 + (o.centre.y - side / 2) * 0.4)
        let elsewhere = CGRect(x: mid.x - 8, y: mid.y - 8, width: 16, height: 16)
        #expect(withAvatars.differs(plain, in: elsewhere) < 0.05)
    }

    @Test("Hub: shows the previous winner's avatar at rest; unchanged while spinning, name-only, or no avatar")
    func hubAvatar() throws {
        let es = (0..<6).map { DrawEntry(label: "P\($0)") }
        let winner = DrawEntry(label: "Priya", avatar: .emoji("🦊"))
        let size = CGSize(width: side, height: side)
        let r = WheelGeometry.radius(side: side)
        let hubRect = CGRect(x: side / 2 - r * 0.15, y: side / 2 - r * 0.15, width: r * 0.3, height: r * 0.3)

        let base = try render(wheel(es, mode: .auto), size: size)
        let withHub = try render(wheel(es, mode: .auto, hub: winner), size: size)
        #expect(withHub.differs(base, in: hubRect) > 0.3, "hub must show the avatar at rest")

        // Only the hub changed.
        let wedge = CGRect(x: side / 2 + r * 0.5, y: side / 2 - 10, width: 20, height: 20)
        #expect(withHub.differs(base, in: wedge) < 0.02)

        // Name-only: F-051 hub (the count) is untouched.
        let nameOnly = try render(wheel(es, mode: .nameOnly), size: size)
        let nameOnlyHub = try render(wheel(es, mode: .nameOnly, hub: winner), size: size)
        #expect(nameOnlyHub.differs(nameOnly, in: hubRect) < 0.02)

        // A winner with no avatar under Automatic: the hub stays the count.
        let noAvatar = try render(wheel(es, mode: .auto, hub: DrawEntry(label: "Plain")), size: size)
        #expect(noAvatar.differs(base, in: hubRect) < 0.02)

        // While the wheel is turning the hub is the count again.
        let plan = DrawEngine.plan(for: es, currentAngle: 0, duration: 5)
        let spinningBase = try render(wheel(es, mode: .auto, plan: plan, start: Date()), size: size)
        let spinningHub = try render(wheel(es, mode: .auto, hub: winner, plan: plan, start: Date()), size: size)
        #expect(spinningHub.differs(spinningBase, in: hubRect) < 0.02)
    }
}

// MARK: - H-11 measurement

/// A headless measurement of the wheel's DRAWING cost, not a frame-rate trace. It renders the real
/// `SpinnerWheelView` offscreen through AppKit (CPU rasteriser, no display link, no GPU present), so
/// it says how much more the avatars cost to draw than the plain wheel — it cannot say whether a
/// given Mac holds 60 fps on screen. That needs Instruments on a real display (the wheel emits an
/// os_signpost interval per frame for exactly that). Prints a table; asserts only that it ran.
@Suite("Wheel draw-cost measurement (H-11)", .serialized)
@MainActor
struct WheelDrawCostMeasurement {

    private func medianMs(_ entries: [DrawEntry], mode: AvatarDisplayMode, roster: UUID, side: CGFloat, iterations: Int = 15) -> Double {
        let view = SpinnerWheelView(entries: entries, plan: nil, spinStart: nil, restAngle: 33, highlightID: nil,
                                    reducedMotion: true, rosterID: roster, avatarMode: mode, avatarLimitOverride: 1_000)
            .frame(width: side, height: side).background(Color.haloBackground)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)          // warm-up
        var times: [Double] = []
        for _ in 0..<iterations {
            host.setNeedsDisplay(host.bounds)
            let t0 = DispatchTime.now().uptimeNanoseconds
            host.cacheDisplay(in: host.bounds, to: rep)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        return times.sorted()[times.count / 2]
    }

    @Test("Draw cost at 10/20/40/60 entries, plain vs with photo avatars")
    func table() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-h11-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); AvatarImageCache.shared.store = nil }
        let store = AvatarStore(rootURL: root, detectFaces: false)
        let roster = UUID()
        let file = try store.importPhoto(data: CompletionFixtures.png(width: 400, height: 400), rosterID: roster)
        AvatarImageCache.shared.store = store
        for px in [20.0, 30, 40, 60, 80] { _ = AvatarImageCache.shared.photo(fileName: file, rosterID: roster, points: px) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        var lines = ["H-11 offscreen draw cost, median ms/frame (CPU raster, NOT on-screen fps):",
                     "  entries | side | plain  | avatars(photo) | ratio | avatar diameter pt"]
        for side in [480.0, 720.0] {
            for n in [10, 20, 40, 60] {
                let es = (0..<n).map { DrawEntry(label: "Person \($0)", avatar: .photo(fileName: file)) }
                let plain = medianMs(es, mode: .nameOnly, roster: roster, side: side)
                let withAv = medianMs(es, mode: .avatarAndName, roster: roster, side: side)
                let r = WheelGeometry.radius(side: side)
                let d = WheelGeometry.wheelAvatarDiameter(mode: .avatarAndName, count: n, side: side, radius: r, limit: 1_000)
                lines.append(String(format: "  %7d | %4.0f | %5.1f  | %14.1f | %4.2fx | %.0f", n, side, plain, withAv, withAv / max(plain, 0.001), d))
                #expect(plain > 0 && withAv > 0)
            }
        }
        let table = lines.joined(separator: "\n")
        print(table)
        if let dir = ProcessInfo.processInfo.environment["HALO_RENDER_DIR"] {
            try? table.write(toFile: dir + "/h11-draw-cost.txt", atomically: true, encoding: .utf8)
        }
    }
}
