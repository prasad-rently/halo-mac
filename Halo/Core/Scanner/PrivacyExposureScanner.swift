import Foundation

// MARK: - Privacy Exposure Scanner (F-018)
//
// Read-only scan of user-writable locations (Downloads, Documents, Desktop — iCloud
// Drive's local folder is opt-in, passed in explicitly by the caller) looking for
// sensitive data left in plain files: credit card numbers, cloud/API keys, SSH
// private keys, and SSNs. All matching happens in-process via `PrivacyPatternDatabase`
// — zero network calls during a scan.
//
// This is find-only. There is no delete/quarantine action anywhere in this type —
// results only ever support "Reveal in Finder". The user decides what to do next.
//
// Safety: only `PrivacyExposureFinding.redactedPreview` (built by
// `PrivacyPatternDatabase`) is ever surfaced. The raw file text read here is never
// logged, printed, or persisted — it lives only in a local `String` for the
// duration of one file's pattern evaluation, then is dropped.
actor PrivacyExposureScanner {

    // MARK: - Scan Events

    enum ScanEvent: Sendable {
        case progress(filesScanned: Int, currentPath: String)
        case finding(PrivacyExposureFinding)
        case completed(filesScanned: Int, findingsCount: Int, truncated: Bool)
        case error(String)
    }

    // MARK: - Configuration

    struct ScanConfig: Sendable {
        var maxDepth: Int = 8
        /// Hard ceiling on files examined.
        ///
        /// `maxDepth` alone does not bound the work: `~/Documents` on a
        /// developer machine routinely holds hundreds of thousands of files
        /// within 8 levels, and every non-binary one under the size cap was read
        /// into a String and matched against every pattern. Sibling F-025 caps
        /// enumeration at 20,000 for the same reason. `.completed` reports
        /// whether the cap was reached, so a truncated scan is never presented
        /// as exhaustive.
        var maxFiles: Int = 20_000
        /// Files larger than this are skipped outright — keeps scans fast and avoids
        /// loading huge files into memory.
        var maxFileSizeBytes: Int64 = 10 * 1024 * 1024
        /// Bytes peeked from the front of a file to run the binary/null-byte heuristic.
        var peekBytes: Int = 8192
    }

    private let patternDB = PrivacyPatternDatabase.shared

    // MARK: - Directories never worth descending into
    //
    // Not part of the spec's binary-file rule, but a plain necessity for scan speed:
    // these are either enormous (node_modules, Library, DerivedData), system/version
    // control bookkeeping that never holds user secrets in a meaningful way (.git,
    // .Trash, Spotlight/FSEvents metadata), or both.
    private static let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".Trash", "Library", ".build", "DerivedData",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ".npm", ".cache", "Pods", ".Trashes"
    ]

    // MARK: - Binary file extensions (skip without reading)
    //
    // Per spec: images / video / audio / archives are skipped by extension. Office
    // documents and PDFs are zip-based or otherwise binary-packed formats, so they're
    // included here too — the null-byte peek is the fallback for anything not covered
    // by this list (e.g. a misnamed binary, or a compiled tool with no extension).
    private static let binaryExtensions: Set<String> = [
        // Images
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "ico", "webp",
        "raw", "psd", "ai", "svg",
        // Video
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm",
        // Audio
        "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma",
        // Archives / disk images
        "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "dmg", "pkg", "iso", "xip",
        // Compiled / binary
        "exe", "dll", "so", "dylib", "bin", "o", "a", "class", "jar", "app",
        // Fonts
        "ttf", "otf", "woff", "woff2",
        // Binary-packed documents (zip containers / non-plaintext)
        "pdf", "docx", "xlsx", "pptx", "numbers", "pages", "keynote", "sqlite", "db"
    ]

    // MARK: - Main Scan Entry Point

    /// `bufferingNewest` rather than the default `.unbounded`: one `.progress`
    /// event is yielded per file examined, and against a slow consumer an
    /// unbounded buffer accumulates every one of them in memory. Progress is
    /// disposable by nature — the newest is the only one worth showing.
    func scan(locations: [URL], config: ScanConfig = ScanConfig()) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                await self.patternDB.load()

                // An empty table matches nothing, so every scan would report
                // "No exposed sensitive data found" in green — a security
                // feature reporting all-clear because it failed to load is the
                // worst possible failure mode.
                guard await self.patternDB.patternCount > 0 else {
                    continuation.yield(.error("Halo couldn't load its privacy pattern database, so nothing was scanned."))
                    continuation.finish()
                    return
                }

                var filesScanned = 0
                var findingsCount = 0
                var hitFileCap = false

                for root in locations {
                    guard !Task.isCancelled else { break }
                    await self.traverse(
                        url: root,
                        depth: 0,
                        config: config,
                        onProgress: { path in
                            filesScanned += 1
                            continuation.yield(.progress(filesScanned: filesScanned, currentPath: path))
                        },
                        onFinding: { finding in
                            findingsCount += 1
                            continuation.yield(.finding(finding))
                        },
                        shouldStop: {
                            guard filesScanned >= config.maxFiles else { return false }
                            hitFileCap = true
                            return true
                        }
                    )
                    if hitFileCap { break }
                }

                continuation.yield(.completed(filesScanned: filesScanned,
                                              findingsCount: findingsCount,
                                              truncated: hitFileCap))
                continuation.finish()
            }

            // The producer above is an unstructured Task, so it is not a child
            // of the consumer and the `Task.isCancelled` checks inside
            // `traverse` were never true when the consumer cancelled.
            // `cancelPrivacyScan()` reset the UI while the recursive walk over
            // Downloads/Documents/Desktop carried on to completion, reading and
            // pattern-matching every file. The cancel test passed visually while
            // the work kept running.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Traversal

    private func traverse(
        url: URL,
        depth: Int,
        config: ScanConfig,
        onProgress: @escaping (String) -> Void,
        onFinding: @escaping (PrivacyExposureFinding) -> Void,
        shouldStop: @escaping () -> Bool
    ) async {
        guard !Task.isCancelled, depth <= config.maxDepth, !shouldStop() else { return }

        let fm = FileManager.default
        // `.skipsHiddenFiles` is deliberately NOT passed — scanning dotfiles is
        // the point, since `.env` and `.npmrc` are where credentials actually
        // live. `.skipsPackageDescendants` is passed but does nothing here: it
        // only applies to `enumerator(at:)`, and this recurses manually, so
        // packages are filtered explicitly in the directory branch below.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                       .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return }

        for entry in entries {
            guard !Task.isCancelled, !shouldStop() else { return }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isSymbolicLink == true { continue }   // never follow symlinks

            if values.isDirectory == true {
                if Self.excludedDirectoryNames.contains(entry.lastPathComponent) { continue }
                // Packages (.app, .rtfd, .photoslibrary) are directories, and
                // recursing manually means `.skipsPackageDescendants` never
                // applied — so app bundles were walked in full, costing time and
                // surfacing findings inside bundles the user cannot act on.
                if values.isPackage == true { continue }
                await traverse(url: entry, depth: depth + 1, config: config,
                               onProgress: onProgress, onFinding: onFinding,
                               shouldStop: shouldStop)
                continue
            }

            guard values.isRegularFile == true else { continue }
            onProgress(entry.lastPathComponent)

            guard await shouldScan(entry, values: values, config: config) else { continue }

            let hits = await evaluateFile(entry, config: config)
            for hit in hits {
                onFinding(PrivacyExposureFinding(
                    category: hit.category,
                    riskLevel: hit.risk,
                    fileURL: entry,
                    redactedPreview: hit.redactedPreview,
                    modifiedDate: values.contentModificationDate,
                    fileSizeBytes: Int64(values.fileSize ?? 0)
                ))
            }
        }
    }

    // MARK: - Skip filters

    private func shouldScan(_ url: URL, values: URLResourceValues, config: ScanConfig) async -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.binaryExtensions.contains(ext) { return false }

        let size = Int64(values.fileSize ?? 0)
        if size <= 0 || size > config.maxFileSizeBytes { return false }

        // Peek the first few KB for a null byte — a reliable, cheap binary heuristic
        // that also catches misnamed/extension-less binaries the list above misses.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let peek = (try? handle.read(upToCount: config.peekBytes)) ?? Data()
        if peek.contains(0) { return false }

        return true
    }

    private func evaluateFile(_ url: URL, config: ScanConfig) async -> [PrivacyPatternHit] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        // Latin-1 maps all 256 byte values, so this decode cannot fail and the
        // old `else { return [] }` branch — with its comment about treating
        // undecodable data as binary — was unreachable. Anything surviving the
        // null-byte peek in `shouldScan` is scanned regardless, which is the
        // real behaviour; the guard against binary content is that peek, not
        // this decode.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return [] }
        return await patternDB.evaluate(text: text)
    }
}
