# Halo — Full Manual Test Plan

> **App:** Halo — *Your Mac. Elevated.*
> **Version:** v2.1+ (post-HaloShare / Ports / CodeBeautifier / Snippets)
> **Bundle ID:** `com.halo.mac` · **Min macOS:** 13.0 (Ventura)
> **Document owner:** QA · **Last updated:** 2026-06-10
> **Scope:** Manual + unit test cases for every module, scanner, intent, and shared component in the project.

---

## How to use this document

- Each test case has a **stable ID** (`TC-<MODULE>-<NN>`), **preconditions**, **steps**, **expected result**, and a **priority** (P0 = blocker, P1 = high, P2 = medium, P3 = low).
- Run **P0** cases on every build; **P1** on every release candidate; **P2/P3** on full regression passes.
- Mark each run as **Pass / Fail / Blocked / N-A**, attach screenshots for UI defects, and link the crash report (Sentry) for any crash.
- "Unit testcase" rows describe logic that should be (or is) covered by `HaloTests` and what to assert when verifying manually.

### Test environment matrix

| Dimension | Values to cover |
|-----------|-----------------|
| macOS | 13 Ventura (min), 14 Sonoma, 15 Sequoia |
| Silicon | Apple Silicon (M-series) **and** Intel |
| Build config | Debug (sandbox OFF) + Release (sandbox ON) |
| Display | Single display + multi-display (for DDC/brightness) |
| Permissions | Fresh install (no perms) + fully granted |
| Power | On battery + on AC (for battery/idle tests) |
| Network | Wi-Fi, Ethernet, VPN active, iCloud Private Relay on |

### Global pre-test setup

1. Clean install: delete `~/Applications/Halo.app`, the App Group container, and all `UserDefaults` keys (or use a fresh user account).
2. Build & sign per `CLAUDE.md` → "Build & Sign". Verify `codesign --verify --deep --strict` returns **OK**.
3. Launch Halo; confirm the menu bar icon appears and no crash dialog shows.

---

## 0. Smoke / Build Acceptance

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SMOKE-01 | P0 | App launches | Launch Halo.app | Menu bar icon appears; no crash; main window opens via menu |
| TC-SMOKE-02 | P0 | Code signature valid | `codesign --verify --deep --strict ~/Applications/Halo.app` | Returns OK, exit 0 |
| TC-SMOKE-03 | P0 | Widget registers | `pluginkit -m -i com.halo.mac.widget` | Widget appex is listed |
| TC-SMOKE-04 | P0 | All sidebar modules load | Click each sidebar item | Each view renders without blank screen or spinner-hang |
| TC-SMOKE-05 | P1 | No console errors on idle | Leave app open 5 min, watch Console.app | No repeating exceptions, no runaway logging |
| TC-SMOKE-06 | P1 | Memory stable on idle | Observe in Activity Monitor 10 min | No continuous RAM growth (leak) |
| TC-SMOKE-07 | P1 | Clean quit | Quit via menu | Process terminates; timers invalidated; no zombie |

---

## 1. App Shell & Navigation

**Files:** `HaloApp.swift`, `AppState.swift`, `ContentView.swift`, `BuildToken.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-SHELL-01 | P0 | MenuBarExtra opens window | App running | Click menu bar icon → choose open/dashboard | Main `NavigationSplitView` window appears |
| TC-SHELL-02 | P0 | Sidebar routing | Window open | Click each module in sidebar | Detail pane switches to correct module view |
| TC-SHELL-03 | P1 | Dashboard is default route | Fresh launch open window | — | Dashboard shown first |
| TC-SHELL-04 | P1 | Settings window | App menu → Settings (⌘,) | Open | Settings/Onboarding-style window opens |
| TC-SHELL-05 | P1 | Window restore | Close window (not quit), reopen from menu | — | Reopens to last/again-valid state, no crash |
| TC-SHELL-06 | P2 | Multiple windows | Open window twice | — | No duplicate-state corruption |

### 1.1 Reorderable Sidebar

**Files:** `AppState.moduleOrder`, `ContentView.SidebarView`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SIDEBAR-01 | P1 | Enter edit mode | Tap edit toggle (`slider.horizontal.3`) | Dashboard row hides; label → "Drag to reorder"; rows show `≡` handle, dim to 80% |
| TC-SIDEBAR-02 | P1 | Reorder a module | Drag a module to new position | Order updates visually |
| TC-SIDEBAR-03 | P0 | Order persists | Reorder, quit, relaunch | New order restored from `UserDefaults["moduleOrder"]` |
| TC-SIDEBAR-04 | P1 | Navigation suppressed in edit | While editing, tap a row | No navigation occurs |
| TC-SIDEBAR-05 | P1 | Exit edit mode | Tap `checkmark.circle.fill` | Dashboard reappears; handles hidden; navigation restored |
| TC-SIDEBAR-06 | P0 | Forward-compat new module | Add a new module to enum, load old saved order | New module appended at end, still appears |
| TC-SIDEBAR-07 | P2 | Dashboard always pinned | Try to reorder Dashboard | Dashboard is not in reorderable list; stays pinned |
| **Unit** TC-SIDEBAR-U1 | P1 | `moveModules(from:to:)` | Call with indices | Array mutates correctly, `.dashboard` excluded |
| **Unit** TC-SIDEBAR-U2 | P1 | Persist/restore roundtrip | Save order → decode | Decoded `[AppModule]` equals saved, unknown rawValues skipped |

---

## 2. Dashboard

**Files:** `DashboardView.swift`, `GPUDashboardCard.swift`, `NetworkSparklineCard.swift`, `AppState.calculateHealthScore()`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-DASH-01 | P0 | Health score ring renders | Dashboard open | — | Ring shows 0–100 value, colour-coded (green/amber/red) |
| TC-DASH-02 | P0 | Live metrics update | Watch CPU/RAM/disk/battery cards | Wait ~2s | Values refresh on the 2s metrics timer |
| TC-DASH-03 | P1 | Health score logic | Spike CPU/RAM (run stress) | Observe | Score drops per CPU/RAM/disk/battery thresholds |
| TC-DASH-04 | P1 | GPU card | App on machine with GPU | — | GPU card shows utilisation; graceful if unsupported |
| TC-DASH-05 | P1 | Network sparkline | Generate traffic (download a file) | — | Sparkline shows up/down trend |
| TC-DASH-06 | P1 | Alert history section | After alerts fired | — | Recent `AlertEntry` items listed |
| TC-DASH-07 | P0 | Export Report button | Click Export Report | — | NSSavePanel; PDF generated (see §15) |
| TC-DASH-08 | P2 | Battery card on desktop Mac | Run on Mac mini/Studio | — | Battery card hidden or "No battery" gracefully |
| **Unit** TC-DASH-U1 | P0 | `calculateHealthScore()` | Feed known CPU/RAM/disk/battery | Returns expected score; clamps 0–100 |
| **Unit** TC-DASH-U2 | P1 | Health thresholds boundary | Values at each threshold edge | Correct deduction at boundaries (off-by-one safe) |

---

## 3. Cleanup

**Files:** `CleanupView.swift`, `DiskHealthSection.swift`, `FileSystemScanner.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLEAN-01 | P0 | Run cleanup scan | Open Cleanup → Scan | AsyncStream populates categories (caches, logs, etc.) with sizes |
| TC-CLEAN-02 | P0 | Selection + size total | Select categories | Running total of reclaimable space updates |
| TC-CLEAN-03 | P0 | Confirmation before delete | Click Clean | Review sheet appears; nothing deleted until confirmed |
| TC-CLEAN-04 | P0 | Deletion uses Trash | Confirm cleanup of a known file | File moved to Trash (recoverable), NOT permanently removed |
| TC-CLEAN-05 | P1 | Cancel scan | Start scan, cancel mid-way | Scan stops cleanly, partial results discarded/kept consistently |
| TC-CLEAN-06 | P1 | Disk health section | View DiskHealthSection | SMART/health status shown or graceful unavailable message |
| TC-CLEAN-07 | P1 | Empty result | Scan an already-clean system | "Nothing to clean" empty state, no crash |
| TC-CLEAN-08 | P2 | Permission-denied path | Scan a protected dir without perms | Skips gracefully, no crash, logged |
| TC-CLEAN-09 | P1 | Celebration overlay | Complete a cleanup | `CelebrationOverlay` shows success animation |
| **Unit** TC-CLEAN-U1 | P1 | Size aggregation | Sum file sizes | Total equals sum of selected items |
| **Unit** TC-CLEAN-U2 | P0 | trashItem invoked | Mock FileManager | `trashItem(at:)` called, never `removeItem` |

