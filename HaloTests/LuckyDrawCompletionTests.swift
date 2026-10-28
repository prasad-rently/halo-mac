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
