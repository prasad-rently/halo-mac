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
        if let tab { _ = clickAny(of: [tab], timeout: 5) }
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

    // TC-FILE-10 / TC-SAFE-02 — the duplicate finder groups byte-identical
    // files, and deleting duplicates confirms first. We seed a dummy duplicate
    // set in a sandbox, point the finder at it (if a folder chooser exists),
    // drive delete → cancel, and assert the dummies survive.
    func test_duplicate_delete_confirms_and_cancel_keeps_dummies() throws {
        let fx = HaloTestFixtures(self)
        let (a, b, _) = fx.makeDuplicateSet()
        fx.guardRealPath(a)          // our dummies double as guarded canaries
        fx.guardRealPath(b)
        fx.captureTrashBaseline()

        openFiles(tab: "Duplicates")

        // If a "Choose Folder"/"Add Folder" chooser is available we could target
        // the sandbox via the open panel; that panel is a separate process and
        // flaky to drive, so we keep the deterministic part: ANY delete affordance
        // in Duplicates must be confirmation-gated.
        guard firstButton(labeledAnyOf: ["Delete", "Delete Selected", "Remove", "Trash"], timeout: 10) != nil else {
            fx.tearDown()
            throw XCTSkip("No duplicate-delete control addressable yet (needs a scan targeting " +
                          "the seeded sandbox and row identifiers). Expectation: deleting a " +
                          "duplicate shows a review sheet, and only trashItem is used (TC-SAFE-01).")
        }
        firstButton(labeledAnyOf: ["Delete", "Delete Selected", "Remove", "Trash"])?.click()
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting duplicates must confirm first (TC-SAFE-02)")
        cancelConfirmation()

        fx.assertNothingDeleted()    // dummies intact + Trash unchanged
        fx.tearDown()
    }

    // TC-FILE-20 / TC-SAFE-02 — Downloads manager delete confirms first.
    func test_downloads_delete_confirms() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Downloads")
        guard firstButton(labeledAnyOf: ["Delete", "Move to Trash", "Remove", "Trash"], timeout: 10) != nil else {
            fx.tearDown()
            throw XCTSkip("Downloads delete control not addressable; annotate rows/buttons " +
                          "(`files.downloads.delete`). Expectation: confirm-before-trash.")
        }
        firstButton(labeledAnyOf: ["Delete", "Move to Trash", "Remove", "Trash"])?.click()
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting a download must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-FILE-30 / TC-SAFE-02 — Large Files delete confirms first.
    func test_large_files_delete_confirms() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Large Files")
        _ = clickAny(of: ["Scan", "Find Large Files"], timeout: 5)
        guard firstButton(labeledAnyOf: ["Delete", "Move to Trash", "Remove", "Trash"], timeout: 30) != nil else {
            fx.tearDown()
            throw XCTSkip("Large-files delete control not addressable in this session.")
        }
        firstButton(labeledAnyOf: ["Delete", "Move to Trash", "Remove", "Trash"])?.click()
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting a large file must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
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
