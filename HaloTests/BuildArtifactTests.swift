import Testing
import Foundation
@testable import Halo

// F-054 Build Artifact Cleaner — tests.
//
// SAFETY: every test that deletes or trashes anything does so on a freshly created temp tree
// (or, for one end-to-end test, on a uniquely named temp folder that is moved through the real
// `trashItem`). Nothing here ever points at the user's real projects, DerivedData or Trash contents.
// Mutation checks done by hand (revert the rule, see red, restore) are listed in the PR body.

// MARK: - Fixtures

/// A throw-away directory tree. Paths are fully resolved (/var -> /private/var) so they compare
/// equal to what the scanner reports.
final class BAFixture: @unchecked Sendable {
    let root: URL
    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("f054-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
    @discardableResult func dir(_ rel: String) -> URL {
        try! FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true); return url(rel)
    }
    @discardableResult func file(_ rel: String, bytes: Int = 16) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(repeating: 0x41, count: bytes).write(to: u)
        return u
    }
    func link(_ rel: String, to dest: URL) {
        try! FileManager.default.createDirectory(at: url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: url(rel), withDestinationURL: dest)
    }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url(rel).path) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

enum BATestCatalog {
    /// The catalogue as shipped in the app bundle (also proves the resource is registered).
    static func bundled() -> BuildArtifactCatalog? { BuildArtifactCatalog.load(bundle: Bundle(for: BuildArtifactsViewModel.self)) }
    static func fromSource() -> BuildArtifactCatalog? {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Halo/Resources/build-artifact-catalog.json")
        guard let d = try? Data(contentsOf: p) else { return nil }
        return try? JSONDecoder().decode(BuildArtifactCatalog.self, from: d)
    }
}

func baItem(_ url: URL, cls: BuildArtifactRegenClass = .safe, git: BuildArtifactGitStatus = .ignored,
            size: Int64 = 1_000, active: Bool = false, project: String = "proj",
            toolchain: String = "rust", modified: Date? = nil, id: String? = nil,
            inUse: Bool = false) -> BuildArtifactItem {
    BuildArtifactItem(id: id ?? CleanupPath.key(url), artifactURL: url, projectName: project,
                      projectPath: url.deletingLastPathComponent().path, toolchainID: toolchain,
                      toolchainName: toolchain.capitalized, regenClass: cls, size: size,
                      artifactModified: modified, projectLastModified: modified, gitStatus: git,
                      regenHint: "rebuild", isActive: active, isInUse: inUse)
}

/// A "now" a week ahead, so folders created a moment ago are not Active (< 24 h) — needed wherever a
/// test expects an item to be permanent-eligible, which Active items no longer are.
let baAged = Date().addingTimeInterval(7 * 86_400)

func baScan(_ f: BAFixture, roots: [String]? = nil, home: String? = nil, excluded: [String]? = nil,
            useGit: Bool = true, ignored: Set<String> = [], now: Date? = nil,
            catalog: BuildArtifactCatalog? = BATestCatalog.fromSource()) async -> (items: [BuildArtifactItem], summary: BuildArtifactScanSummary) {
    var cfg = BuildArtifactScanner.Config()
    cfg.home = home ?? f.url("home").path
    cfg.excludedPaths = excluded ?? BuildArtifactRoots.defaultExcluded(home: cfg.home)
    cfg.useGit = useGit
    cfg.ignoredPaths = ignored
    if let now { cfg.now = now }
    return await BuildArtifactScanner(catalog: catalog).scanAll(roots: roots ?? [f.root.path], config: cfg)
}

// MARK: - Catalogue

@Suite("F-054 catalogue")
struct BuildArtifactCatalogTests {

    @Test func bundledCatalogueLoadsAndMatchesSource() throws {
        let bundled = try #require(BATestCatalog.bundled(), "build-artifact-catalog.json is not in the app bundle")
        let source = try #require(BATestCatalog.fromSource())
        #expect(bundled.toolchains.map(\.id) == source.toolchains.map(\.id))
    }

    @Test func mvpToolchainsAreEnabledAndTheRestShipDisabled() throws {
        let c = try #require(BATestCatalog.fromSource())
        let enabled = Set(c.toolchains.filter(\.enabled).map(\.id))
        #expect(enabled == ["xcode-project", "swiftpm", "node", "node-build", "rust", "gradle", "flutter"])
        #expect(Set(c.toolchains.map(\.id)).count == c.toolchains.count, "toolchain ids must be unique")
    }

    @Test func ruleNamesAreSingleSafePathComponents() throws {
        let c = try #require(BATestCatalog.fromSource())
        for tc in c.toolchains {
            #expect(!tc.markers.isEmpty)
            for r in tc.artifacts {
                #expect(!r.name.isEmpty && !r.name.contains("/") && r.name != ".." && r.name != ".",
                        "\(tc.id): \(r.name)")
                #expect(r.name != "Archives" && r.name != "Devices")
            }
        }
    }

    @Test func pureMatcherRequiresAMarkerSibling() throws {
        let c = try #require(BATestCatalog.fromSource())
        let d = { (n: String) in BuildArtifactCatalog.Entry(name: n, isDirectory: true, isSymlink: false, modified: nil) }
        let f = { (n: String) in BuildArtifactCatalog.Entry(name: n, isDirectory: false, isSymlink: false, modified: nil) }
        #expect(c.matches(in: [d("build"), d("target"), d("node_modules")]).isEmpty, "no marker => nothing offered (D2)")
        #expect(Set(c.matches(in: [f("Cargo.toml"), d("target")]).keys) == ["target"])
        #expect(Set(c.matches(in: [d("Foo.xcodeproj"), d("build")]).keys) == ["build"])
        // A marker that is a symlink does not count.
        let linkedMarker = BuildArtifactCatalog.Entry(name: "Cargo.toml", isDirectory: false, isSymlink: true, modified: nil)
        #expect(c.matches(in: [linkedMarker, d("target")]).isEmpty)
        // A symlinked artifact never matches.
        let linkedArtifact = BuildArtifactCatalog.Entry(name: "target", isDirectory: true, isSymlink: true, modified: nil)
        #expect(c.matches(in: [f("Cargo.toml"), linkedArtifact]).isEmpty)
        // A FILE called target is not a directory artifact.
        #expect(c.matches(in: [f("Cargo.toml"), f("target")]).isEmpty)
    }

    @Test func disabledToolchainsAreNeverOffered() throws {
        let c = try #require(BATestCatalog.fromSource())
        let d = { (n: String) in BuildArtifactCatalog.Entry(name: n, isDirectory: true, isSymlink: false, modified: nil) }
        let f = { (n: String) in BuildArtifactCatalog.Entry(name: n, isDirectory: false, isSymlink: false, modified: nil) }
        #expect(c.matches(in: [f("pom.xml"), d("target")]).isEmpty, "Maven ships disabled")
        #expect(c.matches(in: [f("requirements.txt"), d(".venv")], insideMarkerExists: { _, _ in true }).isEmpty)
    }
}

// MARK: - Scanner: fixture tree, negative cases, containment

@Suite("F-054 scanner")
struct BuildArtifactScannerTests {

    /// AC-1: one project per MVP toolchain, with expected attribution.
    @Test func fixtureTreeYieldsExactlyTheExpectedArtifacts() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.dir("x/App.xcodeproj"); f.file("x/build/a.o")
        f.file("s/Package.swift"); f.file("s/.build/x")
        f.file("n/package.json"); f.file("n/node_modules/lib/index.js"); f.file("n/node_modules/.bin/tool")
        f.file("r/Cargo.toml"); f.file("r/target/debug/x")
        f.file("g/build.gradle.kts"); f.file("g/build/o"); f.file("g/.gradle/c")
        f.file("fl/pubspec.yaml"); f.file("fl/build/x"); f.file("fl/.dart_tool/y")
        // Things that must NOT be offered:
        f.file("orphan/build/x"); f.file("orphan2/target/x"); f.file("orphan3/dist/x"); f.file("orphan4/node_modules/x")
        f.file("maven/pom.xml"); f.file("maven/target/x")                       // disabled toolchain
        f.file("n/dist/bundle.js")                                              // dist needs git-ignore, not a repo
        let r = await baScan(f)

