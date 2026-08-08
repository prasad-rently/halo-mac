//
//  HaloSidebar.swift
//  HaloUITests
//
//  Page object for the NavigationSplitView sidebar. Centralises the
//  module titles and navigation so individual flows stay readable.
//

import XCTest

/// The sidebar modules, keyed by their visible title (see `AppModule.title`
/// in the app). Dashboard is pinned; the rest are reorderable.
enum HaloModule: String, CaseIterable {
    case dashboard     = "Dashboard"
    case cleanup       = "Cleanup"
    case protection    = "Protection"
    case performance   = "Performance"
    case applications  = "Applications"
    case files         = "Files"
    case clipboard     = "Clipboard"
    case actions       = "Actions"
    case haloShare     = "HaloShare"
    case ports         = "Ports"
    case ai            = "AI Assistant"
    case menuBar       = "Menu Bar"
}

struct HaloSidebar {
    let test: HaloUITestCase
    var app: XCUIApplication { test.app }

    /// Click a sidebar module by title. Returns false if the row was not found.
    @discardableResult
    func navigate(to module: HaloModule,
                  file: StaticString = #filePath,
                  line: UInt = #line) -> Bool {
        guard let row = test.element(labeled: module.rawValue) else {
            XCTFail("Sidebar row '\(module.rawValue)' not found", file: file, line: line)
            return false
        }
        row.click()
        return true
    }

    /// Toggle the sidebar's reorder/edit mode. The header button swaps
    /// between `slider.horizontal.3` and `checkmark.circle.fill`; both are
    /// surfaced to the tree, so we click whichever is present.
    func toggleEditMode() {
        for id in ["slider.horizontal.3", "checkmark.circle.fill", "Edit", "Done"] {
            let b = app.buttons[id]
            if b.exists && b.isHittable { b.click(); return }
        }
    }
}
