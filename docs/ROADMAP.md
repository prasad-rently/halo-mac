# Halo — Roadmap

Feature status and future plans. For the detailed iteration pipeline see `docs/FEATURE_ROADMAP.md`.

---

## Completed Features (shipped)

- [x] Dashboard with live health score + metric cards
- [x] Cleanup module — all 10 `CleanupKind` categories
- [x] Protection module — real threat detection via `SignatureDatabase` (45 definitions, auto-updates)
- [x] Performance module — real login item enumeration via `LoginItemScanner` (LaunchAgent/Daemon plists)
- [x] Applications module — installed app list + deep uninstall (12 leftover paths via `AppScanner`)
- [x] Files module — SpaceLens + Duplicate Finder (SHA-256) + Large Files
- [x] Clipboard module — history (500 items), filter, pin, delete
- [x] Clipboard quick-picker overlay (⌘⇧V global shortcut)
- [x] Menu Bar Extra — 4 display styles (icon / text stats / mini bar / dot)
- [x] Onboarding flow (permissions + menu bar style + scan schedule + login item)
- [x] Settings (shortcut recorder, analytics opt-in, scheduled scan config)
- [x] macOS Widget — Small / Medium / Large sizes
- [x] Widget live data pipeline via App Group (60-second refresh)
- [x] HaloTests — DuplicateDetector + Clipboard unit tests
- [x] Dual entitlements (debug non-sandboxed, release sandboxed)
- [x] XPC Helper target (F-002 — privileged ops protocol)
- [x] SignatureDatabase (F-004 — bundled + HTTPS delta updates)
- [x] Sentry crash reporting (F-005 — opt-in, DSN from Info.plist)
- [x] Background Smart Scan scheduling (F-006 — NSBackgroundActivityScheduler)
- [x] Alert history log (F-011 — 50-item persistent in-app log)
- [x] PDF report export (F-012 — 4-page A4 PDF via PDFKit + CoreText)
- [x] Launch at Login toggle (F-014 — SMAppService.mainApp)
- [x] Custom scan schedule — day + hour picker (F-015)

---

## Skipped (user decision)

| Item | Reason |
|------|--------|
| StoreKit 2 ProManager (F-003) | User chose to skip in-app purchases |
| App Store submission assets (F-007) | User chose to skip |
| iCloud Clipboard Sync (F-013) | Depends on F-003 (Pro tier); skipped |

---

## Future / Remaining Items

### 1. StoreKit 2 ProManager

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
Core/ProManager.swift
Features/Paywall/PaywallView.swift
```

---

### 2. App Store Submission Assets

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
- [ ] Replace `SENTRY_DSN_PLACEHOLDER` in `Info.plist` with real Sentry DSN (production build pipeline only — never commit real DSN)

---

### 3. iCloud Clipboard Sync

**Why:** Power users want clipboard history across their Mac and iPhone/iPad.

**Approach:** `CloudKit` private database — each `ClipboardItem` becomes a `CKRecord`. Use `CKQuerySubscription` for push-based sync. Requires `com.apple.developer.icloud-container-identifiers` entitlement.

**Complexity:** High — out of scope until Pro tier is established.

---

### 4. Sentry DSN — Production Setup

Before any release:
1. Create a Sentry project at sentry.io
2. Copy the DSN
3. Set `Info.plist["SentryDSN"]` in the release build pipeline (CI/CD secret injection — **never** commit to source)
4. Verify `enableAnalytics` opt-in flow works end-to-end

---

### 5. Signature Database — Production Endpoint

`SignatureDatabase.checkForUpdate()` currently hits `https://api.halo.mac/signatures/latest.json`. To activate:
1. Host the JSON at that URL (or configure a CDN)
2. Implement server-side versioning (`version` field in JSON)
3. Consider certificate pinning via `URLAuthenticationChallenge` for added security
4. Schedule delta updates on a regular cadence (weekly recommended)