---

## 4. Protection

**Files:** `ProtectionView.swift`, `ProtectionScanner.swift`, `SignatureDatabase.swift`, `signatures.json`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-01 | P0 | Signature DB loads | Launch app | `signatureCount` ≥ 45 from bundle |
| TC-PROT-02 | P0 | Run protection scan | Protection → Scan | Scans complete; threats (if any) listed by kind/risk |
| TC-PROT-03 | P0 | Known signature match | Place file matching a keyword (e.g. `genieo`) | Detected as adware/high |
| TC-PROT-04 | P1 | Clean system | Scan clean machine | No false positives; "No threats" state |
| TC-PROT-05 | P1 | Delta update graceful fail | Block `api.halo.mac` | `checkForUpdate()` fails silently, bundle DB still used |
| TC-PROT-06 | P1 | Cached update wins | Provide newer cached version | Cached signatures merged, higher version used |
| TC-PROT-07 | P0 | Threat removal | Quarantine/remove a detected item | Confirmation sheet; trashItem used |
| **Unit** TC-PROT-U1 | P0 | `matches(keyword:)` hit | Lookup known keyword | Returns correct `(kind, risk)` |
| **Unit** TC-PROT-U2 | P0 | `matches(keyword:)` miss | Lookup unknown | Returns nil |
| **Unit** TC-PROT-U3 | P1 | Case/whitespace handling | Mixed-case keyword | Normalised match works |
| **Unit** TC-PROT-U4 | P1 | JSON schema parse | Load malformed signatures.json | Graceful failure, falls back to bundle |

---

## 5. Performance

**Files:** `PerformanceView.swift`, `TopProcessesSection.swift`, `CPUCoresSection.swift`, `BatteryDetailSection.swift`, `NetworkDetailSection.swift`, `SensorsSection.swift`, `IdleAppsSection.swift`, monitors (`CPUDetailMonitor`, `ProcessMonitor`, `NetworkDetailMonitor`, `SMCReader`, `LoginItemScanner`, `IdleAppMonitor`)

### 5.1 Processes & CPU

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-01 | P0 | Top processes load | Open Performance | Spinner only on first load; list populates with %CPU/RAM |
| TC-PERF-02 | P1 | CPU/RAM picker | Toggle sort CPU↔RAM | List re-sorts; picker is on its own row, no overlap with Hide/Show |
| TC-PERF-03 | P1 | Per-core CPU | View CPUCoresSection | Each core shows utilisation bar |
| TC-PERF-04 | P1 | Empty state after load | Edge: no processes returned | Empty-state text (not infinite spinner) |
| TC-PERF-05 | P2 | Kill / inspect process | Select a process action | Acts on correct PID; confirmation for kill |

### 5.2 Battery

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-10 | P1 | Battery health label | View on laptop | Cycles <100→Excellent, <300→Good, else capacity ratio |
| TC-PERF-11 | P1 | Cycle/capacity display | — | Shows cycle count + max capacity |
| TC-PERF-12 | P2 | No-battery machine | Run on desktop | Section hidden / "no battery" |
| **Unit** TC-PERF-U1 | P0 | Battery label order | Cycles=50,cap=70% | Returns "Excellent" (cycles factored first) |
| **Unit** TC-PERF-U2 | P1 | Battery label fallback | Cycles=500 | Falls back to capacity ratio bucket |

### 5.3 Network

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-20 | P1 | Live throughput | Download file | Up/down rates update |
| TC-PERF-21 | P0 | VPN true positive | Connect a real VPN (utun + .other) | Shows "VPN active" |
| TC-PERF-22 | P0 | iCloud Private Relay not VPN | Enable Private Relay only | NOT flagged as VPN |
| TC-PERF-23 | P1 | Definitive protocols | ppp/ipsec/tap interface | Flagged as VPN |
| **Unit** TC-PERF-U3 | P0 | VPN two-rule logic | Mock utun+.other vs utun+.wifi | First=VPN, second=not |

