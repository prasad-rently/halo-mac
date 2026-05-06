import XCTest

// MARK: - Base

class HaloUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        // Wait for app to finish launching
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: Helpers

    func tapSidebarItem(_ label: String, timeout: TimeInterval = 5) {
        let cell = app.outlineRows.containing(.staticText, identifier: label).firstMatch
        if cell.waitForExistence(timeout: timeout) {
            cell.click()
        } else {
            // Fallback: tap any matching static text in the sidebar
            app.staticTexts[label].firstMatch.click()
        }
    }

    func waitForText(_ text: String, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts[text].waitForExistence(timeout: timeout)
    }
}

// MARK: - TC-001 Onboarding

final class TC001OnboardingTests: HaloUITestCase {

    func test_onboarding_dashboardVisible() {
        // After launch the app should show either Onboarding or Dashboard
        let dashboard = app.staticTexts["Dashboard"]
        let welcome   = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Welcome'")).firstMatch
        let eitherVisible = dashboard.waitForExistence(timeout: 8) || welcome.waitForExistence(timeout: 2)
        XCTAssertTrue(eitherVisible, "Expected Dashboard or Welcome screen on launch")
    }
}

// MARK: - TC-002 Dashboard

final class TC002DashboardTests: HaloUITestCase {

    func test_dashboard_healthRingVisible() {
        tapSidebarItem("Dashboard")
        // Health ring uses accessibility identifier
        XCTAssertTrue(
            app.otherElements["healthScoreRing"].waitForExistence(timeout: 8),
            "Health score ring should be visible on Dashboard"
        )
    }

    func test_dashboard_sixMetricCards() {
        tapSidebarItem("Dashboard")
        let metricIDs = ["cpuMetricCard", "ramMetricCard", "diskMetricCard",
                         "batteryMetricCard", "networkUpCard", "networkDownCard"]
        for id in metricIDs {
            XCTAssertTrue(
                app.otherElements[id].waitForExistence(timeout: 8),
                "Metric card '\(id)' should be visible"
            )
        }
    }

    func test_dashboard_smartScanButtonExists() {
        tapSidebarItem("Dashboard")
        XCTAssertTrue(
            waitForText("Smart Scan"),
            "Smart Scan button should be visible on Dashboard"
        )
    }

    func test_dashboard_quickActionsExist() {
        tapSidebarItem("Dashboard")
        XCTAssertTrue(
            waitForText("Quick Actions"),
            "Quick Actions section should be visible"
        )
    }
}

// MARK: - TC-003 Cleanup

final class TC003CleanupTests: HaloUITestCase {

    private let categories = [
        "System Caches", "User Caches", "Log Files", "Temp Files",
        "Downloads", "Xcode DerivedData", "iOS Backups",
        "Language Packs", "Trash", "Mail Attachments"
    ]

    func test_cleanup_allCategoryRowsVisible() {
        tapSidebarItem("Cleanup")
        for cat in categories {
            XCTAssertTrue(
                waitForText(cat),
                "Cleanup category '\(cat)' should be visible"
            )
        }
    }

