# HaloUITests — End-to-End UI Testing

End-to-end UI automation for Halo, using **XCUITest** (Apple's first-party UI
testing framework).

## Why not Maestro?

Maestro only drives **iOS Simulator, Android, React Native, Flutter, and web**
targets. Halo is a **native macOS app** (`SDKROOT = macosx`, no iOS target), so
Maestro has no driver that can launch or tap it. XCUITest is the macOS
equivalent: it launches the real `Halo.app`, drives the Accessibility tree, and
runs in CI via `xcodebuild test`. These flows are written to map 1:1 onto the
cases in [`docs/MANUAL_TEST_PLAN.md`](../docs/MANUAL_TEST_PLAN.md).

## Layout

| File | Covers |
|------|--------|
| `HaloUITestCase.swift` | Base class: launch, tolerant element lookup, assertions |
| `HaloUITestCase+Confirmation.swift` | Shared cancel-at-confirmation helpers (TC-SAFE gate) |
| `HaloTestFixtures.swift` | **Dummy-file safety harness** — sandbox fixtures + canary/Trash assertions |
| `HaloSidebar.swift` | Page object for the sidebar modules + edit mode |
| `SmokeUITests.swift` | §0 Smoke + §1 Navigation (TC-SMOKE, TC-SHELL) |
| `SidebarReorderUITests.swift` | §1.1 Reorderable sidebar (TC-SIDEBAR) |
| `DashboardUITests.swift` | §2 Dashboard (TC-DASH) |
| `CleanupUITests.swift` | §3 Cleanup (TC-CLEAN + TC-SAFE) |
| `ProtectionUITests.swift` | §4 Protection (TC-PROT) |
| `PerformanceUITests.swift` | §5 Performance — processes/battery/network/speed/login/idle (TC-PERF) |
| `ApplicationsUITests.swift` | §6 Deep uninstaller (TC-APP + TC-SAFE) |
| `FilesUITests.swift` | §7 SpaceLens/Duplicates/Downloads/Large Files/Drive Speed (TC-FILE) |
| `ClipboardSnippetsUITests.swift` | §8 Clipboard + Snippets (TC-CLIP, TC-SNIP) |
| `ActionsUITests.swift` | §9 Actions library/search/execution/custom (TC-ACT) |
| `PortsUITests.swift` | §10 Ports Manager — kill safety via own canary (TC-PORT) |
| `CodeBeautifierUITests.swift` | §11 Code Beautifier (TC-BEAUT) |
| `MenuBarUITests.swift` | §13 Menu Bar styles + format strings (TC-MENU) |
| `SmartScanUITests.swift` | §14 Smart Scan + scheduler (TC-SCAN) |
| `AlertsReportUITests.swift` | §15/16 Alerts, PDF export, App Intents (TC-ALERT, TC-RPT, TC-SIRI) |
| `AIAssistantUITests.swift` | F-046 AI Assistant — BYO-key, no-network (TC-AI) |

### The dummy-file safety harness (`HaloTestFixtures`)

Every destructive flow follows the **"test-only, cancel-at-confirmation"** pattern
and NEVER touches a real user or system file:

1. Seed dummy "canary" files in a throwaway sandbox under the OS temp dir.
2. Snapshot any real path that must not change + the current Trash item count.
3. Drive the destructive action **only up to its confirmation review**, then **Cancel**.
4. Assert: every dummy survives, guarded real paths are byte-for-byte unchanged,
   and the Trash gained nothing — proving the confirmation gate (TC-SAFE-02)
   without ever deleting anything.

`PortsUITests` extends this with a **live canary**: it spawns its own
`python3 -m http.server` listener, drives Kill → Cancel, and asserts the process
is still running (then terminates it itself in teardown).

## Running

UI tests inject a runner into the app, so the host **must be code-signed**
(unlike the `CODE_SIGNING_ALLOWED=NO` build in `CLAUDE.md`). Use a signing
identity:

```bash
xcodebuild test \
  -project Halo.xcodeproj \
  -scheme HaloUITests \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="Apple Development: MobileApp Developers (ZWA6Q77327)" \
  CODE_SIGN_STYLE=Manual
```

Compile-only check (no run, no signing needed):

```bash
xcodebuild build-for-testing \
  -project Halo.xcodeproj -scheme HaloUITests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Run a single class or test:

```bash
xcodebuild test -project Halo.xcodeproj -scheme HaloUITests \
  -destination 'platform=macOS' \
  -only-testing:HaloUITests/SmokeUITests/test_navigate_through_all_modules
```

> UI tests require an **interactive GUI session** (a logged-in desktop). They do
> not run on a headless SSH-only session.

## Selector strategy — IMPORTANT

Flows prefer **stable accessibility identifiers** (`element(id:)`, `assertID`,
`tapID`, `waitForID` in `HaloUITestCase`) and fall back to visible-label lookup
(`element(labeled:)`) only where an identifier isn't wired yet.

Identifiers follow `<module>.<element>.<role>`. Those the app currently exposes:

| Identifier | Where |
|------------|-------|
| `sidebar.row.<AppModule.rawValue>` | every sidebar row (drives all navigation) |
| `dashboard.smartScan.button` / `dashboard.exportReport.button` / `dashboard.alertHistory` | Dashboard |
| `dashboard.appUsageInsights` · `.disabledState` · `.collectingState` · `.chart` · `.backgroundHogs.list` | Dashboard → App Usage Insights (F-021) |
| `settings.appUsageTracking.toggle` · `.clearHistory.button` | Settings → General → Privacy (F-021) |
| `cleanup.cleanAll.button` · `fileListView` | Cleanup |
| `protection.scan.button` | Protection |
| `performance.idleApp.quit.button` | Performance → Idle Apps |
| `applications.row.<bundleId>` · `applications.uninstall.button` · `applications.leftover.<kind>` | Applications |
| `files.tab.<TabTitle>` | Files tab bar |
| `files.duplicates.deleteMarked.button` | Files → Duplicates |
| `files.downloads.row` · `files.downloads.trash.button` · `files.downloads.cleanStale.button` | Files → Downloads |
| `files.largeFiles.row` · `files.largeFiles.trash.button` | Files → Large Files |
| `ports.row.<port>` · `ports.kill.<port>` · `ports.refresh.button` · `ports.search` | Ports |
| `actions.newCustom.button` | Actions |
| `ai.providerPicker` · `ai.modelPicker` · `ai.composer` · `ai.send.button` · `ai.keySetup.title` | AI Assistant |

> **Delete-confirmation gaps fixed.** Wiring these tests surfaced three Files
> delete paths that bypassed the mandatory confirmation rule (TC-SAFE-02):
> Large Files per-row delete and Downloads per-row trash both trashed
> immediately, and Duplicates "Delete marked" was a no-op stub. All three now
> show a confirmation review before trashing (and Duplicates' mark → delete is
> wired), so their tests drive the real confirm → cancel → assert-nothing-deleted
> flow. Remaining skips are purely state-dependent (a duplicate group / a
> download / a >500 MB file / an idle app must exist to act on).

`HaloSidebar.navigate(to:)` clicks `sidebar.row.<module>` (mapping HaloShare →
`localShare`, Menu Bar → `menuBarPreview`) and only falls back to the title.

Remaining `XCTSkip`s are for **state-dependent** rows (a duplicate/large-file to
delete, an idle app to quit, a live threat) and per-row controls that still need
identifiers — each skip names the id to add next.

## Extending the suite

1. Add the view identifiers you need to the app.
2. Add a page object (mirror `HaloSidebar.swift`) for the module.
3. Add a `<Module>UITests.swift` whose test names cite their `TC-` IDs.
4. Keep destructive flows skipped unless they act on a seeded fixture directory
   (never trash real user files — see `TC-SAFE-*`).
