# Manual Test Plan — PR #17: F-017 Network Traffic Monitor

> **Branch:** `feat/f017-network-traffic-monitor` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/17
> **Diff size:** 14 files changed, +1059/-4
> **Master regression doc:** this PR's test cases also appear at [`§5.3.1`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Performance**.

## How to test this PR

```bash
git fetch origin feat/f017-network-traffic-monitor
git checkout feat/f017-network-traffic-monitor
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/NetworkTrafficMonitor.swift`
- `Halo/Features/Performance/NetworkDetailSection.swift`
- `Halo/Features/Performance/NetworkTrafficSection.swift`
- `Halo/Resources/tracker-domains.json`

## Detailed test cases

**Files:** `NetworkTrafficMonitor.swift` (actor), `NetworkTrafficSection.swift` (view, embedded in the Network card).

Read-only per-process network visibility via `lsof -i -n -P` (open sockets) and `nettop -P -L 1 -J bytes_in,bytes_out` (per-app byte totals), joined by **pid** (not process name — the two tools truncate the same process's name differently). Reverse DNS is best-effort via `getaddrinfo`/`getnameinfo`, cached per-IP, and never fabricated: an unresolved host is always `nil`, never guessed, and never flagged as a tracker.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-70 | P0 | Section expands | Open Performance → Network, click "Show" on Network Traffic Monitor | Controls appear; settles into loading, a populated list, or the explicit empty state — never an indefinite spinner |
| TC-PERF-71 | P1 | Filter and sort controls render | Expand the section | Filter-by-app field and sort picker (Recent / App Name / Data) both visible |
| TC-PERF-72 | P1 | Filter narrows the list | Type an app name substring | List narrows to matching rows (case-insensitive substring match) |
| TC-PERF-73 | P1 | Filter with no matches | Type a nonsense string | Explicit "No active outbound connections match." empty state, not a stuck spinner |
| TC-PERF-74 | P0 | Sort by Data | Switch sort picker to "Data" | Rows reorder by joined per-app byte total, descending |
| TC-PERF-75 | P0 | Suspicious flag only on resolved + matched host | View a connection whose reverse DNS resolves to a bundled tracker domain | Red warning icon + red host text; an unresolved IP is never flagged |
| TC-PERF-76 | P1 | Collapse stops polling | Click "Hide" | Controls disappear; re-expanding ("Show") works without error |
| TC-PERF-77 | P2 | Top talker banner | A process has nonzero session bytes | "Top talker: `<name>` — `<bytes>` this session" banner shown above the controls |
| **Unit** TC-PERF-U5 | P0 | lsof parser — ESTABLISHED row | Real captured `lsof -i -n -P` line | pid/host/port/state parsed correctly |
| **Unit** TC-PERF-U6 | P0 | lsof parser — filters LISTEN/connectionless | Rows with `(LISTEN)` or `*:*` | Excluded from parsed connections |
| **Unit** TC-PERF-U7 | P1 | lsof parser — IPv6 brackets | `[2600:1901:1:d18::]:443` | Brackets stripped, port parsed |
| **Unit** TC-PERF-U8 | P1 | lsof parser — dedup | Duplicate (pid, ip, port, protocol) rows | Collapsed to one entry |
| **Unit** TC-PERF-U9 | P0 | nettop parser — pid join with spaced names | `Google Chrome H.902,488148251,1953712,` | pid=902, name preserved with space, bytes parsed |
| **Unit** TC-PERF-U10 | P1 | nettop parser — zero-byte rows filtered, sorted descending | Mixed zero/nonzero rows | Zero-byte rows dropped; remaining sorted by total bytes desc |
| **Unit** TC-PERF-U11 | P0 | pid join survives name mismatch | lsof "Google" vs nettop "Google Chrome H" for same pid | Join by pid succeeds; join by process-name string does not (the bug this PR fixed) |
| **Unit** TC-PERF-U12 | P0 | Tracker domain matching | Exact / subdomain / suffix-only-no-dot / case-insensitive / unrelated host | Exact and subdomain match; bare suffix string and unrelated hosts don't |
| **Unit** TC-PERF-U13 | P1 | Reverse DNS never fabricates | Unresolvable host | Returns `nil`, never a guessed name |
| **Unit** TC-PERF-U14 | P2 | Reverse DNS cache keyed by IP | Same IP looked up twice; two distinct IPs looked up once each | One cache slot for the repeat; two slots for the distinct IPs |

## Regression spot-check

This PR only *adds* a new section to **Performance** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Performance test cases from [`§5` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
