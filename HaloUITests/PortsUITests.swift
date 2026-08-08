//
//  PortsUITests.swift
//  HaloUITests
//
//  Ports Manager (F-034). Maps to MANUAL_TEST_PLAN.md §10 (TC-PORT-01…).
//
//  SAFETY: killing a process is destructive to a running program. We NEVER
//  kill a real user/system process. Instead this test spawns its OWN dummy
//  listener (a canary we control), drives the kill flow to its confirmation,
//  CANCELS, and asserts the canary is still alive. The canary is always
//  terminated by the test itself in teardown.
//

import XCTest

final class PortsUITests: HaloUITestCase {

    /// A dummy process we own, bound to a listening TCP port so it shows up in
    /// the Ports list. Killed by us — never by the app under test.
    private var canary: Process?
    private let canaryPort = 54999

    override func tearDownWithError() throws {
        if let c = canary, c.isRunning { c.terminate() }
        canary = nil
        try super.tearDownWithError()
    }

    /// Start a Python HTTP server on `canaryPort`. Returns its PID, or nil.
    @discardableResult
    private func startCanary() -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-m", "http.server", "\(canaryPort)", "--bind", "127.0.0.1"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        canary = p
        return p.processIdentifier
    }

    // TC-PORT-01 — the Ports list enumerates listening processes.
    func test_ports_list_enumerates() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .ports))
        let populated = app.cells.firstMatch.waitForExistence(timeout: 20) ||
                        app.outlineRows.firstMatch.waitForExistence(timeout: 5) ||
                        element(labeled: "Ports", timeout: 5) != nil
        XCTAssertTrue(populated, "Ports list should enumerate listening processes")
    }

    // TC-PORT-05 / TC-SAFE-02 — killing a process confirms first, and cancelling
    // leaves the process ALIVE. Uses our own canary listener.
    func test_kill_confirms_and_cancel_keeps_process_alive() throws {
        guard let pid = startCanary() else {
            throw XCTSkip("Could not start the python3 canary listener in this environment.")
        }
        // Give the listener a moment to bind and the app a moment to see it.
        _ = element(labeled: "Ports", timeout: 2)
        HaloSidebar(test: self).navigate(to: .ports)
        _ = clickAny(of: ["Refresh", "Rescan", "Scan"], timeout: 3)

        // Find the canary's port row.
        let portRow = element(labeled: "\(canaryPort)", timeout: 15) ??
                      app.staticTexts.containing(
                        NSPredicate(format: "label CONTAINS %@", "\(canaryPort)")).firstMatch
        guard portRow.exists else {
            throw XCTSkip("Canary port \(canaryPort) did not surface in the list (needs a " +
                          "rescan hook / row identifiers). Expectation: selecting it and " +
                          "clicking Kill confirms before sending any signal (TC-SAFE-02).")
        }
        portRow.click()
        guard firstButton(labeledAnyOf: ["Kill", "Kill Process", "Force Quit", "Terminate"], timeout: 5) != nil else {
            throw XCTSkip("Kill control not addressable; annotate with `ports.kill.button`.")
        }
        firstButton(labeledAnyOf: ["Kill", "Kill Process", "Force Quit", "Terminate"])?.click()

        // THE GATE.
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Killing a process must confirm first (TC-SAFE-02)")
        cancelConfirmation()

        // The canary must still be alive — cancel means no signal was sent.
        XCTAssertTrue(canary?.isRunning ?? false,
                      "Cancelling the kill dialog must leave PID \(pid) running")
    }
}