### 5.3.1 Network Traffic Monitor (F-017)

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

### 5.4 Speed Test

**File:** `SpeedTestService.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-30 | P1 | Run speed test | Trigger speed test | Download (25MB), upload (5MB), ping median over 10 reported |
| TC-PERF-31 | P2 | Offline speed test | Disconnect network | Fails gracefully with error message |
| TC-PERF-32 | P2 | Warm-up request | Inspect first request | Warm-up issued before measurement |

### 5.5 Sensors

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-40 | P1 | Sensors on Apple Silicon | View SensorsSection | Either real values or full HaloCard explanation of SMC limits |
| TC-PERF-41 | P2 | Sensors on Intel | View on Intel Mac | Temp/fan values if available |

### 5.6 Login Items

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-50 | P1 | Enumerate login items | View login items | LaunchAgents/Daemons with RunAtLoad/KeepAlive, suspicious-first |
| TC-PERF-51 | P1 | Manage All opens Settings | Click "Manage All" | Opens `com.apple.LoginItems-Settings.extension` |
| TC-PERF-52 | P1 | Toggle Halo login item | Toggle launch-at-login | `SMAppService.mainApp` enabled/disabled reflects |
| **Unit** TC-PERF-U4 | P1 | Suspicious-first sort | Mixed list | Suspicious items sorted to top |

### 5.7 Idle Apps

**Files:** `IdleAppMonitor.swift`, `IdleAppsSection.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PERF-60 | P1 | Detect idle apps | Leave apps idle | Apps consuming resources while idle are listed |
| TC-PERF-61 | P1 | Quit idle app | Action on idle app | App quits / confirmation shown |
| TC-PERF-62 | P2 | No idle apps | All active | Empty state |

---

## 6. Applications (Deep Uninstaller)

**Files:** `ApplicationsView.swift`, `AppScanner.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-APP-01 | P0 | Enumerate apps | Open Applications | `/Applications` + `~/Applications` listed with icons/versions |
| TC-APP-02 | P1 | Leftover detection | Select an app | 12 standard support paths scanned and shown |
| TC-APP-03 | P0 | Uninstall confirmation | Click Uninstall | Confirmation dialog before any deletion |
| TC-APP-04 | P0 | Uninstall trashes | Confirm uninstall of test app | App bundle + selected leftovers → Trash (recoverable) |
| TC-APP-05 | P1 | Error banner | Uninstall protected/SIP app | Error banner, no crash |
| TC-APP-06 | P1 | "Unused" accuracy | App used today | NOT marked unused |
| TC-APP-07 | P1 | "Unused" unknown date | App with no Spotlight date | `isUnused=false` (unknown ≠ unused) |
| TC-APP-08 | P1 | "Unused" true | App unused >90 days | Marked unused |
| **Unit** TC-APP-U1 | P0 | `isUnused` nil date | lastUsed=nil | Returns false |
| **Unit** TC-APP-U2 | P1 | `isUnused` 91 days | date 91d ago | Returns true |
| **Unit** TC-APP-U3 | P1 | `isUnused` 89 days | date 89d ago | Returns false |
| **Unit** TC-APP-U4 | P1 | Leftover path set | Mock fs | All 12 paths checked, only existing returned |

---

## 7. Files (SpaceLens / Duplicates / Large Files)

**Files:** `FilesView.swift`, `DuplicateDetector.swift`, `DownloadsView.swift`, `DownloadsViewModel.swift`

### 7.1 SpaceLens

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-01 | P1 | SpaceLens map | Open SpaceLens tab | Treemap/breakdown of disk usage renders |
| TC-FILE-02 | P1 | Drill into folder | Click a folder | Navigates into subtree, sizes correct |
| TC-FILE-03 | P2 | Reveal in Finder | Right-click item | Opens in Finder |

### 7.2 Duplicates

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-10 | P0 | Duplicate scan | Run on folder with known dupes | 3-phase SHA-256 detection finds true duplicates |
| TC-FILE-11 | P0 | No false dupes | Distinct files same size | NOT flagged (content hash differs) |
| TC-FILE-12 | P0 | Delete dupes via Trash | Select + delete | Confirmation; trashItem; keeps one original |
| **Unit** TC-FILE-U1 | P0 | SHA-256 grouping | Identical content | Grouped as duplicates |
| **Unit** TC-FILE-U2 | P0 | Size pre-filter | Different sizes | Skipped before hashing (perf) |
| **Unit** TC-FILE-U3 | P1 | Single file | One file | No duplicate group emitted |

### 7.3 Downloads Manager

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-20 | P1 | List downloads | Open Downloads view | `~/Downloads` contents listed with size/date |
| TC-FILE-21 | P1 | Sort/filter | Change sort | Re-orders by date/size/type |
| TC-FILE-22 | P1 | Delete download | Delete an item | Confirmation; trashItem |
| TC-FILE-23 | P2 | Large/old highlight | Old large file | Highlighted for cleanup |

### 7.4 Large Files

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-FILE-30 | P1 | Find large files | Run scan | Files above threshold listed, descending size |
| TC-FILE-31 | P1 | Delete large file | Delete | Confirmation; trashItem |

### 7.5 Drive Speed Test (F-043 / NFeat-121)

**Files:** `DriveSpeedTester.swift`, `DriveSpeedView.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-FILE-40 | P0 | Volume enumeration | — | Open Files → Drive Speed | Internal boot volume listed + preselected; externals show "External" badge |
| TC-FILE-41 | P0 | Run internal test | Internal selected | Pick Quick → Run | Progress animates Write→Read across 3 passes; live MB/s updates |
| TC-FILE-42 | P0 | Average + optimal results | Test completes | View result cards | Write & Read each show avg and optimal; **optimal ≥ average** |
| TC-FILE-43 | P1 | External drive test | Plug in external, select it | Run | Writes scratch to `<vol>/.HaloSpeedTest/`; results shown; scratch removed after |
| TC-FILE-44 | P1 | Size selection | — | Switch Quick/Standard/Thorough | Data amount in results reflects 128 MB / 512 MB / 1 GB |
| TC-FILE-45 | P1 | Cancel mid-run | Test running | Click Cancel | Stops cleanly; no result; **scratch file removed** (verify no leftover) |
| TC-FILE-46 | P1 | Read-only / denied volume | Read-only or sandbox-blocked volume | Run | Friendly `notWritable` error banner; no crash |
| TC-FILE-47 | P1 | Uncached accuracy | Run read test | Compare read speed | Not RAM-inflated (device-level, `F_NOCACHE` in effect) |
| TC-FILE-48 | P2 | No leftover on error | Force an I/O error | — | Scratch file `unlink`-ed even on failure (defer) |
| TC-FILE-49 | P2 | Controls disabled while running | Test running | — | Volume/size pickers + Run disabled until done |
| **Unit** TC-FILE-U4 | P1 | Size byte amounts | — | Assert `DriveTestSize.bytes` | 128e6 / 512e6 / 1000e6, strictly increasing |
| **Unit** TC-FILE-U5 | P1 | Enumerate internal | — | `availableVolumes()` | Non-empty; ≥1 internal; internals sorted first |
| **Unit** TC-FILE-U6 | P0 | Positive speeds | — | `run(.quick)` on internal | write/read avg > 0; optimal ≥ avg; sampleCount > 0 |
| **Unit** TC-FILE-U7 | P1 | Cancellation throws | — | Cancel then await | Run throws (CancellationError) |

