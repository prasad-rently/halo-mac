import Foundation
import AppKit
import Darwin.sys.proc_info

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
    /// Modified in the last 24 h (artifact or project marker) — a recency PROXY for "a build may be running".
    let isActive: Bool
    /// A running process demonstrably uses this project (cwd of a build tool, or the workspace is open
    /// in Xcode) — see `BuildArtifactInUse`. Stronger evidence than `isActive`, and like it, blocks
    /// smart-select and permanent removal. A scan-time fact: the remover asks again before acting.
    var isInUse: Bool = false

    var isXcodeGlobal: Bool { toolchainID == BuildArtifactScanner.xcodeGlobalToolchainID }
    /// "Unverified" = nothing but the marker pair vouches for it.
    var isUnverified: Bool { gitStatus != .ignored }

    /// D-02 (owner-accepted): the irreversible "Trash and empty" action is for Safe + git-verified
    /// items ONLY. Caution, Needs-network, Unverified and Xcode-global items get Move to Trash.
    /// Follow-up to the #59 review: an item that is Active (touched < 24 h ago) or In use is not
    /// eligible either — a build may be writing into it, and an irreversible delete is the wrong
    /// moment to bet on "probably finished". They keep the recoverable Move to Trash.
    var permanentRemovalEligible: Bool {
        regenClass == .safe && gitStatus == .ignored && !isActive && !isInUse
    }

    /// "Safe" as the Select-all-Safe control means it: Safe class AND positively vouched for — git
    /// said ignored, or it is a fixed Xcode folder that needs no vouching. An `.notRepo` item
    /// (nothing but the marker pair says it is build output) is Unverified, not Safe.
    var isVerifiedSafe: Bool {
        regenClass == .safe && (gitStatus == .ignored || gitStatus == .notApplicable)
    }

    /// FR-U4: smart-select never picks Caution, Active, In-use, or items git could not vouch for in a repo.
    func isSmartSelectable(staleDays: Int? = nil, now: Date = Date()) -> Bool {
        guard regenClass != .caution, !isActive, !isInUse, gitStatus != .unavailable else { return false }
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
    /// Offered as Unverified because the only thing "ignoring" them is a catch-all pattern (`*`).
    var gitCatchAllIgnored = 0
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

// MARK: - "In use" detection (follow-up to #59, spec §5.3.6)
//
// The mtime-based Active badge is a PROXY. This is evidence: is a running process actually using
// the project? Only cheap, subprocess-free signals are used — `libproc` (the same `proc_pidinfo`
// family ProcessMonitor already reads) and `NSRunningApplication`. No `lsof`, no AppleScript
// (which would need an Automation permission), no file contents are read — apart from DerivedData's
// own `info.plist`, to learn which project a DerivedData folder belongs to.
//
//   1. cwd of any running process that is not an idle shell: `npm run dev`, `cargo watch`,
//      `gradle`, `xcodebuild`, an editor's language server ... — if its cwd is inside the item's
//      project folder (or the artifact), the project is in use.
//   2. Xcode: an Xcode-family process (Xcode, XCBBuildService, SourceKitService, swift-frontend ...)
//      holds files open inside a DerivedData folder => that folder is in use, and its workspace's
//      folder (`info.plist` `WorkspacePath`) is an open project, so e.g. its `build/` is too.
//   3. If Xcode is running but Halo cannot see what it has open (libproc denied — the App Sandbox
//      — or it holds nothing we can read), EVERY DerivedData folder is treated as in use. Not
//      knowing is never read as "free".
//
// Limits, stated plainly: a tool run from a shell that then `cd`s elsewhere, a build that has not
// started yet, or any state in a sandboxed build is invisible. "Not in use" means "no signal",
// not "proven idle" — which is why the remover asks again right before an irreversible action and
// why Active stays as a second, independent badge.

struct BuildArtifactInUseSignals: Sendable, Equatable {
    /// Resolved cwds of running, non-idle processes.
    var busyDirectories: Set<String> = []
    /// Resolved paths of DerivedData folders an Xcode-family process holds files open in.
    var openDerivedDataFolders: Set<String> = []
    /// Resolved folders of the workspaces/projects those DerivedData folders belong to.
    var openProjectDirectories: Set<String> = []
    /// Xcode is running but what it has open could not be read: every DerivedData folder counts as in use.
    var xcodeRunningButOpaque = false
    /// Resolved `…/Xcode/DerivedData`, to recognise Xcode-global items for the opaque case.
    var derivedDataRoot: String = ""

    static let none = BuildArtifactInUseSignals()
}

enum BuildArtifactInUse {

    /// Interactive shells and session holders sit in a project folder without building anything;
    /// counting them would mark every project that has a terminal open in it. (A shell RUNNING a
    /// tool has that tool as a child with the same cwd, which is counted.)
    static let idleProcessNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login", "tmux", "screen",
    ]
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// Pure. Is this item in use, given the signals?
    static func isInUse(_ item: BuildArtifactItem, signals: BuildArtifactInUseSignals) -> Bool {
        let artifact = item.artifactURL.resolvingSymlinksInPath().path
        if signals.busyDirectories.contains(where: { CleanupPath.isCovered($0, by: artifact) }) { return true }
        if item.isXcodeGlobal {
            if signals.openDerivedDataFolders.contains(artifact) { return true }
            if signals.xcodeRunningButOpaque, !signals.derivedDataRoot.isEmpty,
               CleanupPath.isCovered(artifact, by: signals.derivedDataRoot) { return true }
            return false
        }
        let project = URL(fileURLWithPath: item.projectPath).resolvingSymlinksInPath().path
        if signals.openProjectDirectories.contains(project) { return true }
        return signals.busyDirectories.contains { CleanupPath.isCovered($0, by: project) }
    }

    /// The one spelling both sides are compared in. The kernel reports `/private/var/…`, while
    /// Foundation's `resolvingSymlinksInPath` deliberately yields `/var/…` for the same folder;
    /// passing kernel paths through the same function makes them comparable.
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// Xcode, and the services it launches, live inside an `Xcode*.app` bundle.
    static func isXcodeFamily(executablePath path: String) -> Bool {
        path.contains("/Xcode") && path.contains(".app/Contents/")
    }

    /// Blocking libproc reads (about a thousand syscalls) — never call from the main actor.
    /// Under the App Sandbox the reads of OTHER processes are denied and the signals come back
    /// empty (plus `xcodeRunningButOpaque` when Xcode is up); see the header for what that means.
    static func currentSignals(home: String = NSHomeDirectory(),
                               xcodeAppRunning: Bool? = nil,
                               excludingPID: pid_t = getpid(),
                               isXcodeProcess: (pid_t, String) -> Bool = { isXcodeFamily(executablePath: $1) }) -> BuildArtifactInUseSignals {
        var s = BuildArtifactInUseSignals()
        let derivedRoot = canonical(home + "/Library/Developer/Xcode/DerivedData")
        s.derivedDataRoot = derivedRoot

        var xcodePIDs: [pid_t] = []
        for pid in allPIDs() where pid != excludingPID {
            guard let exe = executablePath(of: pid) else { continue }
            if isXcodeProcess(pid, exe) { xcodePIDs.append(pid) }
            let name = (exe as NSString).lastPathComponent
            if !idleProcessNames.contains(name), let cwd = currentDirectory(of: pid), cwd != "/" {
                s.busyDirectories.insert(canonical(cwd))
            }
        }

        var sawAnyOpenFile = false
        for pid in xcodePIDs {
            let paths = openFilePaths(of: pid).map(canonical)
            if !paths.isEmpty { sawAnyOpenFile = true }
            for p in paths where CleanupPath.isCovered(p, by: derivedRoot) && p != derivedRoot {
                let rest = p.dropFirst(derivedRoot.count + 1)
                guard let folder = rest.split(separator: "/").first else { continue }
                s.openDerivedDataFolders.insert(derivedRoot + "/" + folder)
            }
        }
        for folder in s.openDerivedDataFolders {
            if let ws = workspacePath(ofDerivedDataFolder: folder) {
                let url = URL(fileURLWithPath: ws).resolvingSymlinksInPath()
                // `App.xcworkspace` / `App.xcodeproj` / `Package.swift` sit INSIDE the project folder.
                s.openProjectDirectories.insert(url.deletingLastPathComponent().path)
                s.openProjectDirectories.insert(url.path)
            }
        }
        let running = xcodeAppRunning
            ?? !NSRunningApplication.runningApplications(withBundleIdentifier: xcodeBundleID).isEmpty
        s.xcodeRunningButOpaque = running && !sawAnyOpenFile
        return s
    }

    /// `WorkspacePath` from `<DerivedData folder>/info.plist` — the project Xcode built this for.
    static func workspacePath(ofDerivedDataFolder folder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder + "/info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["WorkspacePath"] as? String
    }

    // MARK: libproc readers — each returns nil / [] when the kernel refuses (sandbox, other user)

    private static let procPidListFDs: Int32 = 1
    private static let procPidVnodePathInfo: Int32 = 9
    private static let procPidFDVnodePathInfo: Int32 = 2
    private static let proxFDTypeVnode: UInt32 = 1
    private static let procPidPathMax = 4096

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard actual > 0 else { return [] }
        return pids.prefix(Int(actual)).filter { $0 > 0 }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: procPidPathMax)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The process's current working directory, resolved by the kernel.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, procPidVnodePathInfo, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Paths of the regular files / directories the process has open. Empty when denied.
    static func openFilePaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, procPidListFDs, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, procPidListFDs, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == proxFDTypeVnode {
            var vi = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, procPidFDVnodePathInfo, &vi, size) == size else { continue }
            let path = withUnsafePointer(to: &vi.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
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
        /// Git says ignored, but only because of a catch-all pattern (`*`, `/*`, `.*` ...), as in a
        /// dotfiles repo whose work tree is `$HOME`. That says nothing about THIS folder, so it is
        /// not a positive ignore: offered as Unverified, Trash only, never smart-selected.
        case catchAllIgnore
    }

    /// What `git check-ignore -v` reported for a path: the rule that ignored it.
    struct IgnoreRule: Sendable, Equatable { let source: String; let line: Int; let pattern: String }

    /// Parses ONE record of `git check-ignore -v` output: `<source>:<line>:<pattern>\t<path>`.
    /// nil when it does not look like that — callers must then NOT treat the path as verified.
    static func parseCheckIgnoreVerbose(_ output: String) -> IgnoreRule? {
        guard let record = output.split(separator: "\n").first,
              let tab = record.firstIndex(of: "\t") else { return nil }
        let left = String(record[record.startIndex..<tab])
        guard let rx = try? NSRegularExpression(pattern: #"^(.+?):(\d+):(.*)$"#),
              let m = rx.firstMatch(in: left, range: NSRange(left.startIndex..., in: left)),
              m.numberOfRanges == 4,
              let r1 = Range(m.range(at: 1), in: left), let r2 = Range(m.range(at: 2), in: left),
              let r3 = Range(m.range(at: 3), in: left), let line = Int(left[r2]) else { return nil }
        return IgnoreRule(source: String(left[r1]), line: line, pattern: String(left[r3]))
    }

    /// A pattern with no literal name character in it — only `*`, `?`, `/`, `.`, `!` — ignores
    /// (nearly) everything, so it proves nothing about one folder: `*`, `/*`, `**`, `**/*`, `.*`.
    /// `node_modules/`, `target`, `*.o`, `build*` all carry a literal and are not catch-alls.
    static func isCatchAllPattern(_ pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return true }
        return p.allSatisfy { "*?/.![]\\".contains($0) }
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

        // `-v` names the rule that matched, so a catch-all `*` can be told from a real entry.
        // Asked about THIS folder's own path (relative to the project dir), nothing broader.
        let ign = ShellReader.run(git, ["-C", project.path, "check-ignore", "-v", "--", artifactName], timeout: 10)
        if ign.launchFailure != nil || ign.didTimeOut { return .unavailable }
        switch ign.exitCode {
        case 0:
            // Cannot say which rule ignored it => cannot call it verified.
            guard let rule = parseCheckIgnoreVerbose(ign.standardOutput) else { return .unavailable }
            return isCatchAllPattern(rule.pattern) ? .catchAllIgnore : .ignored
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
        /// Reads the "in use" signals once per sizing pass. nil = no detection (tests, headless).
        /// The pane wires `BuildArtifactInUse.currentSignals`.
        var inUseSignals: (@Sendable () -> BuildArtifactInUseSignals)? = nil
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
            case .catchAllIgnore:
                // A catch-all `*` is not a positive ignore, so rules that need one are not offered;
                // the rest are Unverified (Trash only, never smart-selected).
                if needsIgnore {
                    continuation.yield(.skipped(path: key, reason: .requiresGitIgnore))
                } else {
                    summary.gitCatchAllIgnored += 1
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
        // Read the signals AFTER the (possibly long) sizing: the freshest picture of what is running.
        if let provider = config.inUseSignals {
            let signals = provider()
            out = out.map { var i = $0; i.isInUse = BuildArtifactInUse.isInUse(i, signals: signals); return i }
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