    func test_cleanup_scanningIndicatorClears() {
        tapSidebarItem("Cleanup")
        // "Scanning…" should not persist after 20 seconds
        let scanningLabel = app.staticTexts["Scanning…"]
        let cleared = !scanningLabel.waitForExistence(timeout: 2) ||
                       !scanningLabel.isHittable
        // Wait up to 20 s
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && scanningLabel.exists { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        XCTAssertFalse(scanningLabel.exists, "Scanning… indicator should disappear after scan completes")
    }

    func test_cleanup_cleanSelectedConfirmation() {
        tapSidebarItem("Cleanup")
        // Tap System Caches, select all, verify confirmation sheet with Cancel
        app.staticTexts["System Caches"].firstMatch.click()
        _ = app.otherElements["fileListView"].waitForExistence(timeout: 10)
        let selectAll = app.buttons["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 5) { selectAll.click() }
        let cleanBtn = app.buttons["Clean Selected"].firstMatch
        if cleanBtn.waitForExistence(timeout: 5) { cleanBtn.click() }
        XCTAssertTrue(waitForText("Move to Trash"), "Confirmation sheet must appear before deletion")
        // Cancel — never actually delete in tests
        app.buttons["Cancel"].firstMatch.click()
    }
}

// MARK: - TC-004 Protection

final class TC004ProtectionTests: HaloUITestCase {

    func test_protection_sectionHeadersVisible() {
        tapSidebarItem("Protection")
        XCTAssertTrue(waitForText("Threats"),     "Threats section should be visible")
        XCTAssertTrue(waitForText("Permissions"), "Permissions section should be visible")
    }

    func test_protection_scanButtonAndResult() {
        tapSidebarItem("Protection")
        let scanBtn = app.buttons["Scan Now"].firstMatch
        XCTAssertTrue(scanBtn.waitForExistence(timeout: 5), "Scan Now button must exist")
        scanBtn.click()
        // After scan: either no threats or specific threat categories
        let noThreats    = app.staticTexts["No threats found"]
        let adware       = app.staticTexts["Adware"]
        let pup          = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Potentially Unwanted'")).firstMatch
        let found = noThreats.waitForExistence(timeout: 15) ||
                    adware.waitForExistence(timeout: 2) ||
                    pup.waitForExistence(timeout: 2)
        XCTAssertTrue(found, "Scan result must show either 'No threats found' or threat categories")
    }

    func test_protection_permissionKindsVisible() {
        tapSidebarItem("Protection")
        let permissions = ["Camera", "Microphone", "Location",
                           "Full Disk Access", "Screen Recording", "Accessibility"]
        for p in permissions {
            XCTAssertTrue(waitForText(p), "Permission kind '\(p)' should be visible")
        }
    }
}

// MARK: - TC-005 Performance

final class TC005PerformanceTests: HaloUITestCase {

    func test_performance_loginItemsSectionVisible() {
        tapSidebarItem("Performance")
        XCTAssertTrue(waitForText("Login Items"),    "Login Items section should be visible")
        XCTAssertTrue(waitForText("Startup Impact"), "Startup Impact label should be visible")
    }

    func test_performance_maintenanceTasksVisible() {
        tapSidebarItem("Performance")
        XCTAssertTrue(waitForText("Maintenance"),        "Maintenance section should be visible")
        XCTAssertTrue(waitForText("Flush DNS Cache"),    "Flush DNS Cache task should be visible")
        XCTAssertTrue(waitForText("Purge RAM"),          "Purge RAM task should be visible")
        XCTAssertTrue(waitForText("Repair Permissions"), "Repair Permissions task should be visible")
    }

    func test_performance_flushDnsShowsCompletion() {
        tapSidebarItem("Performance")
        let flushBtn = app.buttons["Flush DNS Cache"].firstMatch
        if !flushBtn.waitForExistence(timeout: 5) { return }
        flushBtn.click()
        let justNow      = app.staticTexts["Just now"]
        let secondsAgo   = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'seconds ago'")).firstMatch
        let completed = justNow.waitForExistence(timeout: 10) || secondsAgo.waitForExistence(timeout: 2)
        XCTAssertTrue(completed, "After flush, task should show 'Just now' or 'seconds ago'")
    }
}

// MARK: - TC-006 Files

final class TC006FilesTests: HaloUITestCase {

    func test_files_tabsVisible() {
        tapSidebarItem("Files")
        XCTAssertTrue(waitForText("SpaceLens"),   "SpaceLens tab should be visible")
        XCTAssertTrue(waitForText("Duplicates"),  "Duplicates tab should be visible")
        XCTAssertTrue(waitForText("Large Files"), "Large Files tab should be visible")
    }

    func test_files_spacelensTreemapVisible() {
        tapSidebarItem("Files")
        app.buttons["SpaceLens"].firstMatch.click()
        XCTAssertTrue(
            app.otherElements["spaceLensTreemap"].waitForExistence(timeout: 12),
            "SpaceLens treemap should render within 12 seconds"
        )
    }

    func test_files_duplicatesScanButton() {
        tapSidebarItem("Files")
        app.buttons["Duplicates"].firstMatch.click()
        XCTAssertTrue(waitForText("Scan for Duplicates"), "Scan for Duplicates button should be visible")
    }

    func test_files_largeFilesTabSizeColumn() {
        tapSidebarItem("Files")
        app.buttons["Large Files"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["Size"].waitForExistence(timeout: 12),
            "Size column header should be visible in Large Files tab"
        )
    }
}

// MARK: - TC-007 Clipboard

final class TC007ClipboardTests: HaloUITestCase {

    func test_clipboard_filterTabsVisible() {
        tapSidebarItem("Clipboard")
        for tab in ["All", "Text", "URL", "Code", "Image"] {
            XCTAssertTrue(waitForText(tab), "Filter tab '\(tab)' should be visible")
        }
    }

    func test_clipboard_sampleItemsVisible() {
        tapSidebarItem("Clipboard")
        XCTAssertTrue(waitForText("developer.apple.com"), "Sample URL item should be visible")
        XCTAssertTrue(waitForText("FileSystemScanner"),   "Sample code item should be visible")
    }

    func test_clipboard_urlFilterHidesCodes() {
        tapSidebarItem("Clipboard")
        app.buttons["URL"].firstMatch.click()
        XCTAssertTrue(waitForText("developer.apple.com"),    "URL item should remain after URL filter")
        XCTAssertFalse(app.staticTexts["FileSystemScanner"].exists,
                       "Code item should be hidden after URL filter")
    }

    func test_clipboard_codeFilterShowsCodeItems() {
        tapSidebarItem("Clipboard")
        app.buttons["Code"].firstMatch.click()
        XCTAssertTrue(waitForText("FileSystemScanner"), "Code item should appear after Code filter")
    }

    func test_clipboard_searchFiltersItems() {
        tapSidebarItem("Clipboard")
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("scanner")
            XCTAssertTrue(waitForText("FileSystemScanner"),     "Search for 'scanner' should show FileSystemScanner")
            XCTAssertFalse(app.staticTexts["developer.apple.com"].exists,
                           "URL item should be hidden during search")
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        }
    }
}

// MARK: - TC-008 Applications

final class TC008ApplicationsTests: HaloUITestCase {

