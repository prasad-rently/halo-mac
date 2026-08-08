//
//  HaloUITestCase.swift
//  HaloUITests
//
//  Base class for all Halo end-to-end UI tests.
//
//  Halo is a native macOS SwiftUI app, so this suite uses XCUITest
//  (Apple's first-party UI automation) — the macOS equivalent of what
//  Maestro provides for mobile. Each test launches the real Halo.app,
//  drives the Accessibility tree, and asserts on visible state.
//
//  Selector strategy
//  -----------------
//  SwiftUI exposes views to the Accessibility tree by their label text.
//  Until views are annotated with `.accessibilityIdentifier(...)`, tests
//  must query by visible label. The `element(labeled:)` helper below is
//  deliberately tolerant — it searches buttons, static texts, cells, and
//  outline rows — so flows survive small structural changes. As stable
//  identifiers are added to the app, prefer querying by identifier.
//

import XCTest

class HaloUITestCase: XCTestCase {

    /// The app under test. Recreated for every test method.
    var app: XCUIApplication!

    /// Default time to wait for an element to appear before failing.
    let defaultTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Launch arguments the app can read to put itself in a deterministic
        // test state (e.g. skip onboarding, seed fixtures). The app does not
        // need to honour these for tests to run; they are forward-looking.
        app.launchArguments += ["-uiTesting", "YES"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Generic element lookup

    /// Find the first hittable element matching `label` across the element
    /// types SwiftUI commonly maps controls to. Returns nil if none appear
    /// within `timeout`.
    @discardableResult
    func element(labeled label: String, timeout: TimeInterval? = nil) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        let queries: [XCUIElementQuery] = [
            app.buttons, app.staticTexts, app.cells,
            app.outlineRows, app.tables.cells, app.menuItems
        ]
        repeat {
            for q in queries {
                let el = q[label]
                if el.exists && el.isHittable { return el }
            }
            // Fall back to a label-predicate match (handles composed labels).
            let predicate = NSPredicate(format: "label == %@", label)
            let match = app.descendants(matching: .any).matching(predicate).firstMatch
            if match.exists && match.isHittable { return match }
        } while Date() < deadline
        return nil
    }

    /// Assert that an element with `label` becomes visible, returning it.
    @discardableResult
    func assertVisible(_ label: String,
                       _ message: String? = nil,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> XCUIElement {
        guard let el = element(labeled: label) else {
            XCTFail(message ?? "Expected element labeled '\(label)' to be visible",
                    file: file, line: line)
            return app.windows.firstMatch
        }
        return el
    }

    /// Tap (click) the element with `label`, failing the test if it is absent.
    func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let el = element(labeled: label) else {
            XCTFail("Could not find tappable element labeled '\(label)'",
                    file: file, line: line)
            return
        }
        el.click()
    }

    // MARK: - Identifier lookup (preferred — durable across title/label changes)

    /// The first element carrying `identifier`, across the common control types.
    /// Prefer this over `element(labeled:)` now that the app is annotated with
    /// `.accessibilityIdentifier(...)`.
    func element(id identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Wait for an element with `identifier` to exist, then return it (or nil).
    @discardableResult
    func waitForID(_ identifier: String, timeout: TimeInterval? = nil) -> XCUIElement? {
        let el = element(id: identifier)
        return el.waitForExistence(timeout: timeout ?? defaultTimeout) ? el : nil
    }

    /// Assert an element with `identifier` becomes visible.
    @discardableResult
    func assertID(_ identifier: String,
                  _ message: String? = nil,
                  timeout: TimeInterval? = nil,
                  file: StaticString = #filePath,
                  line: UInt = #line) -> XCUIElement {
        let el = element(id: identifier)
        XCTAssertTrue(el.waitForExistence(timeout: timeout ?? defaultTimeout),
                      message ?? "Expected element with identifier '\(identifier)'",
                      file: file, line: line)
        return el
    }

    /// Click the element with `identifier` if present within `timeout`.
    @discardableResult
    func tapID(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let el = element(id: identifier)
        guard el.waitForExistence(timeout: timeout) && el.isHittable else { return false }
        el.click()
        return true
    }
}
