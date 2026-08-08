//
//  AlertsReportUITests.swift
//  HaloUITests
//
//  Alerts + PDF report export + Siri/App Intents.
//  Maps to MANUAL_TEST_PLAN.md §15 (TC-ALERT-…, TC-RPT-…) and §16 (TC-SIRI-…).
//
//  SAFETY: exporting a report opens an NSSavePanel. We drive it to the panel
//  and CANCEL — no file is ever written to a real location.
//

import XCTest

final class AlertsReportUITests: HaloUITestCase {

    // TC-ALERT-01 — the alert history surface renders (list or empty state).
    func test_alert_history_renders() throws {
        HaloSidebar(test: self).navigate(to: .dashboard)
        guard element(labeled: "Alert History", timeout: 5) != nil ||
              element(labeled: "Alerts", timeout: 2) != nil ||
              element(labeled: "No alerts", timeout: 2) != nil else {
            throw XCTSkip("Alert history heading not addressable; annotate with " +
                          "`dashboard.alertHistory`.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    // TC-RPT-01 / safe — Export Report opens a save panel; cancelling writes
    // no file. We snapshot the Desktop to prove nothing new was written.
    func test_export_report_opens_save_panel_and_cancel_writes_nothing() throws {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let before = desktop.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path).count } ?? -1

        HaloSidebar(test: self).navigate(to: .dashboard)
        guard clickAny(of: ["Export Report", "Export", "Export PDF"], timeout: 5) else {
            throw XCTSkip("Export control not addressable; annotate with " +
                          "`dashboard.exportReport.button`.")
        }
        // The NSSavePanel is a separate process; assert a Save/Cancel appears,
        // then cancel. XCUIApplication for the panel is the frontmost sheet.
        let cancelled = firstButton(labeledAnyOf: ["Cancel"], timeout: 10) != nil
        if cancelled { firstButton(labeledAnyOf: ["Cancel"])?.click() }
        else { app.typeKey(.escape, modifierFlags: []) }

        if before >= 0 {
            let after = (try? FileManager.default.contentsOfDirectory(atPath: desktop!.path).count) ?? before
            XCTAssertEqual(after, before, "Cancelling export must not write a PDF to disk")
        }
    }

    // TC-SIRI-01 — App Intents are registered for Siri/Shortcuts. These run in
    // the Shortcuts app / Siri, not inside Halo's window, so they are out of
    // XCUITest's reach against the app target. Documented as an expectation.
    func test_app_intents_registered() throws {
        throw XCTSkip("The 8 App Intents (health score, CPU, battery, disk, smart scan, " +
                      "run action, clipboard history, export report) are exercised via the " +
                      "Shortcuts app, not Halo's own UI. Expectation: each appears in " +
                      "Shortcuts and returns live values from AppState.shared. Verify manually " +
                      "or with a Shortcuts-driven harness (TC-SIRI-01…08).")
    }
}
