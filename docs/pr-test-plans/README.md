# Per-PR Manual Test Plans

Step-by-step manual test plans for each of Halo's 16 currently-open pull requests — one doc per
PR, self-contained (checkout instructions, what changed, detailed test cases, a regression
spot-check). For a single document covering **the whole product at once**, including every one
of these PRs merged together, see [`../MASTER_TEST_PLAN.md`](../MASTER_TEST_PLAN.md) instead.

## Recommended order

Merge/test order matters here — a few of these have real dependencies or staleness issues worth
knowing before you start:

1. **PR #6** — docs-only planning (F-044→F-050 specs). Its base branch is stale (targets an
   already-merged branch, not `main`) — retarget before merging. Review-only, no app to test.
2. **PR #7** — stacked directly on PR #6's branch; doesn't make sense to test/merge in isolation
   until #6 lands.
3. **PR #1** — oldest open PR (May 2026); `main`'s test infrastructure has evolved well past it
   independently. Likely needs a rebase, and one of its two bug fixes may already be superseded.
   Read its doc before investing review time.
4. **PR #9, #10, #11, #12, #13, #14, #15, #16, #17, #18, #19, #20, #21** — all cleanly branched
   from current `main`, each adds one self-contained feature (F-016 through F-030). No ordering
   dependency between them; test in any order. All currently show `mergeStateStatus: BLOCKED` on
   GitHub (not a conflict — `mergeable: MERGEABLE` — likely pending required checks/reviews).

## Index

| PR | Feature | Doc |
|----|---------|-----|
| #21 | F-019 Security Posture Dashboard | [PR-21-security-posture-dashboard.md](PR-21-security-posture-dashboard.md) |
| #20 | F-020 S.M.A.R.T. Disk Health Monitor | [PR-20-smart-disk-health.md](PR-20-smart-disk-health.md) |
| #19 | F-025 Duplicate Photos Finder (Perceptual Hash) | [PR-19-duplicate-photos-finder.md](PR-19-duplicate-photos-finder.md) |
| #18 | F-018 Privacy Data Exposure Scanner | [PR-18-privacy-exposure-scanner.md](PR-18-privacy-exposure-scanner.md) |
| #17 | F-017 Network Traffic Monitor | [PR-17-network-traffic-monitor.md](PR-17-network-traffic-monitor.md) |
| #16 | F-022 Time Machine Backup Health Monitor | [PR-16-time-machine-monitor.md](PR-16-time-machine-monitor.md) |
| #15 | F-024 Browser Cleaner | [PR-15-browser-cleaner.md](PR-15-browser-cleaner.md) |
| #14 | F-028 Focus Session Companion | [PR-14-focus-session.md](PR-14-focus-session.md) |
| #13 | F-023 Memory Leak & App Bloat Tracker | [PR-13-memory-leak-tracker.md](PR-13-memory-leak-tracker.md) |
| #12 | F-030 iCloud Drive Analyzer | [PR-12-icloud-drive-analyzer.md](PR-12-icloud-drive-analyzer.md) |
| #11 | F-029 Scheduled Reports & Weekly Digest | [PR-11-scheduled-reports-weekly-digest.md](PR-11-scheduled-reports-weekly-digest.md) |
| #10 | F-021 App Usage & Screen Time Analytics | [PR-10-app-usage-analytics.md](PR-10-app-usage-analytics.md) |
| #9 | F-016 Permission Auditor | [PR-09-permission-auditor.md](PR-09-permission-auditor.md) |
| #7 | F-044 Phase 0 — Cloud foundation + Firebase spike | [PR-07-cloud-foundation.md](PR-07-cloud-foundation.md) |
| #6 | Docs: F-044–F-050 planning specs | [PR-06-upcoming-features-planning.md](PR-06-upcoming-features-planning.md) |
| #1 | Maestro flows + XCUITest suite + onboarding fix | [PR-01-maestro-e2e-tests.md](PR-01-maestro-e2e-tests.md) |

## How these docs were built

13 of the 16 PRs already authored detailed, step-by-step test cases as part of their own diff to
`docs/MANUAL_TEST_PLAN.md` (every feature PR touches that shared file, adding its own section).
Those docs here reproduce that PR's own test cases verbatim, wrapped with checkout instructions
and a regression spot-check. The remaining three (PR #7, #6, #1) don't add a `MANUAL_TEST_PLAN.md`
section, so their docs were written directly from the PR's diff and description instead.
