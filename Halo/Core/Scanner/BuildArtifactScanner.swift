import Foundation

// MARK: - F-054 Build Artifact Cleaner — engine
//
// Finds regenerable build output (node_modules, target/, .build/, build/ ...) across the
// user's project folders. Spec: docs/specs/F-054-build-artifact-cleaner.md.
//
// The hard part is not scanning, it is NEVER OFFERING something that is not regenerable:
//   D2  detection needs a MARKER PAIR (a `build/` with no project file beside it is never offered);
//   D3  if the project is in a git work tree, the artifact must be git-IGNORED and hold no
//       tracked file (`GitGate`, via `ShellReader` — the only sanctioned subprocess path);
//   -   symlinks are never followed and never offered; `~/Library`, `~/Downloads` (D-03),
//       `~/.Trash`, system folders, Xcode Archives and Simulator runtimes are never scanned.
// The scanner reads names, sizes, modification dates and marker existence only — no file contents.

// MARK: - Catalogue (data, bundled JSON)

enum BuildArtifactRegenClass: String, Codable, Sendable, Comparable {
    case safe, needsNetwork, caution

    private var rank: Int { switch self { case .safe: return 0; case .needsNetwork: return 1; case .caution: return 2 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    var label: String {
        switch self { case .safe: return "Safe"; case .needsNetwork: return "Needs network"; case .caution: return "Caution" }
    }
}

struct BuildArtifactCatalog: Codable, Sendable {
    struct Rule: Codable, Sendable {
        let name: String
        let regenClass: BuildArtifactRegenClass
        /// Only offered when git positively says the directory is ignored (e.g. `dist/`).
        let requiresGitIgnore: Bool?
        /// A file that must exist INSIDE the artifact directory (e.g. `pyvenv.cfg`).
        let insideMarker: String?
    }
    struct Toolchain: Codable, Sendable {
        let id: String
        let name: String
        let enabled: Bool
        /// Any one of these must exist beside the artifact. `*.ext` matches by suffix.
        let markers: [String]
        let regenHint: String
        let artifacts: [Rule]
    }
    let version: Int
    let toolchains: [Toolchain]

    /// One entry of a directory listing — the only thing the pure matcher sees.
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let modified: Date?
    }

    struct Match: Sendable {
        let toolchain: Toolchain
        let rule: Rule
        let regenClass: BuildArtifactRegenClass
        let markerNames: [String]
    }

    static func load(bundle: Bundle = .main) -> BuildArtifactCatalog? {
        guard let url = bundle.url(forResource: "build-artifact-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BuildArtifactCatalog.self, from: data)
    }

    private static func markerMatches(_ marker: String, _ name: String) -> Bool {
        marker.hasPrefix("*") ? name.hasSuffix(String(marker.dropFirst())) && name.count > marker.count - 1
                              : name == marker
    }

    /// Pure: which artifact directories in a listing are backed by a marker pair?
    /// `insideMarkerExists(artifactName, marker)` answers the "marker inside the directory" rules.
    /// A name with no marker sibling never matches (D2). Symlinked markers/artifacts never count.
    /// When two toolchains claim the same directory the more conservative class wins.
    func matches(in entries: [Entry],
                 insideMarkerExists: (String, String) -> Bool = { _, _ in false }) -> [String: Match] {
        let realFiles = entries.filter { !$0.isSymlink }
        var out: [String: Match] = [:]
        for tc in toolchains where tc.enabled {
            let hit = realFiles.filter { e in tc.markers.contains { Self.markerMatches($0, e.name) } }
            guard !hit.isEmpty else { continue }
            for rule in tc.artifacts {
                guard realFiles.contains(where: { $0.name == rule.name && $0.isDirectory }) else { continue }
                if let inside = rule.insideMarker, !insideMarkerExists(rule.name, inside) { continue }
                let candidate = Match(toolchain: tc, rule: rule, regenClass: rule.regenClass,
                                      markerNames: hit.map(\.name))
                if let existing = out[rule.name] {
                    // Conservative on conflict: stricter class, and keep "requires git-ignore".
                    if rule.regenClass > existing.regenClass || (rule.requiresGitIgnore ?? false) {
                        out[rule.name] = candidate
                    }
                } else {
                    out[rule.name] = candidate
                }
            }
        }
        return out
    }
}

// MARK: - Model

enum BuildArtifactGitStatus: String, Sendable, Equatable {
    /// In a git work tree, git says ignored and nothing in it is tracked — verified.
    case ignored
    /// Not in a git work tree — relies on the marker pair alone (Unverified).
    case notRepo
    /// In a git work tree but git could not be consulted (sandboxed build, no git, timeout).
    /// Offered as Unverified, Move to Trash only (BRD F054-V2) — never silently dropped.
    case unavailable
    /// Fixed-path Xcode (global) items: no project, no git.
    case notApplicable
}

struct BuildArtifactItem: Identifiable, Sendable, Equatable {
    /// Resolved, standardized path — stable across scans (BUG-001 R2), never a fresh UUID.
    let id: String
    let artifactURL: URL
    let projectName: String
    let projectPath: String
    let toolchainID: String
    let toolchainName: String
    let regenClass: BuildArtifactRegenClass
    let size: Int64
    let artifactModified: Date?
    let projectLastModified: Date?
    let gitStatus: BuildArtifactGitStatus
    let regenHint: String
    let isActive: Bool

    var isXcodeGlobal: Bool { toolchainID == BuildArtifactScanner.xcodeGlobalToolchainID }
    /// "Unverified" = nothing but the marker pair vouches for it.
    var isUnverified: Bool { gitStatus != .ignored }

    /// D-02 (owner-accepted): the irreversible "Trash and empty" action is for Safe + git-verified
    /// items ONLY. Caution, Needs-network, Unverified and Xcode-global items get Move to Trash.
    var permanentRemovalEligible: Bool { regenClass == .safe && gitStatus == .ignored }

    /// FR-U4: smart-select never picks Caution, Active, or items git could not vouch for in a repo.
    func isSmartSelectable(staleDays: Int? = nil, now: Date = Date()) -> Bool {
        guard regenClass != .caution, !isActive, gitStatus != .unavailable else { return false }
        if let days = staleDays {
            let reference = [artifactModified, projectLastModified].compactMap { $0 }.max()
            guard let ref = reference else { return false }
            return now.timeIntervalSince(ref) > Double(days) * 86_400
        }
        return true
    }
}

enum BuildArtifactSkipReason: String, Sendable {
    case trackedByGit, notGitIgnored, requiresGitIgnore, userIgnored, forbiddenPath
}

struct BuildArtifactScanSummary: Sendable, Equatable {
    var foldersScanned = 0
    var itemsFound = 0
    var skippedTrackedByGit = 0
    var skippedNotGitIgnored = 0
    var skippedUserIgnored = 0
    var gitUnavailableInRepo = 0
    var stoppedEarly = false
    var catalogMissing = false
    var rootsScanned: [String] = []
}

enum BuildArtifactScanEvent: Sendable {
    case found(BuildArtifactItem)
    case progress(foldersScanned: Int)
    case skipped(path: String, reason: BuildArtifactSkipReason)
    case finished(BuildArtifactScanSummary)
}

// MARK: - Roots & safety

enum BuildArtifactRoots {
    /// D8 default roots that exist on disk. D-03: `~/Downloads` is NOT here (Downloads is its own
    /// Cleanup category — BUG-001 one-owner-per-path); the user can still add it.
    static func defaultRoots(home: String = NSHomeDirectory(),
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        ["Developer", "Projects", "Code", "dev", "src", "Github", "GitHub", "Documents", "Desktop", "Sites"]
            .map { "\(home)/\($0)" }.filter(exists)
    }

    /// The fixed Xcode (global) folders — owned by this pane since D7 / D-04.
    static func xcodeGlobalRoots(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/Library/Developer/Xcode/DerivedData", "\(home)/Library/Developer/CoreSimulator/Caches"]
    }

    /// True when the scanner would silently drop `path` as a root — it is, or lies inside, an
    /// excluded area. Lets the UI say so instead of accepting a folder and then finding nothing.
    static func isExcludedRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return defaultExcluded(home: home).contains {
            CleanupPath.isCovered(p, by: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        }
    }

    /// Never scanned, never offered, never removable by this feature.
    static func defaultExcluded(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/Library", "\(home)/Downloads", "\(home)/.Trash",
         "/System", "/Applications", "/Library",
         // Tool-managed trees (global npm installs bundle their own node_modules, which `npm install`
         // does NOT recreate). Only reachable if the user picks `/` or similar as a root.
         "/opt/homebrew", "/usr", "/bin", "/sbin"]
    }
}

enum BuildArtifactSafety {
    /// N3: Xcode Archives and Simulator runtimes/devices are not regenerable. Hard stop, regardless
    /// of what any catalogue entry or caller says.
    static func isNeverTouch(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let dev = "\(home)/Library/Developer"
        if CleanupPath.isCovered(p, by: "\(dev)/Xcode/Archives") { return true }
        if CleanupPath.isCovered(p, by: "\(dev)/CoreSimulator/Devices") { return true }
        if CleanupPath.isCovered(p, by: "\(dev)/CoreSimulator/Volumes") { return true }
        if CleanupPath.isCovered(p, by: "\(dev)/CoreSimulator/Cryptex") { return true }
        if p.contains("/Library/Developer/CoreSimulator/Profiles/Runtimes") { return true }
        if p.hasSuffix(".xcarchive") || p.contains(".xcarchive/") { return true }
        return false
    }
}

// MARK: - Git gate (D3)

enum GitGate {
    enum Verdict: Sendable, Equatable {
        case ignored        // in a work tree, ignored, nothing tracked
        case notRepo        // no .git above the project
        case tracked        // git tracks something inside it
        case notIgnored     // in a work tree, untracked but NOT ignored
        case unavailable    // in a work tree but git could not answer
    }

