# Halo Mobile — Feature Development Roadmap & Backlog

> **This document pioneers Halo-mobile development.** It is the single source of
> truth for **which Halo desktop capabilities come to mobile (iOS + Android),
> in what form, and in what order** — plus the mobile-exclusive features that
> only make sense on a phone.
>
> Deep OS-capability analysis lives in
> [`MOBILE_PLATFORM_FEATURES.md`](MOBILE_PLATFORM_FEATURES.md). The **specs** for
> the first mobile features are in [`specs/`](specs/) (F-044/F-045/F-048/F-049/F-050).
> This file is the **actionable backlog + governance**; those are the details.

---

## 0. Governance — READ BEFORE ADDING ANY FEATURE

Two rules, enforced for every change:

1. **Feasibility study first (mandatory).** Before a feature is added to the
   mobile backlog as "buildable," it must have a **feasibility study** (template
   in §6) covering: the iOS mechanism, the Android mechanism, OS blockers,
   permission cost, store-policy risk, and a verdict. No study → it stays in
   *Unassessed*.
2. **Update this doc when Halo desktop gains a feature.** Every new desktop
   feature (a new `F-xxx`) **must** get a row in the §3 portability table and a
   feasibility study **before** it is considered "done" on desktop. Adding a
   desktop feature without assessing its mobile path is incomplete work.

> Agent/dev note: this rule is mirrored in `CLAUDE.md` so it is not forgotten.
> The desktop `FEATURE_ROADMAP.md` "Definition of Done" includes "mobile
> feasibility row added here."

---

## 1. Legend

**Portability verdict** (per platform):

| Symbol | Meaning |
|--------|---------|
| ✅ Port | Same capability achievable with a native equivalent |
| 🟡 Adapt | Partial / reduced / different mechanism (scoped, foreground-only, coarse) |
| 🔵 Reimagine | Desktop feature inspires a *different* mobile-native capability |
| ❌ Blocked | OS sandbox/policy prevents it; no viable path |

**Backlog status:** `Unassessed` → `Assessed` (has feasibility study) →
`Planned` (has a spec / F-id) → `In progress` → `Done` → `Won't do`.

---

## 2. Executive summary

Halo desktop's value is **deep macOS system access**. Mobile OSes remove most of
that (sandbox, no process/filesystem/daemon access), so a 1:1 port is neither
possible nor desirable. The mobile strategy is three-pronged:

1. **Port the OS-agnostic wins** — anything that's just computation, networking,
   text, or crypto (speed test, code beautifier, snippets, clipboard transforms,
   HaloShare, AI, report export).
2. **Adapt the storage/insight features** to scoped, permissioned mobile APIs
   (storage insights, duplicate photos, battery, network usage, widgets).
3. **Lead with mobile-exclusive value** the desktop can't have — **SMS sync
   (Android), expenditure tracking, app-usage/digital-wellbeing, notification
   insights, permission auditing** — which is where a phone genuinely helps.

The already-specced first wave (F-044/045/048/049/050) is exactly this: mobile is
the *device-side* of cross-platform features + a HaloShare peer.

---

## 3. Master portability table (every desktop capability)

Verdicts are **starting positions**; each "Assessed+" row is backed by a
feasibility study (§6). iOS / Android assessed separately.

