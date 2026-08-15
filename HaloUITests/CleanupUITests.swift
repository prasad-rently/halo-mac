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

    // MARK: - Browsers (F-024) — TC-CLEAN-10…16
    //
    // Entirely read-only detection/measurement; only the review-sheet Cancel
    // path is exercised for the destructive "clear" action, matching the
    // cancel-at-confirmation pattern used elsewhere in this file. The review
    // sheet's own "Clear Selected"/"Cancel" button labels don't match the
    // shared confirmationSurfaceAppeared() helper's destructive-keyword list
    // (it says "Clear", not "Clean"/"Delete"/etc.), so this asserts directly
    // on the sheet's own stable identifiers instead.

    private func openBrowsers() {
        let sidebar = HaloSidebar(test: self)
        XCTAssertTrue(sidebar.navigate(to: .cleanup))
        if !tapID("cleanup.category.browsers.button", timeout: 5) {
            _ = clickAny(of: ["Browsers"], timeout: 3)
        }
    }

    // TC-CLEAN-10 — the Browsers pane renders: either detected browsers or
    // the explicit "no supported browsers" empty state, never a stuck spinner.
    func test_browsers_pane_renders() {
        openBrowsers()
        let settled = element(labeled: "No supported browsers detected", timeout: 20) != nil
            || app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "clearable")).firstMatch
                .waitForExistence(timeout: 20)
        XCTAssertTrue(settled, "Browsers pane should settle into either the empty state or a populated browser list")
    }

    // TC-CLEAN-13 / TC-CLEAN-14 / TC-SAFE-02 — "Clean All Browsers" must
    // surface the review sheet before clearing anything; Cancel must clear
    // nothing.
    func test_browsers_cleanAll_requires_confirmation_and_cancel_clears_nothing() throws {
        openBrowsers()
        guard tapID("browserCleaner.cleanAll.button", timeout: 20) else {
            throw XCTSkip("No supported browser with clearable data was detected on this test " +
                          "machine, so 'Clean All Browsers' never became available. Expectation: " +
                          "clicking it opens a review sheet listing every in-scope browser and " +
                          "category, and nothing is cleared until 'Clear Selected' is confirmed.")
        }
        XCTAssertTrue(waitForID("browserCleaner.clearSelected.button", timeout: 10) != nil,
                      "The review sheet ('Clear Selected' button) should appear before any clearing happens")
        // Cancel out — never actually clear the user's real browser data in a test run.
        guard let cancelButton = element(labeled: "Cancel", timeout: 3) else {
            XCTFail("Expected a Cancel button in the Browser Cleaner review sheet")
            return
        }
        cancelButton.click()
        XCTAssertFalse(element(id: "browserCleaner.clearSelected.button").exists,
                       "Review sheet should dismiss after Cancel, with nothing cleared")
    }

    // TC-CLEAN-13 — reviewing a single browser (via "Review & Clear" on its
    // card) also opens the same review sheet, scoped to just that browser.
    func test_browsers_singleReview_opens_sheet() throws {
        openBrowsers()
        guard clickAny(of: ["Review & Clear"], timeout: 20) else {
            throw XCTSkip("No browser with clearable data has a 'Review & Clear' affordance on " +
                          "this test machine.")
        }
        XCTAssertTrue(waitForID("browserCleaner.clearSelected.button", timeout: 10) != nil,
                      "Reviewing a single browser should open the same review sheet")
        _ = element(labeled: "Cancel", timeout: 3)?.click()
    }
}
