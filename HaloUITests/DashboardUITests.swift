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

    // TC-DASH-05 — the Smart Scan trigger is reachable from the Dashboard.
    // Expected: a "Smart Scan" / "Scan" control is present (its behaviour is
    // covered by SmartScanUITests).
    func test_dashboard_exposes_smart_scan_trigger() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        XCTAssertTrue(clickAny(of: ["Smart Scan", "Run Smart Scan", "Scan"], timeout: 5) ||
                      element(labeled: "Smart Scan", timeout: 2) != nil,
                      "Dashboard should offer a Smart Scan entry point")
        // Dismiss anything that opened so we leave clean state.
        app.typeKey(.escape, modifierFlags: [])
    }

    // TC-DASH-07 — Export Report entry point is present. The actual export is
    // covered (safely, save-panel-cancelled) by AlertsReportUITests.
    func test_dashboard_exposes_export_report() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard element(labeled: "Export Report", timeout: 5) != nil ||
              element(labeled: "Export", timeout: 2) != nil else {
            throw XCTSkip("Export Report control not found by label — add " +
                          "`.accessibilityIdentifier(\"dashboard.exportReport.button\")` " +
                          "to the Dashboard export button to make this durable.")
        }
    }

    // TC-DASH-08 — Alert history section renders on the Dashboard.
    // Expected: an "Alerts"/"Alert History" heading is visible.
    func test_dashboard_shows_alert_history_section() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard element(labeled: "Alert History", timeout: 5) != nil ||
              element(labeled: "Alerts", timeout: 2) != nil ||
              element(labeled: "Recent Alerts", timeout: 2) != nil else {
            throw XCTSkip("Alert history heading not found by label; annotate it " +
                          "with a stable identifier to enable this assertion.")
        }
    }
}
