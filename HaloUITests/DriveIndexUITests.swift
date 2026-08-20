//
//  DriveIndexUITests.swift
//  HaloUITests
//
//  F-051 External Drive Indexer & Cross-Drive Search. Maps to
//  docs/specs/F-051-manual-test-plan.md (TC-DRIVE).
//
//  CI can't plug in a real external drive, so these launch with
//  `-uiTestingSeedDriveIndex` (see `additionalLaunchArguments` below),
//  which routes the whole SQLite store to a temp directory and seeds two
//  fake drives: "Test Drive A" (connected) and "Test Drive B"
//  (deliberately left out of connectedVolumesByKey, so it reads as
//  disconnected) sharing a same-size file for the future duplicates path.
//  See `DriveIndexCoordinator.seedForUITesting()`.
//

import XCTest

final class DriveIndexUITests: HaloUITestCase {

    override var additionalLaunchArguments: [String] { ["-uiTestingSeedDriveIndex"] }

    private func openDriveIndex(tab: String? = nil) {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .driveIndex))
        if let tab {
            if !tapID("driveIndex.tab.\(tab)", timeout: 5) { _ = clickAny(of: [tab], timeout: 3) }
        }
    }

    // TC-DRIVE (navigation) — sidebar reaches the module and every tab renders.
    func test_sidebar_navigates_and_tabs_switch() {
        openDriveIndex()
        for tab in ["Drives", "Search", "Duplicates", "Settings"] {
            XCTAssertTrue(tapID("driveIndex.tab.\(tab)", timeout: 5) || clickAny(of: [tab], timeout: 3),
                          "Drive Index tab '\(tab)' should be reachable")
        }
    }

    // TC-DRIVE-01/06 (state surfaced) — seeded drives show with correct
    // connected/disconnected state rather than requiring a real mount.
    func test_drives_tab_shows_seeded_drives() {
        openDriveIndex(tab: "Drives")
        guard waitForID("driveIndex.drives.row", timeout: 10) != nil else {
            XCTFail("Seeded drives did not render — check -uiTestingSeedDriveIndex wiring")
            return
        }
        XCTAssertNotNil(element(labeled: "Test Drive A", timeout: 5),
                        "Connected seeded drive should be visible")
        XCTAssertNotNil(element(labeled: "Test Drive B", timeout: 3),
                        "Disconnected seeded drive should still be visible (last-known state)")
    }

    // TC-DRIVE-10/13/14 — search finds files on both a connected and a
    // disconnected drive, and gates Reveal/Open by connection state.
    func test_search_finds_seeded_files_and_gates_actions_by_connection() {
        openDriveIndex(tab: "Search")
        guard let field = waitForID("driveIndex.search.field", timeout: 5) else {
            XCTFail("Search field not found"); return
        }
        field.click()
        field.typeText("vacation")

        guard waitForID("driveIndex.search.row", timeout: 10) != nil else {
            XCTFail("Expected search results for seeded 'vacation' files"); return
        }
        XCTAssertNotNil(element(labeled: "vacation.mov", timeout: 5), "Connected drive's file should appear")
        XCTAssertNotNil(element(labeled: "vacation-copy.mov", timeout: 3), "Disconnected drive's file should still appear")

        // At least one reveal button must be enabled (the connected drive's
        // row) and at least one disabled (the disconnected drive's row) —
        // exact per-row pairing isn't asserted since XCUITest doesn't cheaply
        // scope "disabled button within this specific row", but the mixed
        // enabled/disabled set is the behavior under test (TC-DRIVE-14).
        let revealButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "driveIndex.search.reveal.button"))
        let anyEnabled = (0..<revealButtons.count).contains { revealButtons.element(boundBy: $0).isEnabled }
        let anyDisabled = (0..<revealButtons.count).contains { !revealButtons.element(boundBy: $0).isEnabled }
        XCTAssertTrue(anyEnabled, "The connected drive's result should have Reveal enabled")
        XCTAssertTrue(anyDisabled, "The disconnected drive's result should have Reveal disabled")
    }

    // TC-DRIVE-50/55 — Settings controls are present and toggle without
    // crashing; @AppStorage persistence itself is covered by unit-level
    // reasoning (it's a stock SwiftUI property wrapper) rather than
    // re-verified via a relaunch here.
    func test_settings_controls_are_interactable() {
        openDriveIndex(tab: "Settings")
        guard let pause = waitForID("driveIndex.settings.pause", timeout: 5) else {
            XCTFail("Pause toggle not found"); return
        }
        let before = pause.value as? String
        pause.click()
        XCTAssertNotEqual(pause.value as? String, before, "Toggling Pause should change its value")
        pause.click() // restore, so this test doesn't leak state into others

        XCTAssertTrue(waitForID("driveIndex.settings.category.Documents", timeout: 5) != nil,
                      "File-type category toggles should render")
        XCTAssertTrue(waitForID("driveIndex.settings.excludeList", timeout: 3) != nil,
                      "Exclude-folders-by-name editor should render")
    }

    // TC-DRIVE-45 — the Duplicates tab and its threshold picker render, and
    // the seeded same-size pair (one drive connected, one not) surfaces as
    // an "awaiting reconnect" group per FR-10 — real hash-confirmed
    // "Confirmed" groups need actual resolvable file bytes across two real
    // drives, which this synthetic seed can't provide (same class of gap as
    // the real-mount stretch goal, F-051-roadmap.md A.9).
    func test_duplicates_tab_shows_awaiting_reconnect_group() {
        openDriveIndex(tab: "Duplicates")
        XCTAssertTrue(waitForID("driveIndex.duplicates.threshold", timeout: 5) != nil,
                      "Size-threshold picker should render on the Duplicates tab")
        XCTAssertNotNil(element(labeled: "Awaiting reconnect", timeout: 10),
                        "Seeded same-size pair across a connected + disconnected drive should surface as awaiting reconnect")
    }

    // TC-SAFE-02 (this feature's variant) — marking the connected copy in a
    // duplicate group and tapping "Delete marked" must confirm before
    // trashing; cancelling must leave every row exactly as it was.
    func test_duplicates_delete_confirms_and_cancel_deletes_nothing() {
        openDriveIndex(tab: "Duplicates")
        guard waitForID("driveIndex.duplicates.item.row", timeout: 10) != nil else {
            XCTFail("Expected the seeded same-size pair to render as a duplicate group"); return
        }
        // Only the connected drive's row is markable — the disconnected
        // one is disabled so it can't be queued for a delete that can't
        // actually happen right now.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "driveIndex.duplicates.item.row"))
        guard let markableRow = (0..<rows.count).map({ rows.element(boundBy: $0) }).first(where: \.isEnabled) else {
            XCTFail("Expected at least one markable (connected-drive) duplicate row"); return
        }
        markableRow.click()

        guard tapID("driveIndex.duplicates.deleteMarked.button", timeout: 5) else {
            XCTFail("'Delete marked' should enable once a copy is marked"); return
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting a duplicate copy must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        // Cancelling must leave the row in place — nothing was trashed.
        XCTAssertNotNil(element(id: "driveIndex.duplicates.item.row"),
                        "Cancelling the confirmation must not remove or delete anything")
    }

    // TC-DRIVE-20/21/22 — the quick search picker opens on ⌘⇧F from
    // anywhere, searches the same data as the in-module Search tab, and a
    // second press dismisses it.
    func test_quick_search_picker_opens_searches_and_dismisses() {
        // Land somewhere else first — the picker must work regardless of
        // which module is active (it's a global overlay, not tab content).
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .dashboard))

        app.typeKey("f", modifierFlags: [.command, .shift])
        guard let field = waitForID("driveIndex.quickSearch.field", timeout: 5) else {
            XCTFail("Quick search picker did not open on ⌘⇧F"); return
        }
        field.typeText("report")
        XCTAssertNotNil(waitForID("driveIndex.quickSearch.row", timeout: 10),
                        "Quick search should find the seeded 'report.pdf'")

        app.typeKey("f", modifierFlags: [.command, .shift])
        // Second press dismisses — the field should no longer be present.
        let stillThere = element(id: "driveIndex.quickSearch.field").waitForExistence(timeout: 3)
        XCTAssertFalse(stillThere, "Second ⌘⇧F press should dismiss the picker")
    }
}