        let got = Set(r.items.map { $0.artifactURL.path.replacingOccurrences(of: f.root.path + "/", with: "") })
        #expect(got == ["x/build", "s/.build", "n/node_modules", "r/target", "g/build", "g/.gradle",
                        "fl/build", "fl/.dart_tool"])
        let byPath = Dictionary(uniqueKeysWithValues: r.items.map { ($0.artifactURL.lastPathComponent + "@" + $0.projectName, $0) })
        #expect(byPath["node_modules@n"]?.toolchainID == "node")
        #expect(byPath["node_modules@n"]?.regenClass == .needsNetwork)
        #expect(byPath["target@r"]?.toolchainID == "rust")
        #expect(byPath["target@r"]?.regenClass == .safe)
        #expect(byPath["build@x"]?.toolchainID == "xcode-project")
        #expect(byPath["build@fl"]?.regenClass == .needsNetwork)
        #expect(r.items.allSatisfy { $0.gitStatus == .notRepo && $0.isUnverified && !$0.permanentRemovalEligible })
        // Ranked: results come back biggest first.
        #expect(r.items.map(\.size) == r.items.map(\.size).sorted(by: >))
    }

    /// AC-2: a build/target/dist/node_modules with no marker sibling is never offered.
    @Test func markerlessFoldersAreNeverOffered() async {
        let f = BAFixture(); defer { f.cleanup() }
        for n in ["build", "target", "dist", "node_modules", ".build", "Pods", ".gradle", "bin", "obj"] {
            f.file("lonely/\(n)/x")
        }
        let r = await baScan(f)
        #expect(r.items.isEmpty)
    }

    @Test func nestedArtifactsInsideAnArtifactAreNotReported() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("n/package.json"); f.file("n/node_modules/dep/package.json"); f.file("n/node_modules/dep/node_modules/x")
        let r = await baScan(f)
        #expect(r.items.map { $0.artifactURL.lastPathComponent } == ["node_modules"])
    }

    /// AC-4.
    @Test func symlinksAreNeverFollowedOrOffered() async {
        let f = BAFixture(); defer { f.cleanup() }
        let outside = BAFixture(); defer { outside.cleanup() }
        outside.file("victim/package.json"); outside.file("victim/node_modules/x")
        // A project whose node_modules is a symlink to a real directory elsewhere.
        f.file("sl/package.json"); f.link("sl/node_modules", to: outside.url("victim/node_modules"))
        // A project whose marker is a symlink.
        f.file("sl2/real-package.json"); f.link("sl2/package.json", to: f.url("sl2/real-package.json")); f.file("sl2/node_modules/x")
        // A symlinked directory inside the root that points at a whole outside project.
        f.link("escape", to: outside.url("victim"))
        let r = await baScan(f)
        #expect(r.items.isEmpty, "found: \(r.items.map(\.artifactURL.path))")
    }

    @Test func aSymlinkedRootIsResolvedAndStillContained() async {
        let f = BAFixture(); defer { f.cleanup() }
        let real = BAFixture(); defer { real.cleanup() }
        real.file("p/Cargo.toml"); real.file("p/target/x")
        f.link("rootlink", to: real.root)
        let r = await baScan(f, roots: [f.url("rootlink").path])
        #expect(r.items.count == 1)
        #expect(r.items.first.map { CleanupPath.isCovered($0.artifactURL.path, by: real.root.path) } == true)
    }

    /// AC-5 + D-03: Library, Downloads, .Trash, system folders are never scanned.
    @Test func excludedAreasAreNeverScanned() async {
        let f = BAFixture(); defer { f.cleanup() }
        let home = f.dir("home").path
        for p in ["Library/foo", "Downloads/proj", ".Trash/proj", "Library/Developer/Xcode/Archives/A/proj"] {
            f.file("home/\(p)/package.json"); f.file("home/\(p)/node_modules/x")
        }
        f.file("home/work/ok/package.json"); f.file("home/work/ok/node_modules/x")
        let r = await baScan(f, roots: [home], home: home)
        #expect(r.items.map(\.projectName) == ["ok"], "found: \(r.items.map(\.artifactURL.path))")
        // A root that IS an excluded area is dropped outright.
        let dl = await baScan(f, roots: [f.url("home/Downloads").path], home: home)
        #expect(dl.items.isEmpty && dl.summary.rootsScanned.isEmpty)
    }

    /// N3: Archives and Simulator data are hard-stopped even if a caller excludes nothing.
    @Test func xcodeArchivesAndSimulatorDataAreNeverTouchedEvenWithNoExclusions() async {
        let f = BAFixture(); defer { f.cleanup() }
        let home = f.dir("home").path
        for p in ["Library/Developer/Xcode/Archives/2026/App.xcarchive/proj",
                  "Library/Developer/CoreSimulator/Devices/ABC/data/proj",
                  "Library/Developer/CoreSimulator/Volumes/iOS/proj",
                  "work/App.xcarchive/proj"] {
            f.file("home/\(p)/Cargo.toml"); f.file("home/\(p)/target/x")
        }
        f.file("home/work/ok/Cargo.toml"); f.file("home/work/ok/target/x")
        let r = await baScan(f, roots: [home], home: home, excluded: [])
        #expect(r.items.map(\.projectName) == ["ok"], "found: \(r.items.map(\.artifactURL.path))")

        #expect(BuildArtifactSafety.isNeverTouch("\(home)/Library/Developer/Xcode/Archives", home: home))
        #expect(BuildArtifactSafety.isNeverTouch("\(home)/Library/Developer/Xcode/Archives/x/y", home: home))
        #expect(BuildArtifactSafety.isNeverTouch("\(home)/Library/Developer/CoreSimulator/Devices/A", home: home))
        #expect(BuildArtifactSafety.isNeverTouch("/x/y/Z.xcarchive", home: home))
        #expect(!BuildArtifactSafety.isNeverTouch("\(home)/Library/Developer/Xcode/DerivedData/App-abc", home: home))
        #expect(!BuildArtifactSafety.isNeverTouch("\(home)/Library/Developer/Xcode/ArchivesButNot", home: home))
    }

    @Test func theUserIgnoreListIsHonoured() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("r/Cargo.toml"); f.file("r/target/x")
        let first = await baScan(f)
        let key = try! #require(first.items.first).id
        let second = await baScan(f, ignored: [key])
        #expect(second.items.isEmpty && second.summary.skippedUserIgnored == 1)
    }

    @Test func recentlyModifiedItemsAreFlaggedActive() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("r/Cargo.toml"); f.file("r/target/x")
        let r = await baScan(f)
        #expect(r.items.first?.isActive == true)
        // ...and an old one is not.
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        for rel in ["r/Cargo.toml", "r/target/x", "r/target", "r"] {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.url(rel).path)
        }
        let r2 = await baScan(f)
        #expect(r2.items.first?.isActive == false)
    }

    @Test func missingCatalogueIsReportedNotSilent() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("r/Cargo.toml"); f.file("r/target/x")
        let r = await baScan(f, catalog: nil)
        #expect(r.items.isEmpty && r.summary.catalogMissing)
    }

    @Test func cancellingStopsTheScanPromptly() async {
        let f = BAFixture(); defer { f.cleanup() }
        for i in 0..<300 { f.file("d\(i)/sub/x") }
        let scanner = BuildArtifactScanner(catalog: BATestCatalog.fromSource())
        var cfg = BuildArtifactScanner.Config(); cfg.home = f.url("home").path
        cfg.excludedPaths = []
        let t = Task { () -> Int in
            var n = 0
            for await ev in await scanner.scan(roots: [f.root.path], config: cfg) { if case .found = ev { n += 1 } }
            return n
        }
        t.cancel()
        let start = Date()
        _ = await t.value
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// Xcode (global), D7 / D-04 — sourced from the same scanner, DerivedData children only.
    @Test func xcodeGlobalItemsComeFromDerivedDataAndSimulatorCachesOnly() async {
        let f = BAFixture(); defer { f.cleanup() }
        let home = f.dir("home").path
        f.file("home/Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyz/Build/x", bytes: 5_000)
        f.file("home/Library/Developer/CoreSimulator/Caches/dyld/y", bytes: 5_000)
        f.file("home/Library/Developer/Xcode/Archives/2026/keep.xcarchive/z", bytes: 5_000)
        f.file("home/Library/Developer/CoreSimulator/Devices/D/data/z", bytes: 5_000)
        var cfg = BuildArtifactScanner.Config(); cfg.home = home
        let items = await BuildArtifactScanner(catalog: nil).xcodeGlobalItems(config: cfg)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.isXcodeGlobal && $0.regenClass == .safe && !$0.permanentRemovalEligible })
        #expect(items.allSatisfy { !$0.artifactURL.path.contains("Archives") && !$0.artifactURL.path.contains("/Devices/") })
        #expect(items.contains { $0.projectName == "App" })
    }
}

// MARK: - Git gate (real `git init` in a temp dir)

@Suite("F-054 git gate")
struct BuildArtifactGitGateTests {
    static let git = GitGate.locateGit()

    @discardableResult
    static func run(_ args: [String]) -> Bool { ShellReader.run(git!, args, timeout: 20).succeeded }

    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func trackedIgnoredAndNotIgnoredAreToldApart() async {
        let f = BAFixture(); defer { f.cleanup() }
        // ignored: node_modules/ and dist/ are in .gitignore.
        f.file("ign/package.json"); f.file("ign/.gitignore", bytes: 0)
        try! "node_modules/\ndist/\n".write(to: f.url("ign/.gitignore"), atomically: true, encoding: .utf8)
        f.file("ign/node_modules/x"); f.file("ign/dist/y")
        #expect(Self.run(["-C", f.url("ign").path, "init", "-q"]))
        // tracked: target/ was committed to the index.
        f.file("trk/Cargo.toml"); f.file("trk/target/x")
        #expect(Self.run(["-C", f.url("trk").path, "init", "-q"]))
        #expect(Self.run(["-C", f.url("trk").path, "add", "-A"]))
        // untracked and NOT ignored.
        f.file("nig/Cargo.toml"); f.file("nig/target/x")
        #expect(Self.run(["-C", f.url("nig").path, "init", "-q"]))

        #expect(GitGate.inspect(artifactName: "node_modules", project: f.url("ign")) == .ignored)
        #expect(GitGate.inspect(artifactName: "dist", project: f.url("ign")) == .ignored)
        #expect(GitGate.inspect(artifactName: "target", project: f.url("trk")) == .tracked)
        #expect(GitGate.inspect(artifactName: "target", project: f.url("nig")) == .notIgnored)

        let r = await baScan(f)
        let got = Dictionary(uniqueKeysWithValues: r.items.map { ($0.artifactURL.path.replacingOccurrences(of: f.root.path + "/", with: ""), $0) })
        #expect(Set(got.keys) == ["ign/node_modules", "ign/dist"], "tracked and non-ignored must never be offered; got \(got.keys)")
        #expect(got["ign/node_modules"]?.gitStatus == .ignored)
        #expect(got["ign/node_modules"]?.permanentRemovalEligible == false, "needs-network is never permanent-eligible (D-02)")
        #expect(r.summary.skippedTrackedByGit == 1 && r.summary.skippedNotGitIgnored == 1)
    }

    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func aSafeGitVerifiedItemIsPermanentRemovalEligible() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("r/Cargo.toml"); f.file("r/.gitignore")
        try! "target/\n".write(to: f.url("r/.gitignore"), atomically: true, encoding: .utf8)
        f.file("r/target/x")
        #expect(Self.run(["-C", f.url("r").path, "init", "-q"]))
        let r = await baScan(f, now: baAged)
        #expect(r.items.count == 1 && r.items[0].gitStatus == .ignored && r.items[0].permanentRemovalEligible)
        // Same folder, scanned "now": freshly built => Active => Move to Trash only.
        let fresh = await baScan(f)
        #expect(fresh.items.count == 1 && fresh.items[0].isActive && !fresh.items[0].permanentRemovalEligible)
    }

    /// Spike S-A degrade path: git cannot be consulted (sandboxed build / no git).
    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func whenGitCannotRunRepoItemsAreUnverifiedAndDistLikeFoldersAreDropped() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("r/Cargo.toml"); f.file("r/target/x"); f.file("r/dist/x")
        f.file("n/package.json"); f.file("n/dist/x"); f.file("n/node_modules/x")
        #expect(Self.run(["-C", f.url("r").path, "init", "-q"]))
        #expect(Self.run(["-C", f.url("n").path, "init", "-q"]))
        let r = await baScan(f, useGit: false)
        let got = Set(r.items.map { $0.artifactURL.path.replacingOccurrences(of: f.root.path + "/", with: "") })
        #expect(got == ["r/target", "n/node_modules"], "dist/ needs a positive git-ignore and must not be offered; got \(got)")
        #expect(r.items.allSatisfy { $0.gitStatus == .unavailable && $0.isUnverified && !$0.permanentRemovalEligible })
        #expect(r.items.allSatisfy { !$0.isSmartSelectable() }, "smart-select must skip what git could not vouch for")
        #expect(r.summary.gitUnavailableInRepo == 2)
        #expect(GitGate.inspect(artifactName: "target", project: f.url("r"), gitPath: nil) == .unavailable)
    }

    @Test func notARepoIsDetectedByTheFilesystemWithoutSpawningAnything() {
        let f = BAFixture(); defer { f.cleanup() }
        f.dir("p")
        #expect(!GitGate.isInsideWorkTreeByFilesystem(f.url("p")))
        f.dir("q/.git"); f.dir("q/sub/deep")
        #expect(GitGate.isInsideWorkTreeByFilesystem(f.url("q/sub/deep")))
        #expect(GitGate.inspect(artifactName: "build", project: f.url("p"), gitPath: nil) == .notRepo)
    }
}

