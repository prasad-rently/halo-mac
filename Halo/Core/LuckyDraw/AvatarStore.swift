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
        /// The file's size could not be read, so the 50 MB cap cannot be checked (H-10: fail closed).
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notAnImage: return "That file isn't a picture Halo can read."
            case .fileTooLarge: return "That picture is larger than 50 MB."
            case .tooManyPixels: return "That picture is larger than 100 megapixels."
            case .decodeFailed: return "Halo couldn't decode that picture."
            case .writeFailed: return "Halo couldn't save the avatar."
            case .unreadable: return "Halo couldn't read that file's size, so it wasn't imported."
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
    /// How the size of a source file is read. Injectable so a test can make it fail; production
    /// always asks the file system.
    let fileSizeReader: @Sendable (URL) -> Int64?

    init(rootURL: URL, pixelLimit: Int = AvatarStore.maxPixels,
         detectFaces: Bool = true, faceTimeout: TimeInterval = 4,
         fileSizeReader: @escaping @Sendable (URL) -> Int64? = AvatarStore.fileSystemSize) {
        self.rootURL = rootURL
        self.pixelLimit = pixelLimit
        self.detectFaces = detectFaces
        self.faceTimeout = faceTimeout
        self.fileSizeReader = fileSizeReader
    }

    static func fileSystemSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
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
        guard let fileName = AvatarFileName.normalized(fileName) else { return nil }
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
        // Fail closed (H-10): a size that cannot be read is NOT "0 bytes". Treating it as zero let a
        // file whose attributes were unavailable skip the cap entirely.
        guard let size = fileSizeReader(source) else { throw AvatarError.unreadable }
        guard size <= Self.maxFileBytes else { throw AvatarError.fileTooLarge }
        try Self.checkHeader(ofFile: source, pixelLimit: pixelLimit)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw AvatarError.notAnImage }
        return try importPhoto(source: src, rosterID: rosterID)
    }

    /// Imports image bytes (pasted or dropped). Same bounds as a file.
    func importPhoto(data: Data, rosterID: UUID) throws -> String {
        guard Int64(data.count) <= Self.maxFileBytes else { throw AvatarError.fileTooLarge }
        try Self.checkHeader(ofData: data, pixelLimit: pixelLimit)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw AvatarError.notAnImage }
        return try importPhoto(source: src, rosterID: rosterID)
    }

    /// PNG and TIFF declare their dimensions in a few header bytes Halo can read itself, so the pixel
    /// limit for those two does not depend on ImageIO's say-so (H-10). Other formats fall through to
    /// the ImageIO property check in `importPhoto(source:)`.
    private static func checkHeader(ofData data: Data, pixelLimit: Int) throws {
        try check(ImageHeaderProbe.probe(read: { off, n in
            guard off >= 0, off < data.count else { return nil }
            return data.subdata(in: off..<min(data.count, off + n))
        }), pixelLimit: pixelLimit)
    }

    private static func checkHeader(ofFile url: URL, pixelLimit: Int) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AvatarError.unreadable }
        defer { try? handle.close() }
        try check(ImageHeaderProbe.probe(read: { off, n in
            guard off >= 0, (try? handle.seek(toOffset: UInt64(off))) != nil else { return nil }
            return try? handle.read(upToCount: n)
        }), pixelLimit: pixelLimit)
    }

    private static func check(_ result: ImageHeaderProbe.Result, pixelLimit: Int) throws {
        switch result {
        case .notPNGOrTIFF: return
        case .malformed: throw AvatarError.decodeFailed
        case .size(let w, let h):
            guard w > 0, h > 0 else { throw AvatarError.decodeFailed }
            guard w <= pixelLimit / h else { throw AvatarError.tooManyPixels }      // w*h > limit, overflow-safe
        }
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
            // Compared in one canonical case (H-10): `abc.jpg` and `ABC.jpg` are one file on APFS.
            let keepNormalized = Set(keep.compactMap(AvatarFileName.normalized))
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                if let canonical = AvatarFileName.normalized(name), !keepNormalized.contains(canonical) {
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

// MARK: - ImageHeaderProbe (H-10)

/// Reads the pixel dimensions of a PNG or TIFF straight from its header bytes — no decoding, no
/// ImageIO. A decompression bomb is a tiny file that *declares* a huge size, so the declaration is
/// exactly what has to be checked, and it has to be checked before anything inflates it.
///
/// `read(offset, count)` returns up to `count` bytes at `offset`, or nil when that is out of range.
enum ImageHeaderProbe {
    enum Result: Equatable {
        /// Neither a PNG nor a TIFF signature — the caller falls back to ImageIO's own properties.
        case notPNGOrTIFF
        /// A PNG/TIFF signature, but a header that cannot be read to a width and height
        /// (truncated, BigTIFF, absurd IFD). Fail closed.
        case malformed
        case size(width: Int, height: Int)
    }

    static func probe(read: (Int, Int) -> Data?) -> Result {
        guard let head = read(0, 8), head.count == 8 else { return .notPNGOrTIFF }
        let b = [UInt8](head)
        if b == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return png(read) }
        let little = b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0
        let big = b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A
        if little || big { return tiff(read, littleEndian: little, head: b) }
        return .notPNGOrTIFF
    }

    /// IHDR is always the first chunk: length(4) "IHDR"(4) width(4, BE) height(4, BE).
    private static func png(_ read: (Int, Int) -> Data?) -> Result {
        guard let d = read(8, 16), d.count == 16 else { return .malformed }
        let b = [UInt8](d)
        guard Array(b[4..<8]) == Array("IHDR".utf8) else { return .malformed }
        let w = Int(b[8]) << 24 | Int(b[9]) << 16 | Int(b[10]) << 8 | Int(b[11])
        let h = Int(b[12]) << 24 | Int(b[13]) << 16 | Int(b[14]) << 8 | Int(b[15])
        return .size(width: w, height: h)
    }

    /// Walks IFD 0 for tags 256 (ImageWidth) and 257 (ImageLength).
    private static func tiff(_ read: (Int, Int) -> Data?, littleEndian le: Bool, head: [UInt8]) -> Result {
        func u16(_ b: [UInt8], _ o: Int) -> Int { le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ b: [UInt8], _ o: Int) -> Int {
            le ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
               : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        let ifd = u32(head, 4)
        guard ifd >= 8, let c = read(ifd, 2), c.count == 2 else { return .malformed }
        let count = u16([UInt8](c), 0)
        guard count > 0, count <= 512, let entries = read(ifd + 2, count * 12), entries.count == count * 12
        else { return .malformed }
        let e = [UInt8](entries)
        var width: Int?, height: Int?
        for i in 0..<count {
            let o = i * 12
            let tag = u16(e, o), type = u16(e, o + 2)
            guard tag == 256 || tag == 257 else { continue }
            // SHORT (3) holds its value in the first two bytes of the value field, LONG (4) in all four.
            let value: Int
            switch type {
            case 3: value = u16(e, o + 8)
            case 4: value = u32(e, o + 8)
            default: return .malformed
            }
            if tag == 256 { width = value } else { height = value }
        }
        guard let w = width, let h = height else { return .malformed }
        return .size(width: w, height: h)
    }
}