> **Data-safety note:** the benchmark scratch file is Halo's own temp data and is
> `unlink`-ed (not trashed) immediately — the only sanctioned exception to
> `TC-SAFE-01`. Verify no `.HaloSpeedTest` residue remains on external drives
> after any run, cancel, or error.

---

## 8. Clipboard & Snippets

**Files:** `ClipboardView.swift`, `ClipboardMonitor.swift`, `ClipboardQuickPickerView.swift`, `SnippetManager.swift`, `SnippetEditorView.swift`, `SnippetListSection.swift`

### 8.1 Clipboard History

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CLIP-01 | P0 | Capture copies | Copy text/URL/code | Items captured, typed (text/url/code colour) |
| TC-CLIP-02 | P0 | Quick picker hotkey | Press ⌘⇧V | Floating NSPanel picker appears |
| TC-CLIP-03 | P0 | Toggle dismiss | Press ⌘⇧V again | Panel dismisses |
| TC-CLIP-04 | P0 | Paste selection | Pick an item | Item pasted into frontmost app |
| TC-CLIP-05 | P1 | 500-item cap | Copy >500 items | Oldest evicted, cap enforced |
| TC-CLIP-06 | P1 | Search history | Type in search | Filters items |
| TC-CLIP-07 | P1 | Delete/clear | Clear history | History emptied; widget snippets cleared |
| TC-CLIP-08 | P2 | URL/code colour coding | Copy a URL then code | Cyan for URL, purple for code |
| **Unit** TC-CLIP-U1 | P1 | Type classification | Feed url/code/plain strings | Correct `ClipboardKind` |
| **Unit** TC-CLIP-U2 | P1 | Dedup consecutive | Copy same twice | Single entry |
| **Unit** TC-CLIP-U3 | P0 | Cap enforcement | Add 501 | Count stays ≤500 |

### 8.2 Snippets

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SNIP-01 | P1 | Create snippet | Add new snippet | Saved, appears in list |
| TC-SNIP-02 | P1 | Edit snippet | Open editor, change | Update persisted |
| TC-SNIP-03 | P1 | Delete snippet | Delete | Removed; confirmation |
| TC-SNIP-04 | P1 | Paste snippet | Use snippet | Content pasted |
| TC-SNIP-05 | P0 | Persistence | Quit/relaunch | Snippets restored from UserDefaults |
| **Unit** TC-SNIP-U1 | P1 | CRUD roundtrip | Create/encode/decode | Equal after roundtrip |

---

## 9. Actions Module

**Files:** `ActionModels.swift`, `ActionLibrary.swift`, `ActionRunner.swift`, `ActionsView.swift`, `QuickActionPickerView.swift`, `CustomActionEditor.swift`, `ActionSettingsStore.swift`, `ActionSettingsTab.swift`, `ActionShareManager.swift`, `VoiceSearchController.swift`

### 9.1 Library & Search

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-01 | P0 | 108 built-ins load | Open Actions | Category tile grid shows all built-in actions |
| TC-ACT-02 | P0 | Quick picker ⌘⇧A | Press ⌘⇧A | Floating picker opens; second press dismisses |
| TC-ACT-03 | P0 | Fuzzy search | Type partial query | AND-logic multi-term match, scored ordering |
| TC-ACT-04 | P1 | Search ranking | Exact vs prefix vs substring | Exact(100)>prefix(80)>substring(60)>subseq(30) |
| TC-ACT-05 | P1 | Usage count ordering | Run an action repeatedly | Sorts higher within equal score |
| **Unit** TC-ACT-U1 | P0 | Fuzzy scorer | Known inputs | Returns expected scores |
| **Unit** TC-ACT-U2 | P1 | All-terms-match | Multi-word, one missing | No match (AND logic) |

### 9.2 Execution

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-10 | P0 | Run shell action | Run "Remove .DS_Store" | Executes via /bin/zsh; stdout streams to ExecutionRow |
| TC-ACT-11 | P0 | Run built-in action | Run "Run Smart Scan" | Calls into AppState correctly |
| TC-ACT-12 | P0 | Privileged action | Run "Flush DNS Cache (sudo)" | osascript admin auth dialog; runs on approve |
| TC-ACT-13 | P1 | Cancel/auth deny | Deny admin prompt | Fails gracefully, marked `.failed` |
| TC-ACT-14 | P1 | Execution history | Run several | History list, most-recent-first, capped at 50 |
| TC-ACT-15 | P1 | Progress indicator | Run long action | Indeterminate (-1) spinner then 1.0 complete |
| TC-ACT-16 | P1 | Output collapse | Expand/collapse ExecutionRow | Output lines toggle |
| **Unit** TC-ACT-U3 | P1 | Multiline→osascript | Multi-line script | Collapsed to `; ` joined |
| **Unit** TC-ACT-U4 | P1 | History cap | Add 51 executions | Count ≤50, oldest dropped |

