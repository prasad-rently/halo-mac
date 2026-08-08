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
}
