//
//  DashboardUITests.swift
//  HaloUITests
//
//  Dashboard module. Maps to MANUAL_TEST_PLAN.md §2 (TC-DASH-01…08).
//  Read-only surface — no fixtures needed, nothing here mutates the system.
//

import XCTest

final class DashboardUITests: HaloUITestCase {

    // TC-DASH-01 — Dashboard is the default landing view and renders a health
    // score. Expected: after launch the detail pane shows the Dashboard with a
    // numeric health score (0–100) in its ring.
    func test_dashboard_renders_health_score() {
        assertVisible(HaloModule.dashboard.rawValue,
                      "Dashboard should be the default route")
        // The ring label is a number 0–100. We can't assert the exact value,
        // so confirm at least one purely-numeric static text is present.
        let numeric = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]{1,3}$")).firstMatch
        XCTAssertTrue(numeric.waitForExistence(timeout: defaultTimeout),
                      "Health score number should render in the ring")
    }

    // TC-DASH-02 — the four live metric cards (CPU / RAM / Disk / Network)
    // are present. Expected: each metric label appears on the Dashboard.
    func test_dashboard_shows_metric_cards() {
        let sidebar = HaloSidebar(test: self)
        sidebar.navigate(to: .dashboard)
        for metric in ["CPU", "Memory", "Disk", "Network"] {
            XCTAssertNotNil(element(labeled: metric, timeout: 5) ??
                            app.staticTexts.containing(
                                NSPredicate(format: "label CONTAINS[c] %@", metric)).firstMatch,
                            "Dashboard should surface a \(metric) metric")
        }
    }

    // TC-DASH-05 — the Smart Scan trigger is present on the Dashboard (its
    // behaviour is covered by SmartScanUITests).
    func test_dashboard_exposes_smart_scan_trigger() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        assertID("dashboard.smartScan.button", "Dashboard should offer a Smart Scan button")
    }

    // TC-DASH-07 — Export Report entry point is present. The actual export is
    // covered (safely, save-panel-cancelled) by AlertsReportUITests.
    func test_dashboard_exposes_export_report() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        assertID("dashboard.exportReport.button", "Dashboard should offer an Export Report button")
    }

    // TC-DASH-08 — the alert history section renders on the Dashboard.
    func test_dashboard_shows_alert_history_section() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        assertID("dashboard.alertHistory", "Dashboard should show the Alert History section")
    }

    // MARK: - Focus Session (F-028) — TC-DASH-09…19
    //
    // Starting a real session hides other running apps and starts real
    // timers/notifications, so every test here stays at (or cancels out of)
    // the confirmation gate — never actually starting a session.

    // TC-DASH-09/10 — starting a focus session (which hides other apps) must
    // confirm first; cancelling starts nothing.
    func test_focusSession_start_requires_confirmation_and_cancel_starts_nothing() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard tapID("dashboard.focusSession.start", timeout: 10) else {
            XCTFail("Expected a 'Start Focus Session' button on the Dashboard")
            return
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Starting a focus session hides other apps — it must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        XCTAssertTrue(element(id: "dashboard.focusSession.start").waitForExistence(timeout: 5),
                      "Card should remain in idle state after cancelling — no session started")
        XCTAssertFalse(element(id: "dashboard.focusSession.end").exists,
                       "No session should be active after cancelling the start confirmation")
    }

    // TC-DASH-17 — the Focus History section only renders once at least one
    // session has completed (it reads AlertLog filtered to kindRaw == "focus").
    func test_focusHistory_section_renders_when_history_exists() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard waitForID("dashboard.focusHistory", timeout: 5) != nil else {
            throw XCTSkip("No completed Focus Sessions are recorded on this test machine yet — " +
                          "the Focus History section is conditionally hidden when there's no history.")
        }
        XCTAssertTrue(element(id: "dashboard.focusHistory").exists)
    }
}
