# F-058 — Release Engineering

> **Status:** 🔧 **Built on PR #56 (unmerged; head `65bc32b`). Independently reviewed (7 fixes).** **The CI workflow has never run on GitHub**; the full `build-dmg.sh` path was not re-run after the review's edits. Not ✅.
> **Extends:** repo-level (scripts, CI, release docs) · **Raised:** 2026-10-28 (v2.6 BRD §10) · **Effort estimate:** ≈ 4 d · **Also delivers hardening item H-18** (rules-sync)
> **Reserved pbxproj IDs:** none — scripts, workflow and docs only; no app source touched.
> **Plan:** [`../V2_6_PLAN.md`](../V2_6_PLAN.md)

---

## 1. Summary

Releases were assembled by hand from a `CLAUDE.md` recipe, and a test build was once mislabelled as the wrong version. F-058 makes the recipe repeatable and checkable: a CI workflow, a DMG script that verifies itself, a version-bump script that cannot half-apply, Android release signing with an owner-held keystore, and a release-notes template that forces a Verified / NOT-verified table.

## 2. Goals / Non-Goals

**Goals:** CI on PRs/pushes to `release/**`; scripted DMG build/sign/verify; scripted APK signing (owner keystore); version bump wrapper; release checklist + notes template; rules-file drift check (H-18).
**Non-Goals:** notarisation (needs a paid Developer ID — `V2.7-05`); store publishing; producing a release; a `main` trigger for CI.
**"Mobile: n/a"** — repo-level work; no mobile feasibility row is required (the Android signing script is Android release plumbing, not a feature).

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D-07 (accepted 2026-10-28) | The owner holds the Android release keystore; CI builds an **unsigned** APK and the owner signs. | Keystore custody is a trust decision. |
| D-08 (accepted 2026-10-28) | One beta containing all six v2.5 PRs. | v2.5 landed on `release/v2.5`; the RC was built from it. |
| D1 | `build-dmg.sh` signs with the first "Apple Development" identity it **discovers** (override `--identity` / `$HALO_SIGN_IDENTITY`); never hard-coded. | The cert differs per machine (`CLAUDE.md` Identity table). |
| D2 | CI runs the **static** entitlements audit only; `audit-entitlements.sh --probe` needs a signing identity a hosted runner lacks and stays a dev-machine / checklist step. | The probe exits 2 on a runner. |
| D3 | `build-dmg.sh` and `sign-release.sh` refuse work/keystore paths inside the repo and resolve paths to physical absolute form. | Review finding: relative or symlinked paths bypassed the guard. |

## 4. User Stories

- **US-1** I run one script and get a signed, verified DMG with the right version on app, widget and helper.
- **US-2** A broken test on a PR goes red before I merge.
- **US-3** I sign the Android release with my own keystore without the passwords leaking into a child process.

