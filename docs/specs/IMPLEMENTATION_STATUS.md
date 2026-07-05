# Implementation Status — NFeat-122→127 (F-044…F-050)

> **Session handoff.** Where the build stands, what's on which branch/PR, and the
> exact next steps. Read this first when resuming.
> **Last updated:** 2026-07 (end of the planning + F-044 Phase 0 session).

---

## 1. Branches & PRs (all open, user merges)

| Branch | Contains | PR | Base | State |
|--------|----------|----|------|-------|
| `main` | old baseline (`e74a855` haloshare) | — | — | behind |
| `feature/f-043-drive-speed-test` | **F-043 Drive Speed** code + XCUITest/unit-test targets | **#5** | `main` | open (merge 1st) |
| `feature/upcoming-features` | **All planning docs** (`docs/specs/`, roadmaps, mobile roadmap) | **#6** | f-043 branch | open (merge 2nd) |
| `feature/f-044-cloud-foundation` | **F-044 Phase 0 code** (cloud foundation + SMS console) | **#7** | upcoming-features | open (merge 3rd) |
| `feat/maestro-e2e-tests` | pre-existing Maestro/XCUITest | **#1** | — | open (pre-existing) |

**Merge order: #5 → #6 → #7** (stacked; each auto-retargets as the one below merges).

> Note: the working tree is a large uncommitted-history situation — `main` lacks
> much of the current app. Build/verify off the tip of `feature/f-044-cloud-foundation`.

---

## 2. Planning — DONE (PR #6)

Complete, internally-consistent spec set in `docs/specs/`:
- `00-foundations.md`, `firebase-setup.md`, `BUILD_PLAN.md`, `README.md`
- `F-044`…`F-050` (each: decisions, data model, blueprint, deep discussion)
- `pattern-packs/india-bank-sms.v1.json` (Hamza lists)
- `docs/HALO_MOBILE_ROADMAP.md` (mobile backlog + governance; enforced via CLAUDE.md + FEATURE_ROADMAP DoD)

**Settled cross-cutting decisions:** RTDB backend · Email/Password auth
(auto-provisioned) · one shared E2E key · runtime config (no rebuild) · native
Kotlin(Android)+Swift(iOS), monorepo, no-store v1 · `Halo/Core/Cloud` built once,
reused by F-044/045/048.

---

## 3. F-044 Phase 0 — DONE (PR #7)

### Shared cloud layer `Halo/Core/Cloud/` (reused by F-045/F-048)
- **CryptoService** — PBKDF2-HMAC-SHA256 KDF + AES-GCM E2E. Deterministic cross-device key. ✅ unit-tested.
- **CloudModels** — `FirebaseConfig` (runtime, no plist), `CloudAuthCredential`, `CloudPairingPayload` (QR, checksummed). ✅ tested.
- **CloudConfigStore** — Keychain store + wipe/re-key + `makeCryptoService`. ✅ tested (resilient).
- **FirebaseRTDBClient** (actor) — runtime `FirebaseOptions` configure + Email/Password auth + setValue/getValue/removeValue/observeChildAdded.
- **firebase-ios-sdk 11.15.0** (Database+Auth) wired via `scripts/add_firebase_package.rb`.

### Spike result
**✅ S1 PASSED** — firebase-ios-sdk builds+links on macOS with runtime config (no plist). RTDB chosen partly for lighter deps (no source gRPC/abseil).

### SMS console (desktop, M2)
- New **`AppModule.messages`** ("Messages"), routed in `ContentView`.
- `SMSModels` (device/line/message/thread + `SMSCategory`) + compact `SmsClassifier` (Hamza 8-cat port).
- **`SMSSyncClient`** — real cloud source: configure→sign-in→read `sms/{uid}`+`devices/{uid}`→**decrypt**→Device→Line→thread model. `seedSampleData()` writes encrypted samples through the real pipeline (no phone needed).
- **`CloudSetupView`** — manual "Connect your Firebase" UI (config + email/pwd + passphrase).
- `SMSConsoleViewModel` (Combine re-publish) + `SMSConsoleView` (3-pane: lines | threads | messages, search, category chips, empty/connect states).
- **Mock removed** (`MockSMSData` deleted).
- Builds, signs, runs. ✅