| Desktop capability | iOS | Android | Mobile approach | Priority | Status |
|--------------------|:---:|:-------:|-----------------|:--------:|--------|
| **Dashboard — health score** | 🟡 | 🟡 | Recompute from available mobile metrics (fewer inputs) | P1 | Assessed |
| Dashboard — CPU usage | 🟡 | 🟡 | Own-process + coarse system load only | P2 | Assessed |
| Dashboard — RAM | 🟡 | 🟡 | `os_proc_available_memory` / `ActivityManager` | P2 | Assessed |
| Dashboard — storage free/total | ✅ | ✅ | Volume capacity APIs | P1 | Assessed |
| Dashboard — battery level/state | ✅ | ✅ | UIDevice battery / BatteryManager | P1 | Assessed |
| Dashboard — battery health/cycles | ❌ | 🟡 | iOS hides cycles; Android coarse health | P3 | Assessed |
| Dashboard — network throughput | ✅ | ✅ | Traffic counters | P2 | Assessed |
| Dashboard — GPU / temp / sensors | ❌ | 🟡 | No public GPU; Android thermal coarse | P3 | Assessed |
| **Dashboard — App Usage Insights (F-021)** | 🟡 | ✅ | iOS: `DeviceActivity`/`FamilyControls` restricted, same foreground-observation-only fallback as desktop; Android: `UsageStatsManager` gives real system-wide usage history — genuinely **better** than the desktop version | P2 | Assessed ✓ (§9) |
| **Cleanup** (caches/logs/trash) | ❌ | 🟡 | Sandbox: own-cache only; Android → guide to Storage settings | P3 | Assessed |
| **Protection** (malware scan) | ❌ | 🟡 | iOS blocks scanning; Android limited pkg/file heuristics | P3 | Assessed |
| Protection — **Privacy/Sensitive Data Scanner (F-018)** | 🟡 | 🟡 | Scoped to user-picked folders (SAF/document picker) — no broad Downloads/Desktop sweep | P3 | Assessed ✓ (§9) |
| **Performance — top processes** | ❌ | ❌ | No public live-process enumeration | — | Won't do |
| Performance — **memory leak tracker (F-023)** | ❌ | ❌ | Extends top-processes' per-app RAM sampling — same blocked capability (no public API on either OS to read another app's resident memory over time) | — | Won't do |
| Performance — login items | ❌ | ❌ | No equivalent concept | — | Won't do |
| Performance — VPN detection | ✅ | ✅ | NetworkExtension / ConnectivityManager | P2 | Assessed |
| Performance — **speed test** | ✅ | ✅ | Socket-based; fully portable | P1 | Assessed |
| Performance — idle-app auto-quit | ❌ | ❌ | Can't kill other apps | — | Won't do |
| **Applications** — list + uninstall | ❌ | 🟡 | Android PackageManager list + uninstall intent; iOS none | P3 | Assessed |
| **Files — SpaceLens** | 🟡 | 🟡 | Scoped/granted dirs only | P2 | Assessed |
| Files — **Duplicates** | 🟡 | 🟡 | Within granted scope (Photos/Downloads) | P2 | Assessed |
| Files — Large files | 🟡 | 🟡 | Scoped | P3 | Assessed |
| Files — Downloads manager | 🟡 | 🟡 | Downloads dir (Android) / Files (iOS) | P3 | Assessed |
| Files — **Drive Speed (F-043)** | 🟡 | 🟡 | Benchmark internal storage; external limited (OTG Android) | P2 | Assessed |
| Files — **iCloud Drive Analyzer (F-030)** | 🟡 | ❌ | iOS: document-picker-scoped folder enumeration only, same limit as SpaceLens; Android: no iCloud concept exists | P3 | Assessed |
| Files — **Drive Health / S.M.A.R.T. (F-020)** | ❌ | ❌ | No public SMART/drive-health API on either OS — not a permission gap, a total API absence | — | Won't do |
| **Clipboard history** | 🟡 | 🟡 | iOS current-only/foreground; Android 10+ limited → F-045 | P1 | Planned (F-045) |
| **Snippets / text expansion** | ✅ | ✅ | **Strong on mobile** (keyboard extension / IME) | P1 | Assessed ✓ (§9) |
| **Actions** — clipboard/text transforms | ✅ | ✅ | JSON/base64/hash/QR/case… pure compute | P1 | Assessed |
| Actions — system/dock/shell | ❌ | 🟡 | Mostly macOS-only; Android some via intents | P3 | Assessed |
| **Ports manager** | ❌ | ❌ | No socket enumeration of other apps | — | Won't do |
| **Menu Bar styles** | 🔵 | 🔵 | Reimagine: iOS Live Activity/widget; Android tile/notification | P2 | Assessed |
| **Focus Session Companion — app auto-hide + countdown (F-028)** | 🔵 | 🟡 | Auto-hide/countdown reimagined: iOS Shortcuts→system Focus + Live Activity; Android real `setInterruptionFilter()` DND toggle behind permission. Neither can hide another app — mac-only piece. | P3 | Assessed ✓ (§9) |
| **Smart Scan** (scheduled) | 🟡 | 🟡 | BGTaskScheduler / WorkManager (constrained) | P2 | Assessed |
| **Widget** | ✅ | ✅ | WidgetKit / App Widgets (Glance) | P1 | Assessed |
| **Alert history** | ✅ | ✅ | Local notifications + log | P2 | Assessed |
| **Report export (PDF)** | ✅ | ✅ | PDFKit / PdfDocument | P2 | Assessed |
| **Scheduled Reports / Weekly Digest (F-029)** | ✅ | ✅ | Local notifications + BGTaskScheduler/WorkManager + share sheet, all direct equivalents of already-assessed rows above | P2 | Assessed ✓ (§9) |
| **Siri Shortcuts / App Intents** | ✅ | 🟡 | iOS App Intents (rich); Android App Actions (lighter) | P2 | Assessed |
| **HaloShare (P2P)** | ✅ | ✅ | LocalSend v2.1 native peer | P0 | Planned (F-050) |
| **Code Beautifier** | ✅ | ✅ | Pure text/render + PNG export; fully portable | P1 | Assessed ✓ (§9) |
| System controls (mic/cam/DDC) | ❌ | ❌ | No mic-mute/DDC; own-screen brightness only | — | Won't do |
| Launch at login | ❌ | 🟡 | Android BOOT_COMPLETED partial; iOS none | P3 | Assessed |
| **AI assistant — cloud (F-046)** | ✅ | ✅ | Cloud providers portable; fewer agent tools on mobile | P1 | Assessed ✓ (§9) |
| **AI — on-device (F-047)** | 🟡 | 🟡 | MLX is Mac-only → mobile uses Core ML / MLC-LLM / llama.cpp | P2 | Assessed |
| **SMS console (F-044)** | 🟡 | ✅ | Android sync source; iOS viewer only | P0 | Planned (F-044) |
| **Expenditure (F-048)** | ✅ | ✅ | Parse device SMS (Android) / cloud (iOS) | P1 | Planned (F-048) |
| **Clipboard sync (F-045)** | 🟡 | 🟡 | F-045 (AccessibilityService Android) | P1 | Planned (F-045) |
| **Permission Auditor (F-016)** | ❌ | 🟡 | iOS exposes zero introspection into other apps' TCC/permission grants — no viable path; Android `PackageManager` can enumerate other installed apps' declared + granted permissions, gated by `QUERY_ALL_PACKAGES` visibility and Play policy | P3 | Assessed ✓ (§9) |
| **Security Posture Dashboard (F-019)** | ❌ | 🟡 | Both OSes block reading passcode/encryption/Find-My status from 3rd-party apps → reimagine as an advisory checklist + Settings deep-links only, no automated pass/fail scoring | P3 | Assessed ✓ (§9) |
| **Time Machine Backup Health (F-022)** | ❌ | ❌ | Time Machine is a macOS-only concept — no iOS/Android equivalent exists to read. Reimagined separately as the iOS-exclusive "iCloud Backup Health" idea (§5), which is a different, much coarser feature, not a port. | — | Assessed ✓ (§9) |

---

## 4. Mobile-first backlog (prioritized)

Ordered build queue for Halo Mobile. **P0 = the already-specced first wave.**

### Tier 0 — Specced (build these first; see `specs/`)
- **HaloShare peer (F-050)** — P0, both platforms.
- **SMS sync + console (F-044)** — P0, Android sync / iOS viewer.
- **Clipboard sync (F-045)** — P1.
- **Expenditure (F-048)** — P1.
- **App shell + BYOB Firebase pairing (F-049)** — the container for all of the above.

### Tier 1 — High-value ports (OS-agnostic, quick wins)
1. **Code Beautifier** — pure port; great share-sheet/keyboard fit.
2. **Snippets / text expansion** — mobile keyboard extension makes this *better* than desktop.
3. **Speed test** — fully portable.
4. **Clipboard transform actions** (JSON/base64/hash/QR/case/sort…) — a mobile "Actions-lite".
5. **AI assistant (cloud, F-046)** — huge value on mobile; agentic tool set trimmed to mobile-safe reads.
6. **Health/metrics widget** + **Dashboard-lite** (storage, battery, network).
7. **Report export (PDF)**.

### Tier 2 — Adapted insight features (scoped/permissioned)
8. **Storage insights** (scoped SpaceLens + duplicate photos in granted scope).
9. **Drive/storage speed test (F-043 port)**.
10. **VPN / network status**.
11. **On-device AI (F-047 mobile runtime)**.
12. **Smart scan / scheduled digest** (BG-task constrained).

### Tier 3 — Best-effort / low priority
13. Applications list (Android), Launch-at-boot (Android), Cleanup guidance.

---

## 5. Mobile-exclusive expansion (features the desktop can't have)

A phone unlocks capabilities Halo desktop never could — these should be
**first-class**, not afterthoughts (each needs a feasibility study before build):