// MARK: - Sizing (D6 / AC-6 / AC-13 method)

@Suite("F-054 sizing")
struct BuildArtifactSizingTests {

    /// A node_modules-like tree of 21,000+ files (the old SpaceLens cap was 20,000), including hidden
    /// dot-folders, agrees with `du`.
    @Test func exactSizeAgreesWithDuOnAnUncappedNodeModulesLikeTree() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("n/package.json")
        let fm = FileManager.default
        for d in 0..<210 {
            let dir = f.url("n/node_modules/pkg\(d)/lib")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<100 {
                try Data(repeating: 0x42, count: (i % 7 == 0) ? 9_000 : 40).write(to: dir.appendingPathComponent("f\(i).js"))
            }
        }
        try fm.createDirectory(at: f.url("n/node_modules/.bin"), withIntermediateDirectories: true)
        for i in 0..<50 { try Data(repeating: 0x43, count: 5_000).write(to: f.url("n/node_modules/.bin/t\(i)")) }
        try fm.createDirectory(at: f.url("n/node_modules/.cache/x"), withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 3_000_000).write(to: f.url("n/node_modules/.cache/x/blob"))

        let target = f.url("n/node_modules")
        let mine = try #require(BuildArtifactScanner.exactSize(of: target))
        let du = ShellReader.run("/usr/bin/du", ["-sk", target.path], timeout: 60)
        #expect(du.succeeded)
        let duBytes = Int64(du.standardOutput.split(separator: "\t").first.flatMap { Int64($0) } ?? 0) * 1024
        let drift = abs(Double(mine - duBytes)) / Double(max(duBytes, 1))
        #expect(drift < 0.005, "exactSize \(mine) vs du \(duBytes)")
        // Hidden content really counted (3 MB blob is in .cache).
        #expect(mine > 3_000_000)

        // End to end: the scanner reports that same number.
        let r = await baScan(f)
        #expect(r.items.count == 1)
        #expect(r.items.first?.size == mine)
        // More than 20,000 files were involved (the cap that would have understated this).
        let count = (fm.enumerator(at: target, includingPropertiesForKeys: nil)?.allObjects.count) ?? 0
        #expect(count > 21_000)
    }

    @Test func symlinksInsideAnArtifactAreCountedAsLinksNotFollowed() throws {
        let f = BAFixture(); defer { f.cleanup() }
        let big = BAFixture(); defer { big.cleanup() }
        big.file("huge", bytes: 5_000_000)
        f.file("a/x", bytes: 100)
        f.link("a/link", to: big.url("huge"))
        let s = try #require(BuildArtifactScanner.exactSize(of: f.url("a")))
        #expect(s < 1_000_000)
    }
}

// MARK: - Roots & invariants (D-03, D-04, BUG-001 one owner per path)

@Suite("F-054 roots")
struct BuildArtifactRootsTests {

    private func allRoots(buildDefaults: [String]) -> [(kind: CleanupKind, paths: [String])] {
        CleanupKind.allCases.filter { $0 != .buildArtifacts }.map { (kind: $0, paths: $0.targetPaths) }
            + [(kind: .buildArtifacts, paths: buildDefaults)]
    }

    /// The default roots of Build Artifacts (and its fixed Xcode-global folders) overlap no other
    /// category's roots. Mutation: put `~/Downloads` in `defaultRoots` => this goes red.
    @Test func noTwoCleanupCategoriesOverlapRoots() {
        let defaults = BuildArtifactRoots.defaultRoots(exists: { _ in true }) + BuildArtifactRoots.xcodeGlobalRoots()
        let overlaps = CleanupPath.overlappingRoots(allRoots(buildDefaults: defaults))
        #expect(overlaps.isEmpty, "\(overlaps.map { "\($0.a) / \($0.b): \($0.path)" })")
        let home = NSHomeDirectory()
        #expect(!defaults.contains("\(home)/Downloads"))
    }

    @Test func theInvariantWouldCatchDownloadsInTwoCategories() {
        let home = NSHomeDirectory()
        let bad = BuildArtifactRoots.defaultRoots(exists: { _ in true }) + ["\(home)/Downloads"]
        #expect(!CleanupPath.overlappingRoots(allRoots(buildDefaults: bad)).isEmpty)
        // ...and a parent of Downloads (home itself, Documents' parent) would too.
        #expect(!CleanupPath.overlappingRoots(allRoots(buildDefaults: [home])).isEmpty)
    }

    @Test func xcodeDataIsRetiredFromThePaneAndOwnsNoRoots() {
        #expect(CleanupKind.xcodeData.targetPaths.isEmpty)
        #expect(!CleanupKind.cleanupPaneKinds.contains(.xcodeData))
        #expect(CleanupKind.cleanupPaneKinds.contains(.buildArtifacts))
        let owners = CleanupKind.allCases.filter { kind in
            kind.targetPaths.contains { CleanupPath.isCovered(BuildArtifactRoots.xcodeGlobalRoots()[0], by: $0) }
        }
        #expect(owners.isEmpty, "DerivedData must have exactly one owner (Build Artifacts)")
    }

    @Test func defaultRootsNeverIncludeDownloadsOrLibrary() {
        let roots = BuildArtifactRoots.defaultRoots(home: "/h", exists: { _ in true })
        #expect(!roots.contains { $0.contains("Downloads") || $0.contains("Library") })
        #expect(roots.contains("/h/Documents") && roots.contains("/h/Github"))
        #expect(BuildArtifactRoots.defaultExcluded(home: "/h").contains("/h/Downloads"))
    }

    @Test func rootsStoreSandboxedWithNoGrantsHasNoRootsAndPrunesNesting() {
        let suite = "f054-roots-\(UUID())"
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let s = BuildArtifactRootsStore(defaults: d)
        #expect(s.scanRoots(sandboxed: true).isEmpty, "sandboxed + nothing granted => Choose-folders state, not a silent default crawl")
        s.addRoot(URL(fileURLWithPath: "/tmp/f054-a"), sandboxed: false)
        s.addRoot(URL(fileURLWithPath: "/tmp/f054-a/inner"), sandboxed: false)
        let unsandboxed = s.scanRoots(sandboxed: false, home: "/nonexistent", exists: { !$0.hasPrefix("/nonexistent") })
        #expect(unsandboxed == ["/tmp/f054-a"], "nested root must be pruned: \(unsandboxed)")
        #expect(BuildArtifactRootsStore.pruneNested(["/a/b", "/a", "/a/bc", "/a"]) == ["/a"])
        #expect(BuildArtifactRootsStore.pruneNested(["/a/b", "/a/bc"]) == ["/a/b", "/a/bc"])
        s.ignore("/x/y"); #expect(s.ignoredPaths == ["/x/y"]); s.resetIgnoreList(); #expect(s.ignoredPaths.isEmpty)
    }
}

// MARK: - Remover (D4b / FR-U5b / AC-14)

/// A stand-in Trash: a temp directory plus a `trashItem` that moves into it and reports the URL, the
/// way the system call does. Counts calls so a test can prove an item was never touched.
/// Whether the real Trash can be used by a test at all.
enum BATrash {
    static var realDirectories: [URL] { FileManager.default.urls(for: .trashDirectory, in: .userDomainMask) }
    /// An existing, writable directory. `trashItem` needs nothing more, and the round-trip test does
    /// not read the Trash's contents.
    static func isUsable(_ dirs: [URL]) -> Bool {
        guard let d = dirs.first else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: d.path)
    }
}

final class FakeTrash: @unchecked Sendable {
    let dir: URL
    private let lock = NSLock()
    private(set) var calls: [URL] = []
    var failFor: Set<String> = []
    var reportNil: Set<String> = []
    var reportInstead: [String: URL] = [:]   // name -> URL to report (outside the Trash)

    init(in f: BAFixture, name: String = "FakeTrash") { dir = f.dir(name) }

    var function: BuildArtifactRemover.TrashFunction {
        { [self] url in
            lock.lock(); calls.append(url); lock.unlock()
            let name = url.lastPathComponent
            if failFor.contains(name) { throw CocoaError(.fileWriteNoPermission) }
            var dest = dir.appendingPathComponent(name)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) { dest = dir.appendingPathComponent("\(name) \(n)"); n += 1 }
            try FileManager.default.moveItem(at: url, to: dest)
            if reportNil.contains(name) { return nil }
            return reportInstead[name] ?? dest
        }
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

@Suite("F-054 remover")
struct BuildArtifactRemoverTests {

    private func makeItems(_ f: BAFixture, names: [String]) -> [BuildArtifactItem] {
        names.map { n in
            f.file("proj/\(n)/artifact.bin", bytes: 64)
            return baItem(f.url("proj/\(n)"))
        }
    }

    /// AC-14. Permanent removal acts ONLY on the URLs trashItem returned; a sentinel already in the
    /// Trash survives. Mutation: replace the returned-URL list with a Trash enumeration => red.
    @Test func trashAndEmptyRemovesExactlyTheReturnedURLsAndTheSentinelSurvives() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let sentinel = f.file("FakeTrash/sentinel.txt", bytes: 8)
        f.dir("FakeTrash/someone-elses-folder"); f.file("FakeTrash/someone-elses-folder/doc.txt")
        let items = makeItems(f, names: ["a", "b"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.moved.count == 2 && out.permanentlyRemoved.count == 2)
        #expect(out.failed.isEmpty && out.leftInTrash.isEmpty && out.refused.isEmpty)
        #expect(!f.exists("proj/a") && !f.exists("proj/b"), "originals moved")
        #expect(!f.exists("FakeTrash/a") && !f.exists("FakeTrash/b"), "and removed from the Trash")
        #expect(FileManager.default.fileExists(atPath: sentinel.path), "the sentinel in the Trash must survive")
        #expect(f.exists("FakeTrash/someone-elses-folder/doc.txt"))
    }

