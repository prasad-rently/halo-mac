import Foundation

// MARK: - DriveAccessManager  (F-051)
//
// Persists a security-scoped bookmark per drive (keyed by `driveKey`) so
// that once a user grants Halo access to an external drive via NSOpenPanel,
// every later mount of that same drive can be re-accessed silently — no
// repeat prompt, and (with the `com.apple.security.files.bookmarks.app-scope`
// entitlement) the grant survives an app relaunch, not just the process that
// created it.

actor DriveAccessManager {

    private var bookmarks: [String: Data] = [:]   // driveKey → bookmark data
    private let bookmarksFileURL: URL

    init() throws {
        let dir = try DriveIndexStore.storeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        bookmarksFileURL = dir.appendingPathComponent("drive-bookmarks.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: bookmarksFileURL),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else { return }
        bookmarks = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: bookmarksFileURL, options: .atomic)
    }

    func hasBookmark(driveKey: String) -> Bool {
        bookmarks[driveKey] != nil
    }

    /// Creates a security-scoped bookmark from a URL the user just granted
    /// (e.g. via `NSOpenPanel`) and persists it under `driveKey`.
    func saveBookmark(driveKey: String, grantedURL: URL) throws {
        let data = try grantedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        bookmarks[driveKey] = data
        persist()
    }

    func forgetBookmark(driveKey: String) {
        bookmarks.removeValue(forKey: driveKey)
        persist()
    }

    /// Resolves the stored bookmark and starts security-scoped access.
    /// Returns `nil` if there's no bookmark, or if access couldn't be
    /// started. The caller MUST call `stopAccessing(_:)` on the returned
    /// URL when done — every call site should pair this with a `defer`.
    func resolveAndStartAccessing(driveKey: String) -> URL? {
        guard let data = bookmarks[driveKey] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Bookmark can't be resolved at all (e.g. drive reformatted).
            return nil
        }

        if isStale {
            // Self-heal: re-derive a fresh bookmark from the resolved URL
            // rather than silently keeping a stale one around.
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[driveKey] = refreshed
                persist()
            }
        }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
