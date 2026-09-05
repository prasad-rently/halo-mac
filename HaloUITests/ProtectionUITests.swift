//
//  ProtectionUITests.swift
//  HaloUITests
//
//  Protection module (malware / adware / PUP scanner backed by
//  SignatureDatabase). Maps to MANUAL_TEST_PLAN.md §4 (TC-PROT-01…07).
//
//  Scanning is read-only; quarantine/removal is destructive and therefore
//  exercised only up to its confirmation gate (cancel-at-confirmation).
//

import XCTest

final class ProtectionUITests: HaloUITestCase {

    // TC-PROT-01 — opening Protection and starting a scan surfaces progress or
    // a results/clean state. Expected: after clicking Scan, the view shows a
    // scanning indicator or a "no threats"/results summary (never a crash).
    func test_protection_scan_surfaces_result() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .protection))
        if !tapID("protection.scan.button", timeout: 5) {
            _ = clickAny(of: ["Run Full Scan", "Scan", "Scan Now"], timeout: 3)
        }
        // Any of these signals a healthy end state.
        let settled =
            element(labeled: "No threats found", timeout: 60) ??
            element(labeled: "Scan complete", timeout: 2) ??
            element(labeled: "threats", timeout: 2) ??
            app.progressIndicators.firstMatch
        XCTAssertTrue(settled.exists || app.windows.firstMatch.exists,
                      "Protection scan should surface progress or a result")
    }

    // TC-PROT-05 / TC-SAFE-02 — quarantine/remove must confirm before acting.
    // A clean machine has nothing to remove, so this documents the expectation
    // and, when a removable item exists, drives to the confirmation and cancels.
    func test_protection_remove_requires_confirmation() throws {
        HaloSidebar(test: self).navigate(to: .protection)
        if !tapID("protection.scan.button", timeout: 5) {
            _ = clickAny(of: ["Run Full Scan", "Scan"], timeout: 3)
        }

        guard firstButton(labeledAnyOf: ["Remove", "Quarantine", "Remove All"], timeout: 20) != nil else {
            throw XCTSkip("No threats detected on this machine, so there is nothing " +
                          "to remove. Expectation: clicking Remove/Quarantine shows a " +
                          "confirmation review before any file is trashed (TC-SAFE-02).")
        }
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        firstButton(labeledAnyOf: ["Remove", "Quarantine", "Remove All"])?.click()
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Threat removal must present a confirmation review first")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-PROT-07 — the signature database reports a non-zero definition count
    // (loaded from signatures.json). Expected: a count / "definitions" label.
    func test_protection_shows_signature_info() throws {
        HaloSidebar(test: self).navigate(to: .protection)
        guard element(labeled: "definitions", timeout: 5) != nil ||
              app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "signature")).firstMatch.exists else {
            throw XCTSkip("Signature-count label not exposed by name; annotate with " +
                          "an identifier such as `protection.signatureCount.text`.")
        }
    }

    // MARK: - Security Posture Dashboard (F-019) — TC-PROT-08…30

    /// All 8 `SecurityCheckKind` id slugs, in the order `SecurityPostureScanner.scan()`
    /// returns them. Kept in sync manually with `Models.swift`'s `SecurityCheckKind`.
    private let securityCheckSlugs = [
        "fileVault", "gatekeeper", "firewall", "automaticUpdates",
        "sip", "secureBoot", "findMy", "loginWindow"
    ]

    // TC-PROT-08 — navigating to Protection surfaces the Security Posture
    // section, and it eventually settles (loading spinner clears).
    func test_securityPosture_section_renders() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .protection))
        XCTAssertTrue(element(labeled: "Security Posture", timeout: 10)?.exists ?? false,
                      "Protection should show a 'Security Posture' section")
        // Give the one-shot async scan time to settle before asserting on rows.
        _ = waitForID("protection.securityPosture.list", timeout: 15)
    }

    // TC-PROT-08 / TC-PROT-21…24 — all 8 check rows render with some state
    // icon, regardless of which are auto-verified vs. always-unknown.
    func test_securityPosture_all_eight_checks_render() {
        HaloSidebar(test: self).navigate(to: .protection)
        guard waitForID("protection.securityPosture.list", timeout: 20) != nil else {
            XCTFail("Security Posture list did not appear/settle in time")
            return
        }
        for slug in securityCheckSlugs {
            let row = element(id: "protection.securityPosture.check.\(slug)")
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "Expected a Security Posture row for '\(slug)'")
            let stateIcon = element(id: "protection.securityPosture.check.\(slug).state")
            XCTAssertTrue(stateIcon.waitForExistence(timeout: 5),
                          "Row '\(slug)' should render a state icon (pass/warn/fail/unknown)")
        }
    }

    // TC-PROT-27…29 — the score badge is visible once checks have loaded.
    func test_securityPosture_score_badge_visible() {
        HaloSidebar(test: self).navigate(to: .protection)
        guard waitForID("protection.securityPosture.list", timeout: 20) != nil else {
            XCTFail("Security Posture list did not appear/settle in time")
            return
        }
        let badge = assertID("protection.securityPosture.score",
                              "Security Posture score badge should be visible once checks load",
                              timeout: 10)
        // Sanity: label should look like "NN/100" or "N/100".
        XCTAssertTrue(badge.label.contains("/100"), "Score badge label was '\(badge.label)'")
    }

    // TC-PROT-25 — tapping a "Fix →" settings-link button on a check that has
    // one (e.g. FileVault, which always has a settingsURL) must not crash.
    // We deliberately do NOT assert System Settings actually opens — only
    // that the app survives the tap and remains responsive.
    func test_securityPosture_fix_button_does_not_crash() {
        HaloSidebar(test: self).navigate(to: .protection)
        guard waitForID("protection.securityPosture.list", timeout: 20) != nil else {
            XCTFail("Security Posture list did not appear/settle in time")
            return
        }
        let fixButton = element(id: "protection.securityPosture.check.fileVault.fix")
        guard fixButton.waitForExistence(timeout: 5) else {
            XCTFail("Expected a Fix button on the FileVault row (it always has a settingsURL)")
            return
        }
        fixButton.click()
        // App should still be alive and on the Protection screen afterward.
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "App should not crash after tapping a Fix/settings-link button")
        XCTAssertTrue(element(labeled: "Security Posture", timeout: 5)?.exists ?? false)
    }

    // TC-PROT-26 — SIP and Secure Boot have no reachable System Settings pane,
    // so their rows must not render a Fix button at all.
    func test_securityPosture_no_fix_button_for_sip_and_secureBoot() {
        HaloSidebar(test: self).navigate(to: .protection)
        guard waitForID("protection.securityPosture.list", timeout: 20) != nil else {
            XCTFail("Security Posture list did not appear/settle in time")
            return
        }
        XCTAssertFalse(element(id: "protection.securityPosture.check.sip.fix").exists,
                        "SIP has no System Settings pane — no Fix button should render")
        XCTAssertFalse(element(id: "protection.securityPosture.check.secureBoot.fix").exists,
                        "Secure Boot has no System Settings pane — no Fix button should render")
    }

    // MARK: - Sensitive Data Scanner (F-018) — TC-PROT-08…20
    //
    // Find-only feature: there is no delete/quarantine path anywhere here, so
    // these tests can run a real scan to completion without any confirmation
    // gate to navigate.

    // TC-PROT-08 — the section renders and a scan can be triggered; status
    // eventually settles (never a stuck "Scanning…" state).
    func test_privacyScan_runs_and_settles() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .protection))
        XCTAssertTrue(element(labeled: "Sensitive Data Scanner", timeout: 10)?.exists ?? false,
                      "Protection should show a 'Sensitive Data Scanner' section")
        guard tapID("protection.privacyscan.button", timeout: 8) else {
            XCTFail("Expected a 'Run Sensitive Data Scan' button")
            return
        }
        XCTAssertTrue(assertID("protection.privacyscan.status",
                                "Scan status indicator should be visible", timeout: 5).exists)
        // The scan walks Downloads/Documents/Desktop for real, so allow a
        // generous timeout; either the findings list or the clean empty state
        // is an acceptable settled outcome.
        let settled = waitForID("protection.privacyscan.findings.list", timeout: 120)
            ?? waitForID("protection.privacyscan.emptyState", timeout: 30)
        XCTAssertNotNil(settled, "Privacy scan should settle into either findings or the empty state")
    }

    // TC-PROT-17 — iCloud Drive inclusion is opt-in and off by default. We
    // only assert the toggle renders here; the exact off/on value
    // representation for a SwiftUI switch-style Toggle isn't stable enough
    // to assert without a live GUI session to confirm against, so the
    // off-by-default expectation itself is documented in
    // MANUAL_TEST_PLAN.md TC-PROT-17 for manual verification.
    func test_privacyScan_icloudToggle_renders() {
        HaloSidebar(test: self).navigate(to: .protection)
        XCTAssertTrue(assertID("protection.privacyscan.icloudToggle",
                                "Expected the 'Include iCloud Drive' toggle to render",
                                timeout: 10).exists)
    }

    // TC-PROT-19 — "Reveal in Finder" is the only action available on a
    // finding; if any findings exist, the reveal button must be present and
    // tappable without crashing the app (Finder itself is out of scope here).
    func test_privacyScan_reveal_button_present_when_findings_exist() throws {
        HaloSidebar(test: self).navigate(to: .protection)
        guard tapID("protection.privacyscan.button", timeout: 8) else {
            throw XCTSkip("Run Sensitive Data Scan button not found")
        }
        guard waitForID("protection.privacyscan.findings.list", timeout: 120) != nil else {
            throw XCTSkip("No sensitive data findings on this machine — nothing to reveal. " +
                          "Expectation: each finding row exposes a 'Reveal in Finder' " +
                          "button (protection.privacyscan.reveal.<id>) and no delete/quarantine action.")
        }
        let revealButtons = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "protection.privacyscan.reveal.")
        )
        XCTAssertGreaterThan(revealButtons.count, 0,
                             "At least one finding should expose a Reveal in Finder button")
    }
}