| Idea | iOS | Android | Notes |
|------|:---:|:-------:|-------|
| **App usage / digital wellbeing** | 🟡 | ✅ | ScreenTime `DeviceActivity` (iOS, restricted) / `UsageStatsManager` (Android) — desktop's F-021 shipped with the Halo-must-be-running fallback; see §9 for why Android's mobile version is actually a strict upgrade over desktop |
| **Notification insights / history** | ❌ | ✅ | Android `NotificationListenerService`; iOS none |
| **Per-app network data usage** | ❌ | ✅ | Android `NetworkStatsManager`; iOS aggregate only |
| **Permission auditor** (what apps can access) | 🟡 | ✅ | Android PackageManager; iOS limited |
| **Duplicate/junk photos cleaner** | ✅ | ✅ | Photos frameworks — big mobile pain point |
| **Device security posture** (lock, encryption, OS patch) | ✅ | ✅ | Read-only checks + advice |
| **Call log / spam insight** | ❌ | 🟡 | Android CallLog (policy-heavy); iOS none |
| **Battery/charging habits** | 🟡 | ✅ | Charging history + advice |
| **iCloud Backup Health** (iOS-exclusive) | 🟡 | ❌ | No public API for actual backup timestamp/size on either OS; iOS: `UIDevice.identifierForVendor` + Settings deep-link only, so the "health" signal is a link, not real data. Android: no equivalent — Google's own backup status isn't exposed to third-party apps either. |

> These are the reason a Halo *phone* app is compelling beyond "companion to
> desktop." SMS + expenditure (already specced) are the flagship examples.

---

## 6. Feasibility study template (required before "Assessed")

Copy this block into a study when assessing a feature for mobile.

```
### Feasibility — <Feature / F-id>
- **Desktop capability:** <what it does on macOS>
- **iOS mechanism:** <API/framework or "none"> · verdict ✅/🟡/🔵/❌
- **Android mechanism:** <API/framework or "none"> · verdict ✅/🟡/🔵/❌
- **OS blockers:** <sandbox/background/permission limits>
- **Permissions required:** <list + user-cost + rationale screen>
- **Store-policy risk:** <e.g. READ_SMS, AccessibilityService, background net>
- **Scope on mobile:** <full / reduced-how>
- **Effort:** <rough> · **Dependencies:** <e.g. F-049 shell, Halo/Core/Cloud>
- **Verdict:** Port / Adapt / Reimagine / Blocked  →  Priority Pn
- **Recommendation:** <build now / defer / won't do + why>
```

---

## 7. Change process (how this doc stays current)