## 5. Functional Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| FR-R1 | `.github/workflows/ci.yml` on PRs/pushes to `release/**`: macOS (`-target Halo` into a clean SYMROOT, `COMPILER_INDEX_STORE_ENABLE=NO`, signing off, leftover-test-bundle check, HaloTests, HaloShareKit tests, both audit scripts), Android (`:halocloud:test :haloshare:test :app:assembleRelease`, uploads the unsigned APK), rules-sync (ubuntu). Built on the existing `feat/ci-workflow`. | A PR with a deliberately broken test goes red — **not yet demonstrated** |
| FR-R2 | `scripts/build-dmg.sh --version X [--build N]`: clean SYMROOT, version overrides, discovered identity, sign dylibs → frameworks → `HaloHelper.xpc` → `HaloWidget.appex` → app, `hdiutil` DMG + `.sha256`, then mount and re-verify (signature, versions, placeholder Sentry DSN, App Group entitlement, no test bundles) | Output verifies with `codesign --verify --deep --strict` |
| FR-R3 | `android/scripts/sign-release.sh` + `android/RELEASE.md`: keystore via `HALO_KEYSTORE` / `HALO_KEYSTORE_PASS` / `HALO_KEY_ALIAS` (passwords as `env:`, keystore outside the repo), zipalign → apksigner → verify | `apksigner verify` |
| FR-R4 | `docs/RELEASE_CHECKLIST.md`, `docs/RELEASE_NOTES_TEMPLATE.md` (mandatory Verified / NOT verified tables) | Committed |
| FR-R5 | `scripts/bump-version.sh <version> [--build N] [--token] [--dry-run]`: rewrites all 10 + 10 version settings in `project.pbxproj`, verifies uniformity before writing | Script test on a scratch copy |
| H-18 | `scripts/check-rules-sync.sh`: every embedded ```json rules block in tracked Markdown vs `docs/specs/firebase-rules.json` (structural compare); zero embedded copies = exit 2; an unparseable block with a `"rules"` key is reported as drift | Edit one copy → script fails |
| NFR | No secrets in the repo or CI logs; Sentry DSN injected only by the release job | Review |

## 6. Non-Functional Requirements

Workflow `permissions: contents: read`; no secrets referenced; `cancel-in-progress` only for `pull_request`; `workflow_dispatch` enabled. The macOS job builds twice (`-target Halo` + the `HaloTests` scheme) as FR-R1 specifies.

## 7. Architecture

`.github/workflows/ci.yml` (3 jobs: macOS, Android, rules-sync) · `scripts/{build-dmg,bump-version,check-rules-sync}.sh` · `android/scripts/sign-release.sh` + `android/RELEASE.md` · `docs/RELEASE_CHECKLIST.md`, `docs/RELEASE_NOTES_TEMPLATE.md` · `*.jks/*.keystore/*.p12` added to `android/.gitignore`.

## 8. Acceptance (ship gate)

- **AC-1** `ci.yml` valid, triggers as intended — ✓ (Ruby `YAML.load_file`; action versions and the `macos-26` runner label checked via `gh api`).
- **AC-2 (needs a real run)** The workflow is green on GitHub, HaloTests pass under `CODE_SIGNING_ALLOWED=NO` on a hosted runner, and a deliberately broken test goes red — **NOT verified; the first run is PR #56 itself.**
- **AC-3** `check-rules-sync.sh`: passes now; a mutated embedded copy, a value mutation and a trailing-comma mutation all fail — ✓.
- **AC-4** `bump-version.sh` on a scratch copy of `project.pbxproj` — ✓; repo file untouched.
- **AC-5** `sign-release.sh` with a throwaway keystore — ✓; **not** with the owner's real keystore, and the signed APK was not install-tested over a previous release.
- **AC-6** `build-dmg.sh --version 2.6.0-script-test` ran **once for real** (build, sign, DMG, mounted-DMG re-verify) — ✓; its failure paths (mislabelled version, stale SYMROOT) were **not triggered**, and the review's later edits (work-dir handling, build-number default) were tested only with a stub `xcodebuild`.

## 9. Open Questions & Risks

Hardening not done: pin actions by SHA; `gradle/actions/wrapper-validation`; enforce `versionCode` (it is `1` in `android/app/build.gradle.kts` and must be bumped by hand — `android/RELEASE.md` says so); the two macOS audit scripts are pure shell and could run on a cheaper runner. Notarisation remains an owner action. R-6 (docs/`CLAUDE.md` conflicts) is why release docs live in `docs/`, not `CLAUDE.md`.

## 10. Execution Plan

| Task | Work | Est. | State |
|---|---|---|---|
| F58-1 | CI workflow (from `feat/ci-workflow`) | 1.5 d | 🔧 #56 — never run on GitHub |
| F58-2 | `build-dmg.sh` | 1 d | 🔧 #56 — one real run |
| F58-3 | Android signing doc + script | 0.5 d | 🔧 #56 — throwaway keystore |
| F58-4 | Release notes template + checklist | 0.5 d | 🔧 #56 (committed; content reviewed) |
| F58-5 | Version-bump wrapper | 0.5 d | 🔧 #56 — scratch-copy test |
| — | Independent review | — | ✅ 7 fixes (`65bc32b`); verdict "approve once CI shows green on the first run" |

## 11. Mobile Feasibility

**n/a** — repo-level release plumbing; not a desktop capability with a phone equivalent. (Recorded so the mobile-parity rule is visibly satisfied rather than skipped.)

## 12. Implementation Record

**PR #56, branch `feat/v2.6-f058-release-eng`** (4 commits; head `65bc32b`). Nothing merged, published or tagged.

**Built:** FR-R1…R5 and H-18 as §5. Review fixes (7): `--work` guard bypass and unscoped `rm -rf` in `build-dmg.sh`; default `--build` could pick the wrong value when the pbxproj disagreed (now fails); missing option value died silently (now exit 2 + message); `sign-release.sh` relative paths resolved against `android/` and a symlink evaded the in-repo-keystore guard; signing passwords exported into Gradle's environment (now only `apksigner`, via `env:`); `cancel-in-progress` cancelled `release/**` push runs; `check-rules-sync.sh` skipped an unparseable embedded block (false pass).

**Verified:** see AC-1…AC-6. `bash -n` and `shellcheck -S warning` clean on all four scripts; `HaloShareKit` `swift test` 60 passed; `./gradlew --no-daemon :halocloud:test :haloshare:test :app:assembleRelease` BUILD SUCCESSFUL locally (yields `app-release-unsigned.apk`); `audit-entitlements.sh` (static) and `audit-subprocess-spawning.sh` exit 0.

**NOT verified:** the workflow on GitHub (HaloTests with signing off on a hosted runner, the Android job on ubuntu, "broken test goes red"); `build-dmg.sh` failure paths and the post-review full path; HaloTests under the CI flags (not run on the shared machine); `sign-release.sh` with the owner's real keystore.
