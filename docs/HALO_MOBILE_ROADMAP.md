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
| **Permission Auditor (F-016)** | ❌ | 🟡 | iOS exposes zero introspection into other apps' TCC/permission grants — no viable path; Android `PackageManager` can enumerate other installed apps' declared + granted permissions, gated by `QUERY_ALL_PACKAGES` visibility and Play policy | P3 | Assessed ✓ (§9) |

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
| **App usage / digital wellbeing** | 🟡 | ✅ | ScreenTime `DeviceActivity` (iOS, restricted) / `UsageStatsManager` (Android) |
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
| 2026-08 | Desktop F-016 (Permission Auditor) shipped. Feasibility study added (§9): iOS blocked (no cross-app TCC introspection exists); Android adapted via `PackageManager` permission enumeration, gated by `QUERY_ALL_PACKAGES` visibility policy → P3. |
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
