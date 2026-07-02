# Halo — Testing Guide

Halo has three test targets plus a manual test plan.

| Target | Type | Scheme | Source |
|--------|------|--------|--------|
| `HaloTests` | Unit (Swift Testing, `@testable import Halo`) | `HaloTests` | `HaloTests/` |
| `HaloUITests` | UI / E2E (XCUITest) | `HaloUITests` | `HaloUITests/` |
| Manual | — | — | [`docs/MANUAL_TEST_PLAN.md`](MANUAL_TEST_PLAN.md) |

Both code targets were added with the `xcodeproj` Ruby gem via the idempotent
scripts in [`scripts/`](../scripts) — re-run them if the project file is
regenerated:

```bash
LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_unittest_target.rb
LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_uitest_target.rb
```

## Unit tests (`HaloTests`)

The host app embeds the widget + helper, which demand provisioning profiles
when signing is enabled. As with the `CLAUDE.md` build, **disable signing** —
Apple Silicon auto-applies ad-hoc signatures so the host still launches:

```bash
xcodebuild test \
  -project Halo.xcodeproj -scheme HaloTests \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/HaloUnitTestBuild \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
```

Last run: **21 tests, 4 suites, all passing**.

> ⚠️ The `FileSystemScanner` "Cancellation stops scan" test runs ~6 min (it
> scans real directories). Consider pointing it at a temp fixture dir to speed
> up CI.

## UI / E2E tests (`HaloUITests`)

See [`HaloUITests/README.md`](../HaloUITests/README.md) for the full selector
strategy. UI tests inject a runner into the app, need an **interactive GUI
session**, and the host must be signed. Compile-only check (no signing, no GUI):

```bash
xcodebuild build-for-testing \
  -project Halo.xcodeproj -scheme HaloUITests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Full run (interactive desktop + signing identity):

```bash
xcodebuild test -project Halo.xcodeproj -scheme HaloUITests \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="Apple Development: MobileApp Developers (ZWA6Q77327)"
```

## Why XCUITest and not Maestro

Maestro only drives iOS Simulator / Android / RN / Flutter / web. Halo is a
native macOS app (`SDKROOT = macosx`, no iOS target), so XCUITest is the correct
E2E tool. See `HaloUITests/README.md`.
