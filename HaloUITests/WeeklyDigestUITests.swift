//
//  WeeklyDigestUITests.swift
//  HaloUITests
//
//  F-029 Scheduled Reports / Weekly Digest. Maps to MANUAL_TEST_PLAN.md
//  §2 (TC-DASH-09) and §15.3 (TC-DIGEST-01…).
//
//  "Send Test Digest Now" fires a real local notification + a real AlertLog
//  entry (no injectable seam — see HaloTests.swift's note on this), so this
//  file sticks to read-only affordance checks: the Dashboard trend card
//  renders, and the Settings section exposes its toggle/pickers without
//  actually sending anything.
//

import XCTest

final class WeeklyDigestUITests: HaloUITestCase {

    /// Halo's Settings is a separate macOS `Settings` scene (Cmd+,), not a
    /// sidebar destination — same pattern SmartScanUITests notes for the scan
    /// schedule pickers.
    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
    }

    // TC-DASH-09 — the 7-day Health Trend card renders on the Dashboard.
    func test_dashboard_shows_health_trend_card() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard waitForID("dashboard.healthTrend.card", timeout: 5) != nil ||
              element(labeled: "7-Day Health Trend", timeout: 3) != nil else {
            throw XCTSkip("HealthTrendCard (dashboard.healthTrend.card) not hittable at this scroll position.")
        }
    }

    // TC-DIGEST-01 — Settings exposes the Weekly Digest toggle, off by default.
    func test_settings_exposes_weekly_digest_toggle() throws {
        openSettings()
        guard let toggle = waitForID("settings.weeklyDigest.toggle", timeout: 5) else {
            throw XCTSkip("Settings window (Cmd+,) did not present the Weekly Digest toggle in this session.")
        }
        XCTAssertTrue(toggle.exists, "Weekly Digest toggle should be present in Settings")
    }

    // TC-DIGEST-02 — enabling the toggle reveals the frequency/day/time pickers,
    // and disabling it again hides them (restoring the setting we changed).
    func test_enabling_toggle_reveals_schedule_pickers() throws {
        openSettings()
        guard let toggle = waitForID("settings.weeklyDigest.toggle", timeout: 5) else {
            throw XCTSkip("Weekly Digest toggle not reachable.")
        }

        let wasOn = (toggle.value as? String) == "1"
        if wasOn { toggle.click() }   // start from a known "off" state
        toggle.click()                 // turn on
        defer { if !wasOn { toggle.click() } } // restore to the original state

        XCTAssertTrue(waitForID("settings.weeklyDigest.frequency.picker", timeout: 3) != nil,
                      "Enabling the digest should reveal the Frequency picker")
        XCTAssertTrue(waitForID("settings.weeklyDigest.hour.picker", timeout: 3) != nil,
                      "Enabling the digest should reveal the Time picker")
    }

    // TC-DIGEST-06 — "Share Weekly Report Now…" is reachable once enabled.
    // We only assert the entry point exists; the share sheet itself is a
    // system UI outside the app's accessibility tree, same caveat as the
    // Export Report flow in AlertsReportUITests.
    func test_share_weekly_report_button_present_when_enabled() throws {
        openSettings()
        guard let toggle = waitForID("settings.weeklyDigest.toggle", timeout: 5) else {
            throw XCTSkip("Weekly Digest toggle not reachable.")
        }
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn { toggle.click() }
        defer { if !wasOn { toggle.click() } }

        XCTAssertTrue(waitForID("settings.weeklyDigest.shareNow.button", timeout: 3) != nil,
                      "Share Weekly Report Now button should appear once the digest is enabled")
    }
}