    private static let cacheLock = NSLock()
    private static var cachedGit: String??  = nil

    /// A real git binary, or nil. Never returns the `/usr/bin/git` shim on a Mac without the
    /// Command Line Tools — spawning it pops an "install developer tools" dialog (spec R5).
    static func locateGit(fm: FileManager = .default) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cachedGit { return cached }
        var found: String?
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                  "/Library/Developer/CommandLineTools/usr/bin/git"] where fm.isExecutableFile(atPath: p) {
            found = p; break
        }
        if found == nil {
            let sel = ShellReader.run("/usr/bin/xcode-select", ["-p"], timeout: 5)
            if sel.succeeded {
                let dir = sel.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                let p = dir + "/usr/bin/git"
                if fm.isExecutableFile(atPath: p) { found = p }
            }
        }
        cachedGit = .some(found)
        return found
    }

    /// True when a `.git` entry exists in `dir` or any ancestor. Pure file-system check: works
    /// in the sandbox, spawns nothing, and is what separates "not a repo" from "git unavailable".
    static func isInsideWorkTreeByFilesystem(_ dir: URL, fm: FileManager = .default) -> Bool {
        var cur = dir.standardizedFileURL
        while true {
            if fm.fileExists(atPath: cur.appendingPathComponent(".git").path) { return true }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { return false }
            cur = parent
        }
    }

    /// True when a Mercurial / Subversion / Fossil control directory sits in `dir` or an ancestor.
    /// Halo cannot ask those tools what is tracked, so a project under one is never "not a repo" —
    /// it is "version-controlled, cannot verify" (`.unavailable`: Trash only, never smart-selected).
    static func isInsideOtherVCSByFilesystem(_ dir: URL, fm: FileManager = .default) -> Bool {
        var cur = dir.standardizedFileURL
        while true {
            for marker in [".hg", ".svn", ".fslckout", "_FOSSIL_"]
            where fm.fileExists(atPath: cur.appendingPathComponent(marker).path) { return true }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { return false }
            cur = parent
        }
    }

    /// Blocking (ShellReader) — call from an actor / detached task, never the main actor.
    static func inspect(artifactName: String, project: URL, gitPath: String? = locateGit()) -> Verdict {
        guard isInsideWorkTreeByFilesystem(project) else {
            return isInsideOtherVCSByFilesystem(project) ? .unavailable : .notRepo
        }
        guard let git = gitPath else { return .unavailable }

        let wt = ShellReader.run(git, ["-C", project.path, "rev-parse", "--is-inside-work-tree"], timeout: 10)
        guard wt.succeeded, wt.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .unavailable
        }
        let tracked = ShellReader.run(git, ["-C", project.path, "ls-files", "--", artifactName], timeout: 15)
        guard tracked.succeeded else { return .unavailable }
        if !tracked.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .tracked }

        let ign = ShellReader.run(git, ["-C", project.path, "check-ignore", "-q", "--", artifactName], timeout: 10)
        if ign.launchFailure != nil || ign.didTimeOut { return .unavailable }
        switch ign.exitCode {
        case 0: return .ignored
        case 1: return .notIgnored
        default: return .unavailable
        }
    }
}

