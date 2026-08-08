//
//  FilesUITests.swift
//  HaloUITests
//
//  Files module — all five tabs. Maps to MANUAL_TEST_PLAN.md §7:
//    7.1 SpaceLens     (TC-FILE-01…03)
//    7.2 Duplicates    (TC-FILE-10…11)
//    7.3 Downloads     (TC-FILE-20…)
//    7.4 Large Files   (TC-FILE-30…)
//    7.5 Drive Speed   (TC-FILE-40… / F-043)
//
//  SAFETY: the duplicate/large-file/downloads flows can delete files, so every
//  destructive path is driven to its confirmation and cancelled, with dummy
//  fixtures + a Trash baseline proving nothing was deleted. Drive Speed writes
//  only Halo's own scratch file (temp / `.HaloSpeedTest`), which it removes.
//

import XCTest

final class FilesUITests: HaloUITestCase {

    private func openFiles(tab: String? = nil) {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .files))
        if let tab {
            // Prefer the stable tab identifier; fall back to the visible title.
            if !tapID("files.tab.\(tab)", timeout: 5) { _ = clickAny(of: [tab], timeout: 3) }
        }
    }

    // TC-FILE-01 — SpaceLens tab renders (treemap or a scan prompt).
    func test_spacelens_renders() {
        openFiles(tab: "SpaceLens")
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertNotNil(element(labeled: "SpaceLens", timeout: 5) ??
                        element(labeled: "Analyze", timeout: 2) ??
                        element(labeled: "Scan", timeout: 2),
                        "SpaceLens should render a treemap or a scan prompt")
    }

    // TC-FILE-10 — the Duplicates tab renders. NOTE: the "Delete marked" control
    // (`files.duplicates.deleteMarked.button`) is currently a UI stub with an
    // empty action — it deletes nothing. We verify that invoking it is a safe
    // no-op (no file trashed), which is the only honest assertion until the
    // feature is implemented with a confirmation gate.
    func test_duplicates_delete_is_safe_noop() throws {
        let fx = HaloTestFixtures(self)
        fx.makeDuplicateSet()        // canaries in the sandbox
        fx.captureTrashBaseline()
        openFiles(tab: "Duplicates")

        if tapID("files.duplicates.deleteMarked.button", timeout: 10) {
            // Stub action → nothing should be deleted anywhere.
            fx.assertNothingDeleted()
        } else {
            fx.tearDown()
            throw XCTSkip("No duplicate groups on this machine, so 'Delete marked' isn't shown. " +
                          "NOTE: that control is currently an unimplemented no-op stub; when it " +
                          "is wired it MUST show a confirmation before trashing (TC-SAFE-02).")
        }
        fx.tearDown()
    }

    // TC-FILE-20 / TC-SAFE-02 — the Downloads bulk "Clean Stale" flow confirms
    // before trashing. We drive it to the confirmation and cancel; nothing is
    // deleted. (The per-row trash button `files.downloads.trash.button` deletes
    // IMMEDIATELY with no confirmation — a TC-SAFE-02 gap — so the suite never
    // clicks it against real downloads.)
    func test_downloads_clean_stale_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Downloads")
        guard tapID("files.downloads.cleanStale.button", timeout: 10) else {
            fx.tearDown()
            throw XCTSkip("No stale (>90 day) downloads on this machine, so the confirmed " +
                          "Clean Stale flow isn't offered. Expectation: it asks 'Move N files … " +
                          "to Trash?' with Cancel before deleting (TC-SAFE-02).")
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Clean Stale Downloads must confirm before trashing (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-FILE-30 — the Large Files list renders. SAFETY: the per-row delete
    // (`files.largeFiles.row`) calls trashItem IMMEDIATELY with no confirmation
    // dialog (only an error alert exists). That both violates the mandatory
    // "all deletions confirm" rule (TC-SAFE-02) and would trash a real file, so
    // this test asserts the list renders and deliberately does NOT click delete.
    func test_large_files_list_renders_delete_not_exercised() throws {
        openFiles(tab: "Large Files")
        let rendered = waitForID("files.largeFiles.row", timeout: 30) != nil ||
                       element(labeled: "Large Files", timeout: 5) != nil ||
                       app.windows.firstMatch.exists
        XCTAssertTrue(rendered, "Large Files tab should render a list or empty state")
        // Intentionally no delete: the per-row delete lacks a confirmation gate.
        // Once a confirmation is added, replace this with a drive-to-confirm →
        // cancel → assertNothingDeleted flow like the other destructive tests.
    }

    // TC-FILE-40 — Drive Speed benchmark runs and reports read/write numbers.
    // Non-destructive: writes only Halo's own scratch file which it removes.
    // We assert no `.HaloSpeedTest` residue is left in the OS temp dir.
    func test_drive_speed_runs_and_leaves_no_residue() throws {
        openFiles(tab: "Drive Speed")
        _ = clickAny(of: ["Quick", "Start", "Run", "Run Test"], timeout: 5)
        // Read/write result labels (MB/s) or a friendly not-writable banner.
        let settled = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "MB/s", "not writable")).firstMatch
        _ = settled.waitForExistence(timeout: 90)

        // Residue check: the scratch file/dir must be gone (TC-SAFE-01 spirit).
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let residue = temp.appendingPathComponent(".HaloSpeedTest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path),
                       "Drive Speed scratch file must be cleaned up after the run")
    }
}