### 9.3 Custom Actions

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-20 | P1 | Create custom action | Open editor, fill name/icon/keywords/script/sudo | Saved to `UserDefaults["haloCustomActions"]` |
| TC-ACT-21 | P1 | Edit custom action | Modify | Update persisted |
| TC-ACT-22 | P1 | Delete custom action | Remove | Removed; confirmation |
| TC-ACT-23 | P0 | Persistence across update | Relaunch | Custom actions + usage counts (`haloActionUsage`) survive |
| TC-ACT-24 | P1 | Share action | Use ActionShareManager export | Action exported/encoded for share |
| TC-ACT-25 | P1 | Import shared action | Import a shared action file | Action added, validated |

### 9.4 Voice Search & Settings

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ACT-30 | P2 | Voice search | Trigger VoiceSearchController | Mic permission prompt; speech → query |
| TC-ACT-31 | P2 | Voice perm denied | Deny mic | Graceful fallback to text |
| TC-ACT-32 | P1 | Action settings tab | Open ActionSettingsTab | Settings persist via ActionSettingsStore |

### 9.5 Category coverage (spot-check each category runs)

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-ACT-40 | P1 | Xcode actions (4) | Each runs, clears expected caches |
| TC-ACT-41 | P1 | Developer actions (11) | node_modules/npm/yarn/pods/gradle/docker/pip/brew run |
| TC-ACT-42 | P1 | System actions (25) | Each runs (sudo ones prompt) |
| TC-ACT-43 | P1 | Network actions (5) | Speed test/connectivity/IP/Wi-Fi password run |
| TC-ACT-44 | P2 | Files actions (2) | Largest files / eject disks run |
| TC-ACT-45 | P1 | Clipboard actions (15) | JSON/encode/hash/QR/beautify operate on clipboard |
| TC-ACT-46 | P2 | Creative actions (10) | Cache clears for FCP/Resolve/PS/etc. |
| TC-ACT-47 | P2 | Media actions (8) | HEIC→JPEG/optimise/gif/screenshot run |
| TC-ACT-48 | P1 | Halo actions (3) | Smart Scan / Export / Clear Clipboard run |
| TC-ACT-49 | P2 | Dock & Desktop (14) | Spacer/reset/autohide/position changes apply |
| TC-ACT-50 | P2 | Display actions (6) | Dark mode/screenshot/desktop icons toggle |
| TC-ACT-51 | P2 | Audio actions (5) | Mute/volume/DND apply |

---

## 10. Ports Manager

**Files:** `PortScanner.swift`, `PortManagerView.swift`, `PortManagerViewModel.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PORT-01 | P0 | Scan listening ports | Open Ports | `lsof` TCP LISTEN + UDP parsed; dedup; port-sorted |
| TC-PORT-02 | P1 | Process resolution | View entries | pid, process name/path, port, protocol, state shown |
| TC-PORT-03 | P0 | Kill SIGTERM | Kill a test process | SIGTERM sent; process gone; success message |
| TC-PORT-04 | P1 | Force kill SIGKILL | Force kill | SIGKILL sent |
| TC-PORT-05 | P1 | Kill signal preference | Set .ask/.sigterm/.sigkill | Behaviour respects `haloKillSignalPref` |
| TC-PORT-06 | P1 | Named port mapping | Assign a name to a port | Persisted to `haloNamedPorts`, shown as friendlyName |
| TC-PORT-07 | P2 | Refresh | Re-scan | List updates after process changes |
| TC-PORT-08 | P2 | Kill failure | Kill protected pid | Failure message, no crash |
| **Unit** TC-PORT-U1 | P0 | lsof parser | Sample lsof output | Correct `[PortEntry]`, deduped, sorted |
| **Unit** TC-PORT-U2 | P1 | Named port persist | Save/load | Mapping roundtrips |

---

## 11. Code Beautifier

**Files:** `CodeBeautifierView.swift`, `CodeTheme.swift`, `SyntaxHighlighter.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-CODE-01 | P1 | Paste + highlight | Paste code | Syntax highlighting renders per language |
| TC-CODE-02 | P1 | Theme switch | Change CodeTheme | Colours update live |
| TC-CODE-03 | P1 | Beautify/format | Format JSON/code | Pretty-printed output |
| TC-CODE-04 | P1 | Copy result | Copy formatted | Clipboard gets formatted text |
| TC-CODE-05 | P2 | Language detect | Paste different langs | Highlighter adapts/falls back |
| TC-CODE-06 | P2 | Large input | Paste huge file | No hang; reasonable perf |
| **Unit** TC-CODE-U1 | P1 | Highlighter tokens | Known snippet | Correct token ranges/colours |
| **Unit** TC-CODE-U2 | P1 | Format invalid JSON | Bad JSON | Error surfaced, no crash |

---

## 12. HaloShare (LocalSend-compatible P2P transfer)

**Files:** `LocalShareManager.swift`, `LocalShareClient.swift`, `LocalShareServer.swift`, `MulticastDiscovery.swift`, `TLSManager.swift`, `TransferPowerAssertion.swift`, `LocalShareModels.swift`, `LocalShareView.swift`, `ReceiveConsentView.swift`

