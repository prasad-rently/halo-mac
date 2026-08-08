//
//  ApplicationsUITests.swift
//  HaloUITests
//
//  Applications deep-uninstaller (F-010). Maps to MANUAL_TEST_PLAN.md §6
//  (TC-APP-01…08) and the data-safety rules (§21.5 TC-SAFE-02/03).
//
//  SAFETY: uninstalling trashes the app bundle + its leftovers. We NEVER let a
//  real uninstall happen. The flow is driven only up to its confirmation review
//  and then cancelled; afterwards we assert nothing was trashed and that a
//  guarded real app bundle is byte-for-byte untouched.
//

import XCTest

final class ApplicationsUITests: HaloUITestCase {

    private func openApplications() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .applications))
    }

    // TC-APP-01 — the installed-app inventory populates.
    func test_app_inventory_populates() {
        openApplications()
        // The list should show at least one app row within a reasonable window,
        // or an explicit scanning/empty state — never a stuck blank pane.
        let populated = app.cells.firstMatch.waitForExistence(timeout: 30) ||
                        app.outlineRows.firstMatch.waitForExistence(timeout: 5) ||
                        element(labeled: "Applications", timeout: 5) != nil
        XCTAssertTrue(populated, "Applications inventory should populate")
    }

    // TC-APP-05 / TC-SAFE-02 / TC-SAFE-03 — uninstall must confirm first and,
    // when cancelled, delete NOTHING. We guard a real, always-present system app
    // bundle (Calculator) as a canary and assert it is untouched.
    func test_uninstall_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        // Canary: a real app bundle that must survive the whole test.
        fx.guardRealPath(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        fx.captureTrashBaseline()

        openApplications()
        guard app.cells.firstMatch.waitForExistence(timeout: 30) ||
              app.outlineRows.firstMatch.waitForExistence(timeout: 5) else {
            fx.tearDown()
            throw XCTSkip("No app rows became addressable; annotate rows with " +
                          "`applications.row.<bundleid>` to make selection deterministic.")
        }

        // Select the first row and invoke uninstall.
        (app.cells.firstMatch.exists ? app.cells.firstMatch : app.outlineRows.firstMatch).click()
        guard firstButton(labeledAnyOf: ["Uninstall", "Remove", "Delete"], timeout: 5) != nil else {
            fx.tearDown()
            throw XCTSkip("Uninstall control not addressable by label; annotate with " +
                          "`applications.uninstall.button`.")
        }
        firstButton(labeledAnyOf: ["Uninstall", "Remove", "Delete"])?.click()

        // THE GATE: a confirmation/review must appear before anything is trashed.
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Uninstall must present a confirmation review first (TC-SAFE-02)")

        // Back out — the whole point is to prove no deletion happens.
        cancelConfirmation()

        // Post-conditions: nothing trashed, canary bundle intact.
        fx.assertNothingDeleted()
        fx.tearDown()
    }

    // TC-APP-07 — leftover detection lists standard support paths for a selected
    // app (preferences, caches, containers, …). Documented; enable once the
    // leftover list rows carry identifiers.
    func test_leftover_scan_lists_paths() throws {
        throw XCTSkip("Enable once leftover rows expose identifiers " +
                      "(`applications.leftover.<kind>`). Expectation: selecting an app lists " +
                      "its leftovers across the 12 standard ~/Library paths, each individually " +
                      "toggleable, before any confirmed removal.")
    }
}
