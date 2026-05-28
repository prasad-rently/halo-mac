# Halo — Feature Roadmap & Execution Pipeline

> **How this document works**
>
> Every new feature lives here as a self-contained card. Features are worked **one at a time, FIFO** — pick the top card marked `📋 Queued`, implement it, flip its status to `✅ Done`, then move to the next.
>
> Each card is complete enough that a developer (or AI agent) with no prior context can implement and test the feature without reading anything else.
>
> To **add a new feature**, append it at the bottom of the Queued section. To **reprioritise**, move the card up or down in the queue. Never remove a Done card — it serves as the implementation record.

---

## Pipeline Status

| ID | Feature | Status | Effort | Depends On |
|---|---|---|---|---|
| [F-001](#f-001--gpu-metrics-dashboard-card) | GPU Metrics Dashboard Card | ✅ Done | 0.5 d | Phase 3 merged |
| [F-002](#f-002--xpc-helper-privileged-operations) | XPC Helper — Privileged Ops | ✅ Done | 3 d | none |
| [F-003](#f-003--storekitmit-2-promanager) | StoreKit 2 ProManager | ⏭ Skipped (user) | 3 d | none |
| [F-004](#f-004--signature-database--real-malware-definitions) | Signature Database | ✅ Done | 3 d | none |
| [F-005](#f-005--bgscheduler--scheduled-smart-scan) | BGScheduler — Scheduled Smart Scan | ✅ Done | 1 d | none |
| [F-006](#f-006--sentry-crash-reporting) | Sentry Crash Reporting | ✅ Done | 0.5 d | none |
| [F-007](#f-007--privacyinfoxcprivacy--app-store-assets) | PrivacyInfo + App Store Assets | ⏭ Skipped (user) | 2 d | F-002, F-003 |
| [F-008](#f-008--menu-bar-display-styles-bardot-mode) | Menu Bar Display Styles | ✅ Done | 1.5 d | Phase 3 merged |
| [F-009](#f-009--login-items--real-smappservice-integration) | Login Items — Real SMAppService | ✅ Done | 2 d | none |
| [F-010](#f-010--applications-deep-uninstall--real-leftover-scan) | Applications Deep Uninstall | ✅ Done | 2.5 d | none |
| [F-011](#f-011--in-app-alert-history-log) | In-App Alert History Log | ✅ Done | 1 d | F-001, Phase 3 |
| [F-012](#f-012--maintenance-tasks--xpc-real-execution) | Maintenance Tasks — Real Execution | ✅ Done | 1 d | F-002 |
| [F-013](#f-013--icloud-clipboard-sync) | iCloud Clipboard Sync | ⏭ Skipped (user) | 5 d | F-003 |
| [F-014](#f-014--pdf-health-report-export) | PDF Health Report Export | ✅ Done | 2 d | none |
| [F-015](#f-015--custom-scan-schedule-ui) | Custom Scan Schedule UI | ✅ Done | 1 d | F-005 |
| [F-016](#f-016--permission-auditor) | Permission Auditor | 💡 Future Idea | ~3 d | F-002 (release) |
| [F-017](#f-017--network-traffic-monitor-app-level-firewall-companion) | Network Traffic Monitor | 💡 Future Idea | ~5 d | none |
| [F-018](#f-018--privacy-data-exposure-scanner) | Privacy Data Exposure Scanner | 💡 Future Idea | ~3 d | none |
| [F-019](#f-019--security-posture-dashboard) | Security Posture Dashboard | 💡 Future Idea | ~1.5 d | none |
| [F-020](#f-020--smart-disk-health-monitor) | S.M.A.R.T. Disk Health Monitor | 💡 Future Idea | ~3 d | none |
| [F-021](#f-021--app-usage--screen-time-analytics) | App Usage & Screen Time Analytics | 💡 Future Idea | ~3 d | none |
| [F-022](#f-022--time-machine-backup-health-monitor) | Time Machine Backup Health Monitor | 💡 Future Idea | ~1.5 d | AlertManager |
| [F-023](#f-023--memory-leak--app-bloat-tracker) | Memory Leak & App Bloat Tracker | 💡 Future Idea | ~3 d | ProcessMonitor |
| [F-024](#f-024--browser-cleaner) | Browser Cleaner | 💡 Future Idea | ~2 d | none |
| [F-025](#f-025--duplicate-photos-finder-perceptual-hash) | Duplicate Photos Finder (pHash) | 💡 Future Idea | ~5 d | DuplicateDetector |
| [F-026](#f-026--downloads-folder-organiser) | Downloads Folder Organiser | 💡 Future Idea | ~2 d | AppScanner |
| [F-027](#f-027--snippet-manager-clipboard-evolution) | Snippet Manager | 💡 Future Idea | ~3 d | Clipboard module |
| [F-028](#f-028--focus-session-companion) | Focus Session Companion | 💡 Future Idea | ~3 d | MenuBarDisplayStyle |
| [F-029](#f-029--scheduled-reports--weekly-digest) | Scheduled Reports & Weekly Digest | 💡 Future Idea | ~2 d | ReportGenerator |
| [F-030](#f-030--icloud-storage-analyser) | iCloud Storage Analyser | 💡 Future Idea | ~4 d | none |

---

## Completed Features (historical record)

| ID | Feature | PR / Commit |
|---|---|---|
| ✅ | Dashboard — health ring + live metrics | Initial commit |
| ✅ | Cleanup — 10-category file scanner | `fix/cleanup-bugs` PR |
| ✅ | Protection — real malware scanner + browser cleaner + launch agents | `fix/protection-bugs` PR #3 |
| ✅ | Performance — RAM optimiser + login items + maintenance | Initial commit |
| ✅ | Applications — installed app list + uninstall | Initial commit |
| ✅ | Files — SpaceLens + Duplicate Finder + Large Files | Initial commit |
| ✅ | Clipboard — history, pin, filter, quick-picker (⌘⇧V) | Initial commit |
| ✅ | Menu Bar Extra — live CPU % + popover | Initial commit |
| ✅ | Onboarding — 3-step + permission prompts | Initial commit |
| ✅ | Settings — shortcut recorder | Initial commit |
| ✅ | macOS Widget — Small / Medium / Large | Initial commit |
| ✅ | Widget live-data pipeline (App Group, 60-s reload) | Initial commit |
| ✅ | Dual entitlements (debug non-sandboxed / release sandboxed) | Initial commit |
| ✅ | Phase 2 · Display Brightness + Night Shift | PR branch `feat/phase2-display-brightness` |
| ✅ | Phase 3 · 12 monitoring features (P3-01 → P3-12) | PR #4 `feat/phase3-monitoring` |
| ✅ | F-001 · GPU Metrics Dashboard Card | PR #4 `feat/phase3-monitoring` |
| ✅ | F-002 · XPC Helper — Privileged Ops | `feat/f002-xpc-helper` — 11 tests pass |
| ✅ | F-004 · Signature Database | `feat/f004-signature-database` |
| ✅ | F-005 · BGTaskScheduler — Scheduled Smart Scan | `feat/f005-bg-scan-scheduler` |
| ✅ | F-006 · Sentry Crash Reporting | `feat/f006-sentry` |
| ✅ | F-008 · Menu Bar Display Styles (icon/text/bars/dot) | `feat/f008-menubar-display-styles` |
| ✅ | F-009 · Login Items Real — plist + SMAppService | `feat/f009-login-items-real` |
| ✅ | F-010 · Applications Deep Uninstall — 12-path leftover scan | `feat/f010-deep-uninstall` |
| ✅ | F-011 · In-App Alert History Log | `feat/f011-alert-history` |
| ✅ | F-012 · Maintenance Tasks Real | completed via F-002 |
| ✅ | F-014 · PDF Health Report Export | `feat/f014-pdf-health-report` |
| ✅ | F-015 · Custom Scan Schedule UI | `feat/f015-custom-scan-schedule` |

---

---

# Queued Features — Detailed Execution Plans

---

## F-001 · GPU Metrics Dashboard Card

**Status:** 📋 Queued — #1  
**Effort:** 0.5 day  
**Branch naming:** `feat/f001-gpu-dashboard-card`  
**Depends on:** Phase 3 merged (GPUMonitor.swift already exists)

### Why
`GPUMonitor.swift` was created in Phase 3 but never connected to a visible UI. Users with M-series or discrete GPUs want to see GPU utilisation alongside CPU/RAM on the Dashboard.

### What it delivers
- New GPU metric card in the Dashboard `HealthAndMetrics` grid (replaces or supplements one of the existing 3-column cards)
- Shows GPU utilisation %, VRAM used/total
- Foreground-active: timer created on Dashboard `onAppear`, destroyed on `onDisappear`

### Implementation steps

1. **Create `Halo/Features/Dashboard/GPUCard.swift`**
   ```swift
   struct GPUCard: View {
       @State private var monitor = GPUMonitor()
       @State private var stats: [GPUMonitor.GPUStats] = []
       @State private var timer: Timer?

       var body: some View { ... }
       // onAppear: start 2-s timer calling monitor.sample()
       // onDisappear: invalidate timer
   }
   ```

2. **Modify `DashboardView.swift` — `HealthAndMetrics` view**
   - Add `GPUCard()` below the existing 3 metric cards
   - Only render if `stats` is non-empty (so Mac mini Intel / no GPU shows nothing)

3. **Add `GPUCard.swift` to `project.pbxproj`**
   - PBXFileReference UUID: `000000000000000000001102`
   - PBXBuildFile UUID: `000000000000000000001103`
   - Add to `Sources` group and `PBXSourcesBuildPhase`

4. **Update `CLAUDE.md` Modules Status table** — mark GPU as ✅

### Test plan
- [ ] Open Dashboard → GPU card appears (on any Mac with IOAccelerator)
- [ ] Navigate away from Dashboard → timer stops (verify in Instruments: CPU drops to zero from GPUMonitor)
- [ ] On a Mac without discrete GPU — card is hidden, no crash
- [ ] GPU % updates in real time when running a GPU-intensive app (e.g. Metal benchmark)

### Acceptance criteria
- GPU card renders on Dashboard with non-zero utilisation when GPU is in use
- No crash on Intel Mac without discrete GPU
- No background timer when Dashboard is not visible

---

## F-002 · XPC Helper — Privileged Operations

**Status:** 📋 Queued — #2  
**Effort:** 3 days  
**Branch naming:** `feat/f002-xpc-helper`  
**Depends on:** none

### Why
The sandboxed release build cannot call `dscacheutil -flushcache`, `purge`, or `diskutil repairPermissions` directly. An XPC service runs as a separate process with the necessary privileges, enabling the Maintenance and Performance modules to work in production.

### What it delivers
- New Xcode target `HaloHelper` (XPC service, bundle ID `com.halo.mac.helper`)
- Shared protocol file compiled into both targets
- Main app communicates via `NSXPCConnection`
- Maintenance tasks and Free RAM buttons call the real system commands
- `SMAppService` registration so the helper launches automatically

### Implementation steps

1. **Add `HaloHelper/` target in Xcode**
   - Product type: `com.apple.xpc-service`
   - Bundle ID: `com.halo.mac.helper`
   - Minimum deployment: macOS 13.0

2. **Create `Shared/HaloHelperProtocol.swift`** (compiled into BOTH targets)
   ```swift
   @objc protocol HaloHelperProtocol {
       func flushDNS(reply: @escaping (Bool) -> Void)
       func purgeRAM(reply: @escaping (Double) -> Void)   // returns MB freed
       func rebuildSpotlight(reply: @escaping (Bool) -> Void)
       func clearFontCache(reply: @escaping (Bool) -> Void)
   }
   ```

3. **Create `HaloHelper/HaloHelperImpl.swift`**
   ```swift
   class HaloHelperImpl: NSObject, HaloHelperProtocol {
       func flushDNS(reply: @escaping (Bool) -> Void) {
           // shell("dscacheutil -flushcache && killall -HUP mDNSResponder")
       }
       func purgeRAM(reply: @escaping (Double) -> Void) {
           // shell("memory_pressure -l critical") or malloc_zone_pressure_relief
       }
   }
   ```

4. **Create `HaloHelper/HaloHelper.swift`** — `NSXPCListener` delegate
   ```swift
   class HaloHelper: NSObject, NSXPCListenerDelegate {
       func listener(_ listener: NSXPCListener,
                     shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
           conn.exportedInterface = NSXPCInterface(with: HaloHelperProtocol.self)
           conn.exportedObject = HaloHelperImpl()
           conn.resume()
           return true
       }
   }
   ```

5. **Create `HaloHelper/main.swift`**
   ```swift
   let delegate = HaloHelper()
   let listener = NSXPCListener.service()
   listener.delegate = delegate
   listener.resume()
   ```

6. **Create `HaloHelper/Info.plist`** — `NSXPCServiceType = Application`

7. **Modify `Halo/App/AppState.swift`** — add `HelperClient` class
   ```swift
   final class HelperClient {
       private lazy var connection: NSXPCConnection = { ... }()
       func flushDNS() async -> Bool { ... }
       func purgeRAM() async -> Double { ... }
   }
   ```

8. **Modify `PerformanceView.swift` → `PerformanceViewModel`**
   - `freeRAM()`: replace simulation with `await helperClient.purgeRAM()`
   - `runMaintenance(_ task:)`: replace sleep simulation with real XPC calls

9. **Register helper at launch in `HaloApp.swift`**
   ```swift
   SMAppService.loginItem(identifier: "com.halo.mac.helper").register()
   ```

10. **Add `HaloHelper.entitlements`** — `com.apple.security.temporary-exception.mach-lookup.global-name`

11. **Update `project.pbxproj`** — new target, build phases, entitlements, embed copy phase

### Test plan
- [ ] **DNS flush**: Run → open Terminal → `nslookup google.com` before; flush; verify cache cleared (different resolution time)
- [ ] **Purge RAM**: Open Activity Monitor; click Free RAM → `ramFreedMB` shows a real number > 0
- [ ] **Spotlight rebuild**: `mds` process activity spikes after running the task
- [ ] **XPC crash safety**: Kill the helper process mid-operation → main app does not crash, shows error gracefully
- [ ] **Sandbox enforcement**: Archive build (sandboxed) uses XPC path; debug (non-sandbox) may call directly
- [ ] **SMAppService**: After first run, helper appears in Login Items in System Settings

### Acceptance criteria
- All 4 maintenance tasks run real system commands (not simulations) in the release build
- Free RAM reports actual freed memory
- Killing the helper process mid-flight shows a user-facing error, not a crash

---

## F-003 · StoreKit 2 ProManager

**Status:** 📋 Queued — #3  
**Effort:** 3 days  
**Branch naming:** `feat/f003-storekit-promanager`  
**Depends on:** none (AppState.isPro already wired)

### Why
Monetisation. The app is free with a Pro upgrade. Without a working purchase flow, Pro-gated features (clipboard cap, Smart Scan frequency, Protection scan depth) cannot be enforced in production.

### What it delivers
- `Core/ProManager.swift` — StoreKit 2 product fetch, purchase, restore
- `Features/Paywall/PaywallView.swift` — sheet shown when hitting a Pro gate
- `AppState.isPro` set from live transaction state
- Two products: annual (₹999/yr) and lifetime (₹2,499)

### Product IDs
```
com.halo.pro.annual     ₹999/year
com.halo.pro.lifetime   ₹2,499 one-time
```

### Pro gates (what's restricted for free users)
| Feature | Free | Pro |
|---|---|---|
| Clipboard history items | 20 | 500 |
| Smart Scan | Once/week | Unlimited |
| Protection deep scan | ❌ | ✅ |
| Duplicate Finder | ❌ | ✅ |
| Disk SMART check | ❌ | ✅ |

### Implementation steps

1. **Create `Halo/Core/ProManager.swift`**
   ```swift
   @MainActor
   final class ProManager: ObservableObject {
       @Published var isPro: Bool = false
       @Published var products: [Product] = []
       @Published var purchaseState: PurchaseState = .idle

       enum PurchaseState { case idle, purchasing, failed(String) }

       func load() async {
           products = (try? await Product.products(for: productIDs)) ?? []
           await checkEntitlement()
       }

       func purchase(_ product: Product) async { ... }
       func restore() async { ... }

       private func checkEntitlement() async {
           for id in productIDs {
               if let _ = await Transaction.currentEntitlement(for: id) {
                   isPro = true; return
               }
           }
           isPro = false
       }

       private let productIDs = ["com.halo.pro.annual", "com.halo.pro.lifetime"]
   }
   ```

2. **Create `Halo/Features/Paywall/PaywallView.swift`**
   - Full-screen sheet with feature comparison table
   - Annual and lifetime product cards with price from StoreKit
   - "Restore Purchase" button
   - Dismiss button (closes sheet, no purchase)

3. **Modify `HaloApp.swift`** — instantiate `ProManager` as `@StateObject`, inject into environment

4. **Modify `AppState.swift`** — subscribe to `ProManager.$isPro` to sync `appState.isPro`

5. **Enforce gates:**
   - `ClipboardView.swift`: cap at 20 items when `!appState.isPro` (show "Upgrade for 500 items" banner)
   - `SmartScanView.swift`: check last scan date, show paywall if < 7 days and `!isPro`
   - `ProtectionView.swift` deep scan button: show paywall if `!isPro`
   - `DiskHealthSection.swift` SMART button: show paywall if `!isPro`

6. **Add StoreKit configuration file** `Halo.storekit` for local testing (Xcode scheme → StoreKit Configuration)

7. **Update `project.pbxproj`** — add `PaywallView.swift`

### Test plan
- [ ] **Sandbox purchase**: Configure Xcode StoreKit file → tap Annual → StoreKit test purchase completes → `isPro = true`
- [ ] **Restore**: Set `isPro = false` manually → tap Restore → isPro restored from existing transaction
- [ ] **Gate: clipboard**: Free mode → add 21st item → capped at 20 → upgrade banner shown
- [ ] **Gate: Smart Scan**: Run scan → immediately run again (free) → paywall sheet appears
- [ ] **Paywall dismiss**: Tap × → sheet closes → feature remains locked
- [ ] **Price display**: Product prices show correctly from StoreKit (not hardcoded)
- [ ] **Receipt validation**: Delete and reinstall app → restore restores Pro status

### Acceptance criteria
- Annual and lifetime purchases complete end-to-end in StoreKit sandbox
- All 5 Pro gates enforce the free tier limit
- Restoring purchases on a clean install recovers Pro status

---

## F-004 · Signature Database — Real Malware Definitions

**Status:** 📋 Queued — #4  
**Effort:** 3 days  
**Branch naming:** `feat/f004-signature-database`  
**Depends on:** none (ProtectionScanner.swift has an inline list; this replaces it)

### Why
`ProtectionScanner.swift` contains a hardcoded list of ~40 known threat signatures. A bundled JSON database with a delta-update endpoint allows the list to grow without an app update, and provides richer metadata (description, removal steps, risk level).

### What it delivers
- `Halo/Resources/signatures.json` — seed database (bundled in app)
- `Core/Scanner/SignatureDatabase.swift` — loads and queries signatures
- HTTPS delta update from `https://api.halo.mac/signatures/latest.json`
- Version tracking in `UserDefaults` — only downloads diffs
- `ProtectionScanner.swift` updated to use `SignatureDatabase` instead of inline array

### JSON schema
```json
{
  "version": 1,
  "updated": "2025-01-01",
  "threats": [
    {
      "id": "mac.adware.genieo",
      "name": "Genieo Adware",
      "kind": "adware",
      "risk": "high",
      "bundleIds": ["com.genieo.engine", "com.genieoinnovation.macextension"],
      "filePaths": ["/Library/LaunchAgents/com.genieo.engine.plist"],
      "sha256": ["abc123..."],
      "description": "Injects ads into Safari, Chrome, and Firefox.",
      "removalNote": "Delete files listed in filePaths and reboot."
    }
  ]
}
```

### Implementation steps

1. **Create `Halo/Resources/signatures.json`** — seed with all 40+ existing inline signatures converted to JSON format (plus descriptions and removal notes)

2. **Create `Halo/Core/Scanner/SignatureDatabase.swift`**
   ```swift
   actor SignatureDatabase {
       struct Threat: Codable, Sendable {
           let id: String; let name: String; let kind: String
           let risk: String; let bundleIds: [String]; let filePaths: [String]
           let sha256: [String]; let description: String; let removalNote: String
       }

       private var threats: [Threat] = []
       private let version = "signatureDBVersion"

       func load() async {    // loads from bundle, then checks for update
           loadBundled()
           await checkForUpdate()
       }

       func matches(bundleId: String) -> Threat?
       func matches(sha256: String) -> Threat?
       func matches(filePath: String) -> Threat?
   }
   ```

3. **`loadBundled()`** — reads `signatures.json` from `Bundle.main`, decodes, stores in `threats`

4. **`checkForUpdate()`** — `GET https://api.halo.mac/signatures/latest.json`
   - Compare `version` field vs `UserDefaults.integer(forKey: "signatureDBVersion")`
   - If newer: decode and replace `threats`; update UserDefaults version
   - Use `URLSession` with `ephemeralConfiguration` (no disk cache)
   - On network failure: silently continue with bundled DB

5. **Modify `ProtectionScanner.swift`**
   - Remove inline `signatures` array
   - Inject `SignatureDatabase` instance
   - Replace `contains()` checks with `database.matches(bundleId:)` etc.

6. **Add `signatures.json` to `project.pbxproj` Resources** (not Sources)

7. **Add update check on app launch in `HaloApp.swift`** (fire-and-forget `Task`)

### Test plan
- [ ] **Bundled load**: Fresh install with no network → Protection scan runs → threats detected from bundled JSON
- [ ] **Update check**: Point update URL to a local mock server returning version 99 → DB updates in memory → re-scan picks up new signature
- [ ] **No-network graceful**: Disable network → launch app → no crash, bundled DB used
- [ ] **Version cache**: Update to v2 → relaunch → no redundant network request (UserDefaults version = 2)
- [ ] **SHA-256 match**: Copy a test file with a known SHA-256 to `~/Desktop` → scan detects it
- [ ] **Bundle ID match**: Install a test app with a flagged bundle ID → scan flags it

### Acceptance criteria
- Protection scan uses JSON-backed signatures (not hardcoded Swift array)
- Delta update downloads only when remote version > local version
- App works fully offline using bundled database

---

## F-005 · BGScheduler — Scheduled Smart Scan

**Status:** 📋 Queued — #5  
**Effort:** 1 day  
**Branch naming:** `feat/f005-bgscheduler`  
**Depends on:** none

### Why
Users want Halo to scan automatically in the background (e.g., once a week) without needing to open the app. `BGProcessingTaskRequest` on macOS 13+ enables this.

### What it delivers
- Weekly background Smart Scan triggered by `BGTaskScheduler`
- Local notification on completion: "Your Mac is clean" or "X items found"
- User-configurable frequency in Settings (daily / weekly / off)
- Next scan date shown in Dashboard header

### Implementation steps

1. **Modify `Halo/Resources/Info.plist`** — register task identifier:
   ```xml
   <key>BGTaskSchedulerPermittedIdentifiers</key>
   <array>
       <string>com.halo.smartscan</string>
   </array>
   ```

2. **Modify `HaloApp.swift` → `init()`**
   ```swift
   BGTaskScheduler.shared.register(
       forTaskWithIdentifier: "com.halo.smartscan",
       using: nil
   ) { task in
       handleBackgroundScan(task: task as! BGProcessingTask)
   }
   scheduleNextBackgroundScan()
   ```

3. **Add `scheduleNextBackgroundScan()` helper** in `HaloApp.swift`
   ```swift
   func scheduleNextBackgroundScan() {
       let freq = UserDefaults.standard.string(forKey: "scanFrequency") ?? "weekly"
       guard freq != "off" else { return }
       let interval: TimeInterval = freq == "daily" ? 86400 : 604800
       let request = BGProcessingTaskRequest(identifier: "com.halo.smartscan")
       request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
       request.requiresNetworkConnectivity = false
       request.requiresExternalPower = false
       try? BGTaskScheduler.shared.submit(request)
   }
   ```

4. **Add `handleBackgroundScan(task:)` in `HaloApp.swift`**
   ```swift
   func handleBackgroundScan(task: BGProcessingTask) {
       let scanTask = Task {
           let coordinator = ScanCoordinator()
           let result = await coordinator.runFullScan()
           scheduleNextBackgroundScan()
           sendScanCompletionNotification(result)
           task.setTaskCompleted(success: true)
       }
       task.expirationHandler = { scanTask.cancel() }
   }
   ```

5. **Add `sendScanCompletionNotification(_ result:)`** — uses `UNUserNotificationCenter`

6. **Modify `SettingsView.swift`** — "Scheduled Scans" section already exists; hook it to `scheduleNextBackgroundScan()` on picker change

7. **Modify `DashboardView.swift` — `DashHeader`** — show "Next scan: in 6 days" from `UserDefaults`

### Test plan
- [ ] **Schedule**: Change Settings frequency to "daily" → verify `BGTaskScheduler` has a pending request (use `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.halo.smartscan"]` in lldb)
- [ ] **Simulate trigger**: Use Xcode debugger `BGTaskScheduler` simulate → scan runs → completion notification fires
- [ ] **Off setting**: Set to "Off" → no pending BGTask request registered
- [ ] **Re-schedule**: After simulated scan runs → next scan is re-queued
- [ ] **Expiration handler**: Task expiry called → scan cancels gracefully, no hang

### Acceptance criteria
- Weekly scan runs in background without app being open
- Notification appears on completion
- "Off" setting prevents any background scan

---

## F-006 · Sentry Crash Reporting

**Status:** 📋 Queued — #6  
**Effort:** 0.5 day  
**Branch naming:** `feat/f006-sentry`  
**Depends on:** none

### Why
Zero visibility into production crashes. Sentry provides symbolicated crash reports, performance traces, and breadcrumbs without requiring users to send feedback.

### What it delivers
- Sentry iOS/macOS SDK via SPM
- Initialised in `HaloApp.init` with DSN from `Info.plist`
- `SENTRY_DSN` read at runtime (not hardcoded)
- `tracesSampleRate = 0.1` (10% of sessions traced)
- **No user-identifying data** logged (no clipboard content, no file paths, no IP addresses)

### Implementation steps

1. **`Package.swift`** — add dependency:
   ```swift
   .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
   ```
   And add `SentrySwiftUI` to `Halo` target dependencies.

2. **`Halo/Resources/Info.plist`** — add key:
   ```xml
   <key>SENTRY_DSN</key>
   <string>$(SENTRY_DSN)</string>
   ```
   Set `SENTRY_DSN` in the Xcode scheme's environment variables (or xcconfig).

3. **`HaloApp.swift` → `init()`**:
   ```swift
   import Sentry
   SentrySDK.start { options in
       options.dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String
       options.tracesSampleRate = 0.1
       options.enableMetricKit = true
       options.attachScreenshot = false   // privacy
       options.attachViewHierarchy = false
   }
   ```

4. **Privacy guard** — confirm no call sites pass clipboard text, file paths, or IP addresses to Sentry breadcrumbs

5. **`Halo/Resources/PrivacyInfo.xcprivacy`** — verify Sentry SDK's required keys are declared (NSPrivacyAccessedAPIType)

### Test plan
- [ ] **Crash capture**: Intentionally crash in debug (e.g. `fatalError("test")`) → Sentry dashboard shows crash within 60 s
- [ ] **DSN missing**: Remove `SENTRY_DSN` env var → app launches without crashing (Sentry init graceful with nil DSN)
- [ ] **No PII**: Run clipboard copy → verify Sentry event payload contains no clipboard content
- [ ] **Performance trace**: Open Dashboard → navigate through all tabs → Sentry shows a transaction with spans
- [ ] **Build succeeded**: `xcodebuild` with Sentry package resolves without errors

### Acceptance criteria
- First crash from a production build appears symbolicated in Sentry within 5 minutes
- No user content (clipboard, file names) in any Sentry payload

---

## F-007 · PrivacyInfo.xcprivacy + App Store Assets

**Status:** 📋 Queued — #7  
**Effort:** 2 days  
**Branch naming:** `feat/f007-appstore-assets`  
**Depends on:** F-002 (XPC entitlements finalised), F-003 (Pro monetisation)

### Why
App Store submission requires `PrivacyInfo.xcprivacy` declarations for all APIs used, correct entitlements for the archive scheme, and five required screenshot sizes. Without these, App Store Connect rejects the binary.

### What it delivers
- Completed `PrivacyInfo.xcprivacy` declaring all API categories
- Archive scheme set to use `Halo.entitlements` (sandboxed), not `Halo-Debug.entitlements`
- Five App Store screenshots (1440 × 900) — Dashboard, Cleanup, Clipboard, Files, Widget
- `NSHumanReadableDescription` strings for all requested entitlements
- Notarisation workflow documented

### Implementation steps

1. **`Halo/Resources/PrivacyInfo.xcprivacy`** — fill in all required `NSPrivacyAccessedAPITypes`:
   ```xml
   <!-- NSPasteboard — read clipboard history -->
   <!-- IOKit — battery, SMC, disk, GPU stats -->
   <!-- FileManager — Cleanup, SpaceLens, Duplicates -->
   <!-- NSWorkspace — Applications module, Launch Agents -->
   <!-- UserNotifications — AlertManager -->
   <!-- Network.framework — speed test, VPN monitor -->
   ```

2. **`Halo.entitlements`** (release) — review and confirm:
   - `com.apple.security.app-sandbox = YES`
   - `com.apple.security.files.user-selected.read-write = YES`
   - `com.apple.security.network.client = YES`
   - `com.apple.security.files.downloads.read-write = YES`
   - `com.apple.security.application-groups = [group.com.halo.mac]`
   - No debug-only keys present

3. **Xcode Archive scheme** — set code signing entitlements to `Halo.entitlements` (not Debug)

4. **Screenshots** — capture five 1440 × 900 PNG screenshots:
   - Dashboard (health ring + metrics + GPU card)
   - Cleanup (scan results with categories)
   - Clipboard (history list + pinned items)
   - Files (SpaceLens tree map)
   - Widget (large size on desktop)
   Use Xcode Simulator or `screencapture` + resize to exact 1440 × 900

5. **App Preview** — optional 30-second MP4; capture with QuickTime Player screen recording

6. **App Store Connect metadata** — prepare:
   - Privacy policy URL: `https://halo.mac/privacy`
   - Support URL: `https://halo.mac/support`
   - Release notes for v1.0

7. **Notarisation workflow script** — add `scripts/notarise.sh`:
   ```bash
   xcrun notarytool submit Halo.pkg \
     --apple-id "$APPLE_ID" \
     --team-id R7S39UR27F \
     --password "$APP_SPECIFIC_PASSWORD" \
     --wait
   ```

### Test plan
- [ ] **Sandbox audit**: Archive build → run in sandbox → all features work (no private-API crashes)
- [ ] **App Group**: Widget reads live data in sandboxed Archive build
- [ ] **Privacy manifest**: Upload to App Store Connect → no API usage rejection warning
- [ ] **Screenshot dimensions**: `file screenshots/*.png` → all show `1440 x 900`
- [ ] **Notarisation**: Submit `.pkg` → `notarytool` returns `Accepted`
- [ ] **Gatekeeper**: Install notarised DMG → no "unidentified developer" warning

### Acceptance criteria
- Archive build passes App Store Connect binary validation without warnings
- All five screenshots meet Apple dimensions
- Notarised `.pkg` passes `spctl --assess`

---

## F-008 · Menu Bar Display Styles (Bar / Dot Mode)

**Status:** 📋 Queued — #8  
**Effort:** 1.5 days  
**Branch naming:** `feat/f008-menubar-styles`  
**Depends on:** Phase 3 merged (P3-09 added module visibility toggles)

### Why
Stats' killer feature is the highly customisable menu bar — users can choose between text percentage, a thin fill bar, or a colour-coded dot per module. Halo's menu bar currently shows only text. Adding styles makes it competitive while adding zero background overhead (same data, different rendering).

### What it delivers
- Three display styles per module: `text` (current default), `bar` (vertical fill), `dot` (colour-coded)
- Style picker per module in Settings → Menu Bar
- `@AppStorage` persistence — survives relaunch
- No new data collection — styles are purely presentational

### Models to add (in `Models.swift`)
```swift
enum MenuBarDisplayStyle: String, Codable, CaseIterable {
    case text    // "42%"
    case bar     // thin capsule, filled proportionally
    case dot     // 8px circle, colour = green/amber/red threshold
}

struct MenuBarModuleConfig: Codable {
    var module: String        // "cpu", "ram", "net", "battery", "disk"
    var isEnabled: Bool
    var style: MenuBarDisplayStyle
}
```

### Implementation steps

1. **`Models.swift`** — add `MenuBarDisplayStyle` and `MenuBarModuleConfig` as above

2. **`MenuBarView.swift` — `MenuBarIconView`** (the label shown in the system menu bar)
   - Currently shows just the animated icon. Extend to also render enabled module values.
   - Read `[MenuBarModuleConfig]` from `@AppStorage("menuBarModules")`
   - Render as `HStack` of styled chips next to the icon:
     ```swift
     // text style: Text("42%")
     // bar style: Capsule().fill(color).frame(width: 3, height: 12)
     // dot style: Circle().fill(thresholdColor).frame(width: 8, height: 8)
     ```

3. **`SettingsView.swift` — Menu Bar tab**
   - Replace simple toggles with a `List` of `MenuBarModuleConfigRow` per module
   - Each row: module name + enabled toggle + style picker (Segmented: Text / Bar / Dot)
   - Save to `@AppStorage("menuBarModules")` as JSON-encoded `[MenuBarModuleConfig]`

4. **Add `MenuBarStyleChip` view** — a small reusable component for rendering one module in the menu bar in any of the three styles

5. **Threshold colours for dot mode:**
   - CPU > 85%: red; > 60%: amber; else: green
   - RAM > 85%: red; > 70%: amber; else: green
   - Battery < 10%: red; < 20%: amber; else: green
   - Network: always accent blue

### Test plan
- [ ] Switch CPU to `bar` style → thin vertical bar appears next to icon in system menu bar
- [ ] Switch RAM to `dot` style → coloured dot appears; goes red when RAM > 85%
- [ ] Disable Battery module → battery value disappears from menu bar label
- [ ] Relaunch app → style preferences persist
- [ ] All 3 modules enabled in `bar` style → menu bar label stays within 60 pts width (no overflow)

### Acceptance criteria
- All three styles render correctly for all 5 modules
- Style preferences persist across app restarts
- No layout overflow in the system menu bar with multiple modules visible

---

## F-009 · Login Items — Real SMAppService Integration

**Status:** 📋 Queued — #9  
**Effort:** 2 days  
**Branch naming:** `feat/f009-login-items-real`  
**Depends on:** none

### Why
`PerformanceView` currently displays hardcoded sample login items. Real `SMAppService` integration reads the system's actual login items and lets users enable/disable them.

### What it delivers
- `Core/Scanner/LoginItemScanner.swift` — reads real login items via `SMAppService` (macOS 13+)
- Enumerate `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`
- Toggle enable/disable via `SMAppService.loginItem(identifier:).register()/.unregister()`
- `PerformanceViewModel` updated to use real data

### Implementation steps

1. **Create `Halo/Core/Scanner/LoginItemScanner.swift`**
   ```swift
   actor LoginItemScanner {
       func scan() async -> [LoginItem] {
           var items: [LoginItem] = []
           // 1. SMAppService.allServices() — registered login items
           // 2. Enumerate LaunchAgent plist paths manually for non-SMApp items
           // 3. Read each plist: Label, ProgramArguments, Disabled key
           return items
       }

       func setEnabled(_ item: LoginItem, enabled: Bool) async -> Bool {
           // SMAppService.loginItem(identifier: item.bundleIdentifier).register() / .unregister()
       }
   }
   ```

2. **Plist paths to enumerate:**
   ```
   ~/Library/LaunchAgents/
   /Library/LaunchAgents/
   /Library/LaunchDaemons/
   ```
   For each `.plist` file: parse with `PropertyListSerialization`, extract `Label`, `ProgramArguments[0]`, `Disabled` key.

3. **`LoginItem` model extension** — add `plistURL: URL` field to existing model

4. **`PerformanceViewModel`** — replace `loginItems = LoginItem.samples` with `loginItems = await scanner.scan()`

5. **`toggleLoginItem(_ item:)`** — call `scanner.setEnabled(item, enabled: !item.isEnabled)`

6. **Update `project.pbxproj`** — add `LoginItemScanner.swift`

### Test plan
- [ ] Open Performance tab → Login Items section shows real apps (Spotify, Dropbox, etc.) not sample data
- [ ] Toggle an item off → verify in System Settings → General → Login Items that it is disabled
- [ ] Toggle back on → re-enabled in System Settings
- [ ] Machine with no third-party login items → section shows "None found" empty state
- [ ] Suspicious item detection: item with no bundle name or path shows amber flag

### Acceptance criteria
- Real login items from the system appear (not sample data)
- Enable/disable persists to system Login Items
- No crash on machines with 0 login items

---

## F-010 · Applications Deep Uninstall — Real Leftover Scan

**Status:** 📋 Queued — #10  
**Effort:** 2.5 days  
**Branch naming:** `feat/f010-deep-uninstall`  
**Depends on:** none

### Why
`ApplicationsView` has a "Deep Uninstall" button that shows a review sheet but does not actually scan for or delete leftover files. This is Halo's most compelling feature for the Applications module and must be real.

### What it delivers
- `ApplicationsViewModel.scanLeftovers(for: AppInfo)` — real file search
- Scans 8 standard leftover locations per app (bundle ID + name)
- Review sheet shows found files with sizes; user selects which to delete
- Uses `FileManager.trashItem` (never `removeItem`) for all deletions

### Locations to scan (per app)
```
~/Library/Application Support/<AppName|BundleID>/
~/Library/Caches/<BundleID>/
~/Library/Caches/<AppName>/
~/Library/Preferences/<BundleID>.plist
~/Library/Preferences/<BundleID>.*.plist
~/Library/Saved Application State/<BundleID>.savedState/
~/Library/Containers/<BundleID>/
~/Library/Group Containers/*.<BundleID>/
/Library/Application Support/<AppName>/
~/Library/Cookies/<BundleID>.binarycookies
~/Library/HTTPStorages/<BundleID>/
~/Library/WebKit/<BundleID>/
```

### Implementation steps

1. **`ApplicationsViewModel` — add `scanLeftovers(for app: AppInfo) async -> [LeftoverFile]`**
   ```swift
   struct LeftoverFile: Identifiable {
       let id: UUID
       let url: URL
       let sizeBytes: Int64
       var isSelected: Bool = true
       var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
       var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
   }
   ```

2. **Implement the scan** — for each template path, substitute `BundleID` and `AppName` from `app`, check existence, calculate size recursively using `FileManager.attributesOfItem`

3. **`deleteLeftovers(_ files: [LeftoverFile]) async`** — trash all selected files using `trashItem`; report total freed

4. **Update `ApplicationsView.swift` → `DeepUninstallSheet`** — replace mock data with real `leftovers` from `viewModel.scanLeftovers(for:)`

5. **Confirmation sheet** — must show total size of selected files and "Move X items to Trash" button before executing

### Test plan
- [ ] Install a test app (e.g. Cyberduck) → Deep Uninstall → scan finds Support/Cache/Prefs files
- [ ] Deselect Preferences file → uninstall → prefs file remains; others trashed
- [ ] App with no leftovers → sheet shows "No leftover files found" empty state
- [ ] Trash verification: after uninstall, files appear in `~/.Trash/`, not permanently deleted
- [ ] Cancel button → no files deleted, sheet dismisses
- [ ] Large leftover set (50+ files) → sheet is scrollable, renders without layout issues

### Acceptance criteria
- Real leftover files discovered (not mock data)
- Only files moved to Trash (never permanent deletion)
- Confirmation required before any deletion

---

## F-011 · In-App Alert History Log

**Status:** 📋 Queued — #11  
**Effort:** 1 day  
**Branch naming:** `feat/f011-alert-history`  
**Depends on:** Phase 3 merged (AlertManager exists)

### Why
`AlertManager` fires `UNUserNotification` toasts but has no persistence. Users who dismiss a notification or miss it have no way to see what alerts Halo fired. A lightweight in-app log solves this.

### What it delivers
- `Core/AlertLog.swift` — stores last 50 fired alerts to `UserDefaults`
- New "Alerts" section in Dashboard or a small bell icon in the sidebar badge
- Alert history list: title, time, kind icon, dismiss all button
- Badge count on Dashboard sidebar item for unread alerts

### Implementation steps

1. **Create `Halo/Core/AlertLog.swift`**
   ```swift
   struct AlertEntry: Codable, Identifiable {
       let id: UUID; let title: String; let body: String
       let kind: String; let firedAt: Date; var isRead: Bool
   }

   @MainActor
   final class AlertLog: ObservableObject {
       @Published var entries: [AlertEntry] = []

       func append(title: String, body: String, kind: String) {
           let entry = AlertEntry(id: .init(), title: title, body: body,
                                   kind: kind, firedAt: .init(), isRead: false)
           entries.insert(entry, at: 0)
           if entries.count > 50 { entries.removeLast() }
           persist()
       }

       var unreadCount: Int { entries.filter { !$0.isRead }.count }
       func markAllRead() { entries.indices.forEach { entries[$0].isRead = true }; persist() }
   }
   ```

2. **`AlertManager.swift`** — inject `AlertLog` and call `log.append(...)` in `fire(...)`

3. **`AppState.swift`** — instantiate `AlertLog`, expose `alertLog.unreadCount` as `@Published var alertBadgeCount: Int`

4. **`DashboardView.swift` — `RecentActivityList`** — add an "Alerts" card above activities if `alertBadgeCount > 0`

5. **`ContentView.swift` — `SidebarItem` for `.dashboard`** — show orange badge with `alertBadgeCount`

6. **`Features/Dashboard/AlertHistorySection.swift`** — list of `AlertEntry` rows with kind icon, relative time, dismiss button

### Test plan
- [ ] Trigger a CPU alert → entry appears in alert history with correct title and timestamp
- [ ] Relaunch app → alert history persists (loaded from UserDefaults)
- [ ] "Dismiss All" → all entries marked read → badge clears
- [ ] 51st alert fired → oldest entry removed (max 50 cap)
- [ ] No alerts ever fired → section hidden, badge = 0

### Acceptance criteria
- All fired notifications appear in the in-app log
- Log persists across app restarts
- Unread badge appears on Dashboard sidebar item

---

## F-012 · Maintenance Tasks — Real Execution

**Status:** 📋 Queued — #12  
**Effort:** 1 day  
**Branch naming:** `feat/f012-maintenance-real`  
**Depends on:** F-002 (XPC Helper must be built first)

### Why
`PerformanceView` maintenance tasks (Flush DNS, Rebuild Spotlight, Repair Permissions, Clear Font Cache) currently sleep for 2 seconds and pretend to complete. With the XPC helper from F-002, these can run real system commands.

### What it delivers
- All 4 maintenance tasks execute real shell commands via XPC
- Last run date persisted to `UserDefaults` per task
- Duration shown after completion (e.g. "Completed in 1.2 s")
- Error state if command fails (amber, not green)

### Implementation steps

1. **Extend `HaloHelperProtocol.swift`** (from F-002) — add:
   ```swift
   func rebuildSpotlight(reply: @escaping (Bool) -> Void)
   func clearFontCache(reply: @escaping (Bool) -> Void)
   func repairDiskPermissions(reply: @escaping (Bool) -> Void)
   ```

2. **`HaloHelperImpl.swift`** — implement:
   - Rebuild Spotlight: `mdutil -i off /; mdutil -i on /` (or `mdutil -E /`)
   - Clear Font Cache: `atsutil databases -remove; atsutil server -shutdown; atsutil server -ping`
   - Repair Permissions: `diskutil resetUserPermissions / $(id -u)`

3. **`PerformanceViewModel.runMaintenance(_ task:)`** — replace `Task.sleep` with:
   ```swift
   let start = Date()
   let success = await helperClient.execute(task.kind)
   let duration = Date().timeIntervalSince(start)
   maintenanceTasks[idx].lastRunDate = Date()
   maintenanceTasks[idx].lastDuration = duration
   maintenanceTasks[idx].lastStatus = success ? .success : .failed
   ```

4. **`SystemMaintenanceTask` model** — add `lastDuration: TimeInterval?`, `lastStatus: TaskStatus?`

5. **`MaintenanceTaskCard` view** — show duration chip and error state

### Test plan
- [ ] Flush DNS → `dscacheutil -flushcache` exits 0 → card shows green checkmark
- [ ] Rebuild Spotlight → `mdutil` process spawns (verify in Activity Monitor)
- [ ] XPC helper crash mid-task → card shows amber "Failed" state, not crash
- [ ] Run the same task twice quickly → second run queued, not run in parallel
- [ ] Last run date persists after relaunch

### Acceptance criteria
- All 4 tasks execute real system commands
- Success/failure state shown correctly
- Duration displayed after completion

---

## F-013 · iCloud Clipboard Sync

**Status:** 📋 Queued — #13  
**Effort:** 5 days  
**Branch naming:** `feat/f013-icloud-clipboard`  
**Depends on:** F-003 (Pro feature — requires active subscription)

### Why
Power users want clipboard history to sync across their Mac and iPhone/iPad. This is a significant Pro differentiator.

### What it delivers
- Each `ClipboardItem` synced as a `CKRecord` in CloudKit private database
- `CKQuerySubscription` for push-based real-time sync across devices
- Encrypted at rest (CloudKit end-to-end encryption zone)
- Pro only — free users see a "Sync with iCloud (Pro)" banner

### Entitlement required
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.halo.mac</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
```

### Implementation steps

1. **`Core/CloudSync/ClipboardSyncManager.swift`** — `@MainActor final class`
   - `container = CKContainer(identifier: "iCloud.com.halo.mac")`
   - `func uploadItem(_ item: ClipboardItem) async`
   - `func fetchAll() async -> [ClipboardItem]`
   - `func subscribeToChanges()`

2. **`CKRecord` mapping for `ClipboardItem`:**
   ```
   recordType = "ClipboardItem"
   fields: id (String), contentType (String), textValue (String?),
           imageData (CKAsset?), url (String?), createdAt (Date), isPinned (Bool)
   ```

3. **`AppState.swift`** — inject `ClipboardSyncManager`; on `addClipboardItem()` upload to CK if isPro

4. **Merge logic** — on fetch: merge by `id`, keep newer `modifiedAt` wins

5. **Subscription setup** — `CKQuerySubscription` on `ClipboardItem` record type, fire `fetchAll()` on push

6. **Settings toggle** — "Sync Clipboard with iCloud" in Settings → General (Pro only)

7. **`PrivacyInfo.xcprivacy`** — add CloudKit API usage declaration

### Test plan
- [ ] Copy text on Mac → appears in iCloud CloudKit dashboard under private database
- [ ] Open app on second device → same item visible within 5 s
- [ ] Delete item on Mac → deleted on secondary device within 10 s
- [ ] Free user → sync toggle shows paywall
- [ ] Offline → items buffered locally, synced when network restores
- [ ] 500 item cap → oldest items not uploaded (only Pro tier's 500 items synced)

### Acceptance criteria
- Items sync end-to-end within 10 seconds on the same iCloud account
- Encrypted in CloudKit private DB (verify in CloudKit Dashboard)
- Disabled for free users

---

## F-014 · PDF Health Report Export

**Status:** 📋 Queued — #14  
**Effort:** 2 days  
**Branch naming:** `feat/f014-pdf-report`  
**Depends on:** none

### Why
Enterprise users and IT admins want a point-in-time PDF report of their Mac's health — all metrics, scan results, threats, and disk usage in one shareable document.

### What it delivers
- "Export Report" button in Dashboard header
- Generates a styled PDF using `PDFKit` + `NSGraphicsContext`
- Sections: Health Score, System Metrics, Scan Results, Threats, Disk Usage, Alert Log
- Saved to `~/Downloads/Halo-Report-<date>.pdf` with `NSOpenPanel`

### Implementation steps

1. **Create `Core/ReportGenerator.swift`**
   ```swift
   actor ReportGenerator {
       func generate(snapshot: SystemSnapshot) -> Data    // returns PDF data
   }

   struct SystemSnapshot {
       let date: Date; let healthScore: Int; let cpuUsage: Double
       let ramUsage: Double; let diskFreeGB: Double; let batteryHealth: Double
       let threats: [MalwareThreat]; let cleanupBytes: Int64
       let alertEntries: [AlertEntry]
   }
   ```

2. **PDF layout using `PDFKit`:**
   - Page 1: Halo logo, report date, health ring (drawn with `CGContext`), summary metrics table
   - Page 2: Scan results table — category, file count, size
   - Page 3: Threats found (or "No threats found")
   - Page 4: Alert log (last 30 entries)

3. **`DashboardView.swift` — `DashHeader`** — add "Export PDF" button (uses `NSSavePanel`)

4. **`Features/Dashboard/ExportReportButton.swift`** — wraps save panel + async generation

### Test plan
- [ ] Tap Export → `NSSavePanel` opens with default filename `Halo-Report-<date>.pdf`
- [ ] Save → PDF opens in Preview → all 4 sections present
- [ ] Health ring renders correctly in PDF (not blank)
- [ ] 0 threats found → PDF shows "System Clean" on threats page
- [ ] Cancel → no file written

### Acceptance criteria
- PDF opens in Preview without errors
- All data sections populated from real AppState data
- File written only after user confirms save location

---

## F-015 · Custom Scan Schedule UI

**Status:** 📋 Queued — #15  
**Effort:** 1 day  
**Branch naming:** `feat/f015-scan-schedule-ui`  
**Depends on:** F-005 (BGScheduler must be built first)

### Why
F-005 adds background scan scheduling tied to a simple picker (daily/weekly/off). Users want to choose a specific day and time (e.g., "Every Sunday at 3 AM") and see the next scheduled scan in the UI.

### What it delivers
- Day-of-week picker and time picker in Settings → Scheduled Scans
- "Next scheduled scan: Sunday, 3:00 AM" label in Dashboard
- Countdown to next scan shown in `DashHeader`
- BGTask re-scheduled to the chosen exact time

### Implementation steps

1. **`SettingsView.swift` — Scheduled Scans section** — replace simple `Picker("Frequency")` with:
   ```
   Frequency: Daily / Weekly / Off
   [if weekly] Day: Mon/Tue/Wed/Thu/Fri/Sat/Sun picker
   Time: DatePicker (time only, using .hourAndMinute)
   ```
   Store as `@AppStorage("scanDayOfWeek")` and `@AppStorage("scanTimeHour")` / `scanTimeMinute`

2. **`scheduleNextBackgroundScan()` in `HaloApp.swift`** — compute `earliestBeginDate` as next occurrence of chosen day+time:
   ```swift
   func nextScanDate(dayOfWeek: Int, hour: Int, minute: Int) -> Date { ... }
   ```

3. **`DashHeader` in `DashboardView.swift`** — replace "Never scanned" with countdown:
   ```
   "Next scan: Sunday 3:00 AM (in 2 days)"
   ```

4. **`AppState.swift`** — expose `nextScheduledScan: Date?` computed from UserDefaults

### Test plan
- [ ] Set to Weekly, Wednesday, 14:00 → `scheduleNextBackgroundScan()` queues task with correct `earliestBeginDate`
- [ ] Dashboard shows "Next scan: Wednesday 2:00 PM"
- [ ] Change day to Friday → dashboard updates countdown, BGTask rescheduled
- [ ] Set to Off → Dashboard shows "Scheduled scans disabled"
- [ ] After simulated scan fires → next occurrence of same weekday/time is re-queued

### Acceptance criteria
- Users can set a specific day and time for background scans
- Countdown displays correctly in Dashboard
- BGTask fires at (or after) the selected time

---

---

---

# Future Ideas — Brainstormed Features (F-016 → F-030)

> These cards capture feature ideas identified during the v2.0 planning session.  
> Status is `💡 Future Idea` — not yet queued for implementation.  
> To promote a card to the active queue, change status to `📋 Queued`, assign a priority number, add it to the Pipeline Status table, and flesh out the Implementation Steps section.

---

## F-016 · Permission Auditor

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** Privacy & Security  
**Branch naming (when ready):** `feat/f016-permission-auditor`  
**Depends on:** none

### Why
macOS grants privacy permissions silently over time. A typical Mac accumulates dozens of apps with stale permissions (microphone, camera, screen recording, full disk access) that were approved once and never revisited. Users have no single place to review and clean up this exposure. This is one of the top features in competing tools like CleanMyMac X and Privacy Cleaner Pro.

### What it delivers
- Full map of all apps' macOS privacy permissions across every TCC category: microphone, camera, location, screen recording, contacts, calendars, reminders, full disk access, photos, Bluetooth, and Accessibility
- Each app shown with: permission status (granted/denied/not determined), date granted (if available), and a contextual risk flag when the permission seems excessive for the app's purpose (e.g., a note-taking app with screen recording access)
- "Revoke" deep-link button per permission that opens the exact pane in System Settings → Privacy & Security
- Summary score: "X of Y apps have excessive permissions"

### Data sources
- TCC database at `~/Library/Application Support/com.apple.TCC/TCC.db` (read-only, SQLite; readable in non-sandboxed debug build)
- `NSWorkspace` for app metadata and icons
- Hardcoded "expected permissions" map (e.g., browser → camera OK; text editor → camera flagged)

### Integration point
New **"Privacy"** module in the sidebar, or a second tab within the existing Protection module. A summary card on Dashboard showing unread permission count.

### Key design decisions to resolve before implementation
- Sandboxed release builds cannot read TCC.db directly — will require XPC helper (F-002) or user guidance to open System Settings
- Risk-flagging heuristics need a curated expected-permissions JSON bundle

---

## F-017 · Network Traffic Monitor (App-Level Firewall Companion)

**Status:** 💡 Future Idea  
**Effort estimate:** 5 days  
**Theme:** Privacy & Security  
**Branch naming (when ready):** `feat/f017-network-traffic-monitor`  
**Depends on:** none (read-only monitoring only; no blocking)

### Why
Privacy-conscious users want to know which processes are phoning home and to what domains. The existing Network section in Performance shows aggregate speed and VPN status — this adds per-app, per-domain granularity. A plain "Slack connected to analytics.mixpanel.com 14 times today" is enormously informative without requiring any network blocking infrastructure.

### What it delivers
- Live scrolling table: App icon | Process name | Remote hostname | Protocol | Bytes sent | Bytes received | Last seen
- "Suspicious" flag when the remote domain matches a bundled telemetry/tracker domain list (same pattern as `signatures.json`)
- Filter by app name; sort by traffic volume or recency
- Session summary card: "Top talker: Chrome — 142 MB sent in this session"
- Read-only — no blocking, no firewall rules, no kernel extension required

### Data sources
- `proc_pidinfo` with `PROC_PIDFDINFO` to enumerate open sockets per PID (same category of API as `ProcessMonitor`)
- `getaddrinfo` / reverse DNS for hostname resolution
- Bundled tracker domain list (JSON, same update pattern as `signatures.json`)

### Integration point
New sub-tab within the existing **Network** section of the Performance module, or a standalone **"Privacy"** module alongside Permission Auditor (F-016).

### Key design decisions to resolve before implementation
- Reverse DNS for every connection is slow — needs async resolution with a local LRU cache
- May need to be rate-limited (sample connections every 2 s rather than streaming) to avoid CPU overhead
- Tracker domain list maintenance: needs a hosting endpoint similar to the signatures update endpoint

---

## F-018 · Privacy Data Exposure Scanner

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** Privacy & Security  
**Branch naming (when ready):** `feat/f018-privacy-exposure-scanner`  
**Depends on:** none

### Why
Developers and professionals routinely accumulate sensitive data in unprotected locations — `.env` files in project folders, exported CSV files with financial data, private SSH keys copied to the Desktop, config files containing hardcoded API keys. No mainstream Mac cleaner scans for this. It is a genuine differentiated value proposition, especially for developer users.

### What it delivers
- Scans user-writable locations (Downloads, Documents, Desktop, and optionally iCloud Drive local folder) for files containing sensitive patterns
- Detection categories: credit card numbers (Luhn-validated), AWS/GitHub/Stripe API key patterns, hardcoded passwords in config files, private SSH key headers (`-----BEGIN RSA PRIVATE KEY-----`), SSN patterns
- Results grouped by risk level (Critical / Warning / Info) with: filename, match type, redacted preview (e.g., `sk_live_••••••••3f2a`), path, and last-modified date
- "Reveal in Finder" button per result — no automatic deletion, user decides what to do
- All pattern matching happens in-process; no file content ever leaves the device

### Data sources
- `FileManager` enumeration of target directories
- Regex patterns shipped as a bundled `privacy-patterns.json` (same update infrastructure as `signatures.json`)
- No network calls during scan

### Integration point
New **"Sensitive Data"** tab within the existing **Protection** module, or an additional scan type surfaced in Smart Scan results.

### Key design decisions to resolve before implementation
- Binary files, images, and files > 10 MB should be skipped to keep scan fast
- Regex false-positive rate needs careful tuning (credit card patterns especially)
- User opt-in required before scanning Documents/iCloud — privacy of the privacy scanner itself

---

## F-019 · Security Posture Dashboard

**Status:** 💡 Future Idea  
**Effort estimate:** 1.5 days  
**Theme:** Privacy & Security  
**Branch naming (when ready):** `feat/f019-security-posture`  
**Depends on:** none

### Why
Most users have no idea whether FileVault is on, if their firewall is disabled, or what their Gatekeeper setting is. These invisible system settings directly determine how exposed a Mac is. Surfacing them as a clear, actionable checklist is high-value for low implementation cost — all states are readable via shell commands that run in milliseconds.

### What it delivers
- Checklist card with 8 security checks, each showing: current state, a green/amber/red indicator, a one-line plain-English explanation, and a "Fix →" button that deep-links to the relevant System Settings pane
- Checks: FileVault encryption, Gatekeeper state, System Integrity Protection (SIP), Secure Boot policy, Find My Mac, automatic security updates enabled, Application Firewall state, login window security (show name+password, not username list)
- An overall **Security Score** (0–100) computed from check pass/fail, shown as a prominent card on Dashboard
- Score feeds into the existing `systemHealthScore` calculation in `AppState`

### Data sources
- `fdesetup status` → FileVault
- `spctl --status` → Gatekeeper
- `csrutil status` → SIP (output parsed from a subprocess)
- `nvram` → Secure Boot (Apple Silicon)
- `defaults read /Library/Preferences/com.apple.alf globalstate` → Firewall
- All via `Process` (read-only, non-blocking, no special entitlements)

### Integration point
New **"Security Posture"** card in the existing **Protection** module's main view, collapsible. Summary score visible on Dashboard.

---

## F-020 · S.M.A.R.T. Disk Health Monitor

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** Intelligent Insights  
**Branch naming (when ready):** `feat/f020-smart-disk-health`  
**Depends on:** none (IOKit is already used in the codebase)

### Why
Drive failure is the most catastrophic unrecoverable event that can happen to a Mac. Most users have no warning until the drive fails completely. S.M.A.R.T. data from the drive's internal sensors gives advance warning days or weeks before failure. The commercial tool DriveDx charges $19.99 for this single feature. It aligns directly with Halo's health-monitoring identity and would be a compelling differentiator.

### What it delivers
- Drive health status: Good / Warning / Failing — based on official S.M.A.R.T. attribute thresholds
- Key metrics displayed: drive model and serial, capacity, health percentage, current temperature, total bytes written (TBW), power-on hours, reallocated sector count, pending sector count, and uncorrectable error count
- A **lifespan remaining** progress bar based on TBW vs the manufacturer-rated endurance for the detected model
- Automatic alert when any critical attribute enters the warning zone (feeds into `AlertManager`)
- Historical temperature sparkline (sampled every 5 minutes, rolling 24-hour window)

### Data sources
- `IOKit` — `IOServiceMatching("IOBlockStorageDriver")` to enumerate physical drives, then `IORegistryEntryCreateCFProperties` to read S.M.A.R.T. attribute dictionaries from the IORegistry
- Model-to-TBW-rating lookup table (bundled JSON — major SSD models and their rated endurance)

### Integration point
New **"Drive Health"** card on Dashboard (alongside CPU, RAM, battery cards). Expanded detail view as a new section in the Performance module. Alert rule in `AlertManager` for failing attributes.

### Key design decisions to resolve before implementation
- NVMe drives on Apple Silicon expose limited S.M.A.R.T. data compared to SATA/Intel Macs — graceful degradation needed
- TBW lookup table needs curation and a maintenance/update strategy
- Sandboxed build will require IOKit entitlement addition

---

## F-021 · App Usage & Screen Time Analytics

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** Intelligent Insights  
**Branch naming (when ready):** `feat/f021-app-usage-analytics`  
**Depends on:** none

### Why
Users increasingly want to understand their own Mac habits — how long they spend in each app, which apps they context-switch into most frequently, and which background apps consume resources without ever being actively used. This data creates a feedback loop: "You've spent 6 hours in Slack this week, which consumed an average of 380 MB of RAM." No existing Mac utility combines usage time and resource cost in a single view.

### What it delivers
- Bar chart: top 5 apps by active foreground time for the past 7 days
- **"Background Hogs"** list: apps that ran continuously for >8 hours without the user ever activating them (using foreground-time vs uptime ratio)
- Weekly/monthly trends with week-over-week percentage change arrows
- "Context switching score": number of app switches per hour as a productivity signal
- All data stored locally in a lightweight SQLite database; no cloud sync, no third-party analytics

### Data sources
- `NSWorkspace.didActivateApplicationNotification` and `didDeactivateApplicationNotification` for foreground-time tracking (event-driven, zero polling cost)
- `ProcessMonitor` (already in codebase) for RAM usage correlation
- Local SQLite store: `~/Library/Application Support/com.halo.mac/usage.sqlite`

### Integration point
New **"Insights"** sub-section within the existing Dashboard, below the health ring. Expandable card showing the weekly bar chart. Toggle in Settings to enable/disable tracking.

---

## F-022 · Time Machine Backup Health Monitor

**Status:** 💡 Future Idea  
**Effort estimate:** 1.5 days  
**Theme:** Intelligent Insights  
**Branch naming (when ready):** `feat/f022-time-machine-monitor`  
**Depends on:** AlertManager (already built)

### Why
Time Machine is the primary backup for most Mac users, but its status is entirely invisible unless the user checks the menu bar icon. It is extremely common for backups to silently stop for weeks — the destination disk fills up, the backup drive gets disconnected, or corruption causes silent failures. Halo surfacing backup health as a first-class metric prevents data loss. The implementation is almost entirely read-only shell commands.

### What it delivers
- **Last backup time** displayed prominently (relative: "2 hours ago" / "3 days ago")
- Backup destination name and available-space progress bar
- 30-day backup frequency **heatmap** (GitHub-style calendar): green = backed up that day, amber = backup was late, red = missed 2+ days
- Automatic persistent alert if no backup has run in 48+ hours (feeds into existing `AlertManager`)
- "Back Up Now" button that calls `tmutil startbackup` via `Process`

### Data sources
- `/Library/Preferences/com.apple.TimeMachine.plist` for destination info and last backup date
- `tmutil status` output via `Process` for in-progress backup state
- Backup destination's `.../Backups.backupdb/` directory listing for historical dates

### Integration point
New **"Backup Health"** card on the Dashboard. Summary status (last backup time, green/red dot) visible as a persistent Dashboard widget even when collapsed.

---

## F-023 · Memory Leak & App Bloat Tracker

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** Intelligent Insights  
**Branch naming (when ready):** `feat/f023-memory-leak-tracker`  
**Depends on:** ProcessMonitor (already built in Performance module)

### Why
Memory leaks in long-running apps — Slack, Chrome, Electron apps, Adobe suite — are one of the most common causes of macOS slowdowns. The user currently has no way to know that Slack has ballooned from 180 MB to 1.4 GB over 6 hours. The existing Top Processes section shows current RAM but has no memory over time. Extending it with trend tracking turns a vague "my Mac feels slow" into an actionable "Slack has grown by 900 MB in 4 hours — restart it."

### What it delivers
- Per-app RAM usage sparkline chart (rolling 2-hour window, sampled every 30 seconds)
- **"Possible memory leak"** badge when an app's RAM usage grows monotonically for >1 hour without any significant drop
- Inline **"Restart App"** button with confirmation, for flagged apps
- Historical data persisted across sessions in a local SQLite store so leaks are visible even after they cause a crash
- Alert when a single app exceeds a user-configurable threshold (default: 2 GB)

### Data sources
- `ProcessMonitor.topProcesses()` (already in codebase) — extended to persist a rolling buffer per PID
- `NSRunningApplication` for mapping PIDs to app names and icons across sessions
- Local SQLite store for historical RAM samples

### Integration point
New sub-section in the **Performance** module, directly below the existing Top Processes section. A "Memory Trends" tab alongside "CPU" and "RAM" in the existing picker.

---

## F-024 · Browser Cleaner

**Status:** 💡 Future Idea  
**Effort estimate:** 2 days  
**Theme:** Cleanup & Storage  
**Branch naming (when ready):** `feat/f024-browser-cleaner`  
**Depends on:** none (extends existing Cleanup module architecture)

### Why
Browser cache is consistently one of the largest junk sources on a Mac. Chrome's GPU shader cache alone can be 2–4 GB; the HTTP cache for an active user can reach 5–10 GB. Safari accumulates years of WebKit data, cookies, and offline storage. This is the single most-requested feature category in Mac cleaner apps. It is also straightforward to implement — all paths are well-documented and fixed per browser.

### What it delivers
- Auto-detects installed browsers: Safari, Chrome, Firefox, Edge, Brave, Arc, Opera, Vivaldi
- For each browser: expandable checklist of data categories with current sizes — HTTP cache, GPU shader cache, browsing history, download history, cookies, crash reports, stored sessions, IndexedDB, WebSQL
- Master **"Clean All Browsers"** button at top; individual per-browser clean buttons
- Pre-clean size summary and post-clean "freed X GB" confirmation
- Checkbox per category (user can keep cookies but clear cache, for example)
- All deletions use `FileManager.trashItem` with the standard confirmation flow

### Data sources
- Each browser's fixed data paths (e.g., `~/Library/Caches/com.google.Chrome`, `~/Library/Caches/org.mozilla.firefox`, `~/Library/Safari`)
- `NSWorkspace` to detect which browsers are actually installed (avoids showing paths that don't exist)

### Integration point
New **"Browsers"** tab within the existing **Cleanup** module, alongside the existing 10 cleanup categories. Also surfaced as a category in Smart Scan results.

---

## F-025 · Duplicate Photos Finder (Perceptual Hash)

**Status:** 💡 Future Idea  
**Effort estimate:** 5 days  
**Theme:** Cleanup & Storage  
**Branch naming (when ready):** `feat/f025-duplicate-photos`  
**Depends on:** DuplicateDetector (existing SHA-256 engine — this extends it with a perceptual layer)

### Why
The existing `DuplicateDetector` finds bit-for-bit identical files using SHA-256. Photos libraries need more: the same photo saved at different compressions, crop variants, burst shots, and screenshots exported multiple times at different sizes all look identical to the eye but have different hashes. Perceptual hashing (pHash) bridges this gap. The commercial app Gemini 2 charges $19.99 specifically for this capability.

### What it delivers
- Perceptual hash generation for images using `CIFilter` + DCT-based pHash algorithm (64-bit fingerprint per image)
- Hamming-distance clustering: images within a configurable threshold (default: ≤8 bits different) are grouped as "near-duplicates"
- Side-by-side comparison UI: cluster grid showing all near-duplicate images, their sizes, dates, and source locations
- "Recommended keep" auto-selection: highest resolution, most recent, or in Photos Library rather than a loose file
- Support for both loose image files (`~/Pictures`) and Photos Library (via PhotoKit, with permission)
- All deletions use `trashItem` with the standard confirmation flow

### Data sources
- `PhotoKit` (`PHPhotoLibrary`) for Photos Library access (requires `NSPhotoLibraryUsageDescription` permission)
- `FileManager` for loose image files in `~/Pictures` and other user-specified folders
- `CIImage` + `CoreImage` for perceptual hash computation

### Integration point
New **"Similar Photos"** tab in the **Files** module, alongside the existing Duplicate Finder, SpaceLens, and Large Files tabs. The existing exact-duplicate tab is renamed to **"Exact Duplicates"** for clarity.

### Key design decisions to resolve before implementation
- pHash generation on large libraries (10,000+ photos) needs background processing and progress indication
- Threshold tuning: too tight misses similar photos; too loose creates false positives
- PhotoKit access requires sandboxed entitlement addition

---

## F-026 · Downloads Folder Organiser

**Status:** 💡 Future Idea  
**Effort estimate:** 2 days  
**Theme:** Cleanup & Storage  
**Branch naming (when ready):** `feat/f026-downloads-organiser`  
**Depends on:** AppScanner (for cross-referencing installed apps against .dmg/.pkg files)

### Why
The Downloads folder on most Macs is years of accumulated chaos — old installers, forgotten PDFs, zip files never unzipped. On average it contains 2–8 GB of files that serve no ongoing purpose. The specific insight that sets this apart from a simple large-files view: identifying `.dmg` and `.pkg` installer files whose apps are already installed, making it safe to delete the installer. This is an obvious, practical feature that no basic cleaner currently offers in an intelligent way.

### What it delivers
- Categorised summary of `~/Downloads` by file type: PDFs, ZIPs/Archives, DMGs, PKGs, Videos, Images, Code files, Other
- Size and count per category; oldest file date per category
- **"Installed App Installers"** subsection: `.dmg`/`.pkg` files cross-referenced against the Applications scanner — if the app is installed, the installer is marked "Safe to remove"
- **"Stale Files"** list: files not opened in 90+ days with total size
- Optional **"Sort into Subfolders"** action: organises files into `Downloads/PDFs/`, `Downloads/Archives/` etc.
- All deletions and moves use the standard confirmation + `trashItem` flow

### Data sources
- `FileManager` enumeration of `~/Downloads`
- UTI type detection via `NSWorkspace.type(ofFile:)` or `UTType`
- `AppScanner.scanApps()` results for installed-app cross-reference
- `NSMetadataItem` for last-opened date per file

### Integration point
New **"Downloads"** tab in the **Files** module. Also surfaced as a Smart Scan category.

---

## F-027 · Snippet Manager (Clipboard Evolution)

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** User Productivity  
**Branch naming (when ready):** `feat/f027-snippet-manager`  
**Depends on:** Clipboard module (this is a direct evolution of it)

### Why
The Clipboard module is already a strong differentiator. Extending it from a passive recorder into an active snippet manager makes it compete with TextExpander and Raycast's snippet feature — tools that charge $40/year and $49/year respectively. The existing infrastructure (ClipboardMonitor, quick-picker overlay ⌘⇧V, 500-item history, AppState) already provides nearly all the plumbing needed.

### What it delivers
- Any clipboard history item can be promoted to a permanent **Snippet** with a custom label, category tag (e.g., "Dev", "Email", "Address"), and optional keyword trigger
- Snippets persist indefinitely across reboots, unlike the rolling history cap
- Searchable by label, tag, and content
- Collections: user-created folders of related snippets (e.g., "SQL Queries", "Email Templates", "Addresses")
- The existing `⌘⇧V` quick-picker overlay gains a **"Snippets"** tab alongside History — identical UX, different data source
- Model change: `ClipboardItem` gains optional `snippetLabel: String?`, `snippetCollection: String?`, and `isSnippet: Bool` fields

### Data sources
- Extension of the existing `ClipboardItem` model and `AppState.clipboardItems` store
- Snippet persistence: separate `UserDefaults` key or a local JSON file for the snippet collection (distinct from rolling history)

### Integration point
**Evolution of the existing Clipboard module.** Three-tab layout: **History** (existing) | **Snippets** (new, permanent) | **Pinned** (existing pin feature promoted to its own tab). No new sidebar module needed.

---

## F-028 · Focus Session Companion

**Status:** 💡 Future Idea  
**Effort estimate:** 3 days  
**Theme:** User Productivity  
**Branch naming (when ready):** `feat/f028-focus-session`  
**Depends on:** MenuBarDisplayStyle (already built — new session mode needed)

### Why
This transforms Halo from a passive monitor into an active productivity companion. It taps into the deep-work/Pomodoro trend while staying true to the app's performance identity. No Mac cleaner or monitor currently offers this — it is a meaningful point of differentiation. The menu bar component is fully built; a session countdown mode is a small addition.

### What it delivers
- **"Start Focus Session"** card on the Dashboard with duration presets: 25 min / 50 min / custom
- On session start: automatically quits/hides a user-specified list of distracting apps (configurable in Settings), suppresses macOS notification banners, and switches the menu bar display to a **session countdown mode** (replacing the normal CPU/RAM stats)
- Dismissible minimal fullscreen countdown overlay — shows time remaining, current productivity score, and a "End Session" button
- Session end: macOS notification + in-app summary: "50-minute session. Top RAM consumer: Chrome (820 MB). CPU stayed below 55%."
- Session history log: date, duration, productivity summary — visible in a "Focus History" section of the Dashboard

### Data sources
- `NSWorkspace.shared.runningApplications` + `NSWorkspace.hideOtherApplications()` / `terminate()` for app management
- `UNUserNotificationCenter` for notification suppression (uses Focus mode API on macOS 12+: `INFocusStatusCenter`)
- Existing `AppState` CPU/RAM metrics for end-of-session report
- New `MenuBarDisplayStyle.sessionCountdown` case added to the existing enum

### Integration point
New collapsible **"Focus"** card on the Dashboard. New `sessionCountdown` style added to `MenuBarDisplayStyle` in `MenuBarView.swift`. Session history stored in `AlertLog` with a new `kindRaw: "focus"` entry.

---

## F-029 · Scheduled Reports & Weekly Digest

**Status:** 💡 Future Idea  
**Effort estimate:** 2 days  
**Theme:** User Productivity  
**Branch naming (when ready):** `feat/f029-scheduled-reports`  
**Depends on:** ReportGenerator (already built), ScanScheduler (already built), AlertLog (already built)

### Why
Power users want to stay informed without opening the app every day. A weekly "your Mac health report" notification is a genuinely useful, sticky feature that creates long-term retention. Nearly all the plumbing already exists — `ReportGenerator` produces PDFs, `ScanScheduler` handles timed background execution, and `AlertLog` has a week's worth of events. This feature is largely about wiring them together.

### What it delivers
- Weekly (or daily) **in-app notification** summarising the past 7 days: health score trend, top storage growers (largest files added), apps with high average RAM, backup status, threats detected, and scans completed
- Optional **PDF attachment** generated by the existing `ReportGenerator` and shareable via `NSSharingService` (Mail, AirDrop, Messages)
- A **7-day sparkline** of the health score trend, stored in a rolling local buffer and displayed in a new Dashboard card
- Settings toggle: "Weekly Digest" with a day + time picker (reuses the existing `ScanScheduler` day/hour picker infrastructure)
- Digest delivery via macOS notification with a "View Report" action button

### Data sources
- Existing `AlertLog.entries` for the event summary
- Existing `AppState` metrics sampled into a rolling 7-day local store (a small new `MetricsHistory` store — lightweight, sampled once/hour)
- `ReportGenerator` for PDF output
- `NSBackgroundActivityScheduler` (existing `ScanScheduler` infrastructure) for timed delivery

### Integration point
New **"Digest"** section in Settings. The 7-day health sparkline appears as a new card on the Dashboard. Entirely reuses existing components — minimal new code.

---

## F-030 · iCloud Storage Analyser

**Status:** 💡 Future Idea  
**Effort estimate:** 4 days  
**Theme:** Cleanup & Storage  
**Branch naming (when ready):** `feat/f030-icloud-storage-analyser`  
**Depends on:** none

### Why
iCloud's free 5 GB quota fills within months of typical use. Apple's own iCloud settings show only a top-level pie chart with no drill-down capability beyond broad categories. Most users have no idea what is consuming their quota and cannot make informed decisions about what to delete or offload. A proper drill-down analyser addresses one of the most persistent pain points in the Apple ecosystem.

### What it delivers
- **Donut chart** showing iCloud storage consumption by category — iCloud Drive, Photos, Backups (other devices), Mail, third-party app data — using Apple's colour coding for familiarity
- **Drill-down into iCloud Drive**: sorted list of the largest files and folders with sizes, last-modified dates, and sync status (local / evicted / uploading)
- **Savings Opportunities** section highlighting: duplicate files synced to iCloud, large files that could use "Optimise Mac Storage" (keep in cloud, evict local copy), and old device backups for devices the user no longer owns
- **Quota usage** progress bar: used / available / total, refreshed on view open
- "Reveal in Finder" and "Move to Trash" actions for iCloud Drive files (with standard confirmation)

### Data sources
- `FileManager` on `~/Library/Mobile Documents/` — iCloud Drive's local sync mirror; accessible without entitlements in debug build
- `NSUbiquitousKeyValueStore` and `NSFileManager.ubiquityIdentityToken` for CloudKit account status
- `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope` for file status (local vs evicted vs uploading/downloading)
- `CKContainer.default().accountStatus` and `CKContainer.default().fetchUserRecordID` for quota — note: quota numbers require `CKOperation` which needs iCloud entitlement

### Integration point
New **"iCloud"** tab in the **Files** module, alongside SpaceLens, Exact Duplicates, Similar Photos, Large Files, and Downloads.

### Key design decisions to resolve before implementation
- Full quota numbers via CloudKit require `com.apple.developer.icloud-services` entitlement — plan for sandboxed build
- File enumeration of a large iCloud Drive can be slow; needs async streaming with progress indicator
- "Old device backups" detection depends on accessing CloudKit backup records, which require user authentication

---

## How to Add a New Feature

1. Copy this template into the Queued section (above F-001):
   ```markdown
   ## F-XXX · Feature Name

   **Status:** 📋 Queued — #XX
   **Effort:** X days
   **Branch naming:** `feat/fXXX-short-name`
   **Depends on:** F-YYY or none

   ### Why
   ### What it delivers
   ### Implementation steps
   1. ...
   ### Test plan
   - [ ] ...
   ### Acceptance criteria
   - ...
   ```

2. Assign the next sequential ID (F-016, F-017, …)
3. Add a row to the Pipeline Status table at the top
4. Position it in the queue by inserting it before or after existing cards

## When a Feature is Done

1. Change status from `📋 Queued — #N` to `✅ Done`
2. Add the PR link next to the status
3. Move the row in the Pipeline Status table to the Completed section
4. Renumber the remaining Queued positions

---

*Last updated: v2.0 · 15 features shipped · 15 future ideas documented (F-016 → F-030)*
