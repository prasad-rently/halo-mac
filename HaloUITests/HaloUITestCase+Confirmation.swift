//
//  HaloUITestCase+Confirmation.swift
//  HaloUITests
//
//  Shared helpers for the "cancel-at-confirmation" safety pattern. Every
//  destructive flow must reach a review/confirmation surface before deleting;
//  these helpers find that surface, prove it appeared, and cancel out of it.
//
//  Matching is by CONTAINS (case-insensitive) so real button texts are caught:
//  "Move to Trash", "Kill (SIGTERM)", "Force Kill (SIGKILL)", "Uninstall", …
//

import XCTest

extension HaloUITestCase {

    /// Substrings that identify a destructive confirmation button.
    static let destructiveKeywords = [
        "Delete", "Remove", "Uninstall", "Trash", "Erase",
        "Kill", "Force Quit", "Clean", "Confirm"
    ]

    /// Substrings that identify an escape hatch.
    static let cancelKeywords = ["Cancel", "Dismiss", "Keep", "Not Now"]

    /// First hittable button whose label EXACTLY equals one of `labels`.
    func firstButton(labeledAnyOf labels: [String], timeout: TimeInterval = 3) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in labels {
                let b = app.buttons[label]
                if b.exists && b.isHittable { return b }
            }
        } while Date() < deadline
        return nil
    }

    /// First button whose label CONTAINS any of `substrings` (case-insensitive).
    func button(containingAnyOf substrings: [String], timeout: TimeInterval = 3) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let format = substrings.map { _ in "label CONTAINS[c] %@" }.joined(separator: " OR ")
        let predicate = NSPredicate(format: format, argumentArray: substrings)
        repeat {
            // Prefer buttons inside a presented dialog/sheet/alert, then anywhere.
            for scope in [app.dialogs, app.sheets, app.alerts] {
                let m = scope.buttons.matching(predicate).firstMatch
                if m.exists && m.isHittable { return m }
            }
            let any = app.buttons.matching(predicate).firstMatch
            if any.exists && any.isHittable { return any }
        } while Date() < deadline
        return nil
    }

    /// True if a modal confirmation surface (alert / dialog / sheet) is present,
    /// OR a destructive + cancel button pair is on screen. This is the
    /// TC-SAFE-02 gate.
    @discardableResult
    func confirmationSurfaceAppeared(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.dialogs.firstMatch.exists || app.alerts.firstMatch.exists { return true }
            let hasDestructive = button(containingAnyOf: Self.destructiveKeywords, timeout: 0.4) != nil
            let hasCancel = button(containingAnyOf: Self.cancelKeywords, timeout: 0.4) != nil
            if hasDestructive && hasCancel { return true }
        } while Date() < deadline
        return false
    }

    /// Cancel out of whatever confirmation surface is showing. Returns true if a
    /// cancel affordance was found and clicked.
    @discardableResult
    func cancelConfirmation() -> Bool {
        if let cancel = button(containingAnyOf: Self.cancelKeywords, timeout: 3) {
            cancel.click()
            return true
        }
        // Fall back to Escape, which dismisses SwiftUI alerts/sheets.
        app.typeKey(.escape, modifierFlags: [])
        return false
    }

    /// Click the first control matching any of `labels` (e.g. a "Clean"/"Scan"
    /// trigger). Returns true if one was clicked.
    @discardableResult
    func clickAny(of labels: [String], timeout: TimeInterval = 3) -> Bool {
        for label in labels {
            if let el = element(labeled: label, timeout: timeout) {
                el.click()
                return true
            }
        }
        return false
    }
}
