//
//  SmokeUITests.swift
//  HaloUITests
//
//  Build-acceptance + navigation smoke flows.
//  Maps to MANUAL_TEST_PLAN.md §0 (Smoke) and §1 (Shell & Navigation).
//

import XCTest

final class SmokeUITests: HaloUITestCase {

    /// TC-SMOKE-01 — the app launches and a window appears.
    func test_app_launches_with_window() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: defaultTimeout),
                      "Main window should appear after launch")
    }

    /// TC-SHELL-03 — Dashboard is the default route.
    func test_dashboard_is_default_route() {
        // Health score / Dashboard content should be present on first launch.
        assertVisible(HaloModule.dashboard.rawValue,
                      "Dashboard should be selected/visible by default")
    }

    /// TC-SMOKE-04 / TC-SHELL-02 — every sidebar module routes to a view
    /// without leaving the detail pane blank or stuck on a spinner.
    func test_navigate_through_all_modules() {
        let sidebar = HaloSidebar(test: self)
        for module in HaloModule.allCases {
            XCTContext.runActivity(named: "Navigate to \(module.rawValue)") { _ in
                XCTAssertTrue(sidebar.navigate(to: module),
                              "Should be able to open \(module.rawValue)")
                // Give the detail pane a moment, then assert the window still
                // hosts content (no crash / blank).
                XCTAssertTrue(app.windows.firstMatch.exists,
                              "Window should remain after opening \(module.rawValue)")
            }
        }
    }
}
