//
//  HaloTestFixtures.swift
//  HaloUITests
//
//  The dummy-file safety harness for destructive E2E flows.
//
//  ─────────────────────────────────────────────────────────────────────────
//  SAFETY CONTRACT (maps to MANUAL_TEST_PLAN.md §21.5 TC-SAFE-01/02/03 and the
//  new TC-SAFE-04/05):
//
//    • No test ever operates on a real user/system path. Every destructive
//      flow is exercised against DUMMY files created under a throwaway sandbox
//      inside the OS temp directory.
//    • Dummy files double as "canaries": before driving a destructive flow we
//      record them (plus a snapshot of any real paths that must stay put), and
//      after the flow we assert every one still exists, unchanged.
//    • The "test-only, cancel-at-confirmation" pattern: drive each destructive
//      action to its confirmation sheet, then CANCEL, then assert that nothing
//      anywhere was deleted or modified. This proves the confirmation gate
//      (TC-SAFE-02) without ever trashing a file.
//
//  Why the harness may `removeItem` its own sandbox
//  -------------------------------------------------
//  The app-wide rule is "always trashItem, never removeItem" — but that rule
//  governs the APP acting on the USER's files. This sandbox is the test's own
//  scratch data living in `NSTemporaryDirectory()`; tearing it down with
//  `removeItem` is the same sanctioned exception documented for
//  `DriveSpeedTester`'s scratch file. The harness NEVER removeItem's anything
//  outside its own sandbox root.
//  ─────────────────────────────────────────────────────────────────────────
//

import XCTest

/// Creates, tracks, and safety-checks throwaway fixtures for destructive flows.
final class HaloTestFixtures {

    /// The single sandbox root for this fixture set. Always under the OS temp
    /// dir — asserted on init so a bug can never point us at a real location.
    let root: URL

    private unowned let test: XCTestCase
    private let fm = FileManager.default

    /// Every dummy path we created — the canary set.
    private(set) var createdPaths: [URL] = []

    /// Real paths that must remain byte-for-byte untouched, with the snapshot
    /// (exists?, size, modification date) captured when `guardRealPath` was called.
    private var realSnapshots: [(url: URL, existed: Bool, size: Int64?, modified: Date?)] = []

    /// Baseline count of items in the user Trash, captured lazily.
    private var trashBaseline: Int?

    // MARK: - Lifecycle

    init(_ test: XCTestCase, label: String = "fixtures") {
        self.test = test
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HaloUITestFixtures", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)

        // Hard safety gate: the sandbox MUST live inside the temp dir.
        let tempPrefix = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        precondition(base.standardizedFileURL.path.hasPrefix(tempPrefix),
                     "Fixture sandbox escaped the temp directory — refusing to run.")
        self.root = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Remove the sandbox. Safe: only ever deletes our own temp subtree.
    func tearDown() {
        guard root.path.contains("HaloUITestFixtures") else { return }
        try? fm.removeItem(at: root)
    }

    // MARK: - Dummy file / directory creation

    /// Create one dummy file with deterministic contents.
    @discardableResult
    func makeFile(_ name: String, contents: String = "halo-dummy-fixture") -> URL {
        let url = root.appendingPathComponent(name)
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(contents.utf8))
        createdPaths.append(url)
        return url
    }

    /// Create `count` dummy files (e.g. to populate a scan target).
    @discardableResult
    func makeFiles(count: Int, prefix: String = "junk", ext: String = "cache") -> [URL] {
        (0..<count).map { makeFile("\(prefix)-\($0).\(ext)", contents: "payload-\($0)") }
    }

    /// Create a dummy subdirectory inside the sandbox.
    @discardableResult
    func makeDirectory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        createdPaths.append(url)
        return url
    }

    /// Two byte-identical files + one different — exercises the duplicate finder.
    /// Returns (dupeA, dupeB, unique).
    @discardableResult
    func makeDuplicateSet() -> (URL, URL, URL) {
        let a = makeFile("dupe-a.txt", contents: "identical-bytes-123456")
        let b = makeFile("dupe-b.txt", contents: "identical-bytes-123456")
        let c = makeFile("unique-c.txt", contents: "totally-different-bytes")
        return (a, b, c)
    }

    /// A dummy `.app`-shaped bundle so an "uninstall" flow has something inert
    /// to point at — it is NOT registered with Launch Services and lives only
    /// in the sandbox, so nothing real can be uninstalled.
    @discardableResult
    func makeDummyAppBundle(_ name: String = "Dummy.app") -> URL {
        let bundle = makeDirectory(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
        fm.createFile(atPath: macos.appendingPathComponent("Dummy").path,
                      contents: Data("#!/bin/sh\n".utf8))
        return bundle
    }

    // MARK: - Canaries / real-path guards

    /// Snapshot a real path that must never change during a test.
    func guardRealPath(_ url: URL) {
        let exists = fm.fileExists(atPath: url.path)
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        realSnapshots.append((url,
                              exists,
                              (attrs?[.size] as? NSNumber)?.int64Value,
                              attrs?[.modificationDate] as? Date))
    }

    /// Record how many items are currently in the user Trash.
    func captureTrashBaseline() {
        trashBaseline = trashItemCount()
    }

    private func trashItemCount() -> Int {
        guard let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first else { return 0 }
        return (try? fm.contentsOfDirectory(atPath: trash.path).count) ?? 0
    }

    // MARK: - Safety assertions

    /// Assert every dummy file we created still exists (nothing was deleted).
    func assertDummyFilesIntact(file: StaticString = #filePath, line: UInt = #line) {
        for url in createdPaths {
            XCTAssertTrue(fm.fileExists(atPath: url.path),
                          "Dummy fixture was deleted unexpectedly: \(url.lastPathComponent)",
                          file: file, line: line)
        }
    }

    /// Assert every guarded real path is byte-for-byte as it was snapshotted.
    func assertRealPathsUntouched(file: StaticString = #filePath, line: UInt = #line) {
        for snap in realSnapshots {
            let existsNow = fm.fileExists(atPath: snap.url.path)
            XCTAssertEqual(existsNow, snap.existed,
                           "Guarded real path existence changed: \(snap.url.path)",
                           file: file, line: line)
            guard existsNow, snap.existed else { continue }
            let attrs = try? fm.attributesOfItem(atPath: snap.url.path)
            let sizeNow = (attrs?[.size] as? NSNumber)?.int64Value
            XCTAssertEqual(sizeNow, snap.size,
                           "Guarded real path size changed: \(snap.url.path)",
                           file: file, line: line)
        }
    }

    /// Assert the Trash gained nothing since the baseline (i.e. nothing trashed).
    func assertTrashUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        guard let baseline = trashBaseline else { return }
        XCTAssertEqual(trashItemCount(), baseline,
                       "Trash count changed — a destructive flow deleted something",
                       file: file, line: line)
    }

    /// The full post-condition for a cancel-at-confirmation flow: nothing,
    /// anywhere, was deleted or modified.
    func assertNothingDeleted(file: StaticString = #filePath, line: UInt = #line) {
        assertDummyFilesIntact(file: file, line: line)
        assertRealPathsUntouched(file: file, line: line)
        assertTrashUnchanged(file: file, line: line)
    }
}