    @Test func moveToTrashIsRecoverableAndNeverRemoves() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let items = makeItems(f, names: ["a", "b"])
        let out = BuildArtifactRemover.moveToTrash(items, trash: trash.function, home: f.url("home").path)
        #expect(out.moved.count == 2 && out.permanentlyRemoved.isEmpty)
        #expect(f.exists("FakeTrash/a/artifact.bin") && f.exists("FakeTrash/b/artifact.bin"))
        #expect(!f.exists("proj/a"))
    }

    @Test func anItemWhoseTrashItemFailsIsNotRemovedAndIsReported() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f); trash.failFor = ["b"]
        let items = makeItems(f, names: ["a", "b"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.moved == [items[0].id] && out.permanentlyRemoved == [items[0].id])
        #expect(out.failed.map(\.id) == [items[1].id])
        #expect(f.exists("proj/b/artifact.bin"), "failed item stays exactly where it was")
    }

    @Test func aNilResultingURLMeansMovedButLeftInTrash() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f); trash.reportNil = ["a"]
        let items = makeItems(f, names: ["a"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.moved == [items[0].id] && out.permanentlyRemoved.isEmpty && out.leftInTrash.count == 1)
        #expect(f.exists("FakeTrash/a/artifact.bin"), "nothing is guessed or reconstructed — it stays in the Trash")
    }

    @Test func aResultingURLOutsideAnyTrashIsRefused() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("elsewhere/precious.txt")
        trash.reportInstead = ["a": f.url("elsewhere")]
        let items = makeItems(f, names: ["a"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.permanentlyRemoved.isEmpty && out.leftInTrash.count == 1)
        #expect(f.exists("elsewhere/precious.txt"), "a URL outside the Trash is never removed")
    }

    @Test func aSymlinkResultOrASymlinkedParentIsRefused() {
        let f = BAFixture(); defer { f.cleanup() }
        let victim = f.dir("victim"); f.file("victim/keep.txt")
        let trash = FakeTrash(in: f)
        // (1) the reported URL is itself a symlink inside the Trash
        f.link("FakeTrash/linkresult", to: victim)
        #expect(!BuildArtifactRemover.isInsideTrash(f.url("FakeTrash/linkresult"), trashDirectories: [trash.dir]))
        // (2) the reported URL goes through a symlinked directory that leaves the Trash
        f.link("FakeTrash/dirlink", to: victim)
        #expect(!BuildArtifactRemover.isInsideTrash(f.url("FakeTrash/dirlink/keep.txt"), trashDirectories: [trash.dir]))
        // (3) the Trash directory itself is not "inside" itself
        #expect(!BuildArtifactRemover.isInsideTrash(trash.dir, trashDirectories: [trash.dir]))
        // (4) a normal child is
        f.file("FakeTrash/ok.txt")
        #expect(BuildArtifactRemover.isInsideTrash(f.url("FakeTrash/ok.txt"), trashDirectories: [trash.dir]))
        // end to end on (1)
        trash.reportInstead = ["a": f.url("FakeTrash/linkresult")]
        let items = makeItems(f, names: ["a"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.permanentlyRemoved.isEmpty)
        #expect(f.exists("victim/keep.txt"))
    }

    /// D-02: only Safe + git-verified. Everything else is refused and the trash function is never called.
    @Test func ineligibleItemsAreRefusedUntouched() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let combos: [(BuildArtifactRegenClass, BuildArtifactGitStatus)] = [
            (.needsNetwork, .ignored), (.caution, .ignored), (.safe, .notRepo), (.safe, .unavailable), (.safe, .notApplicable)]
        var items: [BuildArtifactItem] = []
        for (i, c) in combos.enumerated() {
            f.file("proj/i\(i)/x"); items.append(baItem(f.url("proj/i\(i)"), cls: c.0, git: c.1))
        }
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.refused.count == 5 && out.moved.isEmpty && trash.callCount == 0)
        #expect((0..<5).allSatisfy { f.exists("proj/i\($0)/x") })
    }

    /// S-B: unproven in a sandboxed build => unavailable.
    @Test func permanentRemovalIsUnavailableWhenSandboxed() {
        #expect(BuildArtifactRemover.permanentRemovalAvailable(sandboxed: false))
        #expect(!BuildArtifactRemover.permanentRemovalAvailable(sandboxed: true))
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let items = makeItems(f, names: ["a"])
        let out = BuildArtifactRemover.trashAndEmpty(items, trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: false)
        #expect(out.refused.count == 1 && out.moved.isEmpty && trash.callCount == 0 && f.exists("proj/a/artifact.bin"))
    }

    @Test func aFolderSwappedForASymlinkOrGoneBeforeConfirmIsNotTouched() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let victim = f.dir("victim"); f.file("victim/keep.txt")
        f.link("proj/swapped", to: victim)
        let swapped = baItem(f.url("proj/swapped"))
        let gone = baItem(f.url("proj/gone"))
        let out = BuildArtifactRemover.moveToTrash([swapped, gone], trash: trash.function, home: f.url("home").path)
        #expect(out.failed.count == 2 && out.moved.isEmpty && trash.callCount == 0)
        #expect(f.exists("victim/keep.txt"))
    }

    @Test func protectedPathsAreRefusedAtRemovalTimeToo() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        let home = f.dir("home").path
        f.file("home/Library/Developer/Xcode/Archives/2026/A.xcarchive/x")
        let it = baItem(f.url("home/Library/Developer/Xcode/Archives/2026/A.xcarchive"))
        let out = BuildArtifactRemover.moveToTrash([it], trash: trash.function, home: home)
        #expect(out.failed.count == 1 && trash.callCount == 0)
        #expect(f.exists("home/Library/Developer/Xcode/Archives/2026/A.xcarchive/x"))
    }

    /// End to end through the REAL `FileManager.trashItem` and the real Trash directory list, on a
    /// uniquely named temp folder. Proves `resultingItemURL` is what isInsideTrash expects. Touches the
    /// user's real Trash only with this one folder, which it removes again. OPT-IN: a default test run
    /// must never touch the real Trash (review of #66), so it runs only with `HALO_TEST_REAL_TRASH=1`
    /// in the environment AND a usable Trash (`BATrash.isUsable`); otherwise it is skipped, not failed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HALO_TEST_REAL_TRASH"] == "1"
                       && BATrash.isUsable(BATrash.realDirectories)))
    func realTrashItemRoundTrip() {
        let f = BAFixture(); defer { f.cleanup() }
        let unique = "f054-roundtrip-\(UUID().uuidString)"
        f.file("proj/\(unique)/artifact.bin", bytes: 64)
        let item = baItem(f.url("proj/\(unique)"))
        let out = BuildArtifactRemover.trashAndEmpty([item], home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        // The system itself refused to trash (no permission / no Trash after all): that is the
        // environment, not a regression in the remover — nothing was touched, so end the test quietly.
        if out.moved.isEmpty, out.leftInTrash.isEmpty, out.refused.isEmpty, f.exists("proj/\(unique)") { return }
        #expect(out.moved == [item.id], "failed: \(out.failed) left: \(out.leftInTrash) refused: \(out.refused)")
        #expect(out.permanentlyRemoved == [item.id], "left in Trash: \(out.leftInTrash.map(\.message))")
        #expect(!f.exists("proj/\(unique)"))
        let trashed = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.appendingPathComponent(unique)
        #expect(trashed.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

// MARK: - View model (selection, review, partial failure, supersession, reconcile)

func baStream(_ items: [BuildArtifactItem], delayMs: UInt64 = 0) -> AsyncStream<BuildArtifactScanEvent> {
    AsyncStream { c in
        Task {
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            for i in items { c.yield(.found(i)) }
            c.yield(.finished(BuildArtifactScanSummary()))
            c.finish()
        }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor
@Suite("F-054 view model")
struct BuildArtifactsViewModelTests {

    private func makeVM(_ f: BAFixture, sandboxed: Bool = false, trash: FakeTrash? = nil,
                        scan: BuildArtifactsViewModel.ScanFunction? = nil) -> BuildArtifactsViewModel {
        let suite = "f054-vm-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let t = trash ?? FakeTrash(in: f)
        return BuildArtifactsViewModel(roots: BuildArtifactRootsStore(defaults: defaults), sandboxed: sandboxed,
                                       home: f.url("home").path, trash: t.function, trashDirectories: [t.dir], scan: scan)
    }

    /// AC-10.
    @Test func smartSelectNeverPicksCautionActiveOrUnverifiedInRepo() async {
        let f = BAFixture(); defer { f.cleanup() }
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        let items = [
            baItem(f.url("a"), project: "ok-safe", modified: old),
            baItem(f.url("b"), git: .notRepo, project: "ok-nonrepo", modified: old),
            baItem(f.url("c"), cls: .caution, project: "caution", modified: old),
            baItem(f.url("d"), active: true, project: "active", modified: old),
            baItem(f.url("e"), git: .unavailable, project: "git-unavailable", modified: old),
            baItem(f.url("g"), cls: .needsNetwork, project: "net", modified: old),
            baItem(f.url("h"), project: "fresh", modified: Date()),
            baItem(f.url("i"), project: "in-use", modified: old, inUse: true),
        ]
        let vm = makeVM(f, scan: { _, _ in AsyncStream { c in for i in items { c.yield(.found(i)) }; c.yield(.finished(.init())); c.finish() } })
        await vm.scan()
        vm.selectAllSafe()
        let names = Set(vm.selectedItems.map(\.projectName))
        // `ok-nonrepo` is Unverified (nothing but a marker pair vouches for it): not "Safe".
        #expect(names == ["ok-safe", "fresh"], "\(names)")
        vm.selectStale()
        let stale = Set(vm.selectedItems.map(\.projectName))
        #expect(stale == ["ok-safe", "ok-nonrepo", "net"], "\(stale)")
        #expect(!stale.contains("caution") && !stale.contains("active") && !stale.contains("git-unavailable") && !stale.contains("in-use"))
        vm.selectNone(); #expect(vm.selection.isEmpty)
    }

    /// Review note #2: "Select all Safe" says Safe. Unverified (.notRepo) is out; Xcode's fixed
    /// folders (no project, no git to ask) and git-verified Safe items stay in.
    @Test func selectAllSafeExcludesUnverifiedButKeepsXcodeAndGitVerified() async {
        let f = BAFixture(); defer { f.cleanup() }
        let items = [
            baItem(f.url("a"), git: .ignored, project: "verified"),
            baItem(f.url("b"), git: .notRepo, project: "unverified"),
            baItem(f.url("c"), git: .notApplicable, project: "xcode", toolchain: BuildArtifactScanner.xcodeGlobalToolchainID),
        ]
        let vm = makeVM(f, scan: { _, _ in AsyncStream { c in for i in items { c.yield(.found(i)) }; c.finish() } })
        await vm.scan()
        vm.selectAllSafe()
        #expect(Set(vm.selectedItems.map(\.projectName)) == ["verified", "xcode"])
        #expect(items[1].isUnverified && !items[1].isVerifiedSafe && items[0].isVerifiedSafe && items[2].isVerifiedSafe)
    }

    /// BUG-001 FR-4: a newer scan supersedes an older one; a stale result never lands.
    @Test func aSupersededScanNeverOverwritesANewerOne() async {
        let f = BAFixture(); defer { f.cleanup() }
        let slow = baItem(f.url("slow"), project: "slow"), fast = baItem(f.url("fast"), project: "fast")
        let counter = CallCounter()
        let vm = makeVM(f, scan: { _, _ in
            counter.next() == 1 ? baStream([slow], delayMs: 400) : baStream([fast])
        })
        vm.rescan()
        for _ in 0..<200 where !vm.isScanning { try? await Task.sleep(nanoseconds: 10_000_000) }   // scan 1 really started
        await vm.scan()
        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(vm.items.map(\.projectName) == ["fast"], "stale scan landed: \(vm.items.map(\.projectName))")
        #expect(!vm.isScanning)
    }

    @Test func sandboxedWithNoGrantedRootsShowsChooseFoldersNotAnEmptyList() async {
        let f = BAFixture(); defer { f.cleanup() }
        let calls = CallCounter()
        let vm = makeVM(f, sandboxed: true, scan: { _, _ in calls.next(); return AsyncStream { $0.finish() } })
        await vm.scan()
        #expect(vm.needsRoots && calls.value == 0 && !vm.isScanning)
        #expect(!vm.gitGateAvailable && !vm.permanentRemovalAvailable)
        let open = makeVM(f)
        #expect(open.gitGateAvailable && open.permanentRemovalAvailable)
    }

    /// AC-8: Cancel on the review sheet deletes nothing.
    @Test func cancellingTheReviewDeletesNothing() async {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x"); f.file("proj/b/x")
        let items = [baItem(f.url("proj/a")), baItem(f.url("proj/b"))]
        let vm = makeVM(f, trash: trash, scan: { _, _ in AsyncStream { c in for i in items { c.yield(.found(i)) }; c.finish() } })
        await vm.scan()
        vm.selection = Set(items.map(\.id))
        vm.beginReview()
        #expect(vm.review?.items.count == 2)
        vm.cancelReview()
        #expect(vm.review == nil && trash.callCount == 0 && f.exists("proj/a/x") && f.exists("proj/b/x"))
        #expect(vm.items.count == 2)
    }

    /// AC-8 / FR-U6: partial failure is reported truthfully and only moved rows leave the list;
    /// AC-9: the removed URL is reported so every Cleanup list forgets it at once.
    @Test func partialFailureRemovesOnlyMovedRowsAndReconcilesTheRestOfCleanup() async {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f); trash.failFor = ["b"]
        f.file("proj/a/x"); f.file("proj/b/x")
        let a = baItem(f.url("proj/a"), size: 500), b = baItem(f.url("proj/b"), size: 300)
        let vm = makeVM(f, trash: trash, scan: { _, _ in AsyncStream { c in c.yield(.found(a)); c.yield(.found(b)); c.finish() } })
        // Another Cleanup category lists the same path (the BUG-001 shape).
        let cleanup = CleanupViewModel(coordinator: ScanCoordinator(), kinds: [])
        var cat = CleanupCategory(kind: .userCaches)
        cat.items = [ScannedItem(id: UUID(), url: a.artifactURL.appendingPathComponent("x"), size: 5,
                                 creationDate: nil, modifiedDate: nil, kind: .cache)]
        cleanup.categories = [cat]
        var reported: [URL] = []
        vm.onRemoved = { reported = $0; cleanup.reconcile(removed: $0) }

        await vm.scan()
        vm.selection = [a.id, b.id]
        vm.beginReview()
        await vm.confirm(.trash)

        #expect(vm.items.map(\.id) == [b.id], "only the item that really moved leaves the list")
        #expect(reported.map(\.lastPathComponent) == ["a"])
        #expect(vm.banner?.isError == true && vm.banner?.text.contains("\"b\"") == true && vm.banner?.text.contains("Moved 1") == true)
        #expect(vm.banner?.text.contains("empty the Trash") == true, "D4: must not imply space was freed")
        #expect(f.exists("proj/b/x") && !f.exists("proj/a"))
        #expect(cleanup.categories[0].items.isEmpty, "other Cleanup lists forget it without a rescan")
    }

    /// The confirmation acts on the frozen snapshot, not on what a later scan found.
    @Test func confirmationActsOnTheFrozenSnapshotOnly() async {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x"); f.file("proj/late/x")
        let a = baItem(f.url("proj/a")), late = baItem(f.url("proj/late"))
        let which = CallCounter()
        let vm = makeVM(f, trash: trash, scan: { _, _ in
            let n = which.next()
            return AsyncStream { c in c.yield(.found(a)); if n > 1 { c.yield(.found(late)) }; c.finish() }
        })
        await vm.scan(); vm.selection = [a.id]; vm.beginReview()
        await vm.scan(); vm.selection.insert(late.id)          // a rescan lands while the sheet is open
        await vm.confirm(.trash)
        #expect(trash.calls.map(\.lastPathComponent) == ["a"])
        #expect(f.exists("proj/late/x"))
    }

    @Test func trashAndEmptyIsRefusedByTheViewModelWhenSandboxed() async {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x")
        let a = baItem(f.url("proj/a"))
        let vm = makeVM(f, sandboxed: true, trash: trash, scan: { _, _ in AsyncStream { c in c.yield(.found(a)); c.finish() } })
        await vm.scan()   // needsRoots (no bookmark) -> list empty; seed the review directly
        let snap = BuildArtifactsViewModel.ReviewSnapshot(items: [a])
        vm.review = snap
        await vm.confirm(.trashAndEmpty)
        #expect(trash.callCount == 0 && f.exists("proj/a/x"))
        #expect(vm.banner?.isError == true)
    }

    @Test func reviewSnapshotEligibilityFollowsD02() {
        let f = BAFixture(); defer { f.cleanup() }
        let ok = baItem(f.url("a")), net = baItem(f.url("b"), cls: .needsNetwork)
        #expect(BuildArtifactsViewModel.ReviewSnapshot(items: [ok]).allPermanentEligible)
        let mixed = BuildArtifactsViewModel.ReviewSnapshot(items: [ok, net])
        #expect(!mixed.allPermanentEligible && mixed.ineligibleForPermanent == 1)
        #expect(!BuildArtifactsViewModel.ReviewSnapshot(items: []).allPermanentEligible)
    }

    /// Strict on purpose (the first version used `||` alternatives and could not fail): exact section
    /// order, exact contents, biggest first inside each section.
    @Test func groupingAndFiltersAreSortedBiggestFirst() async {
        let f = BAFixture(); defer { f.cleanup() }
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        let items = [baItem(f.url("a"), size: 10, project: "p1", toolchain: "rust", modified: old),
                     baItem(f.url("b"), size: 90, project: "p2", toolchain: "node", modified: Date()),
                     baItem(f.url("c"), size: 50, project: "p1", toolchain: "rust", modified: Date())]
        let vm = makeVM(f, scan: { _, _ in AsyncStream { c in for i in items { c.yield(.found(i)) }; c.finish() } })
        await vm.scan()
        #expect(vm.items.map(\.size) == [90, 50, 10])

        vm.grouping = .biggest
        #expect(vm.sections.map(\.title) == [""])
        #expect(vm.sections[0].items.map(\.size) == [90, 50, 10])

        vm.grouping = .project                      // p2 = 90, p1 = 60
        #expect(vm.sections.map(\.title) == ["p2", "p1"])
        #expect(vm.sections.map { $0.items.map(\.size) } == [[90], [50, 10]])

        vm.grouping = .toolchain                    // Node = 90, Rust = 60
        #expect(vm.sections.map(\.title) == ["Node", "Rust"])
        #expect(vm.sections.map { $0.items.map(\.size) } == [[90], [50, 10]])

        vm.grouping = .biggest; vm.toolchainFilter = "rust"
        #expect(vm.visibleItems.map(\.size) == [50, 10])
        vm.toolchainFilter = nil; vm.staleOnly = true
        #expect(vm.visibleItems.map(\.size) == [10], "only the folder untouched for 90 days is stale")
    }

    /// Review note #4: a scan still running when a removal completes must not put the trashed row back.
    @Test func aScanRunningDuringARemovalNeverRelistsTheTrashedRow() async {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x"); f.file("proj/b/x")
        let a = baItem(f.url("proj/a"), project: "a"), b = baItem(f.url("proj/b"), project: "b")
        let calls = CallCounter()
        // Scan 1 already sized both folders and is about to report them (slow stream).
        let vm = makeVM(f, trash: trash, scan: { _, _ in calls.next(); return baStream([a, b], delayMs: 1_500) })
        vm.rescan()
        for _ in 0..<300 where !vm.isScanning { try? await Task.sleep(nanoseconds: 10_000_000) }   // scan really running
        #expect(vm.isScanning)
        vm.review = BuildArtifactsViewModel.ReviewSnapshot(items: [a])
        await vm.confirm(.trash)
        #expect(!f.exists("proj/a"), "a was moved to the (fake) Trash while the scan was running")
        #expect(vm.isScanning, "the removal finished well inside the scan's delay, so the scan was still in flight")
        for _ in 0..<600 where vm.isScanning { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!vm.isScanning)
        #expect(vm.items.map(\.projectName) == ["b"], "the scan re-listed a row that is already in the Trash: \(vm.items.map(\.projectName))")
    }
}

// MARK: - Independent-review additions (PR #59): re-verification, TOCTOU, exclusions

@Suite("F-054 review hardening")
struct BuildArtifactReviewHardeningTests {

    /// The permanent action re-asks before it deletes: a refusing verifier means nothing is touched.
    @Test func permanentRemovalIsRefusedWhenReverificationFailsAndNothingIsTouched() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x"); let it = baItem(f.url("proj/a"))
        let out = BuildArtifactRemover.trashAndEmpty([it], trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true,
                                                    reverify: { _ in "no" })
        #expect(out.refused.count == 1 && out.moved.isEmpty && trash.callCount == 0 && f.exists("proj/a/x"))
    }

    /// Default verifier, real git: a folder that was ignored at scan time and is then force-added is
    /// refused; an untouched sibling repo is still removed (so the verifier is not simply "always no").
    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func aFolderGitStartedTrackingAfterTheScanIsNeverRemovedPermanently() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        let git = BuildArtifactGitGateTests.git!
        func g(_ repo: String, _ a: [String]) -> Bool { ShellReader.run(git, ["-C", f.url(repo).path] + a, timeout: 20).succeeded }
        for repo in ["ok", "late"] {
            f.file("\(repo)/Cargo.toml"); f.file("\(repo)/target/x")
            try "target/\n".write(to: f.url("\(repo)/.gitignore"), atomically: true, encoding: .utf8)
            #expect(g(repo, ["init", "-q"]))
        }
        let scan = await baScan(f, roots: [f.root.path], now: baAged)
        let byProject = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.projectName, $0) })
        let ok = try #require(byProject["ok"]), late = try #require(byProject["late"])
        #expect(ok.permanentRemovalEligible && late.permanentRemovalEligible)

        #expect(g("late", ["add", "-f", "target/x"]), "someone force-adds a file after the scan")

        let trash = FakeTrash(in: f)
        let out = BuildArtifactRemover.trashAndEmpty([ok, late], trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true)
        #expect(out.permanentlyRemoved == [ok.id])
        #expect(out.refused.map(\.id) == [late.id])
        #expect(f.exists("late/target/x"), "the tracked folder must still be where it was")
        #expect(trash.calls.map(\.path) == [ok.artifactURL.path])
    }

    /// A parent directory swapped for a symlink between scan and confirm must not redirect the removal.
    @Test func aParentSwappedForASymlinkAfterTheScanIsNotFollowed() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("proj/a/x")
        let it = baItem(f.url("proj/a"))
        // proj -> elsewhere, which also has an `a` directory full of someone's files.
        try! FileManager.default.moveItem(at: f.url("proj"), to: f.url("proj.moved"))
        f.file("elsewhere/a/precious.txt")
        f.link("proj", to: f.url("elsewhere"))
        let out = BuildArtifactRemover.moveToTrash([it], trash: trash.function, home: f.url("home").path)
        #expect(out.moved.isEmpty && out.failed.count == 1 && trash.callCount == 0)
        #expect(f.exists("elsewhere/a/precious.txt"))
    }

    @Test func aTrashSiblingWithACommonPrefixIsNotInsideTheTrash() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)                       // .../FakeTrash
        f.file("FakeTrash2/x")                             // .../FakeTrash2  (shares the prefix)
        #expect(!BuildArtifactRemover.isInsideTrash(f.url("FakeTrash2/x"), trashDirectories: [trash.dir]))
        f.file("FakeTrash/x")
        #expect(BuildArtifactRemover.isInsideTrash(f.url("FakeTrash/x"), trashDirectories: [trash.dir]))
    }

    @Test func sandboxDetectionDoesNotRelyOnOneSignal() {
        #expect(BuildArtifactRemover.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "com.halo.mac"], home: "/Users/x"))
        #expect(BuildArtifactRemover.isSandboxed(environment: [:], home: "/Users/x/Library/Containers/com.halo.mac/Data"))
        #expect(!BuildArtifactRemover.isSandboxed(environment: [:], home: "/Users/x"))
    }

    // MARK: Other version control

    @Test func aProjectUnderMercurialOrSubversionIsNeverJustNotARepo() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("hg/Cargo.toml"); f.dir("hg/.hg"); f.file("hg/target/x")
        f.file("svn/Cargo.toml"); f.dir("svn/.svn"); f.file("svn/sub/Cargo.toml"); f.file("svn/sub/target/x")
        #expect(GitGate.inspect(artifactName: "target", project: f.url("hg"), gitPath: nil) == .unavailable)
        let r = await baScan(f, roots: [f.root.path])
        #expect(r.items.count == 2, "found: \(r.items.map(\.artifactURL.path))")
        #expect(r.items.allSatisfy { $0.gitStatus == .unavailable && !$0.permanentRemovalEligible && !$0.isSmartSelectable() })
    }

    // MARK: Exclusions

    @Test func toolManagerInstallsAndSystemToolTreesAreNeverOffered() async {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("ok/package.json"); f.file("ok/node_modules/x")
        f.file(".nvm/versions/node/v20/lib/node_modules/npm/package.json")
        f.file(".nvm/versions/node/v20/lib/node_modules/npm/node_modules/x")
        f.file(".cargo/registry/src/crate-1/Cargo.toml"); f.file(".cargo/registry/src/crate-1/target/x")
        let r = await baScan(f, roots: [f.root.path])
        #expect(r.items.map(\.projectName) == ["ok"], "found: \(r.items.map(\.artifactURL.path))")
        for p in ["/opt/homebrew/lib/node_modules", "/usr/local/lib", "/System/x", "/h/Library/x", "/h/Downloads", "/h/Downloads/proj", "/h/.Trash"] {
            #expect(BuildArtifactRoots.isExcludedRoot(p, home: "/h"), "\(p)")
        }
        for p in ["/h/Documents", "/h/Github/x", "/Volumes/SSD/Projects", "/opt/projects"] {
            #expect(!BuildArtifactRoots.isExcludedRoot(p, home: "/h"), "\(p)")
        }
    }

    @MainActor
    @Test func addingDownloadsAsARootIsRefusedOutLoudNotSilently() {
        let f = BAFixture(); defer { f.cleanup() }
        let suite = "f054-hard-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!; defaults.removePersistentDomain(forName: suite)
        let store = BuildArtifactRootsStore(defaults: defaults)
        let vm = BuildArtifactsViewModel(roots: store, sandboxed: false, home: f.url("home").path,
                                         trash: FakeTrash(in: f).function, trashDirectories: [], scan: nil)
        let refused = vm.addRoots([f.dir("home/Downloads"), f.dir("home/Library"), f.dir("work")], sandboxed: false)
        #expect(refused.map(\.lastPathComponent) == ["Downloads", "Library"])
        #expect(store.userRoots == [f.url("work").standardizedFileURL.path])
        #expect(vm.banner?.isError == true && vm.banner?.text.contains("Downloads") == true)
    }
}

