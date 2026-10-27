import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - AvatarStore (F-053)
//
// Where a participant's photo lives, and the only code that reads, writes or deletes those
// files. A participant's face is third-party personal data, so the rules are strict:
//
//  • Photos are **copied in** — Halo keeps its own downsampled JPEG (≤256 px) and never a path
//    to the original, which may move, sit on an unmounted volume, or be outside the sandbox.
//  • Nothing here touches the network.
//  • Every file name is untrusted (a roster JSON can be hand-edited): it must be `<UUID>.jpg`
//    and must resolve **inside** the roster's own folder, or it is treated as "no photo".
//  • Decoding is bounded *before* it happens (file size, then pixel dimensions from the header)
//    so a decompression bomb is refused rather than inflated.
//
// A stateless `final class`, not an actor: it holds only a root URL, and CLAUDE.md's rule for
// stateless computation is a class — callers run the heavy parts on a detached task.

final class AvatarStore: @unchecked Sendable {

    static let maxFileBytes: Int64 = 50_000_000
    static let maxPixels = 100_000_000
    /// Edge of the stored square, in pixels.
    static let storedPixelSize = 256

    enum AvatarError: Error, Equatable, LocalizedError {
        case notAnImage, fileTooLarge, tooManyPixels, decodeFailed, writeFailed

        var errorDescription: String? {
            switch self {
            case .notAnImage: return "That file isn't a picture Halo can read."
            case .fileTooLarge: return "That picture is larger than 50 MB."
            case .tooManyPixels: return "That picture is larger than 100 megapixels."
            case .decodeFailed: return "Halo couldn't decode that picture."
            case .writeFailed: return "Halo couldn't save the avatar."
            }
        }
    }

    let rootURL: URL
    /// Instance copy of `maxPixels` so a test can lower it; production always uses the default.
    let pixelLimit: Int
    /// Face-centred crop via Vision. On by default; tests that don't exercise it turn it off, because
    /// concurrent Vision requests inside a test host can stall (see `largestFace`).
    let detectFaces: Bool
    /// How long an import will wait for Vision before cropping the middle of the picture instead.
    let faceTimeout: TimeInterval

    init(rootURL: URL, pixelLimit: Int = AvatarStore.maxPixels,
         detectFaces: Bool = true, faceTimeout: TimeInterval = 4) {
        self.rootURL = rootURL
        self.pixelLimit = pixelLimit
        self.detectFaces = detectFaces
        self.faceTimeout = faceTimeout
    }

    // MARK: Async wrappers
    //
    // Importing blocks (ImageIO decode, and Vision waits on its own queue), so it must not run on
    // Swift concurrency's cooperative pool — a handful of blocked threads there starves everything
    // else, the failure CLAUDE.md gotcha 20 describes for `ShellReader`. These hop to a GCD thread.

