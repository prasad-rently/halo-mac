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

    /// The `AppModule.rawValue` this row maps to — the tail of its
    /// `sidebar.row.<rawValue>` accessibility identifier. A few visible titles
    /// differ from the underlying case name, so the mapping is explicit.
    var appModuleRawValue: String {
        switch self {
        case .haloShare: return "localShare"
        case .menuBar:   return "menuBarPreview"
        default:         return String(describing: self)
        }
    }

    /// The stable identifier of this module's sidebar row.
    var rowIdentifier: String { "sidebar.row.\(appModuleRawValue)" }
}

struct HaloSidebar {
    let test: HaloUITestCase
    var app: XCUIApplication { test.app }

    /// Click a sidebar module. Prefers the stable `sidebar.row.<module>`
    /// identifier and falls back to the visible title for resilience.
    @discardableResult
    func navigate(to module: HaloModule,
                  file: StaticString = #filePath,
                  line: UInt = #line) -> Bool {
        let byID = app.descendants(matching: .any)[module.rowIdentifier]
        if byID.waitForExistence(timeout: 5) && byID.isHittable {
            byID.click()
            return true
        }
        guard let row = test.element(labeled: module.rawValue) else {
            XCTFail("Sidebar row '\(module.rawValue)' (id \(module.rowIdentifier)) not found",
                    file: file, line: line)
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
