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

    /// TC-CLEAN-03 / TC-SAFE-02 — destructive cleanup must present a
    /// confirmation review before deleting anything.
    ///
    /// NOTE: kept as a documented expectation rather than an automatic delete
    /// so the suite never trashes real user files. Enable once a seeded
    /// fixture directory is wired via launch arguments.
    func test_cleanup_requires_confirmation_before_delete() throws {
        throw XCTSkip("Enable with a seeded fixture dir to avoid trashing real files. " +
                      "Expectation: clicking Clean shows a review sheet before any deletion.")
    }
}