| ID | Priority | Title | Preconditions | Steps | Expected |
|----|----------|-------|---------------|-------|----------|
| TC-SHARE-01 | P0 | Device discovery | Two devices on same LAN | Open HaloShare both | Peers appear via multicast discovery |
| TC-SHARE-02 | P0 | Send file | Peer discovered | Send a file | Recipient gets consent prompt; on accept, transfer completes |
| TC-SHARE-03 | P0 | Receive consent | Incoming transfer | — | `ReceiveConsentView` prompts before accepting |
| TC-SHARE-04 | P0 | Reject transfer | Incoming transfer | Decline | Transfer aborts, no file written |
| TC-SHARE-05 | P1 | TLS/PIN security | Inspect connection | — | TLS via TLSManager; protocol v2.1 handshake |
| TC-SHARE-06 | P1 | Multi-file transfer | Send several files | — | All files received intact (checksum) |
| TC-SHARE-07 | P1 | Large file | Send >1GB | — | Progress accurate; power assertion keeps awake; completes |
| TC-SHARE-08 | P1 | Cancel mid-transfer | Cancel | — | Both ends clean up; partial file removed |
| TC-SHARE-09 | P1 | LocalSend interop | Send to/from official LocalSend app | — | Interoperable (protocol v2.1) |
| TC-SHARE-10 | P2 | Network drop | Disconnect Wi-Fi mid-send | — | Error surfaced; no hang |
| TC-SHARE-11 | P1 | Power assertion released | Complete/cancel | — | `TransferPowerAssertion` released (no battery drain after) |
| TC-SHARE-12 | P2 | Discovery off network | No peers | — | Empty state, periodic re-scan |
| **Unit** TC-SHARE-U1 | P1 | Model encode/decode | LocalShareModels JSON | Roundtrip matches protocol schema |
| **Unit** TC-SHARE-U2 | P1 | Discovery announce parse | Sample multicast payload | Correct peer model |
| **Unit** TC-SHARE-U3 | P1 | Checksum verify | Known bytes | Mismatch detected |

---

## 13. Menu Bar Display Styles

**Files:** `MenuBarView.swift` (`MenuBarDisplayStyle`, `MenuBarIconView`, `MenuBarStyleSelector`, `MenuBarFormatRenderer`)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-MENU-01 | P0 | Icon style | Set style=icon | Halo icon only |
| TC-MENU-02 | P1 | Text stats | Set textStats | "CPU 42% · RAM 61%" live |
| TC-MENU-03 | P1 | Mini bar | Set miniBar | 4px capsule bars for CPU/RAM |
| TC-MENU-04 | P1 | Dot | Set dot | Green/amber/red per pressure |
| TC-MENU-05 | P0 | Custom format | Set custom + format string | Tokens render live values |
| TC-MENU-06 | P1 | All 11 tokens | Use each token | `{cpu}{ram}{ram_used}{ram_total}{disk}{disk_free}{battery}{net_down}{net_up}{health}{temp}` all resolve |
| TC-MENU-07 | P1 | 5 presets | Apply each preset | Minimal/Standard/Full/Network/Battery render correctly |
| TC-MENU-08 | P1 | Live preview | Edit format in selector | Preview updates as you type |
| TC-MENU-09 | P0 | Style persists | Change style, relaunch | `menuBarDisplayStyle`/`menuBarFormatString` restored |
| **Unit** TC-MENU-U1 | P0 | Format renderer | format + values | All tokens substituted, unknown tokens left/blank safely |
| **Unit** TC-MENU-U2 | P1 | Pressure→dot colour | CPU/RAM thresholds | Correct colour bucket |

---

## 14. Smart Scan & Scheduler

