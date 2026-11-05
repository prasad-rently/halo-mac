import XCTest

/// Drives the cloud screens in the Simulator against the loopback stand-in (scripts/demo-standin.sh). Not a
/// regression suite — a recorded walkthrough: it saves a screenshot per step to $HALO_SHOT_DIR (default /tmp/halo-shots)
/// and asserts what is on screen. Needs HALO_CODE (the pairing code) and HALO_PASS in the test runner's environment
/// (xcodebuild: TEST_RUNNER_HALO_CODE=… TEST_RUNNER_HALO_PASS=…). Skipped otherwise.
final class CloudWalkthroughUITests: XCTestCase {
    let app = XCUIApplication()
    var shots = 0

    func shot(_ name: String) {
        shots += 1
        let dir = ProcessInfo.processInfo.environment["HALO_SHOT_DIR"] ?? "/tmp/halo-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(String(format: "%02d", shots))-\(name).png"))
    }

    func testPairMessagesClipboardAndUnpair() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["HALO_CODE"], let pass = env["HALO_PASS"] else { throw XCTSkip("HALO_CODE/HALO_PASS not set") }
        continueAfterFailure = false
        app.launchArguments += ["-HaloDebugPairingCode", code]
        app.launch()

        // Messages before pairing: one line + one action
        app.tabBars.buttons["Messages"].tap()
        XCTAssertTrue(app.staticTexts["Set up Cloud first"].waitForExistence(timeout: 5))
        shot("messages-unpaired")

        // Settings -> Cloud -> pair
        app.buttons["Open Cloud setup"].tap()
        XCTAssertTrue(app.buttons["cloud.continue"].waitForExistence(timeout: 5))
        shot("pair-step1")
        app.buttons["cloud.continue"].tap()
        let pp = app.secureTextFields["cloud.passphrase"]
        XCTAssertTrue(pp.waitForExistence(timeout: 5))
        shot("pair-step2")
        // wrong passphrase first: must be refused
        pp.tap(); pp.typeText("not the right passphrase")
        app.buttons["cloud.pair"].tap()
        XCTAssertTrue(app.staticTexts["cloud.error"].waitForExistence(timeout: 20) || app.otherElements["cloud.error"].waitForExistence(timeout: 1))
        shot("pair-wrong-passphrase")
        // start the step over (the code is kept) and type the right one
        app.buttons["Cancel"].tap()
        app.buttons["cloud.continue"].tap()
        let pp2 = app.secureTextFields["cloud.passphrase"]
        XCTAssertTrue(pp2.waitForExistence(timeout: 5))
        pp2.tap(); pp2.typeText(pass)
        app.buttons["cloud.pair"].tap()
        _ = app.buttons["cloud.unpair"].waitForExistence(timeout: 25)
        shot("after-pair-tap")
        XCTAssertTrue(app.buttons["cloud.unpair"].waitForExistence(timeout: 30), "paired state did not appear")
        shot("paired")

        // Check my database
        app.buttons["cloud.runCheck"].tap()
        XCTAssertTrue(app.staticTexts["Run again"].waitForExistence(timeout: 30) || app.buttons["Run again"].waitForExistence(timeout: 5))
        app.swipeUp()
        shot("database-check")

        // Messages
        app.tabBars.buttons["Messages"].tap()
        XCTAssertTrue(app.staticTexts["VM-HDFCBK"].waitForExistence(timeout: 15), "synced thread did not appear")
        shot("messages-list")
        app.buttons["messages.thread.AX-AXISBK"].tap()
        XCTAssertTrue(app.buttons["messages.copyCode"].waitForExistence(timeout: 5))
        shot("conversation-otp")
        app.buttons["messages.copyCode"].tap()
        shot("otp-copied")

        // Clipboard: receive + send round trip
        app.tabBars.buttons["Clipboard"].tap()
        XCTAssertTrue(app.staticTexts["hello from Kotlin ✨ https://example.com/x?y=1"].waitForExistence(timeout: 15))
        shot("clipboard-received")
        UIPasteboard.general.string = "from the iPhone simulator ✨"
        app.buttons["clipboard.send"].tap()
        if app.alerts.buttons["Allow Paste"].waitForExistence(timeout: 2) { app.alerts.buttons["Allow Paste"].tap() }
        XCTAssertTrue(app.buttons["clipboard.confirmSend"].waitForExistence(timeout: 5))
        shot("clipboard-send-sheet")
        app.buttons["clipboard.confirmSend"].tap()
        XCTAssertTrue(app.staticTexts["from the iPhone simulator ✨"].waitForExistence(timeout: 10))
        shot("clipboard-sent")

        // Unpair with confirmation
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.cloud"].tap()
        app.buttons["cloud.unpair"].tap()
        shot("unpair-confirm")
        app.buttons["Unpair and erase keys"].tap()
        XCTAssertTrue(app.buttons["cloud.continue"].waitForExistence(timeout: 5))
        shot("unpaired")
    }
}
