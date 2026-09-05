# Open-PR review — index

Full review of all 16 open PRs, 2026-09-04. Reviewed against each PR's head commit as it stood
that day. Every finding here is also posted as an inline comment on the PR itself.

- **Start here if picking this up cold:** [`00-SESSION-HANDOFF.md`](00-SESSION-HANDOFF.md)
- **Merge order:** [`00-MERGE-ORDER.md`](00-MERGE-ORDER.md)
- **Cross-PR notes:** [consolidated comment on #21](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519)

## Verdicts

| PR | Feature | Branch | Verdict | Blockers | Findings doc |
|----|---------|--------|---------|----------|--------------|
| [#20](https://github.com/prasad-rently/halo-mac/pull/20) | F-020 S.M.A.R.T. Disk Health | `feat/f020-smart-disk-health` | Approve with comments | 1 H | [PR-20](PR-20-f020-smart-disk-health.md) |
| [#6](https://github.com/prasad-rently/halo-mac/pull/6) | docs/specs planning | `feature/upcoming-features` | Approve with comments | — | [PR-06](PR-06-upcoming-features-specs.md) |
| [#16](https://github.com/prasad-rently/halo-mac/pull/16) | F-022 Time Machine Monitor | `feat/f022-time-machine-monitor` | Request changes | 1 H | [PR-16](PR-16-f022-time-machine-monitor.md) |
| [#14](https://github.com/prasad-rently/halo-mac/pull/14) | F-028 Focus Session | `feat/f028-focus-session` | Request changes | 1 H | [PR-14](PR-14-f028-focus-session.md) |
| [#13](https://github.com/prasad-rently/halo-mac/pull/13) | F-023 Memory Leak Tracker | `feat/f023-memory-leak-tracker` | Request changes | 1 H + UUID | [PR-13](PR-13-f023-memory-leak-tracker.md) |
| [#12](https://github.com/prasad-rently/halo-mac/pull/12) | F-030 iCloud Drive Analyzer | `feat/f030-icloud-drive-analyzer` | Request changes | 1 H | [PR-12](PR-12-f030-icloud-drive-analyzer.md) |
| [#11](https://github.com/prasad-rently/halo-mac/pull/11) | F-029 Weekly Digest | `feat/f029-scheduled-reports` | Request changes | 1 H | [PR-11](PR-11-f029-scheduled-reports.md) |
| [#10](https://github.com/prasad-rently/halo-mac/pull/10) | F-021 App Usage Analytics | `feat/f021-app-usage-analytics` | Request changes | 1 H | [PR-10](PR-10-f021-app-usage-analytics.md) |
| [#9](https://github.com/prasad-rently/halo-mac/pull/9) | F-016 Permission Auditor | `feat/f016-permission-auditor` | Request changes | 1 H + UUID | [PR-09](PR-09-f016-permission-auditor.md) |
| [#21](https://github.com/prasad-rently/halo-mac/pull/21) | F-019 Security Posture | `feat/f019-security-posture` | Request changes | 2 H + UUID | [PR-21](PR-21-f019-security-posture.md) |
| [#18](https://github.com/prasad-rently/halo-mac/pull/18) | F-018 Privacy Exposure Scanner | `feat/f018-privacy-exposure-scanner` | Request changes | 2 H | [PR-18](PR-18-f018-privacy-exposure-scanner.md) |
| [#1](https://github.com/prasad-rently/halo-mac/pull/1) | Maestro + XCUITest | `feat/maestro-e2e-tests` | Request changes → **close** | superseded | [PR-01](PR-01-maestro-e2e-tests.md) |
| [#15](https://github.com/prasad-rently/halo-mac/pull/15) | F-024 Browser Cleaner | `feat/f024-browser-cleaner` | Request changes | 1 C + 1 H | [PR-15](PR-15-f024-browser-cleaner.md) |
| [#19](https://github.com/prasad-rently/halo-mac/pull/19) | F-025 Duplicate Photos | `feat/f025-duplicate-photos` | Request changes | 1 C + 3 H | [PR-19](PR-19-f025-duplicate-photos.md) |
| [#7](https://github.com/prasad-rently/halo-mac/pull/7) | F-044 cloud foundation | `feature/f-044-cloud-foundation` | Request changes | 2 C + 1 H + scope | [PR-07](PR-07-f044-cloud-foundation.md) |
| [#17](https://github.com/prasad-rently/halo-mac/pull/17) | F-017 Network Traffic Monitor | `feat/f017-network-traffic-monitor` | Request changes | 2 C + 1 H | [PR-17](PR-17-f017-network-traffic-monitor.md) |

Sorted by remaining work: fewest blockers first. `C` = Critical, `H` = High.

## Critical findings (7)

| PR | File | Issue |
|----|------|-------|
| #17 | `NetworkTrafficMonitor.swift:143` | `waitUntilExit()` before pipe drain — `lsof` >64 KB deadlocks the actor permanently |
| #17 | `NetworkTrafficMonitor.swift:252` | Same on `nettop` |
| #19 | `PerceptualDuplicateDetector.swift:174` | `CGContext(data: &pixels,…)` — pointer does not outlive the call (UB) |
| #15 | `BrowserCleanerScanner.swift:181` | `~/Library/Cookies` is the *shared* cookie store — clears other apps' cookies, misses Safari's |
| #7 | `CryptoService.swift:97` | `SecRandomCopyBytes` status discarded → all-zero PBKDF2 salt on failure |
| #7 | `GoogleOAuthPKCE.swift:36` | Same → constant, publicly-known PKCE verifier |
| — | *(#15)* `BrowserCleanerScanner.swift:220` | Trashes live SQLite without `-wal`/`-shm` siblings → profile corruption *(High)* |

## What this batch does well

Worth recording, because it is the codebase's strongest habit and the reviews should not obscure it:

- **#21** refuses to guess SIP / Secure Boot / Find My / Login Window, and makes `.unknown`
  *structurally* unable to affect the score — pinned by tests.
- **#12** establishes that no public API returns iCloud account quota, drops the donut chart and
  quota bar rather than approximating, and says so up front.
- **#14** corrects the spec: `INFocusStatusCenter` cannot suppress other apps' notifications, so it
  ships a labelled manual deep link instead of faking it.
- **#20** documents exactly what `diskutil`/IOKit expose, cross-checks against a second Apple tool,
  and explains why ATA sector counters *cannot* exist on NVMe.
- **#9** ran the real `TCC.db` read, showed the failure, and built an honest `.unavailable(reason:)`
  around it.
- **#10** is off-by-default opt-in with a clear-history action, and gates every derived statistic
  until there is enough real history to be honest.
- **#15** marks unverified vendor paths as unverified and *omits* Safari's Site Data rather than
  guessing at the container path.

The recurring weakness is not judgement — it is process plumbing: one subprocess bug copied six
times, unbounded concurrency, main-thread filesystem walks, and swallowed errors.

## Batch-level issues

Tracked in each per-PR doc as B1–B8, and in full in the
[cross-PR comment](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519):

| ID | Issue | Risk |
|----|-------|------|
| B1 | pbxproj UUID collision — #21, #13, #9 all claim `8031`/`8032` | High |
| B2 | All 13 report `MERGEABLE`; first merge conflicts the other twelve across 8 shared files | High |
| B3 | No CI exists — `.github/workflows/` absent, no checks on any branch | High |
| B4 | `Process` + release App Sandbox — 6 features inert in the shipping build | Medium |
| B5 | `Process` pipe ordering copied six times; 5 of 6 wrong | High |
| B6 | 4 `ProcessMonitor` instances, 2 `AlertManager` instances with per-instance cooldowns | Medium |
| B7 | Inconsistent privacy posture between #10 (opt-in) and #13 (unconditional) | Medium |
| B8 | Fresh `UUID()` as `Identifiable.id` on re-derived models — 5 files | Low |

## How these docs are distributed

Each PR's findings doc is committed to **that PR's own branch** at
`docs/reviews/PR-<n>-<slug>.md`, so checking out a branch gives you its review alongside its code.
This index and the merge order live on `review/pr-audit`.
