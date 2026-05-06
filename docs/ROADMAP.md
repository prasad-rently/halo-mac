# Halo — Roadmap

Remaining BRD iterations, in priority order. Each item includes enough context for an AI agent or new developer to implement it without prior knowledge of the conversation history.

---

## 1. XPC Helper Target (Privileged Operations)

**Why:** The App Store sandbox prevents calling `dscacheutil -flushcache` (DNS), `purge` (RAM), and `diskutil repairPermissions` directly. An XPC helper runs as a separate process with elevated privileges.

**What to build:**
- New target: `HaloHelper` (XPC service, bundle ID `com.halo.mac.helper`)
- Entitlement: `com.apple.security.temporary-exception.mach-lookup.global-name`
- Protocol: `HaloHelperProtocol` with methods `flushDNS()`, `purgeRAM()`, `repairPermissions()`
- Main app calls via `NSXPCConnection` — the XPC service performs the privileged work
- `SMJobBless` or `SMAppService` (macOS 13+) for installation

**Files to create:**
```
HaloHelper/
├── HaloHelper.swift          ← NSXPCListener delegate
├── HaloHelperProtocol.swift  ← shared protocol (compile into both targets)
└── Info.plist
```

**Note:** Until this is built, Performance module maintenance tasks (`FlushDNS`, `PurgeRAM`) are no-ops in sandboxed builds. The debug (non-sandboxed) build can call them directly with `Process`/`shell()`.

---

## 2. ProManager — StoreKit 2

**Why:** Monetisation. The app is free with a Pro upgrade.

**What to build:**
- `Core/ProManager.swift` — `@MainActor final class ProManager: ObservableObject`
- Product IDs: `com.halo.pro.annual` (₹999/yr), `com.halo.pro.lifetime` (₹2,499)
- `AppState.isPro: Bool` is already wired — `ProManager` just needs to set it
- Use `StoreKit.Product.products(for:)` and `Transaction.currentEntitlement(for:)` for restore

**Gating:**
- Clipboard history cap: free = 20 items, pro = 500
- Smart Scan: free = once/week, pro = unlimited
- Protection / Duplicate Finder: pro only

**Files to create:**
```
Core/
└── ProManager.swift
Features/
└── Paywall/PaywallView.swift   ← presented as sheet when user hits a gated feature
```

---

## 3. SignatureDatabase (Malware Definitions)

**Why:** The Protection module currently has sample data. It needs real malware/adware definitions.

**What to build:**
- Bundled `signatures.json` in `Resources/` — initial seed of known bundle IDs, file hashes, and threat metadata
- `Core/Scanner/SignatureScanner.swift` — actor that loads signatures and compares against installed apps
- Delta update endpoint: `GET https://api.halo.mac/signatures/latest.json` with cert pinning (using `URLSession` + custom `URLAuthenticationChallenge` handler)
- Version tracking in `UserDefaults` so updates only download diffs

**Signature JSON schema:**
```json
{
  "version": 42,
  "threats": [
    {
      "bundleId": "com.known.adware",
      "name": "SuperClean Adware",
      "kind": "adware",
      "risk": "high",
      "sha256": ["abc123..."]
    }
  ]
}
```

---

## 4. BGTaskScheduler — Scheduled Smart Scan

**Why:** Users want Halo to scan automatically in the background, e.g., once a week.

**What to build:**
- Register `BGProcessingTaskRequest` with identifier `com.halo.smartscan` in `Info.plist`
- `BGTaskScheduler.shared.register(forTaskWithIdentifier:)` in `HaloApp.init`
- Schedule after scan completes: `BGProcessingTaskRequest(identifier: "com.halo.smartscan")` with `earliestBeginDate = Date(timeIntervalSinceNow: 7 * 86400)`
- On trigger: call `ScanCoordinator.runFullScan()`, then schedule the next one

**Entitlement needed (production):**
```xml
<key>com.apple.developer.background-task-scheduler-allowed-identifiers</key>
<array>
    <string>com.halo.smartscan</string>
</array>
```

---

## 5. Sentry Integration — Crash Reporting

**Why:** Production crash visibility.

**What to build:**
- `Package.swift` already has a placeholder SPM entry — add the real Sentry SDK:
  ```swift
  .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
  ```
- Initialise in `HaloApp.init`:
  ```swift
  SentrySDK.start { options in
      options.dsn = "https://YOUR_DSN@sentry.io/PROJECT_ID"
      options.tracesSampleRate = 0.1
  }
  ```
- Add `SENTRY_DSN` to `Info.plist` (read at runtime, not hardcoded)

**Do not** log any user-identifying data (clipboard contents, file paths) to Sentry.

---

## 6. App Store Submission Assets

**Checklist:**
- [ ] Screenshots: 1440×900 for each of the 5 required App Store screenshots
  - Dashboard (health ring + metrics)
  - Cleanup (scan results)
  - Clipboard (history + quick picker)
  - Files (duplicate finder)
  - Widget (large size on desktop)
- [ ] App Preview video: 30-second MP4 showing key flows
- [ ] Privacy policy URL: `https://halo.mac/privacy`
- [ ] Support URL: `https://halo.mac/support`
- [ ] Release/production entitlements review: ensure `Halo.entitlements` (sandboxed) is used for the archive scheme
- [ ] `PrivacyInfo.xcprivacy` — declare all API usage (NSPasteboard, IOKit, FileManager, NSWorkspace)
- [ ] Notarisation: `xcrun notarytool submit Halo.pkg --apple-id … --team-id R7S39UR27F`

---

## 7. iCloud Sync for Clipboard (Future)

**Why:** Power users want clipboard history across their Mac and iPhone/iPad.

**Approach:** `CloudKit` private database — each `ClipboardItem` becomes a `CKRecord`. Use `CKQuerySubscription` for push-based sync. Requires `com.apple.developer.icloud-container-identifiers` entitlement.

**Complexity:** High — out of scope until Pro tier is established.

---

## Completed

- [x] Dashboard with live health score + metric cards
- [x] Cleanup module — all 10 `CleanupKind` categories
- [x] Protection module — threat detection + permission audit UI
- [x] Performance module — login item manager + maintenance tasks UI
- [x] Applications module — installed app list + deep uninstall
- [x] Files module — SpaceLens + Duplicate Finder (SHA-256) + Large Files
- [x] Clipboard module — history, filter, pin, delete
- [x] Clipboard quick-picker overlay (⌘⇧V global shortcut)
- [x] Menu Bar Extra with live CPU % + popover
- [x] Onboarding flow (3 steps + permission prompts)
- [x] Settings (shortcut recorder, pro toggle placeholder)
- [x] macOS Widget — Small / Medium / Large sizes
- [x] Widget live data pipeline via App Group (60-second refresh)
- [x] HaloTests — DuplicateDetector + Clipboard unit tests
- [x] Dual entitlements (debug non-sandboxed, release sandboxed)