// MARK: - Scanner

actor BuildArtifactScanner {

    static let xcodeGlobalToolchainID = "xcode-global"

    struct Config: Sendable {
        var maxDepth = 8
        var budgetSeconds: TimeInterval = 120
        var maxConcurrentSizing = 4
        var excludedPaths: [String] = BuildArtifactRoots.defaultExcluded()
        var ignoredPaths: Set<String> = []
        var activeWindow: TimeInterval = 24 * 3600
        var now = Date()
        var home = NSHomeDirectory()
        /// false = behave as if no git binary exists (sandboxed build, or tests of that path).
        var useGit = true
    }

    /// Directory names never descended into during DETECTION (heavy, or output we would only
    /// be walking to find nothing).
    private static let neverDescend: Set<String> = [
        ".git", ".hg", ".svn", ".Trash", "node_modules", ".build", ".gradle", ".dart_tool",
        "Pods", "__pycache__", "DerivedData", "Carthage", ".venv", "venv",
        // Toolchain managers: their installs carry a project file next to a bundled node_modules /
        // target that is NOT regenerable by the usual command. Matters once "Entire home folder" is on.
        ".nvm", ".npm", ".cargo", ".rustup", ".pub-cache", ".volta", ".fnm", ".asdf",
        ".pyenv", ".rbenv", ".sdkman", ".pnpm-store", "Cellar"
    ]
    private static let packageSuffixes = [".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace",
                                          ".photoslibrary", ".playground", ".plugin", ".kext", ".xcarchive"]

    private let catalog: BuildArtifactCatalog?

    init(catalog: BuildArtifactCatalog? = BuildArtifactCatalog.load()) {
        self.catalog = catalog
    }

    private struct Candidate {
        let url: URL
        let project: URL
        let match: BuildArtifactCatalog.Match
        let projectLastModified: Date?
    }

    func scan(roots: [String], config: Config = Config()) -> AsyncStream<BuildArtifactScanEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(roots: roots, config: config, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience for tests and callers that want the whole result.
    func scanAll(roots: [String], config: Config = Config()) async -> (items: [BuildArtifactItem], summary: BuildArtifactScanSummary) {
        var items: [BuildArtifactItem] = []
        var summary = BuildArtifactScanSummary()
        for await ev in await scan(roots: roots, config: config) {
            switch ev {
            case .found(let i): items.append(i)
            case .finished(let s): summary = s
            default: break
            }
        }
        return (items.sorted { $0.size > $1.size }, summary)
    }

    private func run(roots: [String], config: Config,
                     continuation: AsyncStream<BuildArtifactScanEvent>.Continuation) async {
        var summary = BuildArtifactScanSummary()
        defer { continuation.finish() }
        guard let catalog = catalog else {
            summary.catalogMissing = true
            continuation.yield(.finished(summary)); return
        }

        let fm = FileManager.default
        let excluded = config.excludedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let started = Date()
        var candidates: [Candidate] = []

        // Phase 1: detection (names only — no sizing, no git).
        for rootPath in roots {
            if Task.isCancelled { break }
            let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
            // A root that is itself excluded, or not a local directory, is dropped (D-03).
            if excluded.contains(where: { CleanupPath.isCovered(root.path, by: $0) }) { continue }
            let vals = try? root.resourceValues(forKeys: [.volumeIsLocalKey, .isDirectoryKey])
            guard vals?.isDirectory == true, vals?.volumeIsLocal != false else { continue }
            summary.rootsScanned.append(root.path)
            walk(root, depth: 0, root: root, catalog: catalog, config: config, excluded: excluded,
                 started: started, summary: &summary, candidates: &candidates, fm: fm,
                 continuation: continuation)
        }

        // Phase 2: gates (git), then exact sizing, at most N at a time.
        var gated: [(Candidate, BuildArtifactGitStatus)] = []
        let gitPath = config.useGit ? GitGate.locateGit() : nil
        for c in candidates {
            if Task.isCancelled { break }
            let key = c.url.path
            if config.ignoredPaths.contains(key) || config.ignoredPaths.contains(CleanupPath.key(c.url)) {
                summary.skippedUserIgnored += 1
                continuation.yield(.skipped(path: key, reason: .userIgnored)); continue
            }
            if BuildArtifactSafety.isNeverTouch(key, home: config.home) {
                continuation.yield(.skipped(path: key, reason: .forbiddenPath)); continue
            }
            let verdict = GitGate.inspect(artifactName: c.url.lastPathComponent, project: c.project, gitPath: gitPath)
            let needsIgnore = c.match.rule.requiresGitIgnore ?? false
            switch verdict {
            case .tracked:
                summary.skippedTrackedByGit += 1
                continuation.yield(.skipped(path: key, reason: .trackedByGit))
            case .notIgnored:
                summary.skippedNotGitIgnored += 1
                continuation.yield(.skipped(path: key, reason: .notGitIgnored))
            case .ignored:
                gated.append((c, .ignored))
            case .notRepo:
                if needsIgnore {
                    continuation.yield(.skipped(path: key, reason: .requiresGitIgnore))
                } else { gated.append((c, .notRepo)) }
            case .unavailable:
                if needsIgnore {
                    continuation.yield(.skipped(path: key, reason: .requiresGitIgnore))
                } else {
                    summary.gitUnavailableInRepo += 1
                    gated.append((c, .unavailable))
                }
            }
        }

        let items = await sizeAll(gated, config: config)
        for item in items { continuation.yield(.found(item)); summary.itemsFound += 1 }
        continuation.yield(.finished(summary))
    }

    private func walk(_ dir: URL, depth: Int, root: URL, catalog: BuildArtifactCatalog,
                      config: Config, excluded: [String], started: Date,
                      summary: inout BuildArtifactScanSummary, candidates: inout [Candidate],
                      fm: FileManager, continuation: AsyncStream<BuildArtifactScanEvent>.Continuation) {
        if Task.isCancelled { return }
        if Date().timeIntervalSince(started) > config.budgetSeconds { summary.stoppedEarly = true; return }
        if excluded.contains(where: { CleanupPath.isCovered(dir.path, by: $0) }) { return }
        if BuildArtifactSafety.isNeverTouch(dir.path, home: config.home) { return }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .isPackageKey]
        // No .skipsHiddenFiles: `.build`, `.gradle`, `.next` are dot-folders.
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return }
        summary.foldersScanned += 1
        if summary.foldersScanned % 200 == 0 { continuation.yield(.progress(foldersScanned: summary.foldersScanned)) }

        var entries: [BuildArtifactCatalog.Entry] = []
        var packages = Set<String>()
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let name = u.lastPathComponent
            entries.append(.init(name: name, isDirectory: v?.isDirectory ?? false,
                                 isSymlink: v?.isSymbolicLink ?? false, modified: v?.contentModificationDate))
            if v?.isPackage == true || Self.packageSuffixes.contains(where: { name.hasSuffix($0) }) { packages.insert(name) }
        }

        let found = catalog.matches(in: entries) { artifact, marker in
            fm.fileExists(atPath: dir.appendingPathComponent(artifact).appendingPathComponent(marker).path)
        }
        for (name, match) in found {
            let url = dir.appendingPathComponent(name)
            // Gate 4: after resolving, it must still sit inside the scan root.
            let resolved = url.resolvingSymlinksInPath()
            guard CleanupPath.isCovered(resolved.path, by: root.path) else { continue }
            let projectMtime = entries.filter { match.markerNames.contains($0.name) }.compactMap(\.modified).max()
            candidates.append(Candidate(url: resolved, project: dir, match: match, projectLastModified: projectMtime))
        }

        guard depth < config.maxDepth else { return }
        let pruned = Set(found.keys)
        for e in entries where e.isDirectory && !e.isSymlink
            && !pruned.contains(e.name) && !packages.contains(e.name)
            && !Self.neverDescend.contains(e.name) {
            walk(dir.appendingPathComponent(e.name), depth: depth + 1, root: root, catalog: catalog,
                 config: config, excluded: excluded, started: started, summary: &summary,
                 candidates: &candidates, fm: fm, continuation: continuation)
        }
    }

    private func sizeAll(_ gated: [(Candidate, BuildArtifactGitStatus)], config: Config) async -> [BuildArtifactItem] {
        var out: [BuildArtifactItem] = []
        await withTaskGroup(of: BuildArtifactItem?.self) { group in
            var iterator = gated.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let (c, git) = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    guard let size = BuildArtifactScanner.exactSize(of: c.url) else { return nil }
                    let mtime = (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let recent = [mtime, c.projectLastModified].compactMap { $0 }
                        .contains { config.now.timeIntervalSince($0) < config.activeWindow }
                    return BuildArtifactItem(
                        id: CleanupPath.key(c.url), artifactURL: c.url,
                        projectName: c.project.lastPathComponent, projectPath: c.project.path,
                        toolchainID: c.match.toolchain.id, toolchainName: c.match.toolchain.name,
                        regenClass: c.match.regenClass, size: size, artifactModified: mtime,
                        projectLastModified: c.projectLastModified, gitStatus: git,
                        regenHint: c.match.toolchain.regenHint, isActive: recent)
                }
            }
            for _ in 0..<max(1, config.maxConcurrentSizing) { addNext() }
            while let item = await group.next() {
                inFlight -= 1
                if let item { out.append(item) }
                if Task.isCancelled { group.cancelAll(); continue }
                addNext()
            }
        }
        return out
    }

    // MARK: Xcode (global) — fixed paths, D7 / D-04

    /// DerivedData project folders + CoreSimulator/Caches children, one item each. This is what the
    /// retired `.xcodeData` category used to list; Smart Scan now sources its Xcode line from here.
    func xcodeGlobalItems(config: Config = Config()) async -> [BuildArtifactItem] {
        let fm = FileManager.default
        var gated: [(Candidate, BuildArtifactGitStatus)] = []
        let toolchain = BuildArtifactCatalog.Toolchain(
            id: Self.xcodeGlobalToolchainID, name: "Xcode (global)", enabled: true, markers: [],
            regenHint: "Rebuilt by Xcode", artifacts: [])
        let rule = BuildArtifactCatalog.Rule(name: "", regenClass: .safe, requiresGitIgnore: nil, insideMarker: nil)
        for rootPath in BuildArtifactRoots.xcodeGlobalRoots(home: config.home) {
            let root = URL(fileURLWithPath: rootPath)
            guard let kids = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { continue }
            for k in kids {
                let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                if config.ignoredPaths.contains(CleanupPath.key(k)) { continue }
                // Strip Xcode's "-<hash>" suffix for a readable project name.
                var display = k.lastPathComponent
                if let dash = display.lastIndex(of: "-"), display.distance(from: dash, to: display.endIndex) > 20 {
                    display = String(display[..<dash])
                }
                gated.append((Candidate(url: k, project: root.appendingPathComponent(display), match:
                    .init(toolchain: toolchain, rule: rule, regenClass: .safe, markerNames: []),
                    projectLastModified: nil), .notApplicable))
            }
        }
        return await sizeAll(gated, config: config).filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    // MARK: Exact sizing (D6)

    /// Allocated size of everything under `url`, no file cap, hidden files INCLUDED, symlinks not
    /// followed (counted as the link itself). Returns nil only when cancelled.
    nonisolated static func exactSize(of url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let f as URL in en {
            n += 1
            if n % 2048 == 0, Task.isCancelled { return nil }
            let v = try? f.resourceValues(forKeys: Set(keys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        // The directory entry itself.
        if let v = try? url.resourceValues(forKeys: Set(keys)) {
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
