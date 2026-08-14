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
| **Performance — top processes** | ❌ | ❌ | No public live-process enumeration | — | Won't do |
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
| **Clipboard history** | 🟡 | 🟡 | iOS current-only/foreground; Android 10+ limited → F-045 | P1 | Planned (F-045) |
| **Snippets / text expansion** | ✅ | ✅ | **Strong on mobile** (keyboard extension / IME) | P1 | Assessed ✓ (§9) |
| **Actions** — clipboard/text transforms | ✅ | ✅ | JSON/base64/hash/QR/case… pure compute | P1 | Assessed |
| Actions — system/dock/shell | ❌ | 🟡 | Mostly macOS-only; Android some via intents | P3 | Assessed |
| **Ports manager** | ❌ | ❌ | No socket enumeration of other apps | — | Won't do |
| **Menu Bar styles** | 🔵 | 🔵 | Reimagine: iOS Live Activity/widget; Android tile/notification | P2 | Assessed |
| **Smart Scan** (scheduled) | 🟡 | 🟡 | BGTaskScheduler / WorkManager (constrained) | P2 | Assessed |
| **Widget** | ✅ | ✅ | WidgetKit / App Widgets (Glance) | P1 | Assessed |
| **Alert history** | ✅ | ✅ | Local notifications + log | P2 | Assessed |
| **Report export (PDF)** | ✅ | ✅ | PDFKit / PdfDocument | P2 | Assessed |
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
| 2026-08 | Desktop F-021 (App Usage & Screen Time Analytics) shipped. Feasibility study added (§9): iOS 🟡 Adapt (same foreground-only fallback as desktop) / Android ✅ Port-and-improve (`UsageStatsManager` gives real system-wide history desktop can never have) → P2. |
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