    func importPhotoAsync(from source: URL, rosterID: UUID) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try self.importPhoto(from: source, rosterID: rosterID) })
            }
        }
    }

    func importPhotoAsync(data: Data, rosterID: UUID) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try self.importPhoto(data: data, rosterID: rosterID) })
            }
        }
    }

    // MARK: Paths

    func directory(for rosterID: UUID) -> URL {
        rootURL.appendingPathComponent(rosterID.uuidString, isDirectory: true)
    }

    /// The file for `fileName` inside `rosterID`'s folder — or nil if the name isn't a name Halo
    /// would have generated, or resolves anywhere else.
    ///
    /// `allowLinkedFile: false` (the default, used for every read) also refuses a file that is itself
    /// a symlink, so a planted link can't turn "show this avatar" into "read that other file".
    func url(for fileName: String, rosterID: UUID, allowLinkedFile: Bool = false) -> URL? {
        guard AvatarFileName.isValid(fileName) else { return nil }
        let dir = directory(for: rosterID)
        let candidate = dir.appendingPathComponent(fileName)
        guard Self.isInside(candidate, dir), resolvesInsideRoot(candidate) else { return nil }
        if !allowLinkedFile, Self.isSymbolicLink(candidate) { return nil }
        return candidate
    }

    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let d = directory.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// `isInside` is a *textual* check; a symlinked roster folder (`root/<id>` -> `~/Documents`) passes
    /// it while pointing anywhere. This one resolves the symlinks in the item's **parent** chain and
    /// requires the real parent to sit in the real root. The item itself is deliberately not resolved:
    /// removing a symlink removes the link, never its target.
    private func resolvesInsideRoot(_ url: URL) -> Bool {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return parent == root || parent.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    // MARK: Import

    /// Imports a photo from a file the user chose. Returns the generated file name.
    func importPhoto(from source: URL, rosterID: UUID) throws -> String {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.maxFileBytes else { throw AvatarError.fileTooLarge }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw AvatarError.notAnImage }
        return try importPhoto(source: src, rosterID: rosterID)
    }

    /// Imports image bytes (pasted or dropped). Same bounds as a file.
    func importPhoto(data: Data, rosterID: UUID) throws -> String {
        guard Int64(data.count) <= Self.maxFileBytes else { throw AvatarError.fileTooLarge }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw AvatarError.notAnImage }
        return try importPhoto(source: src, rosterID: rosterID)
    }

    private func importPhoto(source src: CGImageSource, rosterID: UUID) throws -> String {
        // 1. Is it an image at all, and how big — from the header, before any pixel is decoded.
        guard let typeID = CGImageSourceGetType(src) as String?,
              UTType(typeID)?.conforms(to: .image) == true else { throw AvatarError.notAnImage }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw AvatarError.decodeFailed }
        guard w * h <= pixelLimit else { throw AvatarError.tooManyPixels }

        // 2. Decode straight to a bounded thumbnail (orientation applied) — a 60 MP photo is
        //    never fully inflated.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { throw AvatarError.decodeFailed }

        // 3. Centre the square on a face when Vision finds one, the middle of the picture otherwise.
        let rect = AvatarCrop.squareRect(imageWidth: CGFloat(thumb.width), imageHeight: CGFloat(thumb.height),
                                         face: detectFaces ? largestFace(in: thumb) : nil)
        guard let cropped = thumb.cropping(to: rect.integral),
              let square = Self.scaled(cropped, to: Self.storedPixelSize),
              let jpeg = Self.jpegData(square) else { throw AvatarError.decodeFailed }

        // 4. Write under a fresh name — replacing an avatar never reuses a name, so no cache
        //    can hold the old picture under the new one's key.
        let fileName = AvatarFileName.make()
        guard let dest = url(for: fileName, rosterID: rosterID) else { throw AvatarError.writeFailed }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: dest, options: .atomic)
        } catch { throw AvatarError.writeFailed }
        return fileName
    }

    /// Largest detected face, in top-left-origin pixels of `image`, or nil. Vision runs on the
    /// device; a failure — or Vision not answering within `faceTimeout` — simply falls back to the
    /// centre crop, so a stalled framework can never leave the picker on "Importing…" forever.
    private func largestFace(in image: CGImage) -> CGRect? {
        final class Box: @unchecked Sendable { var value: CGRect?; let lock = NSLock() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectFaceRectanglesRequest()
            var face: CGRect?
            if (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
               let best = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                      < $1.boundingBox.width * $1.boundingBox.height }) {
                let b = best.boundingBox            // normalised, origin bottom-left
                face = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            }
            box.lock.lock(); box.value = face; box.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + faceTimeout) == .success else { return nil }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }

    private static func scaled(_ image: CGImage, to side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // JPEG has no alpha: flatten a transparent PNG onto the app's own background, not black-hole transparent.
        ctx.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Read

    /// The stored photo, decoded to at most `maxPixel` on its long edge. Nil for an invalid name.
    func loadImage(fileName: String, rosterID: UUID, maxPixel: Int) -> CGImage? {
        guard let url = url(for: fileName, rosterID: rosterID),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: Remove
    //
    // Permanent removal, not `trashItem`: these are Halo's own downsampled copies, and trashing
    // up to 500 of them would only litter the user's Trash. This is the owner-approved exception
    // (2026-10-27, F-053 NFR-S4) to the project's trashItem-only rule — confined to this root,
    // and every call below checks containment first. Nothing else in Halo may use it.

    private func removeInsideRoot(_ url: URL) {
        // Textual containment AND real containment: a symlinked roster folder must not let a
        // `<UUID>.jpg` that lives elsewhere be removed through it. A symlink *itself* is removed as a
        // link (FileManager unlinks it), never followed.
        guard Self.isInside(url, rootURL), resolvesInsideRoot(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func delete(fileName: String, rosterID: UUID) {
        // `allowLinkedFile`: a planted link under a photo's name may be removed (as a link).
        guard let url = url(for: fileName, rosterID: rosterID, allowLinkedFile: true) else { return }
        removeInsideRoot(url)
    }

    func deleteAll(rosterID: UUID) {
        removeInsideRoot(directory(for: rosterID))
    }

    /// Removes every stored photo (Settings → "Clear all photos").
    func deleteEverything() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for item in items { removeInsideRoot(item) }
    }

    /// Deletes photo files no entry references, and folders for rosters that no longer exist.
    /// Only ever looks at UUID-named folders and `<UUID>.jpg` files, so a stray file the user put
    /// there is left alone. Returns how many files it removed.
    @discardableResult
    func sweepOrphans(referenced: [UUID: Set<String>]) -> Int {
        let fm = FileManager.default
        guard let rosterDirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for dir in rosterDirs {
            guard let rosterID = UUID(uuidString: dir.lastPathComponent) else { continue }
            guard let keep = referenced[rosterID] else {
                if !Self.isSymbolicLink(dir) { removed += (try? fm.contentsOfDirectory(atPath: dir.path).count) ?? 0 }
                removeInsideRoot(dir)
                continue
            }
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                if AvatarFileName.isValid(name), !keep.contains(name) {
                    removeInsideRoot(file); removed += 1
                }
            }
        }
        return removed
    }

    /// Copies a photo into another roster's folder under a fresh name (roster duplication).
    func copyPhoto(fileName: String, from source: UUID, to target: UUID) -> String? {
        guard let src = url(for: fileName, rosterID: source) else { return nil }
        let newName = AvatarFileName.make()
        guard let dest = url(for: newName, rosterID: target) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dest)
            return newName
        } catch { return nil }
    }

    /// Total bytes of stored photos, for Settings.
    func totalBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in e { sum += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return sum
    }
}
