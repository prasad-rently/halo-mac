# Manual Test Plan — PR #7: F-044 Phase 0 — Cloud foundation + Firebase RTDB spike

> **Branch:** `feature/f-044-cloud-foundation` · **Base:** `feature/upcoming-features` (PR #6) — **not `main`**
> **Status:** 🔶 Open, not yet merged. **Stacked on PR #6** — this branch only makes sense once PR #6's
> content is present, since it's declared against that branch, not `main`.
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/7
> **Diff size:** 36 files changed, +4613/-109

## What this actually is

This is explicitly a **Phase 0 spike**, not a finished feature: it builds the shared
`Halo/Core/Cloud` layer (crypto, config storage, the Firebase RTDB client) that F-044 (SMS
console), F-045 (clipboard sync), and F-048 (expenditure tracker) will all sit on, and it exists
to answer one question — *does firebase-ios-sdk actually build and link on macOS at runtime with
no bundled plist?* Per the PR description, that spike **passed**. Real end-to-end testing (a live
Firebase project, real device pairing, mobile-side sync) is explicitly **out of scope** for this
PR and needs an actual Firebase account, which most reviewers won't have handy.

So this test plan has two tiers: things you can verify with **zero external accounts** (the
important ones — form validation, navigation, encryption round-trips, build/link health), and an
**optional** tier if you happen to have a spare Firebase project to point it at.

## How to test this PR

```bash
git fetch origin feature/upcoming-features feature/f-044-cloud-foundation
git checkout feature/f-044-cloud-foundation
```

Note this branch's diff (`gh pr diff 7`) is computed against `feature/upcoming-features`, so a
plain `git diff main...feature/f-044-cloud-foundation` will show **both** PR #6's and PR #7's
changes combined — that's expected given the stacking, not a bug in this plan.

Build & sign per `CLAUDE.md` → "Build & Sign", or for a quick unsigned local run:
```bash
xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
```

## Source files this PR adds/changes

- `Halo/Core/Cloud/CryptoService.swift`, `CloudConfigStore.swift`, `CloudModels.swift`, `FirebaseRTDBClient.swift`
- `Halo/Core/Cloud/Provisioning/GoogleOAuthPKCE.swift`
- `Halo/Features/ClipboardSync/ClipboardSyncModels.swift`, `ClipboardSyncService.swift`, `ClipboardSyncSettingsView.swift`
- `Halo/Features/Expenditure/*.swift` (Models, Store, View, ViewModel, TransactionParser, TransactionPipeline)
- `Halo/Features/SMSConsole/*.swift` (CloudSettingsPane, CloudSetupView, SMSConsoleView, SMSConsoleViewModel, SMSModels, SMSSyncClient)
- `Halo/App/AppState.swift`, `Halo/App/ContentView.swift` (two new sidebar entries: `.messages`, `.expenditure`)
- `Halo/Halo.entitlements` (network client for the RTDB connection)

## Tier 1 — verify without any external account (do this)

**Files:** `AppState.swift`, `ContentView.swift`, `CloudSetupView.swift`, `CryptoService.swift`.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLOUD-01 | P0 | App still builds & launches | Build per above, launch | No crash, no hang; existing modules unaffected |
| TC-CLOUD-02 | P0 | New sidebar entries reachable | Open sidebar (edit mode if needed, since these are new reorderable modules) | "Messages" (SMS Console) and "Expenditure" entries present and navigable without crashing |
| TC-CLOUD-03 | P1 | SMS Console empty state | Open Messages module (no cloud configured) | Empty/disconnected state shown — no crash attempting to reach a cloud that isn't set up |
| TC-CLOUD-04 | P1 | Cloud Setup form renders | From SMS Console (or wherever `CloudSetupView` is entry-pointed), open Cloud Setup | Three sections render: "1 · Firebase project" (5 fields), "2 · Sign in" (email/password), "3 · Encryption passphrase" |
| TC-CLOUD-05 | P1 | "Test connection" gated on required fields | Leave fields empty, then fill only the 5 Firebase config fields (skip email/password) | Test/Connect button stays disabled until API key, Project ID, App ID, sender ID, database URL, email, AND password are all non-empty (`canTest`); passphrase is NOT required for `canTest`, only for the final `canConnect` |
| TC-CLOUD-06 | P1 | "Connect" additionally requires the passphrase | Fill all connection fields, leave passphrase empty | Connect stays disabled until passphrase is also filled (`canConnect`) |
| TC-CLOUD-07 | P2 | Garbage config fails gracefully | Fill all fields with obviously invalid values (e.g. `apiKey = "x"`, `databaseURL = "not a url"`), tap Test connection | A clear failure/error banner — no crash, no hang, no silent success |
| TC-CLOUD-08 | P1 | Clipboard Sync settings pane renders | Open Clipboard → sync settings entry point | Renders without a configured cloud; doesn't assume a connection already exists |
| TC-CLOUD-09 | P2 | Expenditure module empty state | Open Expenditure module with no data | Honest "no transactions yet / not connected" state — no fabricated numbers |
| **Unit** | P0 | `CloudFoundationTests.swift` suite | `xcodebuild test -scheme HaloTests -only-testing:HaloTests/CloudFoundationTests` (or full suite) | All pass — covers `CryptoService` round-trip, deterministic cross-device key derivation, wrong-passphrase/wrong-salt failure, malformed input, and `CloudPairingPayload` tamper detection |

## Tier 2 — optional, only if you have a spare Firebase project

Not required to approve this PR (per its own description, this is explicitly still pending and
needs accounts, not code), but if you want to go further:

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLOUD-10 | P2 | Live RTDB connect | Fill Cloud Setup with a real Firebase RTDB project's config + a real Email/Password user | "Test connection" succeeds; "Connect" persists config to Keychain via `CloudConfigStore` |
| TC-CLOUD-11 | P2 | Reconnect after relaunch | Quit and relaunch Halo after connecting | Cloud connection restored from Keychain without re-entering config |
| TC-CLOUD-12 | P2 | Wipe / re-key | Use the disconnect/wipe action in Cloud Settings | Keychain entries cleared; app returns to disconnected empty state |

## Regression spot-check

- `AppState.swift` and `ContentView.swift` are touched — smoke-test the **whole sidebar**
  (every existing module, not just the two new ones) since this is exactly the kind of change
  that can silently break an unrelated `switch` case.
- `Halo.entitlements` gained a network-related change — re-verify the app still launches and
  functions correctly as a **sandboxed Release build**, not just Debug (sandbox is OFF in Debug,
  so an entitlement mistake here would only surface in a Release-config build).

## Before merging — flag to the team

This PR's base is PR #6's branch (`feature/upcoming-features`), not `main`. Merge PR #6 first
(or retarget/rebase this PR onto `main` after #6 lands) — merging #7 as-is today would pull in
all of #6's docs-only changes bundled with it, which is probably not what anyone reviewing "just
the cloud foundation" expects to approve.
