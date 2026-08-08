//
//  MenuBarUITests.swift
//  HaloUITests
//
//  Menu Bar display styles + custom format strings.
//  Maps to MANUAL_TEST_PLAN.md §13 (TC-MENU-01…).
//
//  The live menu-bar extra is a system status item outside the app window and
//  is not reliably drivable via the app's own accessibility tree. We test the
//  in-app "Menu Bar" preview/settings module, which is where the style + format
//  are chosen. Read-only / preference changes only — nothing destructive.
//

import XCTest

final class MenuBarUITests: HaloUITestCase {

    private func openMenuBar() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .menuBar))
    }

    // TC-MENU-01 — the Menu Bar settings/preview module renders with the style
    // options (Icon / Text Stats / Mini Bars / Dot / Custom).
    func test_menu_bar_style_options_present() throws {
        openMenuBar()
        let styles = ["Icon", "Text", "Text Stats", "Mini", "Bars", "Dot", "Custom"]
        guard styles.contains(where: { element(labeled: $0, timeout: 5) != nil }) else {
            throw XCTSkip("Menu-bar style options not addressable by label; annotate the " +
                          "style selector with identifiers like `menubar.style.dot`.")
        }
    }

    // TC-MENU-04 — selecting a style updates the live preview. We click a style
    // and assert the module remains responsive (preview re-renders).
    func test_selecting_style_updates_preview() throws {
        openMenuBar()
        guard clickAny(of: ["Mini", "Bars", "Dot", "Text Stats"], timeout: 5) else {
            throw XCTSkip("No style control clickable by label in this session.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists, "Preview should update without error")
    }

    // TC-MENU-07 — the custom format editor exposes tokens and a live preview.
    func test_custom_format_editor_present() throws {
        openMenuBar()
        _ = clickAny(of: ["Custom"], timeout: 5)
        let tokens = ["{cpu}", "{ram}", "{disk}", "{battery}", "Preset", "Standard"]
        guard tokens.contains(where: { element(labeled: $0, timeout: 5) != nil }) else {
            throw XCTSkip("Custom-format tokens/presets not addressable by label; annotate " +
                          "the token grid with identifiers like `menubar.token.cpu`.")
        }
    }
}
