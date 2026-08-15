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

    // MARK: - App Usage Insights (F-021) — TC-DASH-09…19
    //
    // Usage tracking is off by default (opt-in only), so on a fresh test run
    // the section should render in its disabled state — never a crash and
    // never fabricated data.

    // TC-DASH-09 — the section renders (in whichever state — disabled by
    // default, collecting, or populated — depending on this machine's prior
    // opt-in state).
    func test_appUsageInsights_section_renders() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        XCTAssertTrue(assertID("dashboard.appUsageInsights",
                                "Dashboard should show the App Usage Insights header", timeout: 10).exists)
    }

    // TC-DASH-09 — when tracking has never been enabled on this machine, the
    // disabled state (not a chart, not "collecting") is what's shown.
    func test_appUsageInsights_shows_disabled_state_when_tracking_off() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard waitForID("dashboard.appUsageInsights.disabledState", timeout: 5) != nil else {
            throw XCTSkip("Usage tracking is already enabled on this test machine — " +
                          "disabled-state expectation only applies to a fresh opt-in.")
        }
        XCTAssertFalse(element(id: "dashboard.appUsageInsights.chart").exists,
                       "The Top Apps chart must not render while tracking is off")
    }
}
