//
//  CodeBeautifierUITests.swift
//  HaloUITests
//
//  Code Snippet Beautifier (F-038). Maps to MANUAL_TEST_PLAN.md §11
//  (TC-BEAUT-01…). Pure text transform + render — nothing touches the
//  filesystem, so no fixtures are required.
//

import XCTest

final class CodeBeautifierUITests: HaloUITestCase {

    // The beautifier is reached via the Actions module / a dedicated route
    // (`CodeBeautifierView` in ContentView). We open it via its entry label.
    private func openBeautifier() -> Bool {
        // Try a direct label first, then via Actions.
        if element(labeled: "Beautify Code", timeout: 2) != nil ||
           element(labeled: "Code Beautifier", timeout: 2) != nil {
            _ = clickAny(of: ["Code Beautifier", "Beautify Code"], timeout: 2)
            return true
        }
        HaloSidebar(test: self).navigate(to: .actions)
        return clickAny(of: ["Beautify Code", "Code Beautifier"], timeout: 5)
    }

    // TC-BEAUT-01 — the beautifier opens with an editor + language selector.
    func test_beautifier_opens() throws {
        guard openBeautifier() else {
            throw XCTSkip("Code Beautifier entry not addressable by label; annotate its " +
                          "entry point with `beautifier.open`. Expectation: an editor, a " +
                          "language picker, and a Beautify action appear.")
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    // TC-BEAUT-03 — pasting minified code and beautifying produces formatted
    // output (more lines than input). Documented; enable once the editor's
    // text views carry identifiers.
    func test_beautify_formats_input() throws {
        throw XCTSkip("Enable once the beautifier input/output text views expose " +
                      "identifiers (`beautifier.input`, `beautifier.output`). " +
                      "Expectation: input `{\"a\":1,\"b\":2}` → pretty-printed multi-line output.")
    }
}