// MARK: - Follow-up to PR #59: in-use detection, Active/In-use never permanent, catch-all .gitignore

@Suite("F-054 in use")
struct BuildArtifactInUseTests {

    /// A real child process (`/bin/sleep`) with its cwd in a fixture folder — no stand-in for the
    /// kernel's answer. Test-only use of `Process`: ShellReader is blocking and cannot hold a child open.
    private func spawn(_ exe: String, _ args: [String], cwd: URL, stdin: Pipe? = nil) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if let stdin { p.standardInput = stdin }
        try p.run()
        return p
    }
    private func stop(_ p: Process) { p.terminate(); p.waitUntilExit() }

    private func signals(_ f: BAFixture, xcodeRunning: Bool = false) -> BuildArtifactInUseSignals {
        BuildArtifactInUse.currentSignals(home: f.url("home").path, xcodeAppRunning: xcodeRunning)
    }

    @Test func aRunningToolWhoseCwdIsInTheProjectMarksItsArtifactInUse() throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("busy/package.json"); f.file("busy/node_modules/x"); f.dir("busy/packages/app")
        f.file("idle/package.json"); f.file("idle/node_modules/x")
        let busy = baItem(f.url("busy/node_modules"), project: "busy"), idle = baItem(f.url("idle/node_modules"), project: "idle")

        let child = try spawn("/bin/sleep", ["60"], cwd: f.url("busy/packages/app"))   // a sub-package of `busy`
        defer { stop(child) }
        let live = signals(f)
        #expect(BuildArtifactInUse.isInUse(busy, signals: live), "a tool running inside the project folder")
        #expect(!BuildArtifactInUse.isInUse(idle, signals: live))

        stop(child)
        #expect(!BuildArtifactInUse.isInUse(busy, signals: signals(f)), "the signal follows the process: gone when it exits")
    }

    @Test func anIdleShellSittingInTheFolderIsNotABuild() throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("p/package.json"); f.file("p/node_modules/x")
        let item = baItem(f.url("p/node_modules"), project: "p")
        let stdin = Pipe()
        let shell = try spawn("/bin/bash", ["-c", "read x"], cwd: f.url("p"), stdin: stdin)   // waits on stdin, runs nothing
        defer { stop(shell) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!BuildArtifactInUse.isInUse(item, signals: signals(f)), "a terminal parked in the project is not a running build")
        #expect(BuildArtifactInUse.idleProcessNames.contains("zsh") && BuildArtifactInUse.idleProcessNames.contains("bash"))
    }

    @Test func pureEvaluationFollowsTheSignals() {
        var s = BuildArtifactInUseSignals()
        let node = baItem(URL(fileURLWithPath: "/w/app/node_modules"), project: "app")
        s.busyDirectories = ["/w/app/server"]
        #expect(BuildArtifactInUse.isInUse(node, signals: s))
        s.busyDirectories = ["/w/application"]                      // look-alike sibling
        #expect(!BuildArtifactInUse.isInUse(node, signals: s))
        s.busyDirectories = ["/w/app/node_modules/.bin"]            // inside the artifact itself
        #expect(BuildArtifactInUse.isInUse(node, signals: s))
        s.busyDirectories = []; s.openProjectDirectories = ["/w/app"]
        #expect(BuildArtifactInUse.isInUse(node, signals: s))
        #expect(!BuildArtifactInUse.isInUse(baItem(URL(fileURLWithPath: "/w/other/node_modules"), project: "other"), signals: s))
        #expect(!BuildArtifactInUse.isInUse(node, signals: .none))
    }

    @Test func openFilesAreReadFromTheKernel() throws {
        let f = BAFixture(); defer { f.cleanup() }
        let file = f.file("held/data.mdb")
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        #expect(BuildArtifactInUse.openFilePaths(of: getpid()).map(BuildArtifactInUse.canonical).contains(BuildArtifactInUse.canonical(file.path)))
    }

    /// Xcode-family process with a file open inside a DerivedData folder => that folder, and the
    /// project its info.plist names, are in use. The process is the test's own (real fds, real kernel).
    @Test func xcodeHoldingADerivedDataFolderMarksItAndItsWorkspaceInUse() throws {
        let f = BAFixture(); defer { f.cleanup() }
        let dd = "home/Library/Developer/Xcode/DerivedData"
        f.file("\(dd)/App-aaa/Index.noindex/DataStore/data.mdb"); f.file("\(dd)/Other-bbb/Build/x")
        let plist = ["WorkspacePath": f.url("work/App/App.xcworkspace").path]
        try (PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
            .write(to: f.url("\(dd)/App-aaa/info.plist"))
        f.dir("work/App/App.xcworkspace"); f.file("work/App/Package.swift"); f.file("work/App/build/y")
        f.file("work/Elsewhere/build/y")

        let held = try FileHandle(forReadingFrom: f.url("\(dd)/App-aaa/Index.noindex/DataStore/data.mdb")); defer { try? held.close() }
        let s = BuildArtifactInUse.currentSignals(home: f.url("home").path, xcodeAppRunning: true,
                                                  excludingPID: -1, isXcodeProcess: { pid, _ in pid == getpid() })
        #expect(s.openDerivedDataFolders == [f.url("\(dd)/App-aaa").path])
        #expect(!s.xcodeRunningButOpaque)

        let tc = BuildArtifactScanner.xcodeGlobalToolchainID
        let open = baItem(f.url("\(dd)/App-aaa"), git: .notApplicable, project: "App", toolchain: tc)
        let closed = baItem(f.url("\(dd)/Other-bbb"), git: .notApplicable, project: "Other", toolchain: tc)
        #expect(BuildArtifactInUse.isInUse(open, signals: s))
        #expect(!BuildArtifactInUse.isInUse(closed, signals: s))
        #expect(BuildArtifactInUse.isInUse(baItem(f.url("work/App/build"), project: "App", toolchain: "xcode"), signals: s),
                "the build/ of a project that is open in Xcode")
        #expect(!BuildArtifactInUse.isInUse(baItem(f.url("work/Elsewhere/build"), project: "Elsewhere", toolchain: "xcode"), signals: s))
    }

    /// Not knowing is not "free": Xcode is up but nothing of it is readable => all DerivedData in use.
    @Test func xcodeRunningButOpaqueTreatsEveryDerivedDataFolderAsInUse() throws {
        let f = BAFixture(); defer { f.cleanup() }
        let dd = "home/Library/Developer/Xcode/DerivedData"
        f.file("\(dd)/App-aaa/x"); f.file("home/Library/Developer/CoreSimulator/Caches/c/x"); f.file("work/p/build/y")
        let tc = BuildArtifactScanner.xcodeGlobalToolchainID
        let derived = baItem(f.url("\(dd)/App-aaa"), git: .notApplicable, project: "App", toolchain: tc)
        let simCache = baItem(f.url("home/Library/Developer/CoreSimulator/Caches/c"), git: .notApplicable, project: "c", toolchain: tc)
        let project = baItem(f.url("work/p/build"), project: "p", toolchain: "xcode")

        let opaque = BuildArtifactInUse.currentSignals(home: f.url("home").path, xcodeAppRunning: true,
                                                       excludingPID: -1, isXcodeProcess: { _, _ in false })
        #expect(opaque.xcodeRunningButOpaque)
        #expect(BuildArtifactInUse.isInUse(derived, signals: opaque))
        #expect(!BuildArtifactInUse.isInUse(simCache, signals: opaque), "only DerivedData is Xcode's open-project data")
        #expect(!BuildArtifactInUse.isInUse(project, signals: opaque))

        let notRunning = BuildArtifactInUse.currentSignals(home: f.url("home").path, xcodeAppRunning: false,
                                                           excludingPID: -1, isXcodeProcess: { _, _ in false })
        #expect(!notRunning.xcodeRunningButOpaque && !BuildArtifactInUse.isInUse(derived, signals: notRunning))
    }

    @Test func theScannerStampsInUseFromTheSignalsItIsGiven() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("busy/package.json"); f.file("busy/node_modules/x")
        f.file("idle/package.json"); f.file("idle/node_modules/x")
        let busyDir = f.url("busy").path
        var cfg = BuildArtifactScanner.Config()
        cfg.home = f.url("home").path; cfg.excludedPaths = []; cfg.useGit = false
        cfg.inUseSignals = { var s = BuildArtifactInUseSignals(); s.busyDirectories = [busyDir]; return s }
        let r = await BuildArtifactScanner(catalog: BATestCatalog.fromSource()).scanAll(roots: [f.root.path], config: cfg)
        let byName = Dictionary(uniqueKeysWithValues: r.items.map { ($0.projectName, $0) })
        #expect(byName["busy"]?.isInUse == true && byName["idle"]?.isInUse == false)
        #expect(byName["busy"]?.isSmartSelectable() == false)
    }

    // MARK: never smart-selected, never permanent

    @Test func inUseAndActiveItemsAreNeverPermanentEligible() {
        let u = URL(fileURLWithPath: "/x/a")
        #expect(baItem(u).permanentRemovalEligible, "control: Safe + git-verified, idle")
        #expect(!baItem(u, active: true).permanentRemovalEligible, "Active (< 24 h) keeps only Move to Trash")
        #expect(!baItem(u, inUse: true).permanentRemovalEligible)
        #expect(!baItem(u, inUse: true).isSmartSelectable() && !baItem(u, active: true).isSmartSelectable())
        let snap = BuildArtifactsViewModel.ReviewSnapshot(items: [baItem(u), baItem(u, active: true), baItem(u, inUse: true)])
        #expect(!snap.allPermanentEligible && snap.ineligibleForPermanent == 2 && snap.activeCount == 1 && snap.inUseCount == 1)
    }

    @Test func theRemoverRefusesAnActiveOrInUseItemForPermanentRemovalAndTouchesNothing() {
        let f = BAFixture(); defer { f.cleanup() }
        let trash = FakeTrash(in: f)
        f.file("p/a/x"); f.file("p/b/x")
        let out = BuildArtifactRemover.trashAndEmpty([baItem(f.url("p/a"), active: true), baItem(f.url("p/b"), inUse: true)],
                                                    trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true, reverify: { _ in nil })
        #expect(out.refused.count == 2 && out.moved.isEmpty && trash.callCount == 0 && f.exists("p/a/x") && f.exists("p/b/x"))
        // ...but the recoverable action is still available for them.
        let moved = BuildArtifactRemover.moveToTrash([baItem(f.url("p/a"), active: true)], trash: trash.function, home: f.url("home").path)
        #expect(moved.moved.count == 1)
    }

    /// Eligibility was true at scan time; something happened since. The remover asks again.
    @Test func permanentRemovalReverifiesInUseAndModificationRightBeforeActing() throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("p/a/x")
        let url = f.url("p/a")
        let seen = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let item = baItem(url, modified: seen)

        // A build started: a tool now runs in the project folder.
        let busy = BuildArtifactRemover.reverifyPermanentEligible(signals: {
            var s = BuildArtifactInUseSignals(); s.busyDirectories = [f.url("p").path]; return s
        })
        #expect(busy(item)?.contains("running process") == true)

        // Or something wrote into the folder after the scan.
        try FileManager.default.setAttributes([.modificationDate: seen.addingTimeInterval(120)], ofItemAtPath: url.path)
        let changed = BuildArtifactRemover.reverifyPermanentEligible(signals: { .none })
        #expect(changed(item)?.contains("changed after the scan") == true)

        // End to end through trashAndEmpty with the default verifier: nothing moves.
        let trash = FakeTrash(in: f)
        let out = BuildArtifactRemover.trashAndEmpty([item], trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true,
                                                    reverify: BuildArtifactRemover.reverifyPermanentEligible(signals: { .none }))
        #expect(out.refused.count == 1 && out.moved.isEmpty && trash.callCount == 0 && f.exists("p/a/x"))
    }
}