**Files:** `SmartScanView.swift`, `ScanCoordinator.swift`, `ScanScheduler.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SCAN-01 | P0 | Run Smart Scan | Trigger | ScanCoordinator orchestrates cleanup+protection+files; results aggregate |
| TC-SCAN-02 | P1 | Progress/stages | Watch | Stage-by-stage progress shown |
| TC-SCAN-03 | P1 | Schedule config | Set frequency/weekday/hour | Persists `scanFrequency`/`scanPreferredWeekday`/`scanPreferredHour` |
| TC-SCAN-04 | P0 | Next fire date | Set weekly Mon 3AM | "Next: Monday at 3:00 AM" displayed |
| TC-SCAN-05 | P1 | Reschedule on pref change | Change schedule | Re-schedules via UserDefaults.didChange |
| TC-SCAN-06 | P1 | Background result type | Trigger scheduled run | Uses `.finished`/`.deferred` (not `.success`) |
| TC-SCAN-07 | P1 | Scheduled fire | Set near-term schedule, wait | Scan runs at scheduled time |
| **Unit** TC-SCAN-U1 | P0 | `nextScanDate` daily | freq=daily,hour=3 | Next 3AM occurrence |
| **Unit** TC-SCAN-U2 | P0 | `nextScanDate` weekly | weekday=2,hour=3 | Next Monday 3AM |
| **Unit** TC-SCAN-U3 | P1 | `nextScanDate` monthly | freq=monthly | Correct next month date |
| **Unit** TC-SCAN-U4 | P1 | Default values | No prefs set | weekly/Mon(2)/3AM defaults |

---

## 15. Alerts, Report, & Notifications

**Files:** `AlertLog.swift`, `AlertManager.swift`, `ReportGenerator.swift`

### 15.1 Alerts

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ALERT-01 | P0 | Fire alert | Trigger condition | `UNUserNotification` posted + `AlertLog` entry added at index 0 |
| TC-ALERT-02 | P1 | 50-item cap | Fire >50 | Oldest dropped, cap enforced |
| TC-ALERT-03 | P1 | Mark read | markRead/markAllRead | isRead toggles, persisted |
| TC-ALERT-04 | P1 | Clear all | clearAll | Log empties; persisted |
| TC-ALERT-05 | P1 | Persistence | Relaunch | Log restored from `haloAlertLog` |
| **Unit** TC-ALERT-U1 | P0 | append at index 0 | append 3 | Newest first |
| **Unit** TC-ALERT-U2 | P0 | Cap at 50 | append 51 | Count=50 |
| **Unit** TC-ALERT-U3 | P1 | Codable roundtrip | encode/decode AlertEntry | Equal |

### 15.2 PDF Report

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-RPT-01 | P0 | Generate report | Export Report | 4-page A4 PDF created |
| TC-RPT-02 | P1 | Page content | Open PDF | P1 cover+ring, P2 system, P3 storage/battery, P4 alerts |
| TC-RPT-03 | P0 | Save panel | Choose location | NSSavePanel saves PDF to chosen path |
| TC-RPT-04 | P1 | Snapshot accuracy | Compare to dashboard | Values match captured snapshot |
| TC-RPT-05 | P2 | Empty alert history | No alerts | P4 renders empty gracefully |
| **Unit** TC-RPT-U1 | P1 | Snapshot capture | from AppState | All fields populated on MainActor |
| **Unit** TC-RPT-U2 | P1 | Page bounds | DrawablePDFPage | `bounds(for:)` returns A4 rect |

---

## 16. Siri Shortcuts / App Intents

**Files:** `Halo/Intents/*` (8 intents + provider)

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-INT-01 | P1 | Intents discoverable | Shortcuts app → Halo | All 8 intents listed |
| TC-INT-02 | P1 | GetHealthScore | Run intent | Returns Int 0–100 |
| TC-INT-03 | P1 | GetCPUUsage | Run | Returns Double % |
| TC-INT-04 | P1 | GetBatteryHealth | Run | Returns String summary |
| TC-INT-05 | P1 | GetDiskSpace | Run | Returns String summary |
| TC-INT-06 | P1 | RunSmartScan | Run | Triggers scan, returns result string |
| TC-INT-07 | P1 | RunAction (entity) | Pick HaloAction | Runs action, returns output |
| TC-INT-08 | P1 | GetClipboardHistory | count=5 | Returns up to 5 strings |
| TC-INT-09 | P1 | ExportReport | Run | Returns IntentFile (PDF) |
| TC-INT-10 | P0 | App-not-running guard | Quit app, run intent | `.appNotRunning` error (no crash) |
| TC-INT-11 | P2 | Siri phrases | Speak phrase | Voice invocation works |
| TC-INT-12 | P1 | Action entity query | Shortcuts suggests actions | `suggestedEntities()` from ActionLibrary |
| **Unit** TC-INT-U1 | P1 | count clamp 1–10 | count=0 / count=99 | Clamped to range |
| **Unit** TC-INT-U2 | P1 | actionNotFound | bad stableKey | `.actionNotFound` thrown |

---

## 16.1 AI Assistant (F-046 — cloud providers)

**Files:** `Halo/Features/AIAssistant/*` · **E2E:** `HaloUITests/AIAssistantUITests.swift`

> BYO-key contract (US-5): with **no** API key configured, the assistant must
> surface guidance and make **no** network call. Never store or log keys outside
> the Keychain.

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-AI-01 | P1 | Module renders | Open AI Assistant | Composer + provider/model selector appear |
| TC-AI-02 | P1 | Provider picker | Open picker | Claude / OpenAI / Gemini selectable |
| TC-AI-03 | P0 | No key → no call | With no key set, send a prompt | "No API key set…" guidance; **no** request sent |
| TC-AI-04 | P2 | Quick-ask overlay | Press ⌘⇧I | Floating quick-ask panel toggles (manual — global hotkey) |
| TC-AI-05 | P0 | Tool safety classes | Model calls tools | `.read` tools auto-run; `.act` tools (run_smart_scan, export_health_report) confirm first |
| TC-AI-06 | P1 | Key stored in Keychain | Add a key in AI settings | Persisted to Keychain (`com.halo.mac.ai`), never plaintext on disk |
| **Unit** | — | Agent loop | — | Covered by `HaloTests/AIAssistantTests.swift` (provider parsing, loop, confirmation gate) |

---

## 17. Widget

**Files:** `HaloWidget.swift`, `HaloWidgetBundle.swift`, `HaloSharedData.swift`, `AppState.writeWidgetData()`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-WIDG-01 | P0 | Widget in gallery | App in /Applications, add widget | All 3 sizes appear in gallery |
| TC-WIDG-02 | P0 | Data pipeline | Validate plist (see CLAUDE.md cmd) | `haloWidgetData` present and fresh (≤2s stale) |
| TC-WIDG-03 | P0 | Reload cadence | Observe over an hour | reloadAllTimelines ~60/hr, never exhausts budget |
| TC-WIDG-04 | P1 | Small/medium/large | Add each size | Each renders correct layout |
| TC-WIDG-05 | P1 | Clipboard snippets | Copy items | Top 5 snippets forwarded to widget |
| TC-WIDG-06 | P1 | containerBackground guard | Run macOS 13 vs 14 | No crash; `if #available(macOS 14)` respected |
| TC-WIDG-07 | P1 | Token sync | Compare widget colours to app | Inlined widget tokens match DesignSystem |
| TC-WIDG-08 | P2 | Stale on app-quit | Quit app | Widget shows last data, no crash |
| **Unit** TC-WIDG-U1 | P0 | HaloWidgetData Codable | encode/decode | Backward-compatible roundtrip |
| **Unit** TC-WIDG-U2 | P1 | Timeline entries | getTimeline | 5 entries × 1 min apart |

---

## 18. Onboarding & Settings

**Files:** `OnboardingView.swift`, `@AppStorage`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-ONB-01 | P1 | First-run onboarding | Fresh install | Onboarding flow shows |
| TC-ONB-02 | P1 | Scan schedule setup | Set schedule in onboarding | Persists to scan UserDefaults |
| TC-ONB-03 | P1 | Menu bar style setup | Choose style | Persists `menuBarDisplayStyle` |
| TC-ONB-04 | P1 | Login item setup | Toggle launch-at-login | `SMAppService.mainApp` reflects |
| TC-ONB-05 | P1 | Analytics opt-in | Toggle analytics | `enableAnalytics` set; default false |
| TC-ONB-06 | P2 | Skip onboarding | Skip | App usable with defaults |
| TC-ONB-07 | P2 | Re-run onboarding | From settings | Re-displays flow |

---

## 19. Hotkeys

**File:** `HotkeyManager.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-HOT-01 | P0 | ⌘⇧V clipboard | Press | Clipboard picker toggles |
| TC-HOT-02 | P0 | ⌘⇧A actions | Press | Action picker toggles |
| TC-HOT-03 | P0 | AX permission (debug) | Fresh debug build | Prompts for Accessibility; works once granted |
| TC-HOT-04 | P1 | No conflict | Both hotkeys registered | Independent, no interference |
| TC-HOT-05 | P1 | Hotkey after sleep | Wake from sleep, press | Still functional |

---

## 20. System Controls (Mic/Camera/DDC/Display)

**Files:** `SystemControlsManager.swift`, `MicCameraControlsView.swift`, `DDCHelper.swift`, `HelperClient.swift`, `GPUMonitor.swift`, `SMCReader.swift`

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-SYS-01 | P1 | Mic toggle | Toggle mic | Microphone muted/unmuted |
| TC-SYS-02 | P1 | Camera privacy | Open camera settings | Opens privacy settings panel |
| TC-SYS-03 | P1 | DDC brightness | Adjust external monitor | DDCHelper sets brightness on external display |
| TC-SYS-04 | P2 | DDC unsupported display | Non-DDC monitor | Graceful no-op / message |
| TC-SYS-05 | P1 | Privileged helper | Action needing helper | HelperClient/XPC escalates correctly |
| TC-SYS-06 | P2 | GPU monitor | View GPU stats | Real utilisation or graceful fallback |
| TC-SYS-07 | P2 | Multi-display DDC | Two external monitors | Targets correct display |

---

## 21. Cross-Cutting / Non-Functional

### 21.1 Permissions

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-PERM-01 | P0 | No-permission launch | App launches; features needing perms prompt, don't crash |
| TC-PERM-02 | P1 | Full Disk Access | Cleanup/scan reach protected paths only with FDA |
| TC-PERM-03 | P1 | Notifications denied | Alerts still logged to AlertLog; no notification banner |
| TC-PERM-04 | P1 | Accessibility revoked mid-session | Hotkeys stop; graceful, re-prompt on next use |

### 21.2 Sentry

**File:** `HaloApp.configureSentry()`

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-SENTRY-01 | P0 | Disabled by default | `enableAnalytics=false` → Sentry inactive, no events |
| TC-SENTRY-02 | P1 | Opt-in activates | Enable analytics → Sentry initialises |
| TC-SENTRY-03 | P0 | DSN placeholder in source | `Info.plist["SentryDSN"]=="SENTRY_DSN_PLACEHOLDER"` (no real DSN committed) |
| TC-SENTRY-04 | P1 | No PII | `sendDefaultPii=false`; debug sampleRate 0.0 |

### 21.3 Resilience / Concurrency

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-RES-01 | P1 | Rapid module switching | No crash, no actor deadlock |
| TC-RES-02 | P1 | Concurrent scans | Two scans queued — coordinated, no data race |
| TC-RES-03 | P1 | Background→MainActor updates | UI updates from actors via MainActor.run, no purple runtime warnings |
| TC-RES-04 | P2 | Low disk space | Operations degrade gracefully |
| TC-RES-05 | P2 | System sleep/wake | Timers resume; metrics continue |

### 21.4 Accessibility & UI

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-A11Y-01 | P2 | Dark-only colours | No adaptive colours; consistent dark theme everywhere |
| TC-A11Y-02 | P2 | VoiceOver labels | Key controls have accessibility labels |
| TC-A11Y-03 | P2 | Keyboard navigation | Tab/arrow navigation works in lists |
| TC-A11Y-04 | P3 | Dynamic type | Text scales reasonably |

### 21.5 Data Safety (mandatory rules)

| ID | Priority | Title | Expected |
|----|----------|-------|----------|
| TC-SAFE-01 | P0 | Never removeItem | Audit: every deletion path uses `trashItem` |
| TC-SAFE-02 | P0 | Confirmation everywhere | Every destructive action shows a review sheet first |
| TC-SAFE-03 | P0 | Recoverable deletes | Deleted items appear in Trash, restorable |
| TC-SAFE-04 | P0 | Cancel deletes nothing | Cancelling any confirmation leaves all files + Trash unchanged (automated via `HaloTestFixtures` canaries) |
| TC-SAFE-05 | P0 | Tests never touch real files | E2E destructive flows act only on dummy fixtures in a temp sandbox; a guarded real path (e.g. Calculator.app) is asserted byte-for-byte untouched |

> **Automation note.** `TC-SAFE-02/04/05` are enforced end-to-end by the XCUITest
> suite in [`HaloUITests/`](../HaloUITests/README.md): the `HaloTestFixtures`
> harness seeds dummy canary files, snapshots real paths + the Trash, drives each
> destructive flow to its confirmation, cancels, and asserts nothing was deleted.
> `PortsUITests` spawns its own listener process as a live kill-canary.

---

## 22. Regression Checklist (per release)

Run all **P0** plus these high-risk areas after any change:

- [ ] Widget data pipeline still fresh (TC-WIDG-02/03)
- [ ] Signing order correct, app verifies (TC-SMOKE-02)
- [ ] No `removeItem` introduced (TC-SAFE-01)
- [ ] Hotkeys ⌘⇧V / ⌘⇧A both work (TC-HOT-01/02)
- [ ] VPN vs Private Relay detection (TC-PERF-21/22)
- [ ] Battery health ordering (TC-PERF-U1)
- [ ] Smart Scan schedule next-date (TC-SCAN-U1/U2)
- [ ] HaloShare round-trip with LocalSend (TC-SHARE-09)
- [ ] Sentry DSN placeholder intact (TC-SENTRY-03)
- [ ] All deletions confirm + trash (TC-SAFE-02/03)

---

## 23. Defect reporting template

```
ID:            DEF-<n>
Test case:     TC-<MODULE>-<NN>
Severity:      Blocker / Critical / Major / Minor
Build:         <commit / version>
Environment:   <macOS, silicon, config>
Preconditions: <state>
Steps:         <numbered>
Expected:      <expected result>
Actual:        <observed>
Evidence:      <screenshot / Console log / Sentry link>
Frequency:     Always / Intermittent (<x/y>)
```

---

### Coverage summary

| Area | Modules covered |
|------|-----------------|
| Core UI | Shell, Sidebar, Dashboard, Onboarding |
| Cleanup/Files | Cleanup, SpaceLens, Duplicates, Downloads, Large Files, Disk Health |
| Security | Protection, SignatureDatabase, Permissions, Sentry, Data Safety |
| Performance | Processes, CPU, Battery, Network, Speed Test, Sensors, Login Items, Idle Apps, GPU |
| Productivity | Clipboard, Snippets, Actions (108), Ports, Code Beautifier |
| Connectivity | HaloShare (LocalSend P2P) |
| System integration | Menu Bar, Widget, Siri Intents, Hotkeys, System Controls (Mic/Cam/DDC) |
| Automation | Smart Scan, Scheduler, Alerts, PDF Report |

> **Total numbered test cases:** 200+ across 23 sections, including dedicated unit-test (`-U`) rows for all pure-logic components (health score, fuzzy search, VPN detection, battery label, signature lookup, duplicate hashing, scheduler dates, format renderer, lsof parser, Codable roundtrips).
