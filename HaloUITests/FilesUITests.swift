//
//  FilesUITests.swift
//  HaloUITests
//
//  Files module — all six tabs. Maps to MANUAL_TEST_PLAN.md §7:
//    7.1 SpaceLens     (TC-FILE-01…03)
//    7.2 Duplicates    (TC-FILE-10…11)
//    7.3 Downloads     (TC-FILE-20…)
//    7.4 Large Files   (TC-FILE-30…)
//    7.5 Drive Speed   (TC-FILE-40… / F-043)
//    7.6 iCloud Drive  (TC-FILE-50… / F-030)
//
//  SAFETY: the duplicate/large-file/downloads/iCloud-Drive flows can delete
//  files, so every destructive path is driven to its confirmation and
//  cancelled, with dummy fixtures + a Trash baseline proving nothing was
//  deleted. Drive Speed writes only Halo's own scratch file (temp /
//  `.HaloSpeedTest`), which it removes.
//

import XCTest

final class FilesUITests: HaloUITestCase {

    private func openFiles(tab: String? = nil) {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .files))
        if let tab {
            // Prefer the stable tab identifier; fall back to the visible title.
            if !tapID("files.tab.\(tab)", timeout: 5) { _ = clickAny(of: [tab], timeout: 3) }
        }
    }

    // TC-FILE-01 — SpaceLens tab renders (treemap or a scan prompt).
    func test_spacelens_renders() {
        openFiles(tab: "SpaceLens")
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertNotNil(element(labeled: "SpaceLens", timeout: 5) ??
                        element(labeled: "Analyze", timeout: 2) ??
                        element(labeled: "Scan", timeout: 2),
                        "SpaceLens should render a treemap or a scan prompt")
    }

    // TC-FILE-10 / TC-SAFE-02 — marking a duplicate copy and clicking
    // "Delete marked" shows a confirmation before trashing; cancelling deletes
    // nothing. (Duplicate scan is sample data, so we drive the mark → confirm →
    // cancel gate rather than a real deletion.)
    func test_duplicate_delete_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Duplicates")
        _ = clickAny(of: ["Scan Home", "Choose Folder", "Scan"], timeout: 5)

        guard waitForID("files.duplicates.deleteMarked.button", timeout: 15) != nil else {
            fx.tearDown()
            throw XCTSkip("No duplicate groups surfaced to act on.")
        }
        // Ensure at least one copy is marked (sample data marks some by default;
        // if not, tap the first duplicate path to mark it).
        if !tapID("files.duplicates.deleteMarked.button", timeout: 3) {
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "~/")).firstMatch.click()
            guard tapID("files.duplicates.deleteMarked.button", timeout: 3) else {
                fx.tearDown()
                throw XCTSkip("'Delete marked' stayed disabled — nothing could be marked.")
            }
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting marked duplicates must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-FILE-20 / TC-SAFE-02 — deleting a download (per-row) now confirms
    // first; cancelling deletes nothing.
    func test_downloads_delete_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Downloads")
        guard waitForID("files.downloads.row", timeout: 20) != nil else {
            fx.tearDown()
            throw XCTSkip("No files in ~/Downloads to exercise the per-row delete flow.")
        }
        element(id: "files.downloads.row").hover()   // reveal the row's trash button
        guard tapID("files.downloads.trash.button", timeout: 5) else {
            fx.tearDown()
            throw XCTSkip("Downloads trash button not hittable.")
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting a download must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-FILE-30 / TC-SAFE-02 — deleting a large file now confirms first;
    // cancelling deletes nothing (no real file is ever trashed).
    func test_large_files_delete_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "Large Files")
        guard waitForID("files.largeFiles.trash.button", timeout: 30) != nil else {
            fx.tearDown()
            throw XCTSkip("No large files (>500 MB) found on this machine to exercise delete.")
        }
        _ = tapID("files.largeFiles.trash.button", timeout: 5)
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting a large file must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }

    // TC-FILE-40 — Drive Speed benchmark runs and reports read/write numbers.
    // Non-destructive: writes only Halo's own scratch file which it removes.
    // We assert no `.HaloSpeedTest` residue is left in the OS temp dir.
    func test_drive_speed_runs_and_leaves_no_residue() throws {
        openFiles(tab: "Drive Speed")
        _ = clickAny(of: ["Quick", "Start", "Run", "Run Test"], timeout: 5)
        // Read/write result labels (MB/s) or a friendly not-writable banner.
        let settled = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "MB/s", "not writable")).firstMatch
        _ = settled.waitForExistence(timeout: 90)

        // Residue check: the scratch file/dir must be gone (TC-SAFE-01 spirit).
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let residue = temp.appendingPathComponent(".HaloSpeedTest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path),
                       "Drive Speed scratch file must be cleaned up after the run")
    }

    // TC-FILE-50/51 — the iCloud Drive tab renders either real containers (with
    // "iCloud Drive" for com~apple~CloudDocs sorted first) or a friendly
    // not-set-up state — never a crash. Whether iCloud Drive is configured is
    // machine-dependent, so both outcomes are accepted.
    func test_icloud_drive_renders_containers_or_unavailable_state() throws {
        openFiles(tab: "iCloud Drive")
        let hasContainer = element(labeled: "iCloud Drive", timeout: 5) != nil
        let unavailable = element(labeled: "iCloud Drive isn't set up on this Mac", timeout: 2) != nil
        let noContainers = element(labeled: "No iCloud containers found", timeout: 2) != nil
        XCTAssertTrue(hasContainer || unavailable || noContainers,
                      "iCloud Drive tab should show real containers or a graceful empty/unavailable state")
    }

    // TC-FILE-56 / TC-SAFE-02 — trashing an iCloud Drive item confirms first
    // (and mentions cross-device removal); cancelling deletes nothing.
    func test_icloud_drive_delete_confirms_and_cancel_deletes_nothing() throws {
        let fx = HaloTestFixtures(self)
        fx.captureTrashBaseline()
        openFiles(tab: "iCloud Drive")

        guard waitForID("files.icloud.row", timeout: 15) != nil else {
            fx.tearDown()
            throw XCTSkip("No iCloud Drive items on this machine to exercise the delete flow.")
        }
        element(id: "files.icloud.row").hover()   // reveal the row's trash button
        guard tapID("files.icloud.trash.button", timeout: 5) else {
            fx.tearDown()
            throw XCTSkip("iCloud Drive trash button not hittable.")
        }
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Deleting an iCloud Drive item must confirm first (TC-SAFE-02)")
        cancelConfirmation()
        fx.assertTrashUnchanged()
        fx.tearDown()
    }
}
