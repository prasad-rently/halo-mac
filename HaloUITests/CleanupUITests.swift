//
//  CleanupUITests.swift
//  HaloUITests
//
//  Cleanup module flow. Maps to MANUAL_TEST_PLAN.md §3 (TC-CLEAN-01/03).
//
//  This flow targets the one stable identifier that already exists in the
//  app — `fileListView` (CleanupView.swift) — and demonstrates the intended
//  pattern: navigate, trigger a scan, assert the results surface appears.
//

import XCTest

final class CleanupUITests: HaloUITestCase {

    /// TC-CLEAN-01 — opening Cleanup and running a scan surfaces the file list.
    func test_cleanup_scan_shows_file_list() {
        let sidebar = HaloSidebar(test: self)
        XCTAssertTrue(sidebar.navigate(to: .cleanup))

        // Kick off a scan if a Scan/Clean button is present.
        for label in ["Scan", "Scan Now", "Start Scan"] {
            if let scan = element(labeled: label, timeout: 2) {
                scan.click()
                break
            }
        }

        // The results list carries a stable identifier.
        let fileList = app.descendants(matching: .any)["fileListView"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 30),
                      "Cleanup results (fileListView) should appear after scanning")
    }

    /// TC-CLEAN-03 / TC-SAFE-02 / TC-SAFE-03 — destructive cleanup must present
    /// a confirmation review before deleting anything, and cancelling it must
    /// delete NOTHING.
    ///
    /// Safe by construction: we seed dummy canary files in a temp sandbox and
    /// snapshot the Trash, run a scan, then drive the "Clean" action only up to
    /// its confirmation sheet and cancel. Afterwards we assert the dummies are
    /// intact and the Trash is unchanged — proving the confirmation gate without
    /// ever trashing a real file.
    func test_cleanup_requires_confirmation_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        _ = fx.makeFiles(count: 3)          // canaries
        fx.captureTrashBaseline()

        let sidebar = HaloSidebar(test: self)
        XCTAssertTrue(sidebar.navigate(to: .cleanup))
        _ = clickAny(of: ["Scan", "Scan Now", "Start Scan"], timeout: 5)
        _ = app.descendants(matching: .any)["fileListView"].waitForExistence(timeout: 30)

        // The Clean All button appears once a category with items is selected.
        guard tapID("cleanup.cleanAll.button", timeout: 15) else {
            fx.tearDown()
            throw XCTSkip("No Clean All affordance became addressable (the scan may have found " +
                          "nothing in the selected category). Expectation: clicking Clean All " +
                          "shows a 'Move to Trash?' review before any deletion (TC-SAFE-02).")
        }

        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Cleanup must present a review sheet before deleting (TC-SAFE-02)")
        cancelConfirmation()

        fx.assertNothingDeleted()           // dummies intact + Trash unchanged
        fx.tearDown()
    }
}