@Suite("F-054 catch-all gitignore")
struct BuildArtifactCatchAllIgnoreTests {

    @Test func verboseOutputIsParsedAndCatchAllPatternsAreTold() {
        #expect(GitGate.parseCheckIgnoreVerbose(".gitignore:3:node_modules/\tnode_modules")
                == GitGate.IgnoreRule(source: ".gitignore", line: 3, pattern: "node_modules/"))
        #expect(GitGate.parseCheckIgnoreVerbose("../.gitignore:1:*\tnode_modules\n")?.pattern == "*")
        #expect(GitGate.parseCheckIgnoreVerbose("/a b/.gitignore:12:target\ttarget")?.source == "/a b/.gitignore")
        #expect(GitGate.parseCheckIgnoreVerbose("") == nil && GitGate.parseCheckIgnoreVerbose("garbage") == nil)
        for p in ["*", "/*", "**", "**/*", ".*", "*/", "?", "/**", " * "] { #expect(GitGate.isCatchAllPattern(p), "\(p)") }
        for p in ["node_modules/", "target", "*.o", "build*", "*build", "/build", ".build", "dist/", "**/node_modules"] {
            #expect(!GitGate.isCatchAllPattern(p), "\(p)")
        }
    }

    /// Review of #66: `check-ignore -v` exits 0 and names the rule even when the last matching rule is a
    /// NEGATION — the path is then explicitly NOT ignored. It must never read as verified.
    @Test func aNegatedRuleIsNotIgnored() {
        #expect(GitGate.verdict(for: .init(source: ".gitignore", line: 2, pattern: "!build/")) == .notIgnored)
        #expect(GitGate.verdict(for: .init(source: ".gitignore", line: 2, pattern: "!*")) == .notIgnored)
        #expect(GitGate.verdict(for: .init(source: ".gitignore", line: 1, pattern: "build/")) == .ignored)
        #expect(GitGate.verdict(for: .init(source: ".gitignore", line: 1, pattern: "*")) == .catchAllIgnore)
    }

    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func aFolderExplicitlyUnIgnoredByGitIsNeverVerified() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        let git = BuildArtifactGitGateTests.git!
        func g(_ a: [String]) -> Bool { ShellReader.run(git, ["-C", f.url("repo").path] + a, timeout: 20).succeeded }
        // `build/` is ignored on line 1 and un-ignored on line 2: `git status` shows it as untracked.
        f.file("repo/Cargo.toml"); f.file("repo/target/x"); f.file("repo/dist/x")
        try "target/\n!target/\n".write(to: f.url("repo/.gitignore"), atomically: true, encoding: .utf8)
        #expect(g(["init", "-q"]))
        #expect(GitGate.inspect(artifactName: "target", project: f.url("repo")) == .notIgnored)

