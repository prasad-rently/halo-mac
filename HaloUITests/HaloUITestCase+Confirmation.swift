//
//  HaloUITestCase+Confirmation.swift
//  HaloUITests
//
//  Shared helpers for the "cancel-at-confirmation" safety pattern. Every
//  destructive flow must reach a review/confirmation surface before deleting;
//  these helpers find that surface, prove it appeared, and cancel out of it.
//

import XCTest

extension HaloUITestCase {

    /// Button labels Halo uses to trigger a destructive action. Finding one of
    /// these (alongside a Cancel affordance) is our signal that a confirmation
    /// surface is present.
    static let destructiveLabels = [
        "Delete", "Remove", "Uninstall", "Trash", "Move to Trash",
        "Clean", "Clean Up", "Erase", "Kill", "Force Quit", "Quit", "Confirm"
    ]

    static let cancelLabels = ["Cancel", "Dismiss", "Keep", "Not Now", "Close"]

    /// First hittable button whose label is one of `labels`.
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

    /// True if a confirmation/review surface (a destructive button plus a way
    /// out) is on screen. This is the TC-SAFE-02 gate.
    @discardableResult
    func confirmationSurfaceAppeared(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let hasDestructive = firstButton(labeledAnyOf: Self.destructiveLabels, timeout: 0.5) != nil
            let hasCancel = firstButton(labeledAnyOf: Self.cancelLabels, timeout: 0.5) != nil
            // A sheet/dialog with both a destructive verb and an escape hatch.
            if hasDestructive && hasCancel { return true }
        } while Date() < deadline
        return false
    }

    /// Cancel out of whatever confirmation surface is showing. Returns true if
    /// a cancel affordance was found and clicked.
    @discardableResult
    func cancelConfirmation() -> Bool {
        if let cancel = firstButton(labeledAnyOf: Self.cancelLabels, timeout: 3) {
            cancel.click()
            return true
        }
        // Fall back to pressing Escape, which dismisses SwiftUI sheets.
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
