import Foundation
import UniformTypeIdentifiers

/// Turns what another app put on the share sheet (`NSItemProvider`s) into a staged batch.
///
/// This is the whole of what the Share Extension *does*: read the providers, copy bytes into
/// the App Group container, write a manifest. No network, no device list, no send — sending
/// happens later, in the app, after the user picks a device and taps Send.
public enum ShareIngest {

    public struct Result: Equatable, Sendable {
        public var batch: StagedBatch?
        public var rejections: [StagingRejection]
        public var staged: Int { batch?.items.count ?? 0 }
    }

    public static func stage(providers: [NSItemProvider], into store: ShareStagingStore) async -> Result {
        let builder: BatchBuilder
        do { builder = try store.makeBatchBuilder() }
        catch { return Result(batch: nil, rejections: [(error as? StagingRejection) ?? .storageUnavailable]) }

        var rejections: [StagingRejection] = []
        // Sequential on purpose: bounds disk and memory, and keeps the user's order.
        for provider in providers {
            do { try await ingest(provider, into: builder) }
            catch { rejections.append((error as? StagingRejection) ?? .unreadable(provider.suggestedName ?? "an item")) }
        }
        let batch: StagedBatch?
        do { batch = try builder.commit() }
        catch { return Result(batch: nil, rejections: rejections + [(error as? StagingRejection) ?? .storageUnavailable]) }
        return Result(batch: batch, rejections: rejections)
    }

    // MARK: One provider

    static func ingest(_ provider: NSItemProvider, into builder: BatchBuilder) async throws {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let label = provider.suggestedName ?? "an item"

        // 1. A file URL (Files, Finder-style shares): copy what it points at.
        if let t = types.first(where: { $0.conforms(to: .fileURL) }) {
            if let url = try? await loadURL(provider, t), url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try builder.addFile(copying: url, suggestedName: provider.suggestedName)
                return
            }
        }
        // 2. A web link: staged as a small text file — never fetched.
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) {
            let t = types.first { $0.conforms(to: .url) }!
            if let url = try? await loadURL(provider, t) {
                try builder.addLink(url)
                return
            }
        }
        // 3. Binary content with a concrete type: photos, video, PDFs, documents. The OS hands
        //    over a temp file, copied (not read into memory) inside the callback.
        if let t = types.first(where: { isFileLike($0) }) {
            try await copyFileRepresentation(of: provider, type: t, into: builder)
            return
        }
        // 4. Text.
        if let t = types.first(where: { $0.conforms(to: .text) }) {
            if let text = try? await loadText(provider, t) { try builder.addText(text); return }
        }
        // 5. Last resort: anything that will give us a file.
        if let t = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .item) }) {
            try await copyFileRepresentation(of: provider, type: t, into: builder)
            return
        }
        throw StagingRejection.unsupportedType(types.first?.localizedDescription ?? label)
    }

    /// Image / movie / audio / PDF / archive / generic document — i.e. `data` that isn't text or a URL.
    private static func isFileLike(_ t: UTType) -> Bool {
        guard t.conforms(to: .data) || t.conforms(to: .item) else { return false }
        if t.conforms(to: .text) || t.conforms(to: .url) || t.conforms(to: .fileURL) { return false }
        if t.conforms(to: .directory) || t.conforms(to: .folder) { return false }
        return true
    }

    private static func copyFileRepresentation(of provider: NSItemProvider, type: UTType, into builder: BatchBuilder) async throws {
        let fallbackName = provider.suggestedName
        let ext = type.preferredFilenameExtension
        let mime = type.preferredMIMEType
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    cont.resume(throwing: StagingRejection.unreadable(fallbackName ?? "an item")); return
                }
                do {
                    var name = fallbackName ?? url.lastPathComponent
                    if let ext, (name as NSString).pathExtension.isEmpty { name += "." + ext }
                    try builder.addFile(copying: url, suggestedName: name, mimeType: mime)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, _ type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let url = item as? URL { cont.resume(returning: url) }
                else if let s = item as? String, let url = URL(string: s) { cont.resume(returning: url) }
                else if let d = item as? Data, let s = String(data: d, encoding: .utf8), let url = URL(string: s) { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? StagingRejection.unreadable("a link")) }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider, _ type: UTType) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let s = item as? String { cont.resume(returning: s) }
                else if let d = item as? Data, let s = String(data: d, encoding: .utf8) { cont.resume(returning: s) }
                else { cont.resume(throwing: error ?? StagingRejection.emptyText) }
            }
        }
    }
}
