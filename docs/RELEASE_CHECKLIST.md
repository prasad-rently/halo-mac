# Release checklist (F-058 / FR-R4)

Used for **every** release (beta, RC, final). Copy it into the release PR description, tick it as
you go, and attach the result to the release notes ([`RELEASE_NOTES_TEMPLATE.md`](RELEASE_NOTES_TEMPLATE.md)).
Items marked **(owner)** need the owner's accounts, keys or devices — an agent cannot tick them.

Publishing, notarising, signing the APK and merging PRs are owner actions. Nothing here authorises
them; this list only makes sure they are done on a build that has been checked.

## 1. Before cutting the build

- [ ] Release branch (`release/vX.Y`) is up to date; all feature PRs for this release merged **by the owner**.
- [ ] CI is green on the branch tip (`.github/workflows/ci.yml`: rules-sync, macOS build + HaloTests + audits, Android).
- [ ] `./scripts/check-rules-sync.sh` passes (rules JSON and embedded doc copies agree).
- [ ] `./scripts/audit-entitlements.sh --probe` passes **on a developer machine** (CI runs only the static form: a hosted runner has no signing identity for the probe).
- [ ] `./scripts/audit-subprocess-spawning.sh` passes.
- [ ] Version bumped consistently: `scripts/bump-version.sh <version> [--token]` and committed. App, widget and helper all read the same `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
- [ ] Android `versionCode` / `versionName` bumped in `android/app/build.gradle.kts` (code strictly higher than the last release).
- [ ] Sentry DSN in `Info.plist` is still `SENTRY_DSN_PLACEHOLDER` (never commit the real one).
- [ ] No keystore, `.p12`, token or credential in `git status` / the diff.

## 2. Build the artefacts

- [ ] macOS: `scripts/build-dmg.sh --version <version> --build <n>` — self-verification passed (signature from the mounted DMG, version on all three bundles, placeholder DSN, App Group entitlement, no test bundles). Record the DMG sha256.
- [ ] Android: unsigned APK from CI (or local `./gradlew :app:assembleRelease`), then **(owner)** `android/scripts/sign-release.sh` — `apksigner verify` passed; record the APK sha256 and the signer-certificate digest (must equal the previous release's — [`android/RELEASE.md`](../android/RELEASE.md)).
- [ ] **(owner)** Notarise the DMG if shipping outside developer machines; staple; confirm Gatekeeper opens it on a Mac that has never run Halo. State in the notes if this was **not** done.

## 3. Verification run

- [ ] HaloTests pass locally on a clean checkout of the release commit (`xcodebuild -scheme HaloTests test`); record counts.
- [ ] Android: `./gradlew :halocloud:test :haloshare:test` pass; record counts.
- [ ] Install the built DMG on a clean user account / Mac: launches, widget shows live (non-placeholder) values, Settings → About shows the intended version.
- [ ] Sandboxed Release configuration builds and the new feature paths run (V-9) — or is listed as NOT verified.
- [ ] Walk the release's section of [`MANUAL_TEST_PLAN.md`](MANUAL_TEST_PLAN.md). Every case is recorded as passed / failed / **not run**, with what it ran against (device vs emulator vs stand-in).
- [ ] Owner verification debt (`V-*` rows) reviewed: each is either recorded with a result or carried into **NOT verified** with a reason.

## 4. Release notes

- [ ] Written from the template, with **Verified** and **NOT verified** tables filled in honestly: nothing that ran only on an emulator/stand-in is listed without saying so; nothing unrun is missing from NOT verified.
- [ ] Artefact table has sha256 for every file, the signing identity kind, and whether notarised.
- [ ] Roadmap/status words updated only where a verification result is recorded (🔧 → ✅ needs its `V-*` result).
- [ ] Known issues listed.

## 5. Ship (owner)

- [ ] **(owner)** Tag and publish as a **pre-release** first.
- [ ] **(owner)** Merge to `main` only after the manual test pass; delete nothing until then.
- [ ] Post-release: install the published artefact (not the local build), check `shasum -a 256` against the notes.