    func test_applications_appListVisible() {
        tapSidebarItem("Applications")
        XCTAssertTrue(waitForText("Halo"), "Halo should appear in the applications list")
    }

    func test_applications_sortControlsExist() {
        tapSidebarItem("Applications")
        XCTAssertTrue(waitForText("Name"),      "Name sort button should exist")
        XCTAssertTrue(waitForText("Size"),      "Size sort button should exist")
        XCTAssertTrue(waitForText("Last Used"), "Last Used sort button should exist")
    }
}

// MARK: - TC-010 Settings

final class TC010SettingsTests: HaloUITestCase {

    func test_settings_opensViaKeyboard() {
        app.typeKey(",", modifierFlags: .command)
        // Settings window should appear
        let settingsExists = app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'"))
                               .firstMatch.waitForExistence(timeout: 5)
                          || app.staticTexts["Settings"].waitForExistence(timeout: 5)
        XCTAssertTrue(settingsExists, "Settings should open with ⌘,")
    }

    func test_settings_versionLabel() {
        app.typeKey(",", modifierFlags: .command)
        // Navigate to About
        let aboutBtn = app.buttons["About"].firstMatch
        if aboutBtn.waitForExistence(timeout: 5) { aboutBtn.click() }
        // Version 1.1 must be shown
        let versionVisible = app.staticTexts.matching(NSPredicate(format: "value CONTAINS '1.1'"))
                               .firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(versionVisible, "Settings About should show version 1.1")
    }
}

// MARK: - TC-011 Widget Data Pipeline

final class TC011WidgetPipelineTests: HaloUITestCase {

    func test_widget_appGroupContainerWritten() throws {
        tapSidebarItem("Dashboard")
        // Give AppState's 2-second metricsTimer a chance to fire
        Thread.sleep(forTimeInterval: 3)
        let groupDefaults = UserDefaults(suiteName: "group.com.halo.mac")
        let json = groupDefaults?.string(forKey: "haloWidgetData")
        XCTAssertNotNil(json, "App Group container must contain 'haloWidgetData' within 3 seconds of launch")
    }

    func test_widget_jsonContainsExpectedKeys() throws {
        tapSidebarItem("Dashboard")
        Thread.sleep(forTimeInterval: 3)
        guard let groupDefaults = UserDefaults(suiteName: "group.com.halo.mac"),
              let json = groupDefaults.string(forKey: "haloWidgetData"),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not decode haloWidgetData JSON")
            return
        }
        let requiredKeys = ["cpuUsage", "ramUsage", "ramUsedGB", "ramTotalGB",
                            "networkUpMBps", "networkDownMBps", "clipboardPreviews"]
        for key in requiredKeys {
            XCTAssertNotNil(dict[key], "Widget JSON must contain key '\(key)'")
        }
    }
}