        let r = await baScan(f, roots: [f.root.path], now: baAged)
        #expect(r.items.filter { $0.artifactURL.path.hasSuffix("repo/target") }.isEmpty,
                "an explicitly un-ignored, untracked folder is skipped like any other not-ignored one")
        #expect(r.summary.skippedNotGitIgnored >= 1)
    }

    /// Positive control for the default re-verification, on a REAL scan result: an untouched, ignored,
    /// untracked folder passes (so the "modified since the scan" comparison does not trip on timestamp
    /// precision and silently make permanent removal unreachable), and the same folder fails once a
    /// build writes into it.
    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func theDefaultReverificationPassesAnUntouchedItemAndRefusesAnEditedOne() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        let git = BuildArtifactGitGateTests.git!
        f.file("repo/Cargo.toml"); f.file("repo/target/x")
        try "target/\n".write(to: f.url("repo/.gitignore"), atomically: true, encoding: .utf8)
        #expect(ShellReader.run(git, ["-C", f.url("repo").path, "init", "-q"], timeout: 20).succeeded)
        let r = await baScan(f, roots: [f.root.path], now: baAged)
        let item = try #require(r.items.first { $0.artifactURL.path.hasSuffix("repo/target") })
        #expect(item.permanentRemovalEligible)
        let verify = BuildArtifactRemover.reverifyPermanentEligible(signals: { .none })
        #expect(verify(item) == nil, "untouched since the scan: \(verify(item) ?? "")")
        f.file("repo/target/new-file")                                   // a build adds an entry
        #expect(verify(item)?.contains("changed after the scan") == true)
    }

    /// The review's dotfiles-repo case: the work tree is an enclosing repo whose .gitignore is `*`.
    /// Everything under it is "ignored", which says nothing about THIS folder.
    @Test(.enabled(if: BuildArtifactGitGateTests.git != nil))
    func aRepoThatIgnoresEverythingDoesNotMakeEverythingPermanentEligible() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        let git = BuildArtifactGitGateTests.git!
        func g(_ repo: String, _ a: [String]) -> Bool { ShellReader.run(git, ["-C", f.url(repo).path] + a, timeout: 20).succeeded }
        // Enclosing "dotfiles" repo ignoring everything, with a project inside it (no .git of its own).
        f.file("dots/.gitignore", bytes: 0)
        try "*\n".write(to: f.url("dots/.gitignore"), atomically: true, encoding: .utf8)
        f.file("dots/proj/Cargo.toml"); f.file("dots/proj/target/x"); f.file("dots/proj/dist/x")
        f.file("dots/web/package.json"); f.file("dots/web/node_modules/x")
        #expect(g("dots", ["init", "-q"]))
        // Control: a repo with a REAL ignore entry.
        f.file("good/Cargo.toml"); f.file("good/target/x")
        try "target/\n".write(to: f.url("good/.gitignore"), atomically: true, encoding: .utf8)
        #expect(g("good", ["init", "-q"]))

        #expect(GitGate.inspect(artifactName: "target", project: f.url("dots/proj")) == .catchAllIgnore)
        #expect(GitGate.inspect(artifactName: "target", project: f.url("good")) == .ignored)

        let r = await baScan(f, roots: [f.root.path], now: baAged)
        let byPath = Dictionary(uniqueKeysWithValues: r.items.map { ($0.artifactURL.path.replacingOccurrences(of: f.root.path + "/", with: ""), $0) })
        let proj = try #require(byPath["dots/proj/target"]), web = try #require(byPath["dots/web/node_modules"])
        for i in [proj, web] {
            #expect(i.gitStatus == .unavailable && i.isUnverified)
            #expect(!i.permanentRemovalEligible && !i.isSmartSelectable() && !i.isVerifiedSafe)
        }
        #expect(byPath["dots/proj/dist"] == nil, "dist/ needs a POSITIVE ignore; a catch-all is not one")
        #expect(byPath["good/target"]?.permanentRemovalEligible == true, "the real ignore entry still verifies")
        #expect(r.summary.gitCatchAllIgnored == 2)

        // Even handed a stale "eligible" item, the re-verification at removal time refuses it.
        let forged = BuildArtifactItem(id: proj.id, artifactURL: proj.artifactURL, projectName: proj.projectName,
                                   projectPath: proj.projectPath, toolchainID: proj.toolchainID, toolchainName: proj.toolchainName,
                                   regenClass: .safe, size: proj.size, artifactModified: nil, projectLastModified: nil,
                                   gitStatus: .ignored, regenHint: "", isActive: false)
        #expect(forged.permanentRemovalEligible)
        let trash = FakeTrash(in: f)
        let out = BuildArtifactRemover.trashAndEmpty([forged], trash: trash.function, trashDirectories: [trash.dir],
                                                    home: f.url("home").path, permanentAllowed: true,
                                                    reverify: BuildArtifactRemover.reverifyPermanentEligible(signals: { .none }))
        #expect(out.refused.count == 1 && trash.callCount == 0 && f.exists("dots/proj/target/x"))
    }
}