1. A **new desktop feature** (`F-xxx`) is proposed → its DoD includes a **mobile
   feasibility study** (§6) and a **row in §3** here. (Governance rule #2.)
2. If mobile-viable → add to the §4 backlog at the right tier with a status.
3. When it gets a mobile spec, set status `Planned` and link the `specs/` file.
4. Keep the §8 change log updated.

> Reciprocal hook: `docs/FEATURE_ROADMAP.md` and `CLAUDE.md` reference this rule
> so desktop work triggers the mobile assessment automatically.

---

## 8. Change log

| Date | Change |
|------|--------|
| 2026-08 | Feasibility study added (§9) for **F-030 iCloud Drive Analyzer**: iOS 🟡 (document-picker-scoped only, same ceiling as SpaceLens), Android ❌ (no iCloud concept). Row added to §3. Recommendation: don't build — Apple's own Files app already covers this ground better on iOS. |
| 2026-08 | Desktop F-016 (Permission Auditor) shipped. Feasibility study added (§9): iOS blocked (no cross-app TCC introspection exists); Android adapted via `PackageManager` permission enumeration, gated by `QUERY_ALL_PACKAGES` visibility policy → P3. |
| 2026-08 | Feasibility study added (§9) for Privacy/Sensitive Data Scanner (F-018); row added to §3. |
| 2026-08 | Desktop F-019 (Security Posture Dashboard) shipped. Feasibility study added (§9): Reimagine → P3, advisory-only checklist, no automated scoring possible on either platform. |
| 2026-08 | F-028 Focus Session Companion assessed (§9): app auto-hide is Blocked on both mobile platforms (no cross-app hide/suppress API), but iOS's Shortcuts→Focus integration and Android's permissioned DND toggle are each *more* capable in the "quiet things down" dimension than anything macOS grants a third-party app — noted as a mobile-native reimagining, not a port, deferred to P3. |
| 2026-08 | Desktop F-021 (App Usage & Screen Time Analytics) shipped. Feasibility study added (§9): iOS 🟡 Adapt (same foreground-only fallback as desktop) / Android ✅ Port-and-improve (`UsageStatsManager` gives real system-wide history desktop can never have) → P2. |
| 2026-08 | Feasibility study added (§9): Scheduled Reports / Weekly Digest (F-029). Row added to §3 — near-full Port on both platforms, entirely composed of already-assessed primitives (local notifications, BG scheduling, PDF export, share sheet). |
| 2026-08 | Desktop F-023 (Memory Leak & App Bloat Tracker) shipped. Feasibility study added (§9): Won't do — inherits the same "no public live-process enumeration" blocker as Performance — top processes, on both iOS and Android. |
| 2026-08 | Desktop F-022 (Time Machine Backup Health Monitor) shipped. Feasibility study added (§9): Won't do / Reimagine → Time Machine has no mobile equivalent; the mobile-exclusive "iCloud Backup Health" idea (§5) is a distinct, much coarser reimagining, not a port. |
| 2026-08 | F-020 (S.M.A.R.T. Disk Health Monitor) shipped on desktop. Feasibility study added (§9): both iOS and Android verdict ❌ Blocked — neither OS exposes SMART/drive-health data to third-party apps. Row added to §3; status `Won't do`. |
| 2026-07 | Formal feasibility studies added (§9): Code Beautifier, Snippets, Speed Test, cloud AI. |
| 2026-07 | Document created. Assessed all shipped desktop capabilities (F-001–F-043) + planned cloud features (F-044–F-048) for iOS/Android. Established governance rules. First wave specced: F-044/F-045/F-048/F-049/F-050. |

---

## 9. Feasibility studies — Tier 1 candidates

Completed studies (per §6). These move the rows to **Assessed ✓** and are ready to
promote to `Planned` (spec) when scheduled.

### Feasibility — Code Beautifier (from desktop F-038)
- **Desktop capability:** regex syntax highlighter (14 langs) + 8 themes, live preview, PNG export @2x/4x (`NSHostingView` render), copy to clipboard, auto-detect language from clipboard.
- **iOS mechanism:** the highlighter is pure Swift → **reuses desktop code directly**; SwiftUI render; **`ImageRenderer`** (iOS 16+) for PNG; `UIPasteboard`. Verdict ✅
- **Android mechanism:** Kotlin port of the regex highlighter; Compose `AnnotatedString`; capture Composable → `Bitmap` for PNG; `ClipboardManager`. Verdict ✅
- **OS blockers:** none. **Permissions:** none. **Store-policy risk:** none.
- **Scope on mobile:** full; great **share-sheet** target ("beautify this snippet") + keyboard-adjacent use.
- **Effort:** iOS ~1.5 d (reuse) · Android ~3 d (port). **Dependencies:** F-049 shell.
- **Verdict:** **Port** → **P1**. **Recommendation:** build early — highest value-to-effort ratio; iOS is nearly free.

### Feasibility — Snippets / Text Expansion (from desktop F-027)
- **Desktop capability:** snippet store + `SnippetExpander` (5 placeholders `{date}{time}{clipboard}{uuid}{random:N}`), editor, categories, import/export.
- **iOS mechanism:** store + expansion engine port (Swift, shared). System-wide expansion needs a **Keyboard Extension** (Halo keyboard); `{clipboard}` + any network need **"Allow Full Access"**. Verdict ✅ manager / 🔵 keyboard.
- **Android mechanism:** store + engine port (Kotlin). System-wide expansion via a custom **IME** (Halo keyboard) or accessibility text insertion. Verdict ✅ manager / 🔵 IME.
- **OS blockers:** true auto-expansion only inside the Halo keyboard/IME the user enables (not system-global from a normal app).
- **Permissions:** iOS "Allow Full Access" (privacy prompt) for clipboard/sync; Android IME enablement.
- **Store-policy risk:** keyboard extensions/IMEs are allowed; iOS Full-Access keyboards get extra review.
- **Scope on mobile:** manager+expander full; expansion where the Halo keyboard is used. Mobile keyboards make this arguably **better than desktop**.
- **Effort:** iOS ~4 d (engine reuse + keyboard ext) · Android ~5 d (IME). **Dependencies:** F-049 shell; pairs with F-045 (clipboard placeholder).
- **Verdict:** **Port + Reimagine** → **P1**. **Recommendation:** ship the manager first; keyboard/IME as a fast-follow.

### Feasibility — Speed Test (from desktop Performance)
- **Desktop capability:** 25 MB download / 5 MB upload / 10-ping median RTT, socket-based (`URLSession`).
- **iOS mechanism:** `URLSession` — **identical code**. Verdict ✅
- **Android mechanism:** OkHttp / `HttpURLConnection` — direct port. Verdict ✅
- **OS blockers:** none. **Permissions:** Android `INTERNET` (normal). **Store-policy risk:** none.
- **Scope on mobile:** full (mobile arguably a *more* natural home for a speed test).
- **Effort:** iOS ~0.5 d · Android ~1 d. **Dependencies:** F-049 shell.
- **Verdict:** **Port** → **P1**. **Recommendation:** trivial win; bundle into the mobile Dashboard.

### Feasibility — AI Assistant, cloud (from desktop F-046)
- **Desktop capability:** agentic assistant over Claude/OpenAI/Gemini (streaming + tool-use), tools from F-042 intents + `ActionLibrary`, read-auto / act-confirm, persisted chat.
- **iOS mechanism:** provider layer + agent loop port (Swift, largely shared with desktop core); `URLSession` streaming; **Keychain** keys. Tools = the *mobile* capability set (battery/storage/network/clipboard reads; export/HaloShare acts) exposed as **iOS App Intents**. Verdict ✅ chat / 🟡 agentic (fewer tools).
- **Android mechanism:** provider layer port (Kotlin, OkHttp streaming); **Keystore** keys; agent loop; tools = Android capabilities. Verdict ✅ chat / 🟡 agentic.
- **OS blockers:** none for chat; agentic scope bounded by what mobile Halo can *do* (much smaller tool set than desktop's 108 actions).
- **Permissions:** none (BYO key); network. **Store-policy risk:** none (BYO key, no shared inference).
- **Scope on mobile:** full chat + context (clipboard/selection/share-sheet input); **trimmed** agent toolset.
- **Effort:** iOS ~5 d · Android ~6 d (three providers + streaming + Keystore). **Dependencies:** F-049 shell; mirrors F-046 desktop architecture.
- **Verdict:** **Port (chat) + Adapt (agentic)** → **P1**. **Recommendation:** high value on mobile; ship chat + context first, add the small mobile tool set incrementally. Consider sharing the Swift provider layer between macOS + iOS.

### Feasibility — iCloud Drive Analyzer (from desktop F-030)
- **Desktop capability:** local analyzer of `~/Library/Mobile Documents/` (iCloud Drive's on-disk sync mirror) — real per-item sizes, real modified dates, real per-item sync status (local/downloading/uploading/evicted) via `URLResourceKey.ubiquitousItemDownloadingStatusKey`, drill-down, Reveal in Finder, Move to Trash. Explicitly **not** an account-wide quota/category report (no public API returns that — see `docs/FEATURE_ROADMAP.md` F-030 "As actually built").
- **iOS mechanism:** iOS apps cannot enumerate the user's iCloud Drive tree directly the way macOS's `FileManager` can — there is no sandbox path equivalent to `~/Library/Mobile Documents/` visible to third-party apps. The only legitimate access is via **`UIDocumentPickerViewController`**, which can present the "iCloud Drive" location from the Files app and hand back a security-scoped bookmark to whatever folder the *user explicitly picks* — after which `FileManager` enumeration and the same `ubiquitousItemDownloadingStatusKey` resource keys work identically to macOS, scoped to that one picked folder. This is exactly the same ceiling already assigned to Files — SpaceLens (🟡 "scoped/granted dirs only"), so it is not a distinct new mechanism — it inherits SpaceLens's iOS story. Verdict 🟡
- **Android mechanism:** iCloud is an Apple-only construct; there is no Android equivalent, no local sync mirror, and no API surface to analyze. A generic "cloud drive folder analyzer" could theoretically be built against Android's Storage Access Framework for a user-picked Google Drive/OneDrive sync folder, but that would be a **different feature** aimed at a different cloud provider, not a port of this one. Verdict ❌ (no iCloud concept exists on Android)
- **OS blockers:** iOS — no bulk/background enumeration of iCloud Drive outside a user-granted document-picker scope (same as every other scoped-storage feature). Android — the underlying concept (iCloud) does not exist on the platform at all.
- **Permissions required:** iOS — none beyond the one-time document-picker grant (no privacy prompt, it's a standard system picker).
- **Store-policy risk:** none either platform.
- **Scope on mobile:** iOS — at most, a scoped-folder version identical in shape to SpaceLens (pick a folder inside Files → iCloud Drive, see sizes/dates/sync status, trash items). No value beyond what Apple's own Files app already provides natively (which additionally shows real account storage/quota, something Halo itself can never surface — see the desktop feasibility finding). Android — nothing to build.
- **Effort:** iOS ~2 d if bundled as a SpaceLens variant (reuses the picker + enumeration plumbing already required for SpaceLens's own mobile port). Android: N/A. **Dependencies:** F-049 shell; effectively a sub-mode of the Files — SpaceLens mobile port, not a standalone feature.
- **Verdict:** **Adapt (iOS only, folded into SpaceLens) / Blocked (Android)** → **P3**. **Recommendation:** **don't build as a standalone mobile feature.** On iOS the Files app already does this — and does it better, since it can show real iCloud account quota, which Halo fundamentally cannot access on any platform. The only mobile-exclusive angle worth revisiting later is scoping SpaceLens's own folder picker to include "iCloud Drive" as one of several pickable roots, not a dedicated iCloud tab.
### Feasibility — Permission Auditor (from desktop F-016)
- **Desktop capability:** `PermissionAuditor` actor reads real per-app TCC grants from `TCC.db` via the `sqlite3` CLI when the file is readable (Full Disk Access / non-sandboxed build); groups grants by `PermissionKind` with a risk flag for non-browser/non-communication apps holding Screen Recording or Accessibility, plus per-app "Revoke" deep-links into System Settings. Falls back honestly to a category-card-only view with an explanatory banner when the database can't be read — never a fabricated audit.
- **iOS mechanism:** no public API lets a third-party app enumerate *other* apps' TCC grants — Apple treats "what can app X access" as exactly the kind of cross-app introspection the sandbox exists to prevent. There's no TCC.db-equivalent file an app could reach, sandboxed or not; this is stricter than the desktop's Full-Disk-Access gate, which at least has an *unlock*. Verdict ❌
- **Android mechanism:** `PackageManager.getInstalledPackages(PackageManager.GET_PERMISSIONS)` (or `getPackageInfo` per app) returns the permissions each *other* installed app declares and whether they're currently granted (`checkPermission`) — a genuinely real, public per-app permission list, unlike anything iOS offers. The catch: seeing the full installed-app list at all requires either individual `<queries>` package-name declarations (impractical for an open-ended auditor) or the `QUERY_ALL_PACKAGES` permission, which Play Console requires a declared-use justification for (a security/anti-virus/device-management app is an accepted category, but review can reject overly broad justifications). Verdict 🟡
- **OS blockers:** iOS: absolute — no cross-app permission visibility exists at any privilege level available to a normal App Store app. Android: no blocker to reading the data once package visibility is granted, but the visibility grant itself is a Play-policy checkpoint, not a technical one.
- **Permissions required:** iOS — none possible (moot, since there's nothing to read). Android — `QUERY_ALL_PACKAGES` (special access, declared-use form on Play Console) or a curated `<queries>` list of specific package names (no special review, but only covers apps you enumerate up front).
- **Store-policy risk:** iOS — no risk since no attempt is made. Android — moderate; `QUERY_ALL_PACKAGES` is one of Play's more heavily scrutinized declared-use permissions, and rejection/removal risk exists if the stated purpose ("show the user which apps can access what") isn't judged proportionate to the visibility gained.
- **Scope on mobile:** iOS — none; not even a reduced version, since the underlying data simply isn't exposed (the mobile screen would have to be pure static guidance to "check Settings → Privacy yourself," which is not really an "auditor"). Android — a real, if narrower, adaptation: per-app permission list + granted/denied state + the same non-browser/non-communication risk heuristic as desktop, scoped to whatever the `QUERY_ALL_PACKAGES` justification allows, with Settings deep-links per app (`Settings.ACTION_APPLICATION_DETAILS_SETTINGS`) replacing the desktop's per-category System Settings anchors.
- **Effort:** iOS — N/A (not built). Android ~2.5 d (PackageManager enumeration + `QUERY_ALL_PACKAGES` Play Console justification flow + risk heuristic port + Settings deep-links). **Dependencies:** F-049 shell.
- **Verdict:** **Blocked (iOS)** / **Adapt (Android)** → **P3**. **Recommendation:** skip iOS entirely rather than ship a hollow "guidance only" screen that doesn't audit anything. Android is buildable but should wait until there's a stronger case for taking on `QUERY_ALL_PACKAGES` review risk for a single feature — bundle it with other package-visibility features (e.g. Applications list, Launch-at-boot) if it's ever prioritized, so the declared-use justification covers more surface area at once.
### Feasibility — Privacy/Sensitive Data Scanner (from desktop F-018)
- **Desktop capability:** recursive `FileManager` scan of Downloads/Documents/Desktop (+ opt-in iCloud Drive) for exposed secrets — Luhn-validated credit card numbers, exact-prefix AWS/GitHub/Stripe keys, exact SSH private-key headers, SSN patterns — via a bundled/updatable `privacy-patterns.json`; redacted-preview-only results, "Reveal in Finder" only, no delete path.
- **iOS mechanism:** the pattern-matching core (`PrivacyPatternDatabase` — regex + Luhn + redaction) is pure Swift/Foundation and **ports as-is**. Folder access, however, is fully sandboxed: no equivalent of "just enumerate Downloads/Desktop." The app must go through **`UIDocumentPickerViewController`** (security-scoped bookmark) per folder the user wants scanned, then walk only that scoped tree. Verdict 🟡
- **Android mechanism:** pattern core ports to Kotlin unchanged. Folder access via the **Storage Access Framework** (`ACTION_OPEN_DOCUMENT_TREE`), persisting a `Uri` permission per folder the user grants; scan walks only that `DocumentFile` tree via `ContentResolver`. Broad filesystem access (`MANAGE_EXTERNAL_STORAGE`) is deliberately avoided — Play Store restricts that permission to file-manager-class apps and it would put the whole app's listing at review risk. Verdict 🟡
- **OS blockers:** neither OS allows a background/automatic sweep of Downloads-equivalent folders the way macOS does; every folder must be explicitly picked by the user, per session or via a persisted scoped bookmark/URI. No scheduled background scan is realistic (no persistent full-disk grant to wake into).
- **Permissions required:** iOS — none beyond the standard document-picker UI (no Info.plist usage-description needed since the picker itself is the consent). Android — SAF folder-grant dialog per tree (revocable by the user at any time); explicitly **not** requesting `MANAGE_EXTERNAL_STORAGE`.
- **Store-policy risk:** low if scoped to SAF/document-picker; **high** if `MANAGE_EXTERNAL_STORAGE` were used instead — avoid.
- **Scope on mobile:** reduced — one or more user-picked folders per run rather than a fixed Downloads/Documents/Desktop set; no iCloud-Drive-style "opt-in extra location" concept carries over 1:1 (iOS: pick the iCloud Drive folder via the same picker; Android: pick any SAF-exposed provider tree, including cloud providers that register as a `DocumentsProvider`).
- **Effort:** iOS ~2 d (pattern port + document-picker plumbing + security-scoped bookmark persistence) · Android ~2.5 d (pattern port + SAF tree walk + persisted `Uri` permissions).
- **Dependencies:** F-049 mobile shell.
- **Verdict:** **Adapt / Adapt** → **P3**. **Recommendation:** defer behind Tier 1/2 — the detection engine is a cheap reuse once the mobile shell exists, but the picker-per-folder UX is a meaningfully different (and weaker) product than desktop's "just works on Downloads" story, so it isn't a priority mover on its own.
### Feasibility — Security Posture Dashboard (from desktop F-019)
- **Desktop capability:** 8-check security dashboard (`SecurityPostureScanner`) feeding a 0–100 score into the health score. 4 checks are genuinely auto-verified via read-only shell calls (FileVault, Gatekeeper, Application Firewall, Automatic Updates); the other 4 (SIP, Secure Boot, Find My Mac, Login Window) have no reliable non-interactive read path even on macOS, so they surface as an honest "check manually" row with a deep-link rather than a guessed verdict.
- **iOS mechanism:** no public API exposes passcode/biometric state, on-disk-encryption state, or Find My Mac/iPhone status to a third-party app — Apple treats this as a privacy boundary, not an oversight. Verdict ❌ for automated checks.
- **Android mechanism:** `KeyguardManager.isDeviceSecure()` can confirm *a* lock screen is set (coarse pass/fail, no detail on which kind). Play Protect status is readable only via Play Integrity API (adds a Google Play Services dependency for one data point). Find My Device status is not exposed to third-party apps, matching iOS. Verdict 🟡 (partial, one usable signal).
- **OS blockers:** both platforms treat "can another app read my security settings" as exactly the kind of thing a security-conscious OS should refuse — stronger and more deliberate than most other Halo desktop capabilities' sandbox limits.
- **Permissions required:** none extra for the one Android signal (`isDeviceSecure()` needs no permission); Play Integrity API would need a Google Cloud project + API key, disproportionate for a single checklist row.
- **Store-policy risk:** low if kept purely advisory (deep-links to native Settings screens); would rise if the app tried device-admin APIs to get more signal — Play Store reviews `DevicePolicyManager` device-admin usage heavily.
- **Scope on mobile:** a static advisory checklist (lock screen, Find My, auto-update, "install from unknown sources") with deep-links into native Settings — no automated pass/fail scoring, since neither OS will hand that over. The desktop's honest "unknown, check manually" row *is* what the entire mobile version would look like.
- **Effort:** iOS ~1 d (static list + deep links) · Android ~2 d (same + the one live `isDeviceSecure()` signal). **Dependencies:** F-049 shell.
- **Verdict:** **Reimagine** → **P3**. **Recommendation:** defer as standalone work — thin value without real scoring. Revisit only as a low-cost "security tips" screen bundled into the mobile app shell (F-049), not a dedicated feature.
### Feasibility — Focus Session Companion (from desktop F-028)
- **Desktop capability:** hides a user-configured list of apps (`NSRunningApplication.hide()` — never terminate), live menu-bar countdown (`MenuBarDisplayStyle.sessionCountdown`), end-of-session RAM/CPU summary sampled from the real `ProcessMonitor` actor, session history via `AlertLog`. Desktop explicitly does **not** suppress other apps' notifications — there is no public macOS API for a third-party app to toggle system Focus/DND or silence another app's banners (see `FocusSessionManager.swift`'s header note and `CLAUDE.md`).
- **iOS mechanism:** no API lets a third-party app hide, background, or quit another app — the sandbox makes the "auto-hide distracting apps" half flatly **Blocked**, same conclusion as desktop's own "no public suppression API" finding, just for a different half of the feature. But iOS has something desktop genuinely lacks: the **Shortcuts app** can include a real "Set Focus" action, so a user-authored Shortcut/Automation can turn on an actual system Focus mode (real DND) as part of starting a session, and any app can read (not set) the live state via `INFocusStatusCenter.default.isFocused`. Pairing a Halo countdown **Live Activity** with a Shortcut/Focus-Filter deep link gives iOS users something in the "quiet the phone" dimension that macOS Halo cannot honestly claim. Verdict: ❌ auto-hide / 🔵 reimagine (Focus integration + Live Activity countdown).
- **Android mechanism:** same sandbox wall — no API to hide or suppress another app, so auto-hide is **Blocked** here too. Unlike iOS, though, Android does expose a real, callable **system-wide** DND toggle to a consenting app: `NotificationManager.setInterruptionFilter()`, gated behind the user granting `ACCESS_NOTIFICATION_POLICY` in Settings. That is an actual, if privacy-sensitive, capability neither macOS nor iOS grant a third-party app. Verdict: ❌ auto-hide / 🟡 adapt (real DND toggle, heavier permission ask).
- **OS blockers:** both mobile sandboxes block hiding/suppressing another app outright — this mirrors, rather than solves, the desktop's own "no public API" gap; it is a cross-platform theme, not a macOS-specific limitation.
- **Permissions required:** iOS — none beyond the user authoring their own Shortcut; Android — `ACCESS_NOTIFICATION_POLICY` (user-granted, moderate trust ask) for the DND toggle.
- **Store-policy risk:** Android's DND-toggle permission draws extra review scrutiny (historically abused by "focus"/"battery saver" apps); iOS's Shortcuts integration carries none.
- **Scope on mobile:** a countdown timer + optional Shortcut/Focus-Filter deep link and Live Activity (iOS), or a real DND toggle behind explicit permission plus a timer UI (Android). **No** "auto-hide other apps" on either platform — that piece stays macOS-only.
- **Effort:** iOS ~2 d (Live Activity + Shortcut hookup) · Android ~3 d (DND permission flow + timer UI). **Dependencies:** F-049 shell.
- **Verdict:** **Reimagine (iOS) / Adapt (Android)** → **P3**. **Recommendation:** defer — the desktop version's core value (auto-hiding other apps) has no mobile equivalent at all, and the interesting counter-finding is that each mobile OS's Focus/DND integration is, in its own narrow dimension, *more* real and capable than anything Halo desktop can honestly claim. Worth a standalone mobile-native "Focus" feature later, built around that strength, rather than a straight port of the desktop card.
### Feasibility — App Usage & Screen Time Analytics (from desktop F-021)
- **Desktop capability:** `AppUsageTracker` — per-app foreground time via `NSWorkspace` activation notifications + a 30 s sampling timer, RAM correlation, context-switch counts, "Background Hogs" detection, week-over-week trend. Hard-capped to time Halo itself was running (no macOS API exposes retroactive system Screen Time to a third-party app), stored as UserDefaults+JSON, rolling 14-day window.
- **iOS mechanism:** `DeviceActivity`/`FamilyControls` (Screen Time APIs) exist but are heavily restricted — they're designed for parental-control reporting (opaque `DeviceActivityReport` extension rendering, no raw per-app-second data handed to the host app) and require the same kind of entitlement review as desktop's blocked `FamilyControls` path. Without that entitlement, iOS Halo is in the *exact same position* as desktop: `NSWorkspace`'s iOS analogue doesn't exist for background/other apps at all (iOS apps can't observe when other apps activate), so there isn't even a foreground-observation fallback — an iOS build would have **less** raw data than the desktop version, not equal. Verdict 🟡 Adapt, bounded to either (a) the sanctioned `DeviceActivityReport` extension showing Apple's own pre-rendered charts (no correlation with Halo's own RAM/switch data possible), or (b) Halo's own in-app screen time only (time in Halo, not other apps) which is nearly worthless for this feature's premise.
- **Android mechanism:** `UsageStatsManager.queryUsageStats()` / `queryEvents()` — after the user grants the `PACKAGE_USAGE_STATS` special-access permission (Settings deep link, one-time grant, no runtime prompt dialog), Android hands back **real system-wide foreground-time history**, including time before Halo was ever installed or running. This is not a fallback or an approximation — it is strictly more capable than what desktop Halo can ever do, because Android's OS itself is the one recording the data, not a foreground process that has to be alive to observe it. Combine with `ActivityManager.getRunningAppProcesses()` (own-process RAM only, matching Android's general no-cross-app-RAM sandbox) for a partial RAM correlation — full parity with desktop's per-app RAM tie-in isn't possible (Android doesn't expose other apps' RSS to a normal app), so the "avg RAM while foreground" column would be Halo-only, not universal. Verdict ✅ Port-and-improve for the time data, 🟡 Adapt for the RAM correlation.
- **OS blockers:** iOS treats "which other apps did the user use and for how long" as a privacy boundary requiring the parental-control entitlement class — no path around it for a general-purpose utility app. Android treats it as a special-access permission a normal app can request and be granted without needing a business justification review, reflecting the two platforms' very different philosophies here.
- **Permissions required:** Android `PACKAGE_USAGE_STATS` (Settings → Special app access → Usage access; not a runtime permission, needs a rationale screen since it's a manual multi-tap grant). iOS: none extra for the degraded fallback; the full path would need a `FamilyControls` entitlement Apple grants sparingly and typically not to a general system-utility app.
- **Store-policy risk:** Android — low; `PACKAGE_USAGE_STATS` is a well-established, commonly-granted special access used by many legitimate utility apps (digital wellbeing, launchers). iOS — requesting `FamilyControls` for a non-parental-control app invites App Review scrutiny and plausible rejection; safer to ship the degraded/no-op version and not request it at all.
- **Scope on mobile:** Android — full feature, arguably the flagship "mobile-exclusive" win listed in §5 (real historical data, not just "since the app launched"), reusing the desktop's aggregation logic (top apps, background hogs redefined as "installed but rarely opened", context-switch score from `queryEvents()` transition timestamps) against a genuinely richer data source. iOS — ship only if `DeviceActivityReport`'s sanctioned extension UI is acceptable as-is; otherwise defer/skip on iOS rather than build a hollow "time in Halo" version that undersells the desktop feature it's supposed to port.
- **Effort:** iOS ~2 d (DeviceActivityReport extension, if pursued) or skip · Android ~3 d (UsageStatsManager integration + permission rationale screen + reuse of desktop's aggregation math, ported to Kotlin). **Dependencies:** F-049 shell.
- **Verdict:** **Adapt (iOS, likely defer)** / **Port-and-improve (Android)** → **P2**. **Recommendation:** build the Android version — it's a strictly better feature than what desktop Halo can offer and fits the "mobile-exclusive value" thesis in §2/§5 directly. Treat iOS as optional/deferred rather than force a same-shaped feature onto an OS that structurally can't support it without a special entitlement.
### Feasibility — Scheduled Reports & Weekly Digest (from desktop F-029)
- **Desktop capability:** hourly `MetricsHistory` rolling buffer (health score + disk-free + top-RAM-process samples) feeding a 7-day Dashboard sparkline; `WeeklyDigestScheduler` (`NSBackgroundActivityScheduler`) delivers a local notification summarising the past 7 days (health trend, disk-free delta, scans completed, threats flagged) with a "View Report" action; PDF export/share via the existing `ReportGenerator` + `NSSharingServicePicker`.
- **iOS mechanism:** `UNUserNotificationCenter` local notifications with a matching `UNNotificationCategory`/action (identical API family to macOS — near line-for-line port); **`BGAppRefreshTask`** (or `BGProcessingTask`) for the periodic compose-and-fire step, subject to iOS's opportunistic scheduling (no guaranteed exact-time fire, unlike macOS's `NSBackgroundActivityScheduler`); `PDFKit` for the report; `UIActivityViewController` in place of `NSSharingServicePicker` for the share sheet. Verdict ✅ (notification/PDF/share) / 🟡 (exact-time scheduling).
- **Android mechanism:** local notifications via `NotificationManager` + `NotificationChannel` with an action button; **`WorkManager`** `PeriodicWorkRequest` for the compose-and-fire step (Android's battery optimizations can delay fire time similarly to iOS `BGTaskScheduler`, though `setExpedited`/exact-alarm APIs narrow the gap); `PdfDocument` for the report; `Intent.ACTION_SEND` for the share sheet. Verdict ✅ (notification/PDF/share) / 🟡 (exact-time scheduling).
- **OS blockers:** neither mobile OS guarantees a background task fires at a user-picked exact day/hour the way `NSBackgroundActivityScheduler` does on a running Mac — both platforms treat this as a *best-effort* window (typically within a few hours of the target), so the mobile Settings UI should say "around 9 AM" rather than promise exact delivery. No blocker for the notification/PDF/share primitives themselves — all three are already assessed ✅ elsewhere in this table (Alert history, Report export (PDF)).
- **Permissions required:** notification permission (already requested for Alert history parity); no new permission beyond what F-029's dependencies already need. Background refresh/battery-optimization opt-out is a user-facing nudge, not a hard permission.
- **Store-policy risk:** none — local notifications and periodic background work are standard, well-trodden APIs on both platforms.
- **Scope on mobile:** full for the notification + PDF + share flow; the health-score-trend + disk-free-delta content is directly portable since the mobile Dashboard's health score / storage rows are already assessed (🟡/✅ respectively) elsewhere in §3. The "top-RAM-apps" bullet does **not** port — mobile OSes provide no live per-process RAM enumeration for other apps (see "Performance — top processes: Won't do" in §3), so a mobile digest would honestly drop that line, same honesty principle as the desktop build.
- **Effort:** iOS ~1.5 d (mostly notification category + BGAppRefreshTask wiring; PDF/report code shares heavily with the desktop pattern) · Android ~2 d (WorkManager + NotificationChannel setup). **Dependencies:** mobile Dashboard health score (assessed), mobile Report export (assessed), mobile Alert history (assessed) — F-029 mobile is a thin composition layer over three already-assessed primitives, not new capability.
- **Verdict:** **Port** → **P2**. **Recommendation:** low-risk, low-effort follow-on once the mobile Dashboard + PDF export + notification primitives it depends on are built; schedule after those land rather than before.
### Feasibility — Memory Leak & App Bloat Tracker (from desktop F-023)
- **Desktop capability:** `MemoryTrendTracker` samples every regular running app's RAM every 30 s via `ProcessMonitor.runningAppRAMSamples()` (macOS `proc_pidinfo`/`proc_taskinfo`), keeps a persisted rolling 2-hour history per bundle ID, flags apps with >1 hour of monotonic growth as a "possible memory leak," and offers a confirmed terminate+relaunch.
- **iOS mechanism:** no public API lets one app read another app's resident memory — `proc_pidinfo` and friends are macOS-only, and iOS's per-process sandboxing treats "how much RAM is Slack using" as exactly the kind of cross-app introspection Apple blocks. `os_proc_available_memory()` only reports the *calling* app's own budget. Verdict ❌.
- **Android mechanism:** `ActivityManager.getRunningAppProcesses()` has been restricted to the calling app's own processes since Android 5.0 (Lollipop) — there is no more `getProcessMemoryInfo()` cross-app query without a system/signature permission no third-party app can hold. `UsageStatsManager` reports foreground *time*, not memory. Verdict ❌.
- **OS blockers:** identical to `Performance — top processes` (§3), which this feature is a time-series extension of — both mobile OSes consider "another app's live memory footprint" a sandbox boundary, not a permission that can be requested. There is no reduced/coarse fallback worth reimagining (unlike, say, Security Posture's one Android signal) — there is no data source at all.
- **Permissions required:** none exist that would unlock this — not a permission gap, an API gap.
- **Store-policy risk:** n/a — nothing to submit against a policy that could be built.
- **Scope on mobile:** none. Reimagining this as "track my *own* app's memory" would be a different, far less useful feature (a phone can't leak Slack's memory into the user's awareness the way desktop Halo can) and isn't worth the engineering cost of a self-monitoring dashboard.
- **Effort:** n/a. **Dependencies:** n/a.
- **Verdict:** **Blocked** → **Won't do**. **Recommendation:** do not build a mobile equivalent — the exact same OS-level blocker as `Performance — top processes`, which this feature is layered on top of on desktop. Revisit only if a future OS version ships a legitimate cross-app memory-attribution API (none currently planned on either platform).
### Feasibility — Time Machine Backup Health Monitor (from desktop F-022)
- **Desktop capability:** `TimeMachineMonitor` actor parses `tmutil destinationinfo` / `latestbackup` / `listbackups` / `status` (all read-only shell calls) into last-backup time, destination free space, and a 30-day backup-frequency heatmap; alerts when a configured destination goes 48h+ without a backup; "Back Up Now" triggers `tmutil startbackup`.
- **iOS mechanism:** Time Machine is a macOS-only technology — there is no concept of a local/network backup destination, no `tmutil`-equivalent CLI, and no API exposing backup snapshot history to a third-party app. Verdict ❌.
- **Android mechanism:** same absence — Android has no Time-Machine-like local backup system for third-party apps to observe at all. Verdict ❌.
- **OS blockers:** not a permission or sandbox limit — the underlying *concept* Time Machine represents (versioned local/network snapshots of the whole filesystem) simply doesn't exist as a mobile OS primitive. Nothing to port.
- **Permissions required:** n/a.
- **Store-policy risk:** n/a.
- **Scope on mobile:** none, as a direct port. The nearest analogous mobile idea is the pre-existing "iCloud Backup Health" entry in §5 — but that's a *reimagining*, not this feature: it can only report a coarse, mostly-decorative "last backup" signal via `UIDevice.identifierForVendor` + a Settings deep-link, since iOS doesn't expose real iCloud backup timestamps/size to third-party apps either, and Android has no equivalent concept to reimagine at all (Google's own device-backup status isn't exposed to third-party apps).
- **Effort:** n/a (Won't do) for the direct port; the separate "iCloud Backup Health" idea is iOS-only, ~1 d, advisory-only.
- **Verdict:** **Won't do** (direct port) → the desktop feature has no mobile home. **Reimagine** as "iCloud Backup Health" (§5) tracked as its own, much smaller idea → **P3**.
- **Recommendation:** don't treat F-022 as pending mobile work — it's fully addressed by this study. If "iCloud Backup Health" is ever built, scope it as a single link-out advisory row bundled into the mobile app shell (F-049) rather than a dedicated feature — there isn't enough real, readable data to justify more.
### Feasibility — S.M.A.R.T. Disk Health Monitor (from desktop F-020)
- **Desktop capability:** reads the NVMe S.M.A.R.T./Health-Info Log via `diskutil info -plist` (SMART status, temperature, power-on hours/cycles, total bytes written, available spare, NVMe's own percentage-used wear indicator, media errors) plus an `IONVMeController` IOKit lookup for serial number. Surfaces health status Good/Warning/Failing, a lifespan-remaining bar, and a 24h temperature sparkline; `AlertManager` rule on degradation.
- **iOS mechanism:** none. iOS gives third-party apps zero access to the physical storage device — no IOKit-equivalent, no raw block-device path, no public SMART/NVMe framework of any kind. This isn't a scoped/permissioned gap like Files or Photos; there is no API surface to request access to at all. Verdict ❌
- **Android mechanism:** none for a genuinely equivalent read. `StorageManager`/`StorageVolume` expose free/total space only; SMART-equivalent health data (`smartctl`-style) requires root or a system-signed app, unavailable to a normal installed app, and OEM storage variance (eMMC/UFS/removable SD) means there'd be no vendor-neutral path even if root were assumed. Verdict ❌
- **OS blockers:** full sandbox on iOS (no IOKit-equivalent, no raw device access); Android requires root/system privilege that a distributed app cannot have.
- **Permissions required:** none possible — there is no permission that unlocks this, on either OS.
- **Store-policy risk:** n/a — nothing to request or submit.
- **Scope on mobile:** none.
- **Effort:** n/a. **Dependencies:** none.
- **Verdict:** **Blocked** (both platforms) → **Won't do**.
- **Recommendation:** do not build; the API absence is total, not a reduced/adapted case. If a phone-side "storage health" signal is ever wanted, the honest option is a *different*, clearly-labeled feature — e.g. surfacing Android's `StorageManager` cache-pressure/low-space signals, or iOS's on-device storage breakdown — not a SMART port, since there is nothing on either platform that corresponds to a physical drive's wear/failure telemetry.
