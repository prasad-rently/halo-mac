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
| `HaloSidebar.swift` | Page object for the 11 sidebar modules + edit mode |
| `SmokeUITests.swift` | §0 Smoke + §1 Navigation (TC-SMOKE, TC-SHELL) |
| `SidebarReorderUITests.swift` | §1.1 Reorderable sidebar (TC-SIDEBAR) |
| `CleanupUITests.swift` | §3 Cleanup (TC-CLEAN) |

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

SwiftUI exposes controls to the Accessibility tree by their **label text**. The
app currently has only one stable identifier (`fileListView` in
`CleanupView.swift`), so most flows query by visible label via
`element(labeled:)`, which tolerantly searches buttons, static texts, cells, and
outline rows.

For a durable suite, add `.accessibilityIdentifier(...)` to key views and switch
flows to query by identifier. Recommended convention:

```
<module>.<element>.<role>
e.g.  cleanup.scanButton.button
      sidebar.row.performance
      ports.killButton.button
```

Each new identifier should be referenced from the matching `TC-` case so manual
and automated coverage stay aligned.

## Extending the suite

1. Add the view identifiers you need to the app.
2. Add a page object (mirror `HaloSidebar.swift`) for the module.
3. Add a `<Module>UITests.swift` whose test names cite their `TC-` IDs.
4. Keep destructive flows skipped unless they act on a seeded fixture directory
   (never trash real user files — see `TC-SAFE-*`).
