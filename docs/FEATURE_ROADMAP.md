# Halo — Feature Roadmap & Execution Pipeline

> **How this document works**
>
> Every new feature lives here as a self-contained card. Features are worked **one at a time, FIFO** — pick the top card marked `📋 Queued`, implement it, flip its status to `✅ Done`, then move to the next.
>
> Each card is complete enough that a developer (or AI agent) with no prior context can implement and test the feature without reading anything else.
>
> To **add a new feature**, append it at the bottom of the Queued section. To **reprioritise**, move the card up or down in the queue. Never remove a Done card — it serves as the implementation record.
>
> **Definition of Done (mandatory):** a feature is not `✅ Done` until it has a
> **mobile feasibility study** (iOS + Android) and a row in
> [`docs/HALO_MOBILE_ROADMAP.md`](HALO_MOBILE_ROADMAP.md). Assess the mobile path
> before closing desktop work — see that doc's §0 governance.

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
| [F-021](#f-021--app-usage--screen-time-analytics) | App Usage & Screen Time Analytics | ✅ Done | ~3 d | none |
| [F-020](#f-020--smart-disk-health-monitor) | S.M.A.R.T. Disk Health Monitor | ✅ Done | 3 d | none |
| [F-021](#f-021--app-usage--screen-time-analytics) | App Usage & Screen Time Analytics | 💡 Future Idea | ~3 d | none |
| [F-022](#f-022--time-machine-backup-health-monitor) | Time Machine Backup Health Monitor | 💡 Future Idea | ~1.5 d | AlertManager |
| [F-023](#f-023--memory-leak--app-bloat-tracker) | Memory Leak & App Bloat Tracker | ✅ Done | ~3 d | ProcessMonitor |
| [F-022](#f-022--time-machine-backup-health-monitor) | Time Machine Backup Health Monitor | ✅ Done | ~1.5 d | AlertManager |
| [F-023](#f-023--memory-leak--app-bloat-tracker) | Memory Leak & App Bloat Tracker | 💡 Future Idea | ~3 d | ProcessMonitor |
| [F-024](#f-024--browser-cleaner) | Browser Cleaner | 💡 Future Idea | ~2 d | none |
| [F-025](#f-025--duplicate-photos-finder-perceptual-hash) | Duplicate Photos Finder (pHash) | 💡 Future Idea | ~5 d | DuplicateDetector |
| [F-026](#f-026--downloads-folder-organiser--manager) | Downloads Folder Organiser & Manager | ✅ Done | 2.5 d | AppScanner, FileSystemScanner |
| [F-027](#f-027--snippet-manager--text-expansion-engine-clipboard-evolution) | Snippet Manager & Text Expansion Engine | ✅ Done | 3.5 d | Clipboard module |
| [F-028](#f-028--focus-session-companion) | Focus Session Companion | 💡 Future Idea | ~3 d | MenuBarDisplayStyle |
| [F-029](#f-029--scheduled-reports--weekly-digest) | Scheduled Reports & Weekly Digest | ✅ Done | 2 d | ReportGenerator |
| [F-030](#f-030--icloud-storage-analyser) | iCloud Storage Analyser | 💡 Future Idea | ~4 d | none |
| [F-031](#f-031--dock--desktop-tinker-actions) | Dock & Desktop Tinker Actions | ✅ Done | 0.5 d | none |
| [F-032](#f-032--display--audio-quick-actions) | Display & Audio Quick Actions | ✅ Done | 0.5 d | none |
| [F-033](#f-033--system-junk--developer-cache-cleaner-actions) | System Junk & Dev Cache Cleaner Actions | ✅ Done | 0.5 d | none |
| [F-034](#f-034--port-manager) | Port Manager | ✅ Done | 2.5 d | none |
| [F-036](#f-036--customizable-menu-bar-format-strings) | Customizable Menu Bar Format Strings | ✅ Done | 2 d | MenuBarDisplayStyle |
| [F-037](#f-037--celebration--delight-moments) | Celebration & Delight Moments | ✅ Done | 1.5 d | none |
| [F-038](#f-038--code-snippet-beautifier) | Code Snippet Beautifier | ✅ Done | 3 d | Clipboard module |
| [F-039](#f-039--auto-quit-idle-apps) | Auto-Quit Idle Apps | ✅ Done | 2.5 d | none |
| [F-041](#f-041--shareable-action-configurations) | Shareable Action Configurations | ✅ Done | 2 d | Actions module |
| [F-042](#f-042--siri-shortcuts--app-intents) | Siri Shortcuts / App Intents | ✅ Done | 4 d | AppState |
| [F-043](#f-043--drive-read--write-speed-test-nfeat-121) | Drive Read & Write Speed Test (NFeat-121) | ✅ Done | 2 d | Files module |
| [F-044](#f-044--shared-sms-console-nfeat-122) | Shared SMS Console (NFeat-122) | 🗓 Planned | TBD | Firebase, Halo Mobile |
| [F-045](#f-045--cross-device-clipboard-sync-nfeat-123) | Cross-Device Clipboard Sync (NFeat-123) | 🗓 Planned | TBD | Firebase, Clipboard module |
| [F-046](#f-046--ai-querying--cloud-providers-nfeat-124) | AI Querying — Cloud Providers (NFeat-124) | ✅ Done | Desktop | none |
| [F-047](#f-047--on-device-ai--custom-rag-nfeat-125) | On-Device AI & Custom RAG (NFeat-125) | 🗓 Planned | TBD | none |
| [F-048](#f-048--personal-expenditure-tracker-nfeat-126) | Personal Expenditure Tracker (NFeat-126) | 🗓 Planned | TBD | F-044 |
| [F-049](#f-049--halo-mobile-app-product-line) | Halo Mobile App (product line) | 🗓 Planned | TBD | F-044, F-045, F-050 |
| [F-050](#f-050--haloshare-mobile--desktop-nfeat-127) | HaloShare Mobile ↔ Desktop (NFeat-127) | 🗓 Planned | TBD | HaloShare (LocalSend) |

> **Status legend:** ✅ Done · 📋 Queued (next up) · 🗓 Planned (user-requested, spec pending discussion) · 💡 Future Idea (unsolicited) · ⏭ Skipped

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

**Status:** ✅ Done · **Effort:** 3 d · **Depends on:** none

### Summary
Read-only S.M.A.R.T./NVMe health monitor for internal & external drives. Health
status (Good / Warning / Failing), drive model/serial/capacity, temperature,
power-on hours/cycles, total bytes written, available spare, NVMe's own
percentage-used wear indicator, media errors, and a 24-hour temperature
sparkline (internal drive only, sampled every 5 minutes). Surfaced as a
**"Drive Health"** card in the Files → **Drive Speed** tab (not Dashboard —
see "Integration point" below for why). `AlertManager` fires a Warning/Failing
notification whenever health degrades.

### As actually built — Apple Silicon data-availability findings

The original spec (above, preserved for context in git history) assumed
`IOServiceMatching("IOBlockStorageDriver")` + `IORegistryEntryCreateCFProperties`
would expose S.M.A.R.T. attributes directly from the IORegistry, the same
pattern the existing `DiskHealthMonitor` (P3-07, Cleanup module) already uses.
**That assumption doesn't hold on Apple Silicon** — independently re-verified
on this machine (Apple Silicon, macOS 26.2, internal `APPLE SSD AP0512Z`) with
a standalone `IOServiceMatching` probe before trusting any of the
implementation:

| Path tried | Result on this machine |
|---|---|
| `IOServiceMatching("IOBlockStorageDriver")` → `IORegistryEntryCreateCFProperties` | Only an aggregate I/O `Statistics` dict (bytes/ops/errors/latency read+write). **No S.M.A.R.T. data at all.** This is exactly why P3-07's existing SMART panel in Cleanup always shows "N/A" here. |
| `IOServiceMatching("IONVMeBlockDevice")` / `IOServiceMatching("IOAHCIBlockDevice")` | **No matching service at all** on Apple Silicon (0 instances returned). |
| `IOServiceMatching("IONVMeController")` | **Real data** — `Model Number`, `Serial Number`, `Firmware Revision`, `Vendor Name`. No SMART log fields, but this is where the serial number comes from (diskutil never reports one). |
| `diskutil info -plist <path>` (a `Process` shell-out) | **Real S.M.A.R.T./NVMe Health Info Log data** — confirmed against `system_profiler SPNVMeDataType` as a second, independent source. This became the primary data path instead of raw IOKit. |

Given that, the implementation pivots to `diskutil info -plist` as the
primary read path, with an `IONVMeController` IOKit lookup only for the
serial number diskutil omits.

**Confirmed available on this machine** (via `diskutil info -plist`):
`SMARTStatus` (Verified/Failing), temperature (Kelvin → converted to °C),
power-on hours, power cycles, unsafe shutdown count, data units read/written
(→ real total bytes written, i.e. TBW), available spare %, available spare
threshold %, NVMe's own `PERCENTAGE_USED` wear indicator, media error count,
error-log entry count, bus protocol, solid-state flag, capacity. Plus serial
number and model, via IOKit, once resolved (see gotcha below).

**Confirmed NOT available on this machine — rendered as "Not available on
this drive", never faked:**
- **Reallocated / pending sector counts** (ATA SMART attributes 5 and 197) —
  these are ATA-only concepts. NVMe's Health Information Log page has no
  equivalent counter; it isn't a failed read, the concept doesn't exist for
  NVMe. `Available Spare` / `Available Spare Threshold` and `Media Errors`
  are the nearest NVMe analogs, and both are surfaced instead of faking the
  ATA fields.
- **Uncorrectable error count** as a distinct SATA-style metric — NVMe
  surfaces `Media Errors` and an error-log entry count instead; there's no
  separate "uncorrectable" counter to report.
- **A manufacturer TBW-rating lookup table** — dropped entirely from the
  design. NVMe drives report their own firmware wear assessment
  (`PERCENTAGE_USED`, the drive's own view of consumed endurance against its
  rated spec) directly in the SMART log, which is more accurate than a
  bundled JSON table of SSD models could be and needs no maintenance. The
  lifespan-remaining bar is `100 - PERCENTAGE_USED`.

**A real bug caught by on-machine verification, not just code review:**
querying `diskutil info -plist` by *mount path* (what both callers pass — the
boot volume's `"/"` from the periodic `AppState` check, and a volume's
`.url.path` from the Drive Health card) returns an **empty string** for
`MediaName`, even though the SMART log itself comes through fine at that
level. `MediaName` is only populated when diskutil is queried by the
*physical whole-disk BSD identifier* (e.g. `disk0`) — confirmed by hand:
`diskutil info -plist /` → `MediaName ""` vs `diskutil info -plist disk0` →
`MediaName "APPLE SSD AP0512Z"`, same physical drive. Left unfixed, this
would have silently shown "Unknown drive" for every scan, and — since the
IOKit serial-number lookup matches by model string — would have also
silently blocked the serial number from ever resolving. `SMARTDiskMonitor.scan(path:id:)`
now falls back to a second `diskutil` query against the already-computed
whole-disk id whenever the first `MediaName` comes back empty.

**External drives:** the model-to-serial IOKit match and the empty-`MediaName`
fallback above were both verified against the internal NVMe SSD only — no
external SATA/USB-UASP drive was available to test against on this machine.
Treat external-drive serial/model resolution as architecturally sound but
unverified until tested against a real external drive.

### Files
| File | Role |
|------|------|
| `Halo/Core/Scanner/SMARTDiskMonitor.swift` | `actor SMARTDiskMonitor` — `diskutil`-backed scan + IOKit serial lookup; `SMARTDiskInfo` model with `healthLevel` classification; `SMARTTemperatureHistory` — `@MainActor` rolling 24h sample store, persisted to `UserDefaults` |
| `Halo/Features/Files/DriveHealthSection.swift` | `DriveHealthSection` view + `DriveHealthViewModel` — on-demand ("Check Drive Health" button) card: status row, metrics grid, lifespan bar, temperature sparkline (`Charts`) |
| `Halo/Features/Files/DriveSpeedView.swift` | Adds `DriveHealthSection(volume:)` below the volume picker |
| `Halo/App/AppState.swift` | `startSMARTMonitoring()` — one check at launch + a 300s (5-minute) timer against the boot volume only; feeds `SMARTTemperatureHistory` and `AlertManager.evaluateSMART` |
| `Halo/Core/AlertManager.swift` | `evaluateSMART(model:healthLevel:)` — fires `.diskSmartWarning` (24h cooldown) / `.diskSmartFailing` (1h cooldown); `.good`/`.unknown` never fire |

### API
```swift
actor SMARTDiskMonitor {
    func scan(volume: DriveVolume) async -> SMARTDiskInfo
    func scan(path: String, id: String) async -> SMARTDiskInfo

    enum DriveHealthLevel { case good, warning, failing, unknown }
    struct SMARTDiskInfo {
        let model, serialNumber, busProtocol: String?
        let overallStatus: SMARTOverallStatus   // .verified / .failing / .other(String) / .unavailable
        let temperatureCelsius: Double?
        let powerOnHours, powerCycles, unsafeShutdowns: Int?
        let totalBytesWritten, totalBytesRead: Int64?
        let availableSparePercent, availableSpareThresholdPercent, percentageUsed: Int?
        let mediaErrorCount, errorLogEntryCount: Int?
        let reallocatedSectorCount, pendingSectorCount: Int?   // always nil — ATA-only, see above
        var healthLevel: DriveHealthLevel { get }
        var lifespanRemainingPercent: Int? { get }             // 100 - percentageUsed
    }
}
```

### Why the boot-volume-only, 5-minute cadence
`diskutil info -plist` is a `Process` shell-out — cheap, but there's no reason
to run it on the 2 s metrics loop. The temperature history is deliberately
internal-drive-only: external drives aren't guaranteed to stay connected, so
only the always-present internal SSD gets a rolling 24h history.

### Known constraints
- No manufacturer TBW-rating table — intentionally dropped (see above); the
  lifespan bar uses the drive's own `PERCENTAGE_USED` instead.
- Reallocated/pending sector counts and a distinct "uncorrectable errors"
  metric are permanently `nil` on NVMe drives — this is a real NVMe-vs-ATA
  protocol difference, not a missing read, and the UI/metrics grid renders
  them accordingly ("N/A on NVMe" / "Not available on this drive").
- External-drive serial/model resolution is unverified (no external drive
  available to test against on this machine).
- Integration point differs from the original spec: the health card lives in
  Files → Drive Speed (alongside the related F-043 benchmark), not as a new
  Dashboard card or Performance section — this keeps all "drive-related"
  surfaces in one tab rather than splitting drive info across three modules.

### Test plan
- [ ] Files → Drive Speed → select internal volume → Drive Health card
      appears below the volume picker
- [ ] Tap "Check Drive Health" → status resolves to Good, model/serial/
      capacity/temperature/power-on-hours/TBW populate
- [ ] Reallocated/Pending Sectors show "N/A on NVMe" (not blank, not "0")
- [ ] Lifespan bar renders and matches `100 - PERCENTAGE_USED`
- [ ] Wait 24h+ (or seed `haloSMARTTemperatureHistory` in UserDefaults) →
      temperature sparkline renders for the internal drive
- [ ] Switch to an external volume (if available) → card re-scans; confirm
      serial number behavior against a real external bridge
- [ ] Force a Warning/Failing health level (simulate via a modified plist in
      a debug build, since a real failing drive isn't available for testing)
      → confirm `AlertManager` notification fires with correct cooldown
- [ ] Confirm the 5-minute `AppState` timer doesn't fire more than once per
      5 minutes (Console log or breakpoint count)

### Acceptance criteria
- Health status computed from official S.M.A.R.T./NVMe attribute thresholds,
  never fabricated
- Every field diskutil/IOKit doesn't report renders "Not available on this
  drive" — never a zeroed or guessed value
- Alert fires on Warning/Failing, never on Unknown (unreadable ≠ unhealthy)
- Temperature sparkline persists across app restarts

#### Amended during code review (2026-09-05)

Three of the original rules turned out to be wrong against real hardware. All
three are now regression-tested in `HaloTests`; see `CLAUDE.md` gotchas 22–24.

- **Vendor spare thresholds are not trustworthy as reported.** Apple Silicon
  reports `AVAILABLE_SPARE_THRESHOLD = 99` against `AVAILABLE_SPARE = 100`
  (verified on the dev machine). A literal `spare <= threshold` comparison
  declares a healthy drive **Failing** the first time spare ticks to 99 on
  normal wear, then fires "back up your data immediately" hourly and
  indefinitely. `classify` now ignores any threshold above
  `maxCredibleSpareThreshold` (50), uses the spec's strict `<`, and keeps a
  threshold-independent `criticalSparePercent` (10) backstop.
- **An unrecognised `SMARTStatus` is Unknown, not Warning.** Every USB /
  Thunderbolt bridge reports `"Not Supported"` — the healthy state for that
  hardware, since enclosures don't pass the health log through. Flagging it
  amber put a Warning badge on a working external SSD.
- **The card and the notification are different bars.** Split into
  `healthLevel` (drives the badge — surfaces anything notable, including a
  non-zero media-error count) and `alertLevel` (what `AlertManager` acts on —
  only conditions that are real *and* actionable). A single lifetime
  unrecovered read is worth showing but must not nag daily forever.

Also fixed: switching volumes while a scan was in flight left the previous
drive's data on screen under the new drive's name, and the temperature chart
was gated on `isInternal` rather than on the boot volume it actually samples.

---

## F-021 · App Usage & Screen Time Analytics

**Status:** ✅ Done  
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

### As actually built

The build deviates from the original card in two deliberate ways, both worth understanding before touching this feature:

**1. No SQLite — UserDefaults + JSON, matching the rest of the codebase.**
Halo has zero SQLite/CoreData dependency anywhere (verified before writing a line of code). Every other rolling-history store in this app — `AlertLog` (50-item cap), the widget pipeline, custom actions — uses `UserDefaults` + `Codable`/JSON. Introducing SQLite for one feature would mean a new dependency, a new persistence pattern, and a new set of edge cases (schema migration, WAL files inside a sandboxed container) for a dataset that's at most a few hundred small records. `AppUsageTracker` persists `[AppUsageRecord]` (one record per app per day) as JSON to `UserDefaults["haloAppUsageHistory"]`, pruned to a rolling 14-day window — same cap-and-persist pattern as `AlertLog`, just date-windowed instead of count-capped. If usage ever grows enough that this becomes a real bottleneck, that's a good problem to revisit with real numbers; it isn't one today.

**2. "Screen Time" only covers time Halo itself was running — this is a hard OS limitation, not a corner cut.**
There is no macOS API available to a third-party app that retroactively retrieves system-level Screen Time history. Apple's real Screen Time data lives behind the private `FamilyControls`/`ManagedSettings` frameworks, which require a parental-control entitlement Halo does not have and would not qualify for as a system-utility app. So every number this feature reports is scoped to **time Halo was open and running**:
- If the Mac was asleep, no time is counted for that period (the sampling timer simply doesn't fire — this is *correct* behavior, not a gap: it prevents a Mac that slept for 5 hours with Slack frontmost from reporting 5 fake hours of usage).
- If Halo wasn't launched (quit, or not set to launch at login), that window isn't counted either, and is never backfilled or estimated.
- The bar chart, Background Hogs list, and stats all carry a caption — *"Based on time Halo has been running"* — directly in the UI so this is never presented as a full-day Screen Time replacement.
- Context-switches-per-hour and week-over-week comparisons return `nil` (shown as "not enough data yet") until there's enough real history (≥1 hour, ≥14 days respectively) to make the number honest rather than a wild extrapolation from a few minutes of data.

This is the same honesty discipline F-019 (Security Posture Dashboard) applies to its unverifiable checks, and the same discipline behind the "isUnused"/`NSMetadataItem` fixes in the Bug Fixes & Polish log — Halo does not show a plausible-looking number it can't actually stand behind.

**Implementation:** `Halo/Core/AppUsageTracker.swift` (`@MainActor final class AppUsageTracker: ObservableObject`, singleton, same style as `AlertLog`) + `Halo/Features/Dashboard/AppUsageInsightsSection.swift` (expandable `HaloCard` below `HealthAndMetrics()` on the Dashboard). Toggle in Settings → General → Privacy, off by default (matches `enableAnalytics`'s opt-in convention). See `CLAUDE.md`'s "AppUsageTracker (F-021)" section for the full API surface.

---

## F-022 · Time Machine Backup Health Monitor

**Status:** ✅ Done  
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

### As actually built
Data sourcing deviated from the original plan for reliability: rather than parsing `/Library/Preferences/com.apple.TimeMachine.plist` or walking `Backups.backupdb/` directly (both fragile — the plist schema shifts across macOS versions, and APFS-snapshot backups don't produce a `Backups.backupdb` directory at all on modern destinations), the implementation goes entirely through the public `tmutil` CLI: `destinationinfo` (destination name + mount point), `status` (in-progress state), `latestbackup` (fast-path last-backup date), and `listbackups` (full snapshot history for the heatmap, with a graceful fallback to the newest `listbackups` entry when `latestbackup` fails because the destination is unreachable). Free-space numbers come from `URLResourceValues` on the mounted destination volume itself (`tmutil` doesn't expose capacity). Verified live on the dev machine, which has **no Time Machine destination configured** — `tmutil destinationinfo` returns `"No destinations configured."`, `latestbackup` fails with `Failed to mount destination.` (error 17), and `listbackups` fails with `"No machine directory found for host."` — confirming the `.notConfigured` empty state (rather than a fabricated "healthy" card) is what actually renders on a real, unconfigured Mac.
- `Halo/Core/Scanner/TimeMachineMonitor.swift` — actor, `status()` (async, shells out to `tmutil`) + static `heatmap(backupDates:days:referenceDate:)` (pure, no I/O) + `startBackupNow()` (`tmutil startbackup`)
- `Halo/Core/Models/Models.swift` — `TimeMachineStatus` (`isConfigured`/`isReachable`/`isStale`/`spaceUsedRatio`), `BackupDayState`, `BackupHeatmapDay`
- `Halo/Features/Dashboard/BackupHealthCard.swift` — three honest states (not configured / configured-but-unreachable / fully configured), free-space `HaloMiniBar`, 30-day `LazyVGrid` heatmap with per-cell tooltips, "Back Up Now" button disabled while a backup is already running or launching
- `Halo/App/AppState.swift` — `timeMachineStatus`/`isCheckingTimeMachine`/`isStartingBackup`, polled every 15 minutes (not the 2 s metrics tick — `tmutil` shell calls are tens of ms each and backup status doesn't change that fast)
- `Halo/Core/AlertManager.swift` — `evaluateBackup(status:)` fires `.backupStale` with a 24 h cooldown once a configured, reachable destination's last backup exceeds 48 h; a disconnected/unreachable destination or "never backed up" state does not spuriously alert
- Heatmap gray "no data" cells are used both before the earliest known backup and for the entire 30 days when Time Machine isn't configured at all — never rendered as red "missed" days, which would misrepresent absence of data as backup failure

---

## F-023 · Memory Leak & App Bloat Tracker

**Status:** ✅ Done — `feat/f023-memory-leak-tracker` branch (2026-08)  
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

### As actually built
Two deviations from the spec, both for honesty/consistency with the existing codebase rather than scope-cutting:

- **JSON file, not SQLite.** This codebase has no SQLite/CoreData dependency anywhere (`AlertLog` persists its 50-item history as JSON in `UserDefaults`, following the same pattern). Introducing SQLite for one feature's ~240-samples-per-app history would be a new dependency for no real benefit at this scale, so persistence is a JSON file at `Application Support/Halo/memoryTrendHistory.json` (a dedicated file rather than `UserDefaults`, unlike `AlertLog`, because several tracked apps × 240 samples grows past what a single plist should comfortably carry in memory).
- **Separate new section, not a picker tab.** The existing `TopProcessesSection` CPU/RAM `Picker` toggles between two views of the *same* top-10 list; Memory Trends tracks a materially different, persisted data set (all regular apps over 2 hours, not the top 10 by instantaneous CPU/RAM). Bolting a third picker option onto that control would have made it toggle between two different underlying data sources under one switch, which is more confusing than a clearly-separated sub-section directly below it — which is also literally what the spec's "Integration point" says first, before offering the tab as an alternative framing.

**Leak-detection algorithm (`MemoryTrendTracker.leakStatus(for:)`)** — walks the persisted samples oldest→newest tracking a "growth streak":
- A streak's local peak only ever moves up; a sample **more than 15% below the streak's peak** (`significantDropFraction = 0.15`) resets the streak to start at that sample. 15% was chosen as a threshold that survives normal allocator/cache churn (typically a few percent of RSS) while still catching a real "user closed some tabs" drop.
- A gap between two consecutive samples **greater than 5× the 30 s sample interval** (`maxSampleGapSeconds = 300`) also resets the streak — across a gap that size the Mac (or Halo) was very likely asleep or quit, so "monotonic growth" can't honestly be claimed through it.
- The **"Possible memory leak"** badge only shows once the surviving streak has lasted **more than 1 hour** (`leakWindowSeconds = 3600`) of real, densely-sampled data. Because a streak can never be older than how long Halo has actually observed the app, this single duration check also satisfies the spec's "don't flag a just-launched app" requirement — no separate "has it been running long enough" guard was needed.
- The result is **recomputed fresh on every read**, never itself persisted or cached, so a stale "leak" flag can never survive a real RAM drop on the next sample.
- Badge and alert copy consistently say "possible" / "consider restarting" — never "confirmed leak" — since this is a heuristic on a rolling window, not a diagnosis.

**Alert threshold** — default **2 GB**, exposed as a `Stepper` (0.5 GB steps, 0.5–16 GB range) in the Memory Trends section header, persisted to `UserDefaults["memoryLeakAlertThresholdGB"]`. Wired into `AlertManager` via a new `checkAppMemory(appName:bundleID:ramMB:)` entry point (distinct from the existing `evaluate()`, which only handles one system-wide metric per kind) with its own per-bundle-ID cooldown dictionary so one app crossing the threshold doesn't suppress another's alert; a new `AlertKind.appMemoryHigh` case feeds the existing `AlertLog`.

**Restart** — `NSRunningApplication.terminate()`, a 1.5 s grace period (falling back to `forceTerminate()` if the app is still around), then `NSWorkspace.shared.openApplication(at:configuration:)` using the app's persisted bundle path. Gated behind a `.confirmationDialog` per CLAUDE.md's "disruptive actions require confirmation" rule, and only offered on apps the leak badge has already flagged (not a general-purpose restart button).

- `Halo/Core/Scanner/ProcessMonitor.swift` — extended (not replaced) with `AppRAMSample` + `runningAppRAMSamples()`, reusing the existing `proc_taskinfo` resident-size read, re-keyed by bundle ID instead of PID
- `Halo/Core/Scanner/MemoryTrendTracker.swift` — `@MainActor final class`, singleton, started once from `AppState.init()`
- `Halo/Core/Models/Models.swift` — `MemorySample`, `AppMemoryHistory`, `MemoryLeakStatus`
- `Halo/Core/AlertManager.swift` — `checkAppMemory(appName:bundleID:ramMB:)`, `AlertKind.appMemoryHigh`
- `Halo/Core/AlertLog.swift` — icon/color for `app_memory_high`
- `Halo/Features/Performance/MemoryTrendsSection.swift` — new sub-section below `TopProcessesSection`

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

## F-026 · Downloads Folder Organiser & Manager

**Status:** 📋 Queued — #5 (was 💡 Future Idea; promoted and merged with F-035)  
**Effort estimate:** 2.5 days  
**Theme:** Cleanup & Storage  
**Branch naming (when ready):** `feat/f026-downloads-organiser`  
**Depends on:** AppScanner (for cross-referencing installed apps against .dmg/.pkg files), FileSystemScanner

### Why
The Downloads folder on most Macs is years of accumulated chaos — old installers, forgotten PDFs, zip files never unzipped. On average it contains 2–8 GB of files that serve no ongoing purpose. The specific insight that sets this apart from a simple large-files view: identifying `.dmg` and `.pkg` installer files whose apps are already installed, making it safe to delete the installer. This is an obvious, practical feature that no basic cleaner currently offers in an intelligent way.

*Merged with F-035 (Downloads Manager, Raycast-inspired) — adds age-based grouping, visual size breakdown, and size threshold alerts from Raycast's `downloads-manager` extension (7 commands).*

### What it delivers
- Categorised summary of `~/Downloads` by file type: PDFs, ZIPs/Archives, DMGs, PKGs, Videos, Images, Code files, Other
- Size and count per category; oldest file date per category
- **Age-based grouping** *(from F-035)*: Today, This Week, This Month, Older (30–90d), Stale (90d+) — with visual bar chart breakdown
- **"Installed App Installers"** subsection: `.dmg`/`.pkg` files cross-referenced against the Applications scanner — if the app is installed, the installer is marked "Safe to remove"
- **"Stale Files"** list: files not opened in 90+ days with total size
- **One-click "Clean Stale Downloads"** *(from F-035)*: moves 90+ day files to Trash with confirmation review sheet
- Optional **"Sort into Subfolders"** action: organises files into `Downloads/PDFs/`, `Downloads/Archives/` etc.
- **Size threshold notification** *(from F-035)*: alert when `~/Downloads` exceeds 5 GB (configurable)
- All deletions and moves use the standard confirmation + `trashItem` flow

### Files to create
```
Halo/Features/Files/DownloadsView.swift         — tab view within Files module
Halo/Features/Files/DownloadsViewModel.swift     — @MainActor ObservableObject
```

### Data sources
- `FileManager` enumeration of `~/Downloads`
- UTI type detection via `NSWorkspace.type(ofFile:)` or `UTType`
- `AppScanner.scanApps()` results for installed-app cross-reference
- `NSMetadataItem` for last-opened date per file
- File creation/modification dates for age grouping

### Implementation steps

1. **Create `DownloadsViewModel.swift`**
   ```swift
   @MainActor
   final class DownloadsViewModel: ObservableObject {
       @Published var files: [DownloadFile] = []
       @Published var isScanning = false
       @Published var totalSize: Int64 = 0

       func scan() async
       func groupedByAge() -> [DownloadAgeGroup: [DownloadFile]]
       func groupedByType() -> [DownloadFileType: [DownloadFile]]
       func cleanStale() async -> Int64  // returns bytes freed
       func organizeIntoSubfolders() async
       func installersCrossRef(apps: [InstalledApp]) -> [DownloadFile]  // .dmg/.pkg with apps installed
   }
   ```

2. **`scan()`** — enumerate `~/Downloads` using `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:[.fileSizeKey, .creationDateKey, .contentModificationDateKey])`. Skip hidden files and `.DS_Store`.

3. **Installer cross-reference** — for `.dmg`/`.pkg` files, extract app name from filename, compare against `AppScanner.scanApps()` results. Mark as "Safe to remove" if app is installed.

4. **Create `DownloadsView.swift`** — tab within FilesView:
   - Summary header: "X files · Y GB" with breakdown bar (color-coded by age group)
   - Segmented picker: "By Age" / "By Type"
   - Collapsible sections per group with file count + total size
   - "Installed Installers" callout section with green "Safe to remove" badges
   - Bottom bar: "Clean Stale (X files, Y GB)" + "Organize" buttons

5. **Size threshold alert** — in `AppState.refreshMetrics()`, check Downloads folder size. If > 5 GB and not alerted in 24h, fire `AlertManager` notification.

### Test plan
- [ ] Open Files → Downloads tab → all files from `~/Downloads` listed
- [ ] "By Age" view → files grouped correctly (today's downloads in "Today")
- [ ] "By Type" view → correct categorization (PDF, Archive, Installer, etc.)
- [ ] Installed installer detection → .dmg for installed app shows "Safe to remove"
- [ ] "Clean Stale" → confirmation → files move to Trash
- [ ] "Organize" → subdirectories created → files sorted by type
- [ ] Downloads > 5 GB → notification fires
- [ ] Empty ~/Downloads → shows "Downloads folder is empty" state

### Acceptance criteria
- All ~/Downloads files enumerated with correct sizes and dates
- Both age-based and type-based grouping work correctly
- Installer cross-reference correctly identifies safe-to-remove .dmg/.pkg files
- Stale files (90+ days) correctly identified and trashable
- No data loss — all deletions via `trashItem`

### Integration point
New **"Downloads"** tab in the **Files** module. Also surfaced as a Smart Scan category.

---

## F-027 · Snippet Manager & Text Expansion Engine (Clipboard Evolution)

**Status:** 📋 Queued — #10 (was 💡 Future Idea; promoted and merged with F-040)  
**Effort estimate:** 3.5 days  
**Theme:** User Productivity  
**Branch naming (when ready):** `feat/f027-snippet-manager`  
**Depends on:** Clipboard module (this is a direct evolution of it)

### Why
The Clipboard module is already a strong differentiator. Extending it from a passive recorder into an active snippet manager makes it compete with TextExpander and Raycast's snippet feature — tools that charge $40/year and $49/year respectively. The existing infrastructure (ClipboardMonitor, quick-picker overlay ⌘⇧V, 500-item history, AppState) already provides nearly all the plumbing needed.

*Merged with F-040 (Snippet / Text Expansion Engine, Raycast-inspired) — adds dynamic placeholder expansion (`{date}`, `{clipboard}`, `{uuid}`, `{random:N}`), keyword trigger prefixes, bundled starter packs, and import from CSV / ray.so snippet URLs. Inspired by Raycast Snippets Explorer (ray.so/snippets) and the `clipboard-sequential-paste` extension.*

### What it delivers
- Any clipboard history item can be promoted to a permanent **Snippet** with a custom label, category tag (e.g., "Dev", "Email", "Address"), and optional keyword trigger
- Snippets persist indefinitely across reboots, unlike the rolling history cap
- Searchable by label, tag, and content
- Collections: user-created folders of related snippets (e.g., "SQL Queries", "Email Templates", "Addresses")
- The existing `⌘⇧V` quick-picker overlay gains a **"Snippets"** tab alongside History — identical UX, different data source
- **Dynamic placeholder expansion** *(from F-040)*:
  - `{date}` → current date (localized)
  - `{time}` → current time
  - `{clipboard}` → current clipboard contents
  - `{uuid}` → freshly generated UUID
  - `{random:N}` → random alphanumeric string of length N
- **Keyword trigger prefixes** *(from F-040)*: snippets can be triggered by typing a keyword (e.g., `//sig` → expands to full email signature)
- **Bundled starter snippet packs** *(from F-040)*: 20 pre-loaded snippets (Symbols: →←✓✗•, Date/Time templates, Dev shortcuts: `console.log()`, `print()`, Email templates)
- **Import** *(from F-040)*: from CSV, Raycast snippet format (ray.so URLs), and JSON files
- Model change: `ClipboardItem` gains optional `snippetLabel: String?`, `snippetCollection: String?`, and `isSnippet: Bool` fields

### Files to create
```
Halo/Features/Clipboard/SnippetManager.swift        — @MainActor singleton; CRUD, expansion engine, import
Halo/Features/Clipboard/SnippetEditorView.swift      — create/edit snippet sheet
Halo/Features/Clipboard/SnippetListSection.swift     — list section in ClipboardView
```

### Models (add to `Models.swift`)
```swift
struct TextSnippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String                    // "Email Signature"
    var trigger: String                 // "//sig"
    var body: String                    // "Best regards,\n{clipboard}"
    var category: String                // "Email", "Code", "Symbols"
    var usageCount: Int = 0
    var createdAt: Date = Date()
}
```

### Data sources
- Extension of the existing `ClipboardItem` model and `AppState.clipboardItems` store
- Snippet persistence: separate `UserDefaults` key (`"haloSnippets"`) as JSON-encoded `[TextSnippet]`

### Implementation steps

1. **Create `SnippetManager.swift`**
   ```swift
   @MainActor
   final class SnippetManager: ObservableObject {
       static let shared = SnippetManager()
       @Published var snippets: [TextSnippet] = []
       private let storageKey = "haloSnippets"

       func add(_ snippet: TextSnippet)
       func update(_ snippet: TextSnippet)
       func delete(_ snippet: TextSnippet)
       func expand(_ snippet: TextSnippet) -> String  // replaces {date}, {clipboard}, {uuid}, {random:N}
       func search(_ query: String) -> [TextSnippet]
       func importFromCSV(url: URL) async
       func importFromRaycast(json: Data) async
       func loadStarterPack()  // 20 bundled snippets, only on first launch
   }
   ```

2. **Create `SnippetEditorView.swift`** — sheet for create/edit:
   - Name, trigger keyword, body (multi-line with placeholder insertion buttons), category picker
   - Live preview showing expanded result

3. **Create `SnippetListSection.swift`** — section in ClipboardView:
   - Filterable list grouped by category; each row shows name, trigger badge, body preview
   - Click to copy expanded text; context menu: Edit, Duplicate, Delete

4. **Quick Picker integration** — add "Snippets" tab to `ClipboardQuickPickerView` and `QuickActionPickerView`

5. **Starter pack** — load 20 predefined snippets on first launch (`UserDefaults["haloSnippetsLoaded"]` guard)

### Test plan
- [ ] Create snippet `//sig` → body `"Best regards,\n{clipboard}"` → paste "John" → expand → "Best regards,\nJohn"
- [ ] `{date}` → expands to today's date; `{uuid}` → valid UUID; `{random:8}` → 8-char string
- [ ] Search "sig" in `⌘⇧V` Quick Picker → snippet appears → select → expanded text pasted
- [ ] Import CSV with 10 snippets → all appear in library
- [ ] Collections: create "Email" collection → assign snippets → filter by collection
- [ ] Starter pack loads on first launch, not on subsequent launches
- [ ] Delete snippet → removed → no longer searchable

### Acceptance criteria
- All 5 placeholder types expand correctly
- Snippets persist across app restarts
- Quick Picker integration works alongside clipboard history
- Starter snippet pack loads on first launch
- Import from CSV and JSON works

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

**Status:** ✅ Done — `feat/f029-scheduled-reports` branch (2026-08)  
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

### As actually built
Scope was narrowed from the original 6-bullet digest plan for honesty, following the same principle as F-019's "verified data only" approach:
- **Health score trend** — REAL. New `MetricsHistory` actor-adjacent `@MainActor` store samples once/hour (a dedicated slow timer in `AppState`, deliberately separate from the existing 2 s metrics timer) and persists a rolling 168-sample (7-day) buffer to `UserDefaults`. Powers both the new `HealthTrendCard` Dashboard sparkline and the digest body.
- **"Top storage growers"** — simplified to a real week-over-week **disk-free delta** (current `diskFreeGB` vs. the oldest sample in the 7-day window) rather than the originally-imagined "largest files added" audit, which would need a full filesystem diff Halo doesn't otherwise track. This is called out explicitly in the digest body as a GB delta, not a fabricated file list.
- **"Apps with high average RAM"** — built as a real, if coarse, minimal version: the hourly `MetricsHistory` sample also captures the top 5 RAM processes via the existing `ProcessMonitor.topProcesses(sortBy: .ram)` (already used by the Performance module's Top Processes section). The digest aggregates these hourly readings into a per-app average RAM ranking (`WeeklyDigestGenerator.composeSummary` → `RankedApp`). This is genuinely real data, just sampled hourly rather than continuously — an app that spiked RAM briefly between samples won't be caught.
- **Backup status** — **omitted**. Halo has no Time Machine integration yet (that's F-022, still a Future Idea in this pipeline) — rather than fabricate a backup-status line, the digest simply doesn't include one.
- **Threats detected / scans completed** — REAL, filtered from `AlertLog.entries` over the digest period.
- **PDF attachment / NSSharingService** — built as a "Share Weekly Report Now…" button in Settings (generates the existing 4-page `ReportGenerator` PDF to a temp file and opens `NSSharingServicePicker` — Mail/AirDrop/Messages), plus the notification's "View Report" action button which reuses the Dashboard's existing Export Report flow (save panel). Not a true PDF *attachment* inside the notification banner itself — macOS `UNNotificationAttachment` is meant for images/audio/video preview thumbnails, not documents, so attaching a PDF there would render awkwardly; the two explicit share paths above are the honest equivalent.
- **Delivery + schedule** — new `WeeklyDigestScheduler` (mirrors `ScanScheduler`'s `NSBackgroundActivityScheduler` pattern exactly, with its own `com.halo.mac.weeklydigest` identifier so it's fully independent of the Smart Scan schedule). Settings → General → "Weekly Digest" section reuses the identical day/hour `Picker` UI as "Scheduled Scans". A "Send Test Digest Now" button lets the user manually fire a digest to verify the flow without waiting for the schedule.

**Files:**
- `Halo/Core/MetricsHistory.swift` — hourly rolling sample store (new)
- `Halo/Core/WeeklyDigestGenerator.swift` — summary composition, notification delivery, `WeeklyDigestScheduler`, `DigestNotificationDelegate` (new)
- `Halo/Features/Dashboard/HealthTrendCard.swift` — 7-day sparkline Dashboard card (new)
- `Halo/Core/Models/Models.swift` — `MetricsSample`, `ProcessRAMSample`, `RankedApp`, `WeeklyDigestSummary`
- `Halo/App/AppState.swift` — `metricsHistoryTimer` (hourly), `recordMetricsHistorySample()`
- `Halo/App/HaloApp.swift` — `WeeklyDigestScheduler.shared.start(appState:)` alongside `ScanScheduler.shared.start(appState:)`
- `Halo/Features/Onboarding/OnboardingView.swift` — "Weekly Digest" section in `SettingsView`'s General tab
- `Halo/Features/Dashboard/DashboardView.swift` — `HealthTrendCard()` added to the Dashboard stack

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

*Last updated: v4.0 · 25 features shipped (F-001–F-015 + F-026, F-027, F-031–F-034, F-036–F-039, F-041–F-042) · 13 future ideas remaining (F-016–F-025, F-028–F-030)*

---

---

# Raycast-Inspired Features — Queued Execution Plans (F-031 → F-042)

> **Source:** Analysis of [raycast/extensions](https://github.com/raycast/extensions) (2,962 extensions) and [raycast/ray-so](https://github.com/raycast/ray-so) (8 web tools). Features are ordered by effort (quick wins first) to maximize velocity.

---

## F-031 · Dock & Desktop Tinker Actions

**Status:** 📋 Queued — #1
**Effort:** 0.5 day
**Branch naming:** `feat/f031-dock-tinker-actions`
**Depends on:** none
**Inspired by:** Raycast `dock-tinker` extension (12 no-view commands)

### Why
Raycast's dock-tinker is one of its most beloved utility extensions — 12 simple `defaults write` commands that modify hidden Dock preferences. These are exactly the kind of power-user tweaks that Halo's `ActionCommand.shell` system was built for. Zero new infrastructure needed — just add entries to `ActionLibrary.predefined`.

### What it delivers
A new **"Dock & Desktop"** action category with 14 shell actions covering spacers, animations, orientation, auto-hide tuning, and resets.

### Implementation steps

1. **`Halo/Core/Actions/ActionModels.swift`** — add new case to `ActionCategory`:
   ```swift
   case dock = "Dock & Desktop"
   ```
   Add corresponding `icon` (return `"dock.rectangle"`), `color` (return `Color(hex: "#06b6d4")`).

2. **`Halo/Core/Actions/ActionLibrary.swift`** — add 14 entries to `predefined` array:

   | # | Name | Script | Sudo |
   |---|------|--------|------|
   | 1 | Add Dock Spacer | `defaults write com.apple.dock persistent-apps -array-add '{"tile-type"="spacer-tile";}' && killall Dock` | No |
   | 2 | Add Small Dock Spacer | `... "small-spacer-tile" ...` | No |
   | 3 | Reset Dock to Default | `defaults delete com.apple.dock && killall Dock` | No |
   | 4 | Toggle Auto-Hide Dock | `osascript -e 'tell app "System Events" to tell dock preferences to set autohide to not autohide of dock preferences'` | No |
   | 5 | Remove Auto-Hide Delay | `defaults write com.apple.dock autohide-delay -float 0 && defaults write com.apple.dock autohide-time-modifier -float 0.5 && killall Dock` | No |
   | 6 | Restore Auto-Hide Delay | `defaults delete com.apple.dock autohide-delay && defaults delete com.apple.dock autohide-time-modifier && killall Dock` | No |
   | 7 | Minimize Effect: Suck | `defaults write com.apple.dock mineffect suck && killall Dock` | No |
   | 8 | Minimize Effect: Scale | `defaults write com.apple.dock mineffect scale && killall Dock` | No |
   | 9 | Minimize Effect: Genie | `defaults write com.apple.dock mineffect genie && killall Dock` | No |
   | 10 | Hide Recent Apps from Dock | `defaults write com.apple.dock show-recents -bool false && killall Dock` | No |
   | 11 | Show Recent Apps in Dock | `defaults write com.apple.dock show-recents -bool true && killall Dock` | No |
   | 12 | Dock Position: Left | `defaults write com.apple.dock orientation left && killall Dock` | No |
   | 13 | Dock Position: Right | `defaults write com.apple.dock orientation right && killall Dock` | No |
   | 14 | Dock Position: Bottom | `defaults write com.apple.dock orientation bottom && killall Dock` | No |

   Each entry follows the existing `ActionItem(name:subtitle:icon:iconColorHex:category:keywords:command:requiresPrivilege:isBuiltIn:)` pattern.

3. **`project.pbxproj`** — no changes needed (existing files modified, no new files).

4. **`CLAUDE.md`** — update predefined action count from 70 to 84. Add "Dock & Desktop" category description.

### Test plan
- [ ] Open Actions → "Dock & Desktop" category tile appears with dock icon
- [ ] Run "Add Dock Spacer" → Dock restarts → spacer tile visible
- [ ] Run "Minimize Effect: Suck" → minimize a window → suck animation plays
- [ ] Run "Reset Dock to Default" → all customizations reverted
- [ ] All 14 actions appear in `⌘⇧A` Quick Picker search
- [ ] Each action shows in execution history with stdout output

### Acceptance criteria
- All 14 Dock actions execute successfully and produce visible changes
- Dock restarts cleanly after each `killall Dock`
- No sudo required for any action

---

## F-032 · Display & Audio Quick Actions

**Status:** 📋 Queued — #2
**Effort:** 0.5 day
**Branch naming:** `feat/f032-display-audio-actions`
**Depends on:** none
**Inspired by:** Raycast `display-modes`, `audio-device`, `1-click-confetti`

### Why
Display and audio switching are among the most-installed Raycast extension categories. These are simple shell/AppleScript actions that Halo's `ActionCommand.shell` handles natively. Two new categories for low effort.

### What it delivers
Two new action categories: **"Display"** (6 actions) and **"Audio"** (5 actions).

### Implementation steps

1. **`ActionModels.swift`** — add two new cases to `ActionCategory`:
   ```swift
   case display = "Display"
   case audio   = "Audio"
   ```
   Icons: `"display"` / `"speaker.wave.3.fill"`. Colors: `"#8b5cf6"` / `"#14b8a6"`.

2. **`ActionLibrary.swift`** — add 11 entries to `predefined`:

   **Display (6):**
   | # | Name | Script |
   |---|------|--------|
   | 1 | Toggle Dark Mode | `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'` |
   | 2 | Screenshot to Clipboard | `screencapture -c && echo "✓ Screenshot copied to clipboard."` |
   | 3 | Screenshot Region to Clipboard | `screencapture -ic && echo "✓ Region screenshot copied to clipboard."` |
   | 4 | Screenshot with 5s Timer | `screencapture -T5 ~/Desktop/screenshot-$(date +%Y%m%d-%H%M%S).png && echo "✓ Screenshot saved to Desktop."` |
   | 5 | Toggle Desktop Icons | Toggle script using `defaults write com.apple.finder CreateDesktop` + `killall Finder` |
   | 6 | Open Display Settings | `open "x-apple.systempreferences:com.apple.Displays-Settings.extension"` |

   **Audio (5):**
   | # | Name | Script |
   |---|------|--------|
   | 1 | Mute Microphone | `osascript -e 'set volume input volume 0' && echo "✓ Microphone muted."` |
   | 2 | Unmute Microphone | `osascript -e 'set volume input volume 100' && echo "✓ Microphone unmuted."` |
   | 3 | Set Volume to 25% | `osascript -e 'set volume output volume 25' && echo "✓ Volume set to 25%."` |
   | 4 | Set Volume to 75% | `osascript -e 'set volume output volume 75' && echo "✓ Volume set to 75%."` |
   | 5 | Toggle Do Not Disturb | `shortcuts run "Toggle Do Not Disturb" 2>/dev/null || echo "⚠ Create a 'Toggle Do Not Disturb' shortcut in Shortcuts.app first."` |

3. **`CLAUDE.md`** — update predefined count (84 → 95) and add category descriptions.

### Test plan
- [ ] "Display" and "Audio" category tiles appear in Actions grid
- [ ] "Toggle Dark Mode" → system appearance switches
- [ ] "Screenshot to Clipboard" → paste in Preview works
- [ ] "Mute Microphone" → System Settings shows input volume at 0
- [ ] All 11 actions searchable via `⌘⇧A`

### Acceptance criteria
- All 11 actions execute and produce correct system changes
- No new files needed — only `ActionModels.swift` and `ActionLibrary.swift` modified

---

## F-033 · System Junk & Developer Cache Cleaner Actions

**Status:** 📋 Queued — #3
**Effort:** 0.5 day
**Branch naming:** `feat/f033-junk-cleaner-actions`
**Depends on:** none
**Inspired by:** Raycast `dev-cache-cleaner`, `dot-underscore-files-cleaner`, `folder-cleaner`

### Why
Developer cache cleanup (CocoaPods, Gradle, Docker, pip, Homebrew) and system junk removal (resource forks, font caches, broken symlinks) are highly requested. These are safe shell commands that expand Halo's existing System and Developer categories.

### What it delivers
12 new actions added to existing categories (7 System, 5 Developer).

### Implementation steps

1. **`ActionLibrary.swift`** — add to `predefined`:

   **System (7 new):**
   | # | Name | Script | Sudo |
   |---|------|--------|------|
   | 1 | Remove ._ Resource Fork Files | `find ~ -name "._*" -type f -delete 2>/dev/null; echo "✓ Resource fork files removed."` | No |
   | 2 | Clear Font Caches | `atsutil databases -remove 2>/dev/null; atsutil server -shutdown 2>/dev/null; atsutil server -ping 2>/dev/null; echo "✓ Font caches cleared. Restart apps to see effect."` | Yes |
   | 3 | Clear User Logs | `rm -rf ~/Library/Logs/* 2>/dev/null; echo "✓ User logs cleared."` | No |
   | 4 | Remove Broken Symlinks | `find ~ -maxdepth 4 -type l ! -exec test -e {} \; -delete 2>/dev/null; echo "✓ Broken symlinks removed."` | No |
   | 5 | Flush Quicklook Cache | `qlmanage -r cache 2>/dev/null; echo "✓ QuickLook cache flushed."` | No |
   | 6 | Clear Launch Services Database | `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user; echo "✓ Launch Services database rebuilt."` | No |
   | 7 | Kill All Background Apps | `osascript -e 'tell application "System Events" to set quitApps to name of every application process whose visible is false and background only is false' -e 'repeat with a in quitApps' -e 'try' -e 'tell application a to quit' -e 'end try' -e 'end repeat' && echo "✓ Background apps quit."` | No |

   **Developer (5 new):**
   | # | Name | Script | Sudo |
   |---|------|--------|------|
   | 1 | Clear CocoaPods Cache | `pod cache clean --all 2>/dev/null && echo "✓ CocoaPods cache cleared." \|\| echo "⚠ CocoaPods not installed."` | No |
   | 2 | Clear Gradle Cache | `rm -rf ~/.gradle/caches 2>/dev/null; echo "✓ Gradle cache cleared."` | No |
   | 3 | Docker System Prune | `docker system prune -f 2>/dev/null && echo "✓ Docker unused images/containers removed." \|\| echo "⚠ Docker not running."` | No |
   | 4 | Clear pip Cache | `pip cache purge 2>/dev/null && echo "✓ pip cache cleared." \|\| pip3 cache purge 2>/dev/null && echo "✓ pip3 cache cleared." \|\| echo "⚠ pip not installed."` | No |
   | 5 | Clear Homebrew Cache | `brew cleanup -s 2>/dev/null && rm -rf $(brew --cache 2>/dev/null) 2>/dev/null && echo "✓ Homebrew cache cleared." \|\| echo "⚠ Homebrew not installed."` | No |

2. **`CLAUDE.md`** — update predefined count (95 → 107) and note new actions.

### Test plan
- [ ] "Remove ._ Resource Fork Files" → runs without error on clean system
- [ ] "Clear Font Caches" → shows admin password dialog → completes
- [ ] "Clear Homebrew Cache" → on system with brew → shows freed space
- [ ] "Docker System Prune" → on system without Docker → shows warning message
- [ ] All 12 actions in Quick Picker search

### Acceptance criteria
- All 12 actions execute and handle missing tools gracefully (informative error, not crash)
- Sudo actions correctly escalate via osascript admin dialog

---

## F-034 · Port Manager

**Status:** 📋 Queued — #4
**Effort:** 2.5 days
**Branch naming:** `feat/f034-port-manager`
**Depends on:** none
**Inspired by:** Raycast `port-manager` (4 commands, named ports, configurable kill signals) and `kill-process` (604k installs)

### Why
Kill Process is Raycast's #1 extension with 604,000 installs. Port management is a top developer need. Halo already has "Kill Process on Port" and "Show All Listening Ports" as quick actions, but a dedicated view with named ports, process grouping, and kill confirmation would be a major upgrade and competitive differentiator.

### What it delivers
- Dedicated port management view showing all listening TCP/UDP ports with process info
- **Named ports**: user-assigned friendly labels ("React Dev → 3000", "Postgres → 5432")
- Kill actions with configurable signal (SIGTERM/SIGKILL/ask)
- Copy commands for debugging (`lsof`, `kill`)
- Auto-refresh (5s interval)
- Optional menu bar integration showing open port count

### Files to create
```
Halo/Core/Scanner/PortScanner.swift           — actor; parses lsof output
Halo/Features/Ports/PortManagerView.swift      — main view
Halo/Features/Ports/PortManagerViewModel.swift  — @MainActor ObservableObject
```

### Models (add to `Models.swift`)
```swift
struct PortEntry: Identifiable, Equatable {
    let id: UUID = UUID()
    let pid: Int32
    let processName: String
    let processPath: String?
    let port: Int
    let protocol_: String           // "TCP" or "UDP"
    let state: String               // "LISTEN", "ESTABLISHED", etc.
    var friendlyName: String?       // user-assigned via named ports
}

struct NamedPort: Codable, Identifiable {
    var id: Int { port }
    let port: Int
    let name: String
}
```

### Implementation steps

1. **Create `Halo/Core/Scanner/PortScanner.swift`**
   ```swift
   actor PortScanner {
       func scan() async -> [PortEntry] {
           // Execute: lsof -iTCP -sTCP:LISTEN -P -n
           // Parse each line: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
           // Extract: processName, pid, port (from NAME column "hostname:port")
           // Also: lsof -iUDP -P -n for UDP listeners
       }
   }
   ```

2. **Create `Halo/Features/Ports/PortManagerViewModel.swift`**
   ```swift
   @MainActor
   final class PortManagerViewModel: ObservableObject {
       @Published var ports: [PortEntry] = []
       @Published var namedPorts: [NamedPort] = []
       @Published var searchText: String = ""
       @Published var isLoading = false
       @Published var killSignal: KillSignal = .ask  // .ask / .sigterm / .sigkill

       private let scanner = PortScanner()
       private let namedPortsKey = "haloNamedPorts"
       private var refreshTimer: Timer?

       func startRefresh()     // 5s timer
       func stopRefresh()
       func refresh() async
       func killPort(_ entry: PortEntry, force: Bool) async
       func killAllByName(_ processName: String) async
       func addNamedPort(port: Int, name: String)
       func removeNamedPort(port: Int)

       var filteredPorts: [PortEntry]  // filtered by searchText + enriched with friendlyName
   }
   ```

3. **Create `Halo/Features/Ports/PortManagerView.swift`**
   - Header: "Open Ports" title + port count badge + refresh button
   - Search bar
   - Port list: each row shows process icon + name + port + protocol + state + friendly name tag
   - Context menu per row: Kill (SIGTERM), Force Kill (SIGKILL), Copy PID, Copy Port, Copy `lsof` command, Copy `kill` command, Show in Finder (process path), Add/Edit Named Port
   - Named ports section: collapsible list with CRUD
   - Empty state: "No listening ports found"
   - Kill confirmation alert: "Kill process <name> (PID <pid>) on port <port>?"

4. **`ContentView.swift`** — add `.ports` to `AppModule` enum and sidebar. Icon: `"network.badge.shield.half.filled"`. Position after Performance.

5. **`AppState.swift`** — add `AppModule.ports` to `moduleOrder` default and `reorderable` list.

6. **`project.pbxproj`** — add 3 new files with UUIDs `6013`/`6014` (PortScanner), `6015`/`6016` (PortManagerView), `6017`/`6018` (PortManagerViewModel).

7. **`CLAUDE.md`** — add Ports module to Modules Status table.

### Test plan
- [ ] Open Ports module → lists all listening ports (compare with `lsof -iTCP -sTCP:LISTEN -P -n` output)
- [ ] Run a dev server (`python3 -m http.server 8080`) → port 8080 appears in list within 5s
- [ ] Kill port 8080 → process terminates → row disappears on next refresh
- [ ] Add named port "Dev Server → 8080" → label appears as green tag on row
- [ ] Search "node" → filters to only Node.js processes
- [ ] Copy `lsof` command → paste in terminal → produces same output
- [ ] Navigate away → timer stops (no background CPU usage)

### Acceptance criteria
- All listening TCP ports displayed with correct PID, process name, and port
- Named ports persist across app restarts
- Kill action terminates the process (verified by `lsof` showing it gone)
- No crash on systems with 0 listening ports

---

## ~~F-035~~ · ~~Downloads Manager~~ — MERGED INTO F-026

> **This feature has been merged into [F-026 · Downloads Folder Organiser & Manager](#f-026--downloads-folder-organiser--manager).** Age-based grouping, visual size breakdown, one-click stale cleanup, and size threshold alerts from F-035 have been absorbed into F-026's expanded card. See F-026 for the combined implementation plan.

---

## F-036 · Customizable Menu Bar Format Strings

**Status:** 📋 Queued — #6
**Effort:** 2 days
**Branch naming:** `feat/f036-menubar-format-strings`
**Depends on:** MenuBarDisplayStyle (already built)
**Inspired by:** Raycast `system-monitor` menu bar (format string tokens, pinnable stats, Free/Used toggle)

### Why
Raycast's system-monitor menu bar is one of its most praised features — users define custom format templates with tokens like `<PERCENT>`, `<VALUE>`, `<TOTAL>`. Halo's current `MenuBarDisplayStyle` enum offers 4 fixed styles. User-configurable format strings would make Halo's menu bar best-in-class while keeping the existing styles as presets.

### What it delivers
- User-editable format string for the menu bar text display
- Token system: `{cpu}`, `{ram}`, `{disk}`, `{battery}`, `{net_down}`, `{net_up}`, `{temp}`, `{health}`
- Preset templates for common configurations
- Live preview in Settings while editing
- Backward-compatible — existing styles become presets

### Implementation steps

1. **`MenuBarView.swift`** — add format string support alongside existing styles:
   ```swift
   enum MenuBarDisplayStyle: String, CaseIterable {
       case icon           // existing
       case textStats      // existing → becomes preset "CPU {cpu}% · RAM {ram}%"
       case miniBar        // existing
       case dot            // existing
       case custom         // NEW — uses format string
   }
   ```

2. **Add `@AppStorage("menuBarFormatString")` to `MenuBarIconView`**
   - Default: `"CPU {cpu}% · RAM {ram}%"`
   - Parser: regex replace `{token}` with live values from `AppState`

3. **Token definitions:**
   | Token | Value | Example |
   |-------|-------|---------|
   | `{cpu}` | CPU usage % (integer) | `42` |
   | `{ram}` | RAM usage % (integer) | `61` |
   | `{ram_used}` | RAM used in GB | `8.2` |
   | `{ram_total}` | RAM total in GB | `16.0` |
   | `{disk}` | Disk usage % | `55` |
   | `{disk_free}` | Disk free in GB | `120.5` |
   | `{battery}` | Battery % | `87` |
   | `{net_down}` | Download speed | `1.2MB/s` |
   | `{net_up}` | Upload speed | `340KB/s` |
   | `{temp}` | CPU temp °C | `45` |
   | `{health}` | Health score | `92` |

4. **Settings UI** — in Menu Bar settings section:
   - Segmented picker: Icon / Text Stats / Mini Bar / Dot / Custom
   - When "Custom" selected: text field with format string
   - Preset buttons: "Minimal", "Standard", "Full", "Network"
   - Live preview showing rendered text
   - Help text listing available tokens

5. **`AppState.swift`** — add computed property `menuBarTokenValues: [String: String]` updated every 2s with all token values.

6. **Rendering** — in `MenuBarIconView`, when style is `.custom`:
   ```swift
   func renderFormatString(_ format: String, values: [String: String]) -> String {
       var result = format
       for (token, value) in values {
           result = result.replacingOccurrences(of: "{\(token)}", with: value)
       }
       return result
   }
   ```

### Test plan
- [ ] Select "Custom" → enter `"{cpu}%"` → menu bar shows "42%"
- [ ] Enter `"↓{net_down} ↑{net_up}"` → menu bar shows live network speeds
- [ ] Select "Standard" preset → format string auto-fills → menu bar shows "CPU 42% · RAM 61%"
- [ ] Invalid token `{foo}` → rendered as literal `{foo}` (no crash)
- [ ] Switch back to "Icon" → icon-only display restored
- [ ] Relaunch → custom format persists

### Acceptance criteria
- Custom format strings render correctly with live data
- All 11 tokens produce correct values
- Preset templates work as one-click shortcuts
- Existing styles (icon/textStats/miniBar/dot) continue working unchanged

---

## F-037 · Celebration & Delight Moments

**Status:** 📋 Queued — #7
**Effort:** 1.5 days
**Branch naming:** `feat/f037-celebration-moments`
**Depends on:** none
**Inspired by:** Raycast `raycast://confetti`, toast lifecycle pattern, HUD feedback hierarchy

### Why
Raycast's confetti animation, success toasts, and sound effects create a sense of accomplishment that makes users feel good about maintaining their system. Halo's dark aesthetic is perfect for particle effects and glow animations. This adds emotional resonance to significant completions.

### What it delivers
- Particle-based celebration overlay triggered on significant events
- Brief success flash animations for action completions
- Configurable via Settings (enable/disable celebrations)
- No impact on app performance — Canvas-based, auto-dismiss after 2s

### Files to create
```
Halo/DesignSystem/CelebrationOverlay.swift    — Canvas particle system
```

### Implementation steps

1. **Create `CelebrationOverlay.swift`**
   ```swift
   struct CelebrationOverlay: View {
       @Binding var isActive: Bool
       let type: CelebrationType

       var body: some View {
           if isActive {
               TimelineView(.animation) { timeline in
                   Canvas { context, size in
                       // Draw particles based on type
                   }
               }
               .allowsHitTesting(false)
               .onAppear {
                   DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                       withAnimation { isActive = false }
                   }
               }
           }
       }
   }

   enum CelebrationType {
       case healthySystem      // green sparkle burst (health score ≥ 90 after scan)
       case spaceRecovered     // blue particles floating up (cleanup freed > 1 GB)
       case scanComplete       // subtle glow pulse (any scan completes)
       case actionSuccess      // brief green checkmark flash (action completes)
   }
   ```

2. **Particle system** — each `CelebrationType` generates different particles:
   - `healthySystem`: 30 green/cyan circles, random velocity, fade over 2s
   - `spaceRecovered`: 20 blue/purple circles, upward drift, size counter
   - `scanComplete`: single expanding ring from center, fade at edges
   - `actionSuccess`: green checkmark scales up then fades

3. **Trigger points** — add `NotificationCenter` post at key moments:
   - `SmartScanView` → after scan completes with score ≥ 90 → `.healthySystem`
   - `CleanupViewModel` → after cleanup frees > 1 GB → `.spaceRecovered`
   - `ScanCoordinator` → after any scan completes → `.scanComplete`
   - `ActionRunner` → after action state becomes `.completed` → `.actionSuccess`

4. **`HaloApp.swift` / `ContentView.swift`** — add `CelebrationOverlay` as a ZStack overlay at the root level:
   ```swift
   ZStack {
       NavigationSplitView { ... }
       CelebrationOverlay(isActive: $showCelebration, type: celebrationType)
   }
   ```

5. **Settings toggle** — `@AppStorage("enableCelebrations") var enableCelebrations = true` in Settings → General.

6. **`project.pbxproj`** — add `CelebrationOverlay.swift`.

### Test plan
- [ ] Run Smart Scan → score ≥ 90 → green sparkle burst plays for 2s
- [ ] Run Cleanup → free > 1 GB → blue particles animation plays
- [ ] Run any action → brief green checkmark flash
- [ ] Disable celebrations in Settings → no animations play
- [ ] Animation does not block UI interaction (allowsHitTesting false)
- [ ] Rapid successive triggers → animations don't stack/crash

### Acceptance criteria
- All 4 celebration types animate correctly
- Animations auto-dismiss after 2 seconds
- No UI interaction blocked during animation
- Celebrations toggleable via Settings

---

## F-038 · Code Snippet Beautifier

**Status:** 📋 Queued — #8
**Effort:** 3 days
**Branch naming:** `feat/f038-code-beautifier`
**Depends on:** Clipboard module
**Inspired by:** ray.so Code Image Generator (40 themes, 80 languages, PNG/SVG export at 2x/4x/6x)

### Why
ray.so is Raycast's most visible product — developers share code screenshots daily on social media, Slack, and documentation. A native macOS equivalent eliminates the browser round-trip and leverages the clipboard. This would be a unique feature that no macOS system utility currently offers.

### What it delivers
- Detect code on clipboard → present in a styled code card
- Syntax highlighting for 10+ languages (Swift, Python, JavaScript, TypeScript, Go, Rust, Java, Ruby, HTML, CSS, JSON, Bash)
- 8 themes matching Halo's dark aesthetic
- Customization: padding, background gradient, window chrome, font, line numbers
- Export as PNG (2x/4x), copy to clipboard, save to file

### Files to create
```
Halo/Features/CodeBeautifier/CodeBeautifierView.swift       — main sheet view
Halo/Features/CodeBeautifier/CodeTheme.swift                — theme definitions
Halo/Features/CodeBeautifier/SyntaxHighlighter.swift        — regex-based highlighter
Halo/Features/CodeBeautifier/CodeCardRenderer.swift         — NSView → PNG export
```

### Implementation steps

1. **Create `SyntaxHighlighter.swift`**
   ```swift
   final class SyntaxHighlighter {
       enum Language: String, CaseIterable {
           case swift, python, javascript, typescript, go, rust,
                java, ruby, html, css, json, bash, sql, plaintext
       }

       func highlight(code: String, language: Language, theme: CodeTheme) -> NSAttributedString {
           // Regex-based token matching for: keywords, strings, comments,
           // numbers, functions, types, operators
           // Apply NSFont + NSColor from theme
       }

       static func detectLanguage(from code: String) -> Language {
           // Heuristics: import/func/let → Swift, def/import → Python, etc.
       }
   }
   ```

2. **Create `CodeTheme.swift`**
   ```swift
   struct CodeTheme: Identifiable {
       let id: String
       let name: String
       let background: (Color, Color)      // gradient from/to
       let keyword: Color
       let string: Color
       let comment: Color
       let function: Color
       let number: Color
       let type: Color
       let foreground: Color
       let font: String                     // "SF Mono", "JetBrains Mono", etc.
   }

   extension CodeTheme {
       static let midnight = CodeTheme(...)   // Halo's dark blue
       static let noir = CodeTheme(...)       // Pure black
       static let aurora = CodeTheme(...)     // Green/cyan gradient
       static let sunset = CodeTheme(...)     // Orange/red gradient
       static let ocean = CodeTheme(...)      // Blue gradient
       static let forest = CodeTheme(...)     // Green gradient
       static let candy = CodeTheme(...)      // Pink/purple gradient
       static let ice = CodeTheme(...)        // Light blue/white
   }
   ```

3. **Create `CodeBeautifierView.swift`** — presented as a sheet:
   - Live preview: NSViewRepresentable rendering the highlighted code card
   - Controls sidebar: theme picker, language picker, padding (16/32/64/128), background toggle, line numbers toggle, font picker, window chrome toggle
   - Export buttons: "Copy Image", "Save PNG (2x)", "Save PNG (4x)"
   - Code editing: editable text area (user can paste and tweak)

4. **Create `CodeCardRenderer.swift`** — renders the code card to PNG:
   ```swift
   final class CodeCardRenderer {
       func render(code: NSAttributedString, theme: CodeTheme,
                   padding: CGFloat, showBackground: Bool,
                   showChrome: Bool, scale: CGFloat) -> NSImage {
           // Create NSView hierarchy:
           //   Background gradient (if enabled)
           //   → Rounded rect card with shadow
           //     → Window chrome (traffic lights + title)
           //     → Code text view
           // Render to NSBitmapImageRep at given scale
       }
   }
   ```

5. **Integration** — add "Beautify Code" action to Clipboard category in `ActionLibrary`:
   ```swift
   ActionItem(
       name: "Beautify Code",
       subtitle: "Create a beautiful code screenshot from clipboard",
       command: .builtIn(.beautifyCode), ...)
   ```
   Add `.beautifyCode` case to `BuiltInAction` enum. `ActionRunner` presents `CodeBeautifierView` sheet.

6. **`project.pbxproj`** — add 4 new files.

### Test plan
- [ ] Copy Swift code → run "Beautify Code" → sheet opens with highlighted preview
- [ ] Auto-detect language: Swift code → "Swift" pre-selected
- [ ] Switch themes → preview updates in real-time
- [ ] Toggle background off → transparent card (checkered pattern in preview)
- [ ] "Copy Image" → paste in Slack/Discord → image renders correctly
- [ ] "Save PNG (4x)" → 4x resolution file saved
- [ ] Empty clipboard → sheet shows "No code on clipboard" message

### Acceptance criteria
- Syntax highlighting works for at least 10 languages
- All 8 themes render with correct gradient backgrounds
- PNG export produces clean, high-resolution images
- Export works at 2x and 4x resolutions

---

## F-039 · Auto-Quit Idle Apps

**Status:** 📋 Queued — #9
**Effort:** 2.5 days
**Branch naming:** `feat/f039-auto-quit-idle-apps`
**Depends on:** none
**Inspired by:** Raycast `auto-quit-app` extension

### Why
A unique "smart resource reclamation" feature that no standalone macOS app does well. Monitors running apps for idle state (no visible windows) and suggests quitting them to free RAM. Aligns perfectly with Halo's "system health" identity and directly improves the health score.

### What it delivers
- Background monitoring of running apps for idle state
- Configurable timeout (15m / 30m / 1h / 2h)
- Notification before auto-quitting: "Figma has been idle for 1h — quit to free 850 MB?"
- Allowlist/blocklist for apps to include/exclude
- Dashboard integration showing "Apps auto-quit today: N, RAM recovered: X GB"
- Suggest-only mode (default) vs auto-quit mode

### Files to create
```
Halo/Core/Scanner/IdleAppMonitor.swift           — actor; tracks app idle state
Halo/Features/Performance/IdleAppsSection.swift   — view section in Performance
```

### Implementation steps

1. **Create `IdleAppMonitor.swift`**
   ```swift
   actor IdleAppMonitor {
       struct IdleApp: Identifiable {
           let id: String               // bundle ID
           let name: String
           let icon: NSImage?
           let ramMB: Double
           let idleSince: Date
           var idleDuration: TimeInterval
       }

       private var lastActiveTime: [String: Date] = [:]  // bundleID → last active
       private var excludeList: Set<String> = []

       func startMonitoring()    // observe NSWorkspace notifications
       func stopMonitoring()
       func idleApps(timeout: TimeInterval) -> [IdleApp]
       func quitApp(bundleID: String) async -> (Bool, Double)  // returns (success, ramFreedMB)
   }
   ```

2. **Idle detection** — observe `NSWorkspace.didActivateApplicationNotification` to track `lastActiveTime[bundleID] = Date()`. An app is "idle" when:
   - `Date() - lastActiveTime[bundleID] > timeout`
   - App has 0 visible windows (check via `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)`)
   - App is not in the exclude list
   - App is not a menu bar-only app (no `activationPolicy == .accessory`)

3. **Notification flow** — when an app becomes idle past threshold:
   - In suggest-only mode: fire `AlertManager` notification with "Quit" and "Ignore" actions
   - In auto-quit mode: fire notification, wait 30s, then `NSRunningApplication.terminate()`

4. **Create `IdleAppsSection.swift`** — section in PerformanceView:
   - List of currently idle apps with: app icon, name, idle duration, RAM usage
   - "Quit" button per app with confirmation
   - "Quit All Idle" button
   - Settings: timeout picker, mode toggle (suggest/auto), exclude list editor

5. **`AppState.swift`** — add `@Published var appsQuitToday: Int = 0` and `@Published var ramRecoveredTodayMB: Double = 0`.

6. **Dashboard integration** — add "Idle Apps" metric card showing quit count and RAM recovered.

7. **Settings** — in Performance settings section:
   - Enable/disable idle app monitoring
   - Timeout: 15m / 30m / 1h / 2h picker
   - Mode: Suggest / Auto-Quit
   - Exclude list: multi-app picker showing running apps

8. **`project.pbxproj`** — add 2 new files.

### Test plan
- [ ] Open Figma → close all windows → wait timeout → notification appears
- [ ] "Quit" from notification → Figma terminates → RAM freed shown
- [ ] Add Figma to exclude list → no notification for Figma
- [ ] Menu bar-only apps (1Password, Bartender) → never flagged as idle
- [ ] Suggest mode → notification only, no auto-quit
- [ ] Auto-quit mode → app quits 30s after notification
- [ ] Dashboard shows "Apps quit today: 2, RAM recovered: 1.2 GB"

### Acceptance criteria
- Idle apps correctly detected based on window count and active time
- Notifications fire at correct timeout intervals
- Exclude list prevents monitoring of specified apps
- No crash when monitored app quits on its own

---

## ~~F-040~~ · ~~Snippet / Text Expansion Engine~~ — MERGED INTO F-027

> **This feature has been merged into [F-027 · Snippet Manager & Text Expansion Engine](#f-027--snippet-manager--text-expansion-engine-clipboard-evolution).** Dynamic placeholder expansion (`{date}`, `{clipboard}`, `{uuid}`, `{random:N}`), keyword trigger prefixes, bundled starter packs, and import from CSV/ray.so have been absorbed into F-027's expanded card. See F-027 for the combined implementation plan.

---

## F-041 · Shareable Action Configurations

**Status:** 📋 Queued — #11
**Effort:** 2 days
**Branch naming:** `feat/f041-shareable-actions`
**Depends on:** Actions module
**Inspired by:** ray.so URL-encoded state sharing, Raycast `raycast://` deep link import

### Why
ray.so's killer insight: every configuration is a URL. For Halo, this means custom actions become portable — a developer creates a useful action and shares it with their team via a link or QR code. This creates network effects and community around Halo's action library.

### What it delivers
- "Share" button on custom actions → generates `halo://action/BASE64` deep link
- Import flow: clicking the link opens Halo with an import confirmation sheet
- QR code export for in-person sharing (workshops, team meetings)
- Batch import/export as JSON file

### Implementation steps

1. **Register `halo://` URL scheme** in `Halo/Resources/Info.plist`:
   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLSchemes</key>
           <array><string>halo</string></array>
           <key>CFBundleURLName</key>
           <string>com.halo.mac</string>
       </dict>
   </array>
   ```

2. **URL format:**
   ```
   halo://action/{base64-json}          — single action import
   halo://actions/{base64-json-array}   — batch import
   ```
   JSON is the `ActionItem` struct encoded, then Base64url-encoded.

3. **`HaloApp.swift`** — add `.onOpenURL` handler:
   ```swift
   .onOpenURL { url in
       guard url.scheme == "halo" else { return }
       switch url.host {
       case "action":
           let json = Data(base64Encoded: url.pathComponents[1])
           let action = try JSONDecoder().decode(ActionItem.self, from: json)
           appState.pendingActionImport = action
       case "actions":
           // batch decode
       default: break
       }
   }
   ```

4. **Create `ActionImportSheet.swift`** — confirmation sheet:
   - Shows action preview: name, icon, category, script preview (first 5 lines)
   - Warning if `requiresPrivilege == true`: "This action requires admin privileges"
   - "Import" and "Cancel" buttons
   - On import: `ActionLibrary.shared.add(custom: action)`

5. **Share flow** in `CustomActionEditor.swift` and `ActionsView.swift`:
   - "Share" button → generates URL → presents `NSSharingServicePicker`
   - Options: Copy Link, AirDrop, Messages, QR Code
   - QR code: generate using `CIFilter.qrCodeGenerator()` → display in a sheet

6. **Export/Import as JSON file:**
   - "Export All Custom Actions" → `NSSavePanel` → writes JSON array
   - "Import Actions from File" → `NSOpenPanel` → reads JSON → batch import with confirmation

7. **`project.pbxproj`** — add `ActionImportSheet.swift`.

### Test plan
- [ ] Create custom action → Share → Copy Link → open link in Safari → Halo opens with import sheet
- [ ] Import sheet shows correct action preview → "Import" → action appears in library
- [ ] QR code generation → scan with iPhone → opens link → Halo imports
- [ ] Privileged action → import sheet shows warning badge
- [ ] Export all → save JSON → delete all custom → import JSON → all restored
- [ ] Invalid URL → Halo ignores gracefully (no crash)

### Acceptance criteria
- Deep link import works end-to-end (URL → confirmation → library)
- QR code generates and scans correctly
- JSON export/import preserves all action properties
- Privileged actions show warning before import

---

## F-042 · Siri Shortcuts / App Intents

**Status:** ✅ Done
**Effort:** 4 days
**Branch naming:** `feat/f042-app-intents`
**Depends on:** AppState
**Inspired by:** Raycast AI-callable tools pattern (typed inputs, JSDoc descriptions, confirmation dialogs)

### Why
Raycast's newest pattern — AI-callable tools — shows where developer tools are heading. Apple's equivalent is App Intents / Siri Shortcuts. Exposing Halo's capabilities as Shortcuts actions makes it composable with other apps, automatable, and discoverable via Siri. This is the highest-impact strategic investment for long-term platform integration.

### What it delivers
- 8 App Intents exposing Halo's core capabilities to Shortcuts
- Discoverable in Shortcuts.app with parameter configuration
- Siri-invocable: "Hey Siri, what's my Mac's health score?"
- Composable with other Shortcuts actions for automation

### Files to create
```
Halo/Intents/GetHealthScoreIntent.swift
Halo/Intents/GetCPUUsageIntent.swift
Halo/Intents/GetBatteryHealthIntent.swift
Halo/Intents/GetDiskSpaceIntent.swift
Halo/Intents/RunSmartScanIntent.swift
Halo/Intents/RunActionIntent.swift
Halo/Intents/GetClipboardHistoryIntent.swift
Halo/Intents/ExportReportIntent.swift
Halo/Intents/HaloShortcutsProvider.swift
```

### Implementation steps

1. **Create intent structs** — each follows the `AppIntent` protocol:
   ```swift
   struct GetHealthScoreIntent: AppIntent {
       static var title: LocalizedStringResource = "Get Health Score"
       static var description = IntentDescription("Returns the current Mac health score (0-100)")

       func perform() async throws -> some IntentResult & ReturnsValue<Int> {
           let score = await MainActor.run { AppState.shared.systemHealthScore }
           return .result(value: score)
       }

       static var parameterSummary: some ParameterSummary { Summary("Get Mac health score") }
   }
   ```

2. **Intent catalog:**
   | Intent | Input | Output | Siri phrase |
   |--------|-------|--------|-------------|
   | GetHealthScore | — | Int (0–100) | "What's my Mac's health score?" |
   | GetCPUUsage | — | Double (%) | "What's my CPU usage?" |
   | GetBatteryHealth | — | String | "How's my battery?" |
   | GetDiskSpace | — | String | "How much disk space do I have?" |
   | RunSmartScan | — | String (summary) | "Run a Mac health scan" |
   | RunAction | actionName: String | String (output) | "Run [action name] in Halo" |
   | GetClipboardHistory | count: Int (1–10) | [String] | "Show my clipboard history" |
   | ExportReport | — | IntentFile (PDF) | "Export my Mac health report" |

3. **`RunActionIntent`** — the most complex; needs an `AppEntity` for action discovery:
   ```swift
   struct HaloAction: AppEntity {
       static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Halo Action")
       static var defaultQuery = HaloActionQuery()
       var id: String
       var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
       var name: String
   }

   struct HaloActionQuery: EntityQuery {
       func entities(for identifiers: [String]) async throws -> [HaloAction]
       func suggestedEntities() async throws -> [HaloAction]
   }
   ```

4. **Create `HaloShortcutsProvider.swift`**:
   ```swift
   struct HaloShortcutsProvider: AppShortcutsProvider {
       static var appShortcuts: [AppShortcut] {
           AppShortcut(intent: GetHealthScoreIntent(),
                       phrases: ["What's my Mac's health score in \(.applicationName)"],
                       shortTitle: "Health Score",
                       systemImageName: "heart.fill")
           // ... repeat for each intent
       }
   }
   ```

5. **`RunSmartScanIntent`** — needs confirmation since it's a longer operation:
   ```swift
   func perform() async throws -> some IntentResult & ReturnsValue<String> {
       let coordinator = ScanCoordinator()
       let result = await coordinator.runFullScan()
       return .result(value: "Health score: \(result.score). \(result.issueCount) issues found.")
   }
   ```

6. **`ExportReportIntent`** — returns a PDF file via `IntentFile`:
   ```swift
   func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
       let snapshot = await MainActor.run { ReportSnapshot.capture(from: AppState.shared) }
       let pdf = ReportGenerator.shared.generate(snapshot: snapshot)
       let data = pdf.dataRepresentation()!
       return .result(value: IntentFile(data: data, filename: "Halo-Report.pdf"))
   }
   ```

7. **`project.pbxproj`** — add 9 new files.

8. **`CLAUDE.md`** — add Siri Shortcuts section to documentation.

### Test plan
- [ ] Open Shortcuts.app → search "Halo" → all 8 intents listed
- [ ] Create shortcut with "Get Health Score" → run → returns integer
- [ ] "Hey Siri, what's my Mac's health score?" → Siri responds with number
- [ ] "Run Smart Scan in Halo" → scan executes → summary returned
- [ ] "Export my Mac health report" → PDF file returned to Shortcuts
- [ ] RunAction with "Flush DNS Cache" → action executes → output returned
- [ ] GetClipboardHistory with count=5 → returns last 5 items
- [ ] Automation: "When health score < 60, send notification" → works

### Acceptance criteria
- All 8 intents discoverable in Shortcuts.app
- Siri voice invocation works for at least 3 intents
- RunAction correctly discovers and executes any built-in action
- ExportReport returns a valid PDF file

---

## F-043 — Drive Read & Write Speed Test (NFeat-121)

**Status:** ✅ Done · **Effort:** 2 d · **Depends on:** Files module

### Summary
A dedicated screen to benchmark **read and write throughput** for internal and
external drives, reporting both the **average** (sustained real-world) and
**optimal** (peak/burst) speeds. Lives as a new **"Drive Speed"** tab in the
Files module. On-demand only — zero background footprint.

### Why it's trustworthy (methodology)
- **Uncached I/O** — the benchmark file descriptor is flagged `F_NOCACHE`, so
  reads/writes bypass the unified buffer cache and hit the device. Without this,
  a read test just measures RAM bandwidth.
- **Durable writes** — after each write pass, `F_FULLFSYNC` forces the drive to
  flush its own write-back (DRAM) cache to media, so the write figure is the
  real device speed.
- **Incompressible payload** — the write buffer is filled with random bytes
  (`arc4random_buf`) so dedup/compressing controllers can't inflate results.
- **Average vs Optimal** — every 8 MB chunk is individually timed.
  `average = total bytes ÷ total time`; `optimal = fastest single chunk`.
- **Multi-pass** — 3 passes aggregate all chunk samples for a stable average and
  the best observed peak.

### Files
| File | Role |
|------|------|
| `Halo/Core/Scanner/DriveSpeedTester.swift` | `actor DriveSpeedTester` — volume enumeration + benchmark engine; models `DriveVolume`, `DriveSpeedResult`, `DriveSpeedProgress`, `DriveTestSize`, `DriveSpeedError` |
| `Halo/Features/Files/DriveSpeedView.swift` | `DriveSpeedView` + `@MainActor DriveSpeedViewModel` — volume picker, size picker, live progress, read/write result cards |
| `Halo/Features/Files/FilesView.swift` | Adds `.driveSpeed` tab |
| `HaloTests/DriveSpeedTesterTests.swift` | Unit tests (size bytes, volume enumeration, positive-speed run, cancellation) |

### API
```swift
actor DriveSpeedTester {
    func availableVolumes() -> [DriveVolume]           // internal-first, local & browsable only
    func run(volume:size:progress:) async throws -> DriveSpeedResult
}

enum DriveTestSize { case quick /*128MB*/, standard /*512MB*/, thorough /*1GB*/ }

struct DriveSpeedResult {
    let writeAverageMBps, writeOptimalMBps: Double
    let readAverageMBps,  readOptimalMBps:  Double
    let fileSizeBytes: Int64; let passes, sampleCount: Int; let testedAt: Date
}
```

### Scratch-file safety
- Internal volumes: scratch file lives in `FileManager.temporaryDirectory`
  (sandbox-safe).
- External volumes: scratch file lives in `<volume>/.HaloSpeedTest/`.
- The scratch file is Halo's own temp data (never user files), so it is
  `unlink`-ed immediately in a `defer` — **not** moved to Trash. This is the one
  sanctioned exception to the trashItem-only rule, and is commented as such.

### Known constraints
- **Sandbox (release):** writing to *external* volumes may require user-granted
  access; failures surface as a friendly `DriveSpeedError.notWritable` banner.
- Benchmark writes real data (size × 3 passes) — Thorough = ~3 GB of write I/O.

### Test plan
- [ ] Open Files → Drive Speed → internal volume preselected
- [ ] Run Quick test → progress animates through write then read, 3 passes
- [ ] Result shows Write avg/optimal and Read avg/optimal, optimal ≥ average
- [ ] External drive appears with "External" badge; test writes to it
- [ ] Cancel mid-run → stops cleanly, scratch file removed
- [ ] Read-only / permission-denied volume → friendly error banner
- [ ] Unit tests pass (`-only-testing:HaloTests/DriveSpeedTester`)

### Acceptance criteria
- Internal and external drives both benchmarkable
- Reports average AND optimal for both read and write
- Uncached results (read speed not RAM-inflated)
- No leftover scratch files after run/cancel/error

---

# Upcoming / Planned Features (NFeat-122 → NFeat-127)

> **Detailed requirements + execution plans now live in [`docs/specs/`](specs/README.md)** —
> one self-contained document per feature (F-044 → F-050) plus a shared
> [foundations](specs/00-foundations.md) doc. The cards below remain as the
> short briefing; the `docs/specs/` files are the authoritative specs.
>
> These cards capture the requested intent, references, the privacy/config
> model, and open questions. Status: 🗓 Planned.
>
> **Cross-cutting principle — "Bring Your Own Backend (BYOB)":** Halo is
> open-source. Any cloud-backed feature (SMS sync, clipboard sync, expenditure)
> uses a **user-supplied, user-owned Firebase project**, configurable from
> Settings on **both** the desktop and mobile apps. Halo ships **no shared /
> default backend** — every user's data lives in their own Firebase account.
> This keeps the model private-by-design and avoids Halo operating (or paying
> for) central infrastructure.

---

## F-044 — Shared SMS Console (NFeat-122)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** Firebase integration, Halo Mobile app · **Ref:** *SMSArchiver* project

### Intent
A desktop console that displays SMS messages synced from the user's phone.
The **Halo Mobile app** reads SMS on-device (keyed by phone number) and syncs
them to the user's **configurable Firebase** database; the **Halo desktop app**
reads from that same database and presents a searchable/threaded SMS view.

### Scope
- **Mobile side (NFeat-122 mobile):** read device SMS, sync to Firebase. Owned by the Halo Mobile app (see F-049).
- **Desktop side (this card):** Firebase client + SMS console UI (threads, search, per-number filtering).
- **Config:** Firebase project credentials configurable in Settings on both apps; **no default backend**.

### Open questions (to discuss)
- Firebase product: Firestore vs Realtime DB? Auth model (anonymous, email, service account)?
- Data schema for messages/threads; dedup + incremental sync strategy.
- iOS cannot read arbitrary SMS (platform blocker) — is this **Android-only** on the mobile side? Confirm target platforms.
- Desktop: new sidebar module vs. sub-view. Read-only, or reply/send (likely read-only)?
- Retention, encryption-at-rest, and what exactly leaves the device.

---

## F-045 — Cross-Device Clipboard Sync (NFeat-123)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** Firebase integration, Clipboard module

### Intent
Extend the existing Clipboard module into a **common clipboard interface synced
across the user's devices** via their **configurable Firebase** account. When a
user copies on any connected device, the item is published to their Firebase and
becomes available on the others.

### Scope
- Desktop: hook `ClipboardMonitor` → publish new items to Firebase; subscribe to remote items and merge into history.
- Mobile (NFeat-123 mobile): listen for copy events, push to the same Firebase (see F-049).
- **Config:** same BYOB Firebase account, configurable in Settings on both apps.
- Note: this supersedes the previously **skipped** F-013 "iCloud Clipboard Sync" with a Firebase, user-owned approach (no Pro tier, no iCloud dependency).

### Open questions (to discuss)
- Conflict/ordering model; per-device identity; history cap sync semantics.
- Sensitive-content handling (passwords, tokens) — opt-out rules, TTL, redaction.
- End-to-end encryption before upload? (recommended, since clipboard is high-sensitivity.)
- Mobile clipboard listening constraints (iOS `UIPasteboard` has no background change events; Android has limits) — confirm feasibility per platform.

---

## F-046 — AI Querying — Cloud Providers (NFeat-124)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** none

### Intent
Connect Halo to **leading cloud AI providers** and let the user ask questions /
get answers from within the app.

### Scope
- Provider abstraction with user-supplied API keys (BYO key), configurable in Settings.
- Chat/query surface in the app; likely reuse of the Actions/Quick-picker paradigm.

### Open questions (to discuss)
- Which providers first (Anthropic Claude, OpenAI, Google, local gateway)? Default to latest Claude models.
- Where keys are stored (Keychain) and how requests are scoped/limited.
- Query surface: dedicated module, menu-bar quick-ask, or Actions integration?
- Relationship to F-047 (on-device) — one unified "AI" module with cloud + local backends?

---

## F-047 — On-Device AI & Custom RAG (NFeat-125)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** none

### Intent
An **on-device AI** assistant for quick, local tasks — writing scripts, regex,
and other small snippets, plus suggesting quick responses — backed by a **custom
RAG service** that answers queries grounded in user-provided **context files of
any format**. The user can **choose the model and control GPU usage**.

### Scope
- Local inference runtime (model download/management) with a model picker + GPU/compute setting.
- RAG pipeline: ingest attached files (any format) → chunk/embed → retrieve → answer.
- Output use-cases: scripts, regex, quick replies; likely feeds into Actions/Clipboard/CodeBeautifier.

### Open questions (to discuss)
- Inference stack on macOS: MLX (Apple Silicon), llama.cpp/Metal, or Core ML? GPU-usage control granularity.
- Supported model formats + where models are stored; size/first-run UX.
- RAG: embedding model, vector store (local), file parsers per format (PDF/DOCX/code/etc.).
- Privacy guarantee: fully offline? Interaction with F-046 (cloud) — shared "AI" module with backend toggle.
- Apple Silicon vs Intel support boundary.

---

## F-048 — Personal Expenditure Tracker (NFeat-126)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** F-044 (SMS data via Firebase) · **Ref:** *Hamza* project

### Intent
An **approximate expenditure tracker** built on the SMS data from F-044 (bank/
transaction SMS synced to the user's Firebase). Parse transaction messages to
produce a spending overview. Take inspiration from the *Hamza* project.

### Scope
- Transaction-SMS parser (amount, merchant, debit/credit, date) over the F-044 dataset.
- Aggregation + visualization (by period/category/merchant); "approximate" by design.

### Open questions (to discuss)
- Parsing strategy: rules/regex per bank vs. AI-assisted extraction (ties to F-046/F-047).
- Categorization taxonomy; handling multi-bank / multi-format SMS; currency/locale.
- How much of *Hamza*'s approach/heuristics to adopt; India-centric bank SMS formats?
- Purely local compute on Firebase-sourced data (no third-party financial API).

---

## F-049 — Halo Mobile App (product line)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** F-044, F-045, F-050

### Intent
A **mobile app that extends the Halo desktop app**. It is the device-side half of
several cross-platform features and a new HaloShare peer.

### Mobile feature set (this release)
- **NFeat-122 (mobile):** Shared SMS Console — fetch device SMS, sync to the user's **configurable** Firebase (not a default backend). → pairs with desktop F-044.
- **NFeat-123 (mobile):** Clipboard sync — configurable Firebase; on copy, listen and publish to the user's cloud so data is available across connected devices. 100% private (user's own account). → pairs with desktop F-045.
- **NFeat-127:** HaloShare peer — participate in HaloShare transfers (see F-050).

### Open questions (to discuss)
- Platform(s) & stack: native iOS/Android, or cross-platform (Flutter/React Native/KMP)? (See `docs/MOBILE_PLATFORM_FEATURES.md` for portability analysis.)
- iOS limitations: no SMS read API (F-044 likely Android-only); `UIPasteboard` background-listening constraints for F-045.
- Shared Firebase config UX across desktop + mobile (pairing/QR to copy credentials?).
- Repo/product structure: same repo vs. separate `halo-mobile` repo.

---

## F-050 — HaloShare Mobile ↔ Desktop (NFeat-127)

**Status:** 🗓 Planned · **Effort:** TBD · **Depends on:** HaloShare (LocalSend Protocol v2.1)

### Intent
Extend **HaloShare** — currently desktop↔desktop over the LocalSend-compatible
protocol — to also work **between Halo mobile apps** and desktop (mobile↔desktop
and mobile↔mobile).

### Scope
- Implement the LocalSend v2.1 protocol on the Halo Mobile app (discovery, TLS, consent, transfer).
- Verify interop across desktop↔mobile and mobile↔mobile; ideally still interoperable with the official LocalSend apps.

### Open questions (to discuss)
- Mobile discovery constraints (multicast/mDNS on iOS requires the Local Network entitlement; Android background limits).
- Background transfer + power/foreground requirements on mobile.
- Reuse of the existing `Core/LocalShare` protocol models across platforms.
