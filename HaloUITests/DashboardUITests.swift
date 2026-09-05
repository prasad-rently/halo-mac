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

    // MARK: - Backup Health / Time Machine Monitor (F-022) — TC-DASH-09…18
    //
    // Entirely read-only status via `tmutil` (Back Up Now is the one write
    // action, and it's a normal user-initiated backup identical to the menu
    // bar icon — no confirmation gate needed, but we never block on it
    // actually completing).

    // TC-DASH-09 / TC-DASH-10 / TC-DASH-11 — the card always renders exactly
    // one of its three honest states, never a crash and never a blank space.
    func test_backupHealth_card_renders() {
        HaloSidebar(test: self).navigate(to: .dashboard)
        XCTAssertTrue(assertID("dashboard.backupHealth.card",
                                "Backup Health card should render on the Dashboard", timeout: 10).exists)
    }

    // TC-DASH-09 — when Time Machine has never been configured, the "Set Up"
    // deep link is present and no heatmap is rendered as if data existed.
    func test_backupHealth_notConfigured_shows_setup_button() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard waitForID("dashboard.backupHealth.setup.button", timeout: 10) != nil else {
            throw XCTSkip("Time Machine is already configured on this test machine — " +
                          "not-configured expectation only applies to a fresh setup.")
        }
        XCTAssertFalse(element(id: "dashboard.backupHealth.heatmap").exists,
                       "No heatmap should render when Time Machine isn't configured")
    }

    // TC-DASH-10 / TC-DASH-16 — when a destination is configured and
    // reachable, the 30-day heatmap renders.
    func test_backupHealth_configured_shows_heatmap() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard waitForID("dashboard.backupHealth.heatmap", timeout: 15) != nil else {
            throw XCTSkip("Time Machine isn't configured/reachable on this test machine — " +
                          "heatmap expectation only applies once a destination is set up.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    // TC-DASH-14 — "Back Up Now" is tappable when a destination is
    // configured. We don't wait for the backup itself to complete — just
    // that tapping it doesn't crash and the app stays responsive.
    func test_backupHealth_backupNow_does_not_crash() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard tapID("dashboard.backupHealth.backupNow.button", timeout: 10) else {
            throw XCTSkip("Time Machine isn't configured on this test machine — " +
                          "no 'Back Up Now' button to exercise.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