// MARK: - Settings → Cleanup (model)

@MainActor
@Suite("F-054 settings model")
struct BuildArtifactSettingsModelTests {

    private func store() -> (BuildArtifactRootsStore, UserDefaults, String) {
        let suite = "f054-settings-\(UUID())"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite)
        return (BuildArtifactRootsStore(defaults: d), d, suite)
    }

    @Test func staleDaysDefaultsPersistsAndIsClamped() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        let m = BuildArtifactSettingsModel(store: s, sandboxed: false)
        #expect(m.staleDays == 30 && s.staleDays == 30)
        m.staleDays = 45
        #expect(BuildArtifactRootsStore(defaults: d).staleDays == 45, "persisted under \(BuildArtifactRootsStore.staleDaysKey)")
        #expect(d.integer(forKey: "buildArtifactStaleDays") == 45)
        m.staleDays = 0;    #expect(m.staleDays == 1 && s.staleDays == 1)
        m.staleDays = 9999; #expect(m.staleDays == 365 && s.staleDays == 365)
        d.set(100_000, forKey: BuildArtifactRootsStore.staleDaysKey)
        #expect(s.staleDays == 365, "a hand-edited value is clamped on read too")
    }

    @Test func includeHomeIsOffByDefaultPersistsAndAddsTheHomeRoot() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        let m = BuildArtifactSettingsModel(store: s, sandboxed: false)
        #expect(!m.includeHome && !s.includeHome && m.includeHomeAvailable)
        let before = s.scanRoots(sandboxed: false, home: "/h", exists: { $0 == "/h/Documents" || $0 == "/h" })
        #expect(before == ["/h/Documents"])
        m.includeHome = true
        #expect(BuildArtifactRootsStore(defaults: d).includeHome)
        #expect(d.bool(forKey: "buildArtifactIncludeHome"))
        let after = s.scanRoots(sandboxed: false, home: "/h", exists: { $0 == "/h/Documents" || $0 == "/h" })
        #expect(after == ["/h"], "home covers the project roots inside it, so nothing is scanned twice")
        #expect(BuildArtifactSettingsModel.includeHomeWarning.contains("slower") && BuildArtifactSettingsModel.includeHomeWarning.contains("Unverified"))
    }

    @Test func includeHomeIsUnavailableAndNeverPersistedWhenSandboxed() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: BuildArtifactRootsStore.includeHomeKey)        // stale value from an unsandboxed run
        let m = BuildArtifactSettingsModel(store: s, sandboxed: true)
        #expect(!m.includeHomeAvailable && !m.includeHome)
        m.includeHome = true
        #expect(!m.includeHome, "the toggle cannot be switched on")
    }

    @Test func resetIgnoreListForgetsEveryNeverOfferChoiceAndOnlyThat() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        s.addRoot(URL(fileURLWithPath: "/tmp/f054-keep"), sandboxed: false)
        s.ignore("/a/node_modules"); s.ignore("/b/target")
        let m = BuildArtifactSettingsModel(store: s, sandboxed: false)
        #expect(m.ignoredCount == 2)
        m.resetIgnoreList()
        #expect(m.ignoredCount == 0 && s.ignoredPaths.isEmpty)
        #expect(s.userRoots == ["/tmp/f054-keep"], "the user's chosen roots are not part of the ignore list")
    }

    /// The pane holds its own store over the same defaults; it must re-render when Settings changes one.
    @Test func changingASettingNotifiesAnOpenPane() async {
        let f = BAFixture(); defer { f.cleanup() }
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        let vm = BuildArtifactsViewModel(roots: s, sandboxed: false, home: f.url("home").path,
                                         trash: FakeTrash(in: f).function, trashDirectories: [], scan: nil)
        var fired = 0
        let sub = vm.objectWillChange.sink { fired += 1 }; defer { sub.cancel() }
        BuildArtifactSettingsModel(store: BuildArtifactRootsStore(defaults: d), sandboxed: false).staleDays = 60
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired >= 1 && vm.roots.staleDays == 60)
    }
}

// MARK: - Smart Scan still covers ~/Library/Caches (BUG-001 OQ-4)

@Suite("Smart Scan coverage (BUG-001 OQ-4)")
struct SmartScanCoverageTests {

    @Test func smartScanCoversUserCachesExactlyOnce() {
        let caches = "\(NSHomeDirectory())/Library/Caches"
        let owners = ScanCoordinator.smartScanKinds.filter { kind in
            kind.targetPaths.contains { CleanupPath.isCovered(caches, by: $0) || CleanupPath.isCovered($0, by: caches) }
        }
        #expect(owners == [.userCaches], "~/Library/Caches must be scanned by Smart Scan once, via exactly one owner: \(owners)")
    }

    @Test func smartScanKindsOwnDisjointPaths() {
        let roots = ScanCoordinator.smartScanKinds.map { (kind: $0, paths: $0.targetPaths) }
        #expect(CleanupPath.overlappingRoots(roots).isEmpty)
        #expect(Set(ScanCoordinator.smartScanKinds).count == ScanCoordinator.smartScanKinds.count)
    }

    @Test func runFullScanScansExactlyTheSmartScanKindsAndIncludesUserCaches() async throws {
        let f = BAFixture(); defer { f.cleanup() }
        f.file("userCaches/app/blob.bin", bytes: 64 * 1024)
        let uc = f.url("userCaches").path
        let coordinator = ScanCoordinator(
            roots: { kind in kind == .userCaches ? [uc] : [] },
            trashDirectories: { [] },
            xcodeGlobal: { [] })
        let result = await coordinator.runFullScan()
        #expect(Set(result.categoryResults.map(\.kind)) == Set(ScanCoordinator.smartScanKinds))
        let user = try #require(result.categoryResults.first { $0.kind == .userCaches })
        #expect(user.allBytes >= 64 * 1024 && result.totalBytes >= 64 * 1024, "the user's cache folder is part of the Smart Scan total")
    }
}

// MARK: - Trash gate predicate (the real round-trip test is skipped without a usable Trash)

@Suite("F-054 trash availability gate")
struct BuildArtifactTrashGateTests {
    @Test func aMissingOrUnwritableTrashSkipsInsteadOfFailing() {
        let f = BAFixture(); defer { f.cleanup() }
        #expect(BATrash.isUsable([f.dir("Trash")]))
        #expect(!BATrash.isUsable([f.url("no-such-trash")]))
        #expect(!BATrash.isUsable([]))
        #expect(!BATrash.isUsable([f.file("a-file-not-a-dir")]))
        let ro = f.dir("ro"); try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path) }
        #expect(!BATrash.isUsable([ro]))
    }
}