### Firebase configuration status
- **Manual config = DONE** (the CloudSetupView setup screen).
- **Assisted auto-provisioning (Google login → provision) = NOT DONE** (S2 OAuth spike).

---

## 4. Next steps (resume here)

**Finish F-044 desktop:**
1. ~~**"Test connection"**~~ ✅ DONE — `FirebaseRTDBClient.testConnection(_:email:password:)` configures a throwaway `HaloCloudTest` app, signs in, writes+reads a `meta/{uid}` token, tears the app down on every exit (retryable). Surfaced in `CloudSetupView` as a "Test connection" button (no passphrase needed) + result banner; `SMSSyncClient.TestResult`/`testResult`.
2. ~~**Live updates**~~ ✅ DONE — `SMSSyncClient` now attaches `child_added` observers (`sms/{uid}` → per-device `lines`/`messages`, `devices/{uid}`) that stream in live and dedup by id into `devicesById`/`linesById`/`messagesById`; message ids are `deviceId/msgId` (collision-safe). `disconnect()` is now async and tears observers down; Refresh = one-shot `reconcile` fallback.
3. ~~**Re-key / wipe UI** (D24/D28) + per-line sync toggle (D29) + new-SMS notification (D30)~~ ✅ DONE:
   - **New `CloudSettingsPane.swift`** (registered via `add_source_files.rb`) — opened from the console gear when connected (CloudSetupView remains for the unconfigured/connect flow). Notification toggle, per-line sync toggles + per-line wipe, per-device wipe, wipe-all, re-key, disconnect; all destructive actions gated behind a `confirmationDialog`.
   - **D30 notification** — `AlertManager.fireExternal(kindRaw:title:body:)` reuses the UNNotification + AlertLog pipeline. `SMSSyncClient.mergeMessage` fires only for genuinely-new messages whose `date >= connectedAt` (skips `child_added` backfill) and only when `notificationsEnabled` (`UserDefaults["smsNotificationsEnabled"]`, default on).
   - **D29 per-line toggle** — `SMSLine.syncEnabled` (reads `syncEnabled` from the line registry); `SMSSyncClient.setLineSync(_:enabled:)` writes it back so the phone's uploader obeys.
   - **D28 wipe** — `wipeAll` / `wipeDevice` / `wipeLine` (per-line reads the messages node and removes rows by `subscriptionId`, so undecryptable rows go too). Observers are torn down/restarted correctly (`removeDeviceObservers`, full restart on wipe-all/re-key) to avoid dupes and the "won't re-attach" bug.
   - **D24 re-key** — `rekey(newPassphrase:)`: rotate salt, wipe `sms/{uid}`+`devices/{uid}`, rebuild crypto, refresh Keychain passphrase cache; devices re-sync under the new key. ← resume here
4. ~~**Device/line registry** decryption polish (own-number, carrier) + "All lines" vs per-line correctness~~ ✅ DONE:
   - **Contact normalization** — `SMSSyncClient.normalizeContact` (keep leading `+` and digits, drop separators; alphanumeric DLT sender IDs kept verbatim) feeds the per-line `threadKey`, so one contact written in different formats no longer splits into multiple threads. Thread display uses the most-recent contact variant.
   - **"All lines" source badge** — thread rows show a "device · line" SIM badge when `selectedLineID == nil` (`SMSConsoleViewModel.isAllLines`/`sourceLabel`), keeping per-line threads distinguishable (a contact on two SIMs = two badged rows).
   - **Line subtitle polish** — `lineSubtitle` drops `Unknown`/`—` placeholders (undecryptable `ownNumberEnc` shows carrier/SIM slot instead of "Unknown · —") and appends "Sync off" when D29 sync is disabled.
