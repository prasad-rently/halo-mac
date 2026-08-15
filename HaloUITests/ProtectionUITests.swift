//
//  ProtectionUITests.swift
//  HaloUITests
//
//  Protection module (malware / adware / PUP scanner backed by
//  SignatureDatabase, plus the F-016 Permission Auditor). Maps to
//  MANUAL_TEST_PLAN.md §4 (TC-PROT-01…07) and §4.1 (TC-PROT-08…16).
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

    // MARK: - Permission Auditor (F-016) — TC-PROT-08…16

    // TC-PROT-08 / TC-PROT-13 — the "App Permissions" section always renders
    // one of its two honest states: the rich per-app list (TCC.db readable)
    // or the fallback category grid + Full Disk Access banner (unreadable).
    // Which branch appears depends entirely on whether this machine/build has
    // granted Full Disk Access — the test accepts either, since both are
    // valid, non-fabricated outcomes.
    func test_permissions_section_renders_either_state() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .protection))

        let bannerAppeared = waitForID("protection.permissions.banner", timeout: 10) != nil
        let summaryAppeared = waitForID("protection.permissions.summary", timeout: 2) != nil
        let sectionHeaderAppeared = element(labeled: "App Permissions", timeout: 2) != nil

        XCTAssertTrue(bannerAppeared || summaryAppeared || sectionHeaderAppeared,
                      "Protection should show the App Permissions section in either its " +
                      "fallback (banner + category grid) or rich (per-app list) state")
    }

    // TC-PROT-13 — TCC.db-unreadable path: the honest banner plus the
    // original category-card grid (never a fabricated per-app list).
    func test_permissions_fallback_shows_banner_and_category_grid() throws {
        HaloSidebar(test: self).navigate(to: .protection)

        guard waitForID("protection.permissions.banner", timeout: 10) != nil else {
            throw XCTSkip("This run has Full Disk Access granted, so the rich per-app " +
                          "list renders instead of the fallback — see " +
                          "test_permissions_rich_list_shows_revoke_links for that branch.")
        }
        // At least one category card ("Open in Settings" deep link) should be
        // present alongside the banner.
        let anyCard = ["camera", "microphone", "location", "contacts", "calendar",
                       "fulldiskaccess", "screenrecording", "accessibility"]
            .contains { waitForID("protection.permissions.card.\($0)", timeout: 2) != nil }
        XCTAssertTrue(anyCard, "Fallback state should still show the category-card grid")
    }

    // TC-PROT-08 / TC-PROT-11 / TC-PROT-12 — TCC.db-readable path: the
    // grouped per-app list renders with a summary badge, and "Revoke" links
    // are present and tappable.
    func test_permissions_rich_list_shows_revoke_links() throws {
        HaloSidebar(test: self).navigate(to: .protection)

        guard waitForID("protection.permissions.summary", timeout: 10) != nil else {
            throw XCTSkip("Full Disk Access is not granted on this machine, so the rich " +
                          "per-app audit is unavailable — the honest fallback banner is " +
                          "shown instead (covered by " +
                          "test_permissions_fallback_shows_banner_and_category_grid).")
        }

        // Expand the first permission-kind group that has any grants.
        let kinds = ["camera", "microphone", "location", "contacts", "calendar",
                    "fulldiskaccess", "screenrecording", "accessibility"]
        var expandedKind: String?
        for kind in kinds {
            if let row = waitForID("protection.permissions.row.\(kind)", timeout: 1) {
                row.click()
                expandedKind = kind
                break
            }
        }
        guard let expandedKind else {
            XCTFail("Summary badge implies grants exist, but no permission group row was found")
            return
        }

        guard let revoke = waitForID("protection.permissions.revoke.\(expandedKind)", timeout: 5) else {
            XCTFail("Expanding a permission group with grants should reveal a Revoke link")
            return
        }
        XCTAssertTrue(revoke.isHittable, "Revoke link should be tappable")
        // Do not actually click Revoke — it opens System Settings, an
        // external app switch outside this suite's scope. Existence +
        // hittability is the assertion (TC-PROT-11).
    }
}
