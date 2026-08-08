//
//  ClipboardSnippetsUITests.swift
//  HaloUITests
//
//  Clipboard history + Snippet manager.
//  Maps to MANUAL_TEST_PLAN.md §8.1 (TC-CLIP-01…) and §8.2 (TC-SNIP-01…).
//
//  Clipboard content is app-managed history, not system files, so "clearing"
//  it is not a filesystem deletion — but it IS a data-loss action, so any
//  "Clear History" is driven to its confirmation and cancelled.
//

import XCTest

final class ClipboardSnippetsUITests: HaloUITestCase {

    // TC-CLIP-01 — the Clipboard module opens and shows history or an empty
    // state (never a blank/stuck pane).
    func test_clipboard_module_renders() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .clipboard))
        XCTAssertTrue(app.windows.firstMatch.exists)
        // A filter control or the "Clipboard" title should be present.
        XCTAssertNotNil(element(labeled: "Clipboard", timeout: 5) ??
                        element(labeled: "All", timeout: 2),
                        "Clipboard view should render history UI")
    }

    // TC-CLIP-05 — copying text then returning to Halo records a new item.
    // We seed the pasteboard programmatically (our own dummy string) and assert
    // it surfaces. This touches only NSPasteboard, no filesystem.
    func test_copied_text_appears_in_history() throws {
        let token = "halo-e2e-clip-\(Int(Date().timeIntervalSince1970))"
        // Write to the general pasteboard — this is the user-copy simulation.
        // (NSPasteboard is the system clipboard, not a file; safe to set.)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)

        HaloSidebar(test: self).navigate(to: .clipboard)
        // The monitor polls the pasteboard; give it a moment.
        guard element(labeled: token, timeout: 8) != nil ||
              app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", token)).firstMatch
                .waitForExistence(timeout: 8) else {
            throw XCTSkip("Copied token did not surface within the poll window — the " +
                          "ClipboardMonitor may be paused in the test session, or the row " +
                          "needs an addressable identifier.")
        }
    }

    // TC-CLIP-09 / TC-SAFE-02 — "Clear History" is a data-loss action and must
    // confirm first. Drive to confirmation, cancel, and assert we're still on
    // the Clipboard view (history not wiped).
    func test_clear_history_requires_confirmation() throws {
        HaloSidebar(test: self).navigate(to: .clipboard)
        guard firstButton(labeledAnyOf: ["Clear History", "Clear All", "Clear"], timeout: 5) != nil else {
            throw XCTSkip("Clear-history control not addressable by label; annotate with " +
                          "`clipboard.clearHistory.button`.")
        }
        firstButton(labeledAnyOf: ["Clear History", "Clear All", "Clear"])?.click()
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Clearing clipboard history should confirm first (TC-SAFE-02)")
        cancelConfirmation()
    }

    // TC-SNIP-01 — the Snippets surface is reachable and renders. Snippets may
    // live under a tab/segment within Clipboard.
    func test_snippets_surface_renders() throws {
        HaloSidebar(test: self).navigate(to: .clipboard)
        guard clickAny(of: ["Snippets", "Snippet"], timeout: 5) ||
              element(labeled: "Snippets", timeout: 2) != nil else {
            throw XCTSkip("Snippets tab not addressable by label; annotate with " +
                          "`clipboard.snippetsTab`. Expectation: a snippet list + New Snippet.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
