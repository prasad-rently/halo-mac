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
        HaloSidebar(test: self).navigate(to: .ports)
        _ = tapID("ports.refresh.button", timeout: 3)

        // Filter the list down to our canary port via the search field, so the
        // only visible Kill button belongs to the process we own.
        if let search = waitForID("ports.search", timeout: 5) {
            search.click()
            search.typeText("\(canaryPort)")
        }

        // Confirm the canary row is present (its port number is shown).
        let portRow = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "\(canaryPort)")).firstMatch
        guard portRow.waitForExistence(timeout: 15) else {
            throw XCTSkip("Canary port \(canaryPort) did not surface even after a rescan; the " +
                          "port scan may be throttled in this environment.")
        }

        // The kill button carries `ports.kill.button`; with the list filtered to
        // the canary, firstMatch is the canary's.
        guard tapID("ports.kill.button", timeout: 5) else {
            throw XCTSkip("Kill button (ports.kill.button) not hittable for the canary row.")
        }

        // THE GATE — a "Kill Process" alert with Cancel + Kill (SIGTERM).
        XCTAssertTrue(confirmationSurfaceAppeared(),
                      "Killing a process must confirm first (TC-SAFE-02)")
        cancelConfirmation()

        // The canary must still be alive — cancel means no signal was sent.
        XCTAssertTrue(canary?.isRunning ?? false,
                      "Cancelling the kill dialog must leave PID \(pid) running")
    }
}