5. ~~**Release-sandbox network entitlement** check~~ ✅ DONE:
   - `com.apple.security.network.client` was **already present** in `Halo/Halo.entitlements` (added for signature-DB updates) — covers Firebase's outbound RTDB/Auth traffic under the App Sandbox. Firebase is client-only, so no `network.server` needed.
   - **Added `keychain-access-groups`** (`$(AppIdentifierPrefix)com.halo.mac`) to the release entitlements: FirebaseAuth persists auth state to the Keychain and fails sign-in with `errSecMissingEntitlement (-34018)` under sandbox without it. It's also the default group for Halo's own `CloudConfigStore` items, so their unqualified `SecItem` queries keep resolving.
   - Verified: `plutil -lint` OK; Debug→`Halo-Debug.entitlements` / Release→`Halo.entitlements` mapping correct; **Release configuration builds** with signing off.
   - ⚠️ **Not runtime-verified** — the sandboxed signed app's actual Firebase sign-in needs App Store provisioning + real Firebase creds; couldn't exercise that here. Confirm on a real signed release build before shipping.

**F-044 desktop is now feature-complete** (items 1–5 done).

**S2 assisted-provisioning spike — ✅ DONE (2026-07):**
- Verified against Google docs: **device/limited-input OAuth flow can't request `cloud-platform`** (fixed scope allowlist) → the only viable native flow is **loopback-IP + PKCE authorization code**. Built + RFC-7636-vector-tested: `Halo/Core/Cloud/Provisioning/GoogleOAuthPKCE.swift` (+ `GoogleOAuthPKCETests`, 4 tests). NOT UI-wired.
- Full REST provisioning sequence (R1–R5) mapped in `firebase-setup.md §7` (addFirebase / RTDB instances.create / rules PUT / identitytoolkit config + accounts:signUp / webApps config).
- **Blocker = Google restricted-scope app verification** (policy, not tech). **v1 recommendation: keep the guided wizard** (= existing manual `CloudSetupView`); assisted provisioning is a fast-follow once a verified or per-user OAuth client exists.
- ⚠️ Live provisioning not exercised (no Google consent in the build env).

## 6. F-045 Clipboard Sync — desktop Phase 1+2 DONE (2026-07)

Cross-device clipboard sync reusing the F-044 cloud core (`FirebaseRTDBClient`, `CryptoService`, `CloudConfigStore`). New `Halo/Features/ClipboardSync/`:
- **`ClipboardSyncService`** (`@MainActor`) — publish local copies (encrypt → `clipboard/{uid}/items/{itemId}`) + `observeChildAdded` remote items → decrypt → **history-only** insert (D9, never overwrites the live pasteboard). Echo suppression by `deviceId` (D3) + `seenItemIds` dedup (D8). Cloud rolling-cap eviction to 500 (D4, opportunistic sweep). Stable persisted `deviceId` + `deviceName`.
- **`ClipboardSyncModels`** — `ClipboardSyncEnvelope` (RTDB node ⇄ struct) + `ClipboardSensitiveFilter` (opt-in secret detection: keywords + AWS/GitHub/Slack/JWT/OpenAI/hex patterns; **off by default**, D5).
- **`ClipboardSyncSettingsView`** — sheet from the Clipboard tab bar: status, enable toggle (+ passphrase → connect, cached for auto-reconnect), opt-in sensitive filter, **purge** (cloud + local, D10). Points to Messages module when cloud unconfigured.
- **Model:** `ClipboardItem.syncedFrom` (source device) drives the synced badge in `ClipboardItemRow`.
- **AppState wiring:** local copies publish; remote items land in history via `receiveSyncedClipboardItem`; `clipboardSync` auto-connects on launch iff enabled + configured + passphrase cached.
- **Only text/url/code sync in v1** (D6; image/color skipped). 7 unit tests (filter, envelope round-trip, encrypt→decrypt codec) pass. Builds.
- **Mobile:** F-045 rows already in `HALO_MOBILE_ROADMAP.md` (governance satisfied). Android = AccessibilityService (D7), iOS = foreground push — both land with **F-049**.
- **Not done (deferred):** live 2-device round-trip (needs real Firebase + a phone); concealed-pasteboard-type detection at monitor time; images/Cloud Storage; security review before ship.

