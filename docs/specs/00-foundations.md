# 00 — Cross-Cutting Foundations

Shared architecture and decisions that multiple upcoming features depend on.
Feature specs reference this document instead of re-deriving these choices.

---

## 1. Bring Your Own Backend (BYOB)

Halo is open-source and ships **no shared or default cloud backend**. Every
cloud-backed feature (SMS sync F-044, clipboard sync F-045, expenditure F-048)
runs against a **Firebase project the user creates and owns**.

- **Why:** privacy-by-design. A user's data lives only in their own Google/
  Firebase account. Halo (the project) never sees, stores, or pays for it.
- **Consequence:** Halo needs a first-class **configuration + pairing** flow so
  the same Firebase project can be attached on desktop and mobile.

### Configuration model

> **Runtime config — no rebuild (hard requirement).** Halo ships **no** bundled
> `GoogleService-Info.plist` / `google-services.json`. The released desktop and
> mobile binaries are generic; the user's Firebase config is injected **at
> runtime** via `FirebaseApp.configure(options:)` (desktop) /
> `Firebase.initializeApp(options:)` (mobile). Open-source users **never
> recompile Halo** to use their own backend. See [firebase-setup.md](firebase-setup.md).

- Desktop: **Settings → Cloud (Firebase)** pane. User provides their Firebase
  config (apiKey, projectId, appId, databaseURL, …) or uploads the config file —
  and Halo configures the **live app** with it.
- Mobile: same config in the mobile app's Settings.
- **Pairing helper:** desktop renders a **QR code** encoding the config so the
  mobile app can scan it (and vice-versa), avoiding manual re-entry.
- **Setup friction:** provisioning the backend (create project, RTDB, rules, auth)
  is offered as an **in-app assisted flow** ("log in once → auto-provision"); a
  guided wizard is the fallback. Full zero-interaction automation is **not**
  possible (auth/billing/OAuth-client blockers) — see
  [firebase-setup.md](firebase-setup.md) for the feasibility study.
- Config stored in the **macOS Keychain** (desktop) / platform secure storage
  (mobile). Never written to plaintext prefs, never committed, never logged.
- A **"Test connection"** action validates credentials + read/write before save.

### Decision — Firebase product

| Choice | Decision | Rationale |
|--------|----------|-----------|
| Database | **Firebase Realtime Database** (confirmed for F-044; default for cloud features) | Matches the proven *SMSArchiver* reference; cheaper append-heavy writes; simple `setValue` overwrite-dedup. Desktop keeps a **local decrypted cache** and runs search/filter/pagination over it (RTDB has no rich server-side query). Firestore was considered for its querying but RTDB won on proven fit + cost. Re-validated per-feature. |
| Auth | **Firebase Auth — Email/Password (auto-provisioned)**, NOT anonymous/Google | Both devices sign in with an email/password credential auto-created during assisted provisioning (moved to the phone via the pairing QR). Chosen over Google Sign-In because it is **fully API-provisionable** (no OAuth-client step). Shared `uid`. See [firebase-setup.md](firebase-setup.md). |
| Realtime | RTDB **`.observe`** (`child_added` / `value`) listeners | Push updates to clipboard/SMS consoles without polling. |
| Storage | **Cloud Storage for Firebase** (only if needed, e.g. MMS/attachments) | Deferred unless a feature requires blobs. |

### Security requirements (apply to all cloud features)

- **Realtime Database Security Rules** must restrict every node to the owner —
  `auth != null && auth.uid === $uid` under `.../{$uid}`. A hardened rules file
  ships in the docs so users deploy consistent rules (see F-044 §7.2).
- **Client-side encryption for sensitive payloads.** Clipboard (F-045) and SMS
  (F-044) may contain secrets/PII. Payload bodies are encrypted **before upload**
  with a user passphrase-derived key (e.g., AES-GCM, key via PBKDF2/Argon2), so
  even the user's own Firebase stores ciphertext. Metadata minimised.
- **No secrets in logs / Sentry.** Extend the existing `sendDefaultPii = false`
  posture to all cloud modules.
- **Transport:** Firebase SDK TLS. No custom endpoints.

---

## 2. Desktop integration conventions

Cloud features follow existing Halo patterns (see `CLAUDE.md`):

- A dedicated **`actor`** (or `@MainActor final class` for stateless) per service
  — e.g. `FirebaseClient`, `SMSSyncService`, `ClipboardSyncService`.
- ViewModels are `@MainActor final class ... ObservableObject`, owned by the view
  as `@StateObject`, never stored in `AppState`.
- Background→main updates via `await MainActor.run { ... }`.
- New sidebar modules registered in `AppModule` (reorderable) with title + SF
  Symbol, matching the existing module pattern.
- Settings live in the existing Settings window as new panes.

### Firebase SDK on macOS

- **firebase-ios-sdk** (Swift Package Manager) supports macOS for Realtime Database + Auth.
- Add as `XCRemoteSwiftPackageReference` in `project.pbxproj` (same mechanism as
  Sentry — see gotcha #11). Confirm macOS deployment target (13.0) compatibility.
- **Risk:** SDK size + sandbox/network entitlements; validate early (spike).

---

## 3. Mobile stack (F-049 and mobile halves of F-044/F-045/F-050)

### Decision — cross-platform framework

| Option | Verdict |
|--------|---------|
| **Flutter** | **Default choice.** Single Dart codebase for iOS+Android, first-class `firebase_flutter` plugins, mature. Good for the SMS console UI, clipboard, settings. Platform channels cover native bits (SMS read, clipboard listener, mDNS). |
| Kotlin Multiplatform | Strong for shared logic + native UI, but more setup; keep as alternative. |
| Native (Swift + Kotlin) | Maximum fidelity but 2× UI work; only if platform depth demands it. |

Default: **Flutter**, with platform-channel plugins for the OS-specific pieces
(Android SMS content resolver, clipboard listeners, NSD/mDNS for HaloShare).

### Hard platform constraints (drive scope)

- **iOS cannot read SMS** (no public API) → **F-044 mobile is Android-only.**
- **iOS `UIPasteboard`** has no background change notification → F-045 clipboard
  capture on iOS is foreground/manual only; Android tightened clipboard access in
  10+ (foreground or default IME/focus required).
- **HaloShare discovery:** iOS needs the **Local Network** entitlement + Bonjour;
  Android background execution + NSD limits.

See `docs/MOBILE_PLATFORM_FEATURES.md` §8 for the full feasibility matrix.

---

## 4. AI stack (F-046 cloud, F-047 on-device)

- **Cloud (F-046):** provider abstraction, **BYO API key** in Keychain. Default
  provider **Anthropic Claude** (latest models), plus OpenAI and Google Gemini.
- **On-device (F-047):** **MLX** on Apple Silicon as the primary runtime
  (llama.cpp/Metal fallback); local embeddings + local vector store for RAG.
  Model picker + GPU/compute control.
- A **unified "AI" surface** is preferred: one module with a backend toggle
  (cloud provider vs. local model) so F-046 and F-047 share UI.

---

## 5. Effort & risk notes

- Effort values in each spec are **rough order-of-magnitude** pending the spikes
  called out (Firebase-macOS SDK spike; MLX spike; Android SMS/clipboard spike).
- Each cloud feature carries a **security review** gate before shipping, given
  PII/secret handling.
- Open-source posture: document required Firebase setup (rules, indexes, auth) so
  users can self-host confidently.
