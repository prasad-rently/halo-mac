# Manual Test Plan — PR #9: F-016 Permission Auditor

> **Branch:** `feat/f016-permission-auditor` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/9
> **Diff size:** 12 files changed, +685/-17
> **Master regression doc:** this PR's test cases also appear at [`§4.1`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Protection**.

## How to test this PR

```bash
git fetch origin feat/f016-permission-auditor
git checkout feat/f016-permission-auditor
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/PermissionAuditor.swift`
- `Halo/Features/Protection/ProtectionView.swift`

## Detailed test cases

**Files:** `PermissionAuditor.swift`, `ProtectionView.swift` (`PermissionsAuditSection`, `PermissionAuditList`, `PermissionGroupRow`, `FullDiskAccessBanner`, `PermissionCard`)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | TCC.db readable — real per-app audit | Grant Halo (or the debug binary) Full Disk Access in System Settings, relaunch, open Protection | "App Permissions" shows the grouped, expandable per-app list (`PermissionAuditList`) instead of the category grid; subtitle reads "Real per-app grants read from this Mac's permission database" |
| TC-PROT-09 | P0 | Risk-flag heuristic — elevated flagged | With FDA granted, a non-browser/non-communication app holds Screen Recording or Accessibility | Its row shows the amber "excessive for this app" label and a warning-triangle icon; the group's "N elevated" badge counts it |
| TC-PROT-10 | P1 | Risk-flag heuristic — browsers/comms exempt | A known browser (e.g. Chrome/Safari) or comms app (e.g. Slack, Zoom) holds Screen Recording or Accessibility | NOT flagged elevated — green checkmark icon, no "excessive" label |
| TC-PROT-11 | P1 | Revoke deep link | Click "Revoke" on a per-app grant row | Opens the matching System Settings privacy pane for that permission kind (e.g. `Privacy_ScreenCapture` for Screen Recording) via `x-apple.systempreferences:` |
| TC-PROT-12 | P0 | Summary badge — "X of Y apps excessive" | View the section header once grants have loaded | Badge reads "N of M apps excessive" (M = unique audited bundle IDs, N = unique bundle IDs with ≥1 elevated grant); amber if N > 0, green if N == 0 |
| TC-PROT-13 | P0 | TCC.db unreadable — honest fallback | Default state: no Full Disk Access (sandboxed/release build, or FDA not granted) | `FullDiskAccessBanner` shows the honest reason text (e.g. "Halo needs Full Disk Access to show per-app grants — showing categories only"); the original 4-column category-card grid renders beneath it, unchanged |
| TC-PROT-14 | P1 | Zero readable grants treated as unavailable | TCC.db opens but every row is denied/undetermined (`auth_value` 0 or 1) | Falls back to `.unavailable("No readable permission grants found…")` — the category grid is shown, never an empty per-app list |
| TC-PROT-15 | P2 | Loading indicator | Observe the section header while `permissionAuditor.run()` is in flight | A small spinner replaces the summary badge; no flash of stale content or crash |
| TC-PROT-16 | P2 | Release/sandboxed build always falls back | Run the sandboxed release build | TCC.db is unreachable by design → category-card view + banner always shown, never the rich list |
| **Unit** TC-PROT-U5 | P0 | Risk heuristic — non-browser elevated | `TCCGrant` for Screen Recording/Accessibility, arbitrary bundle ID | `isElevatedRisk == true` |
| **Unit** TC-PROT-U6 | P0 | Risk heuristic — browser/comm exemption | `TCCGrant` for Screen Recording/Accessibility, known browser/comm bundle ID | `isElevatedRisk == false` |
| **Unit** TC-PROT-U7 | P1 | Risk heuristic — non-eligible kinds | `TCCGrant` for Camera/Microphone/etc. | Never flagged elevated regardless of bundle ID |
| **Unit** TC-PROT-U8 | P0 | Grouping by category | Mixed-kind synthetic grant list | Grants bucket correctly per `PermissionKind`; kinds with no grants have no entry |
| **Unit** TC-PROT-U9 | P0 | "X of Y" count — one excessive app, multiple grants | Same bundle ID: one elevated + one non-elevated grant | Counted once in both total and excessive (no double-count) |
| **Unit** TC-PROT-U10 | P1 | "X of Y" count — zero apps | Empty grant list | `total == 0`, `excessive == 0` |
| **Unit** TC-PROT-U11 | P1 | `.unavailable(reason:)` handled gracefully | `PermissionAuditor.run()` on a machine without Full Disk Access | Returns `.unavailable` with a non-empty reason; never throws or crashes |

## Regression spot-check

This PR only *adds* a new section to **Protection** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Protection test cases from [`§4` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