## 7. F-048 Expenditure Tracker — desktop v1 DONE (2026-07)

Approximate SMS→expenditure tracker over F-044's synced data. Deterministic Hamza pipeline, rules-only (D14). New `Halo/Features/Expenditure/` + `AppModule.expenditure`:
- **`ExpenditureModels`** — `PatternPack` (Codable; embedded `indiaDefault` = the india-bank-sms.v1 lists/regexes, FR-12) + `ParsedTransaction`/`ParseOutcome`/`TransactionDirection` + category taxonomy (§12).
- **`TransactionParser`** (pure enum) — §11.3 heuristics: `-P`/non-bank/exclude/promo rejects, earliest-verb direction, amount regex with **balance-drop + nearest-to-verb**, account tail + merchant → Ok/Unreadable/NotTransaction.
- **`TransactionPipeline`** (pure) — classify(keep transactional)→parse→**self-transfers** (D7)→**dedup ±120s cross-device** (D8/D15)→categorize→overrides. Re-parse on load = delete-sync mirror (D10).
- **`ExpenditureStore`** — force-include/exclude + re-categorize overrides (D9), persisted to UserDefaults (SQLite TxnStore deferred — re-parse gives the mirror).
- **`ExpenditureViewModel`** — owns an `SMSSyncClient`, flattens `threads`→messages, runs pipeline, month aggregates (spent/received/net, `en-IN` ₹) + category breakdown + CSV export (FR-13).
- **`ExpenditureView`** — month nav, "Approximate" label, summary cards, spend-by-category bars (click to filter), txn list with **source-SMS drill-in** + re-categorize/exclude + confidence/dup/transfer badges, unreadable tally.
- **14 unit tests** (parser corpus incl. every documented Hamza bug fix: URL false-reject, TXN RS verb, balance-drop, nearest-to-verb, autopay; pipeline self-transfer/dedup/override) pass. Builds.
- **Mobile:** F-048 row in `HALO_MOBILE_ROADMAP.md`; mobile parses device SMS directly (D16), lands with **F-049**.
- **Deferred:** calendar-heatmap/weekday/year charts (§11.6 — did month summary + category breakdown), SQLite TxnStore, AI-assist (D14), live end-to-end over real F-044 data (needs a phone + real Firebase).

Remaining cloud work: **F-049 mobile** (native Android/iOS — the real SMS + clipboard source that fills the desktop consoles).

**Then:**
- **S2 spike** — assisted provisioning OAuth + Google app-verification.
- **F-045 clipboard** + **F-048 expenditure** — reuse `Halo/Core/Cloud` (fast once F-044 done).
- **F-049 mobile app** (native) — the Android SMS sync source that fills the console for real.

**Build/verify commands:**
```
# build (signing off)
xcodebuild -project Halo.xcodeproj -scheme HaloTests -configuration Debug \
  -derivedDataPath /tmp/HaloBuild CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
# cloud tests
xcodebuild test -project Halo.xcodeproj -scheme HaloTests -destination 'platform=macOS' \
  -only-testing:HaloTests/CryptoService -only-testing:HaloTests/CloudPairingPayload \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
# sign+run: see CLAUDE.md "Build & Sign" (remove HaloTests.xctest from PlugIns first)
```

**Helper scripts (idempotent, `LANG=en_US.UTF-8 RUBYOPT="-Eutf-8"`):**
`add_source_files.rb` (add file → Halo target) · `add_firebase_package.rb` ·
`add_unittest_target.rb` · `add_uitest_target.rb`.
