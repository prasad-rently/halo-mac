# Firebase Setup & Provisioning — Model + Automation Feasibility

Covers two hard requirements for the BYOB cloud features (F-044/F-045/F-048):

1. **Runtime configuration — no rebuild.** Open-source users run the **released**
   Halo desktop + mobile apps and connect *their own* Firebase live, in-app.
2. **Minimise setup friction.** Study of how much of the backend provisioning can
   be **automated** so the user avoids a manual console tutorial.

---

## 1. Runtime configuration (no compile-time config, no rebuild) — REQUIRED

**Decision:** Halo ships with **no** `GoogleService-Info.plist` / `google-services.json`
baked in. The user's Firebase config is supplied **at runtime** into the shipped app.

- Desktop (firebase-ios-sdk on macOS):
  ```swift
  let options = FirebaseOptions(googleAppID: appID, gcmSenderID: senderID)
  options.apiKey = apiKey
  options.databaseURL = databaseURL   // the user's RTDB
  options.projectID = projectID
  FirebaseApp.configure(options: options)          // configure LIVE app
  let db = Database.database(url: databaseURL)
  ```
- Mobile (Flutter): `Firebase.initializeApp(options: FirebaseOptions(...))` with the
  same runtime values (no bundled config file required).
- Config is entered/scanned once, stored in **Keychain / secure storage**, and used
  to configure Firebase on every launch. **The released binary is generic; the user
  never recompiles.**

This is a first-class, supported SDK path — not a hack. It is the foundation of BYOB.

---

## 2. What a working backend needs (the target state)

For F-044 to work, the user's Firebase project must have:

| # | Resource | Manual console action |
|---|----------|-----------------------|
| R1 | A Firebase project | Create project |
| R2 | Realtime Database instance | Enable RTDB, pick region |
| R3 | Security rules deployed | Paste rules JSON, publish |
| R4 | Auth provider enabled | Enable Google Sign-In (or Email/Password) |
| R5 | App registration + config values | Add app, copy config |
| R6 | (Google Sign-In only) OAuth client ID | Auto-created with the Apple/iOS app, or configure consent screen |

Automation feasibility is assessed per-resource below.

---

## 3. Automation options studied

| Approach | Can create project | RTDB + rules | Auth provider | Get config | Zero-interaction? | Verdict |
|----------|:---:|:---:|:---:|:---:|:---:|---------|
| **Firebase CLI** (`firebase`) | ⚠️ needs `firebase login` + sometimes billing | ✅ `deploy --only database` | ❌ (no provider enable) | ✅ `apps:sdkconfig` | ❌ (browser login) | Good for R2/R3/R5, not R4 |
| **Firebase Management REST API** (`firebase.googleapis.com` + `firebasedatabase.googleapis.com` + `identitytoolkit` admin) | ✅ addFirebase to a GCP project | ✅ instances.create + rules PUT | ⚠️ Email/Pwd yes; Google IDP needs client id/secret | ✅ getConfig | ❌ (needs OAuth token) | Most capable, still needs login |
| **Terraform** (`google_firebase_*`) | ✅ | ✅ | ⚠️ same IDP gap | ✅ | ❌ + too technical | Reproducible but not end-user friendly |
| **Hosted one-click provisioner** (Halo-run service) | ✅ | ✅ | ✅ | ✅ | ⚠️ user OAuths once | Best UX, but Halo must host + pass Google OAuth verification; dents the "no shared infra" ethos |
| **In-app assisted flow** (client-side, token stays local) | ✅ | ✅ | ⚠️ IDP gap | ✅ | ⚠️ user OAuths once | **Recommended** — see §5 |
| **Pure `curl`/shell, no interaction** | ❌ | — | — | — | — | **Impossible** (see blockers) |

---

## 4. The three hard blockers (why zero-touch is impossible)

1. **Authentication is unavoidable.** Any action in the user's Google/GCP account
   requires *their* OAuth consent via a browser. A bundled anonymous `curl` script
   cannot create resources in someone's account. There is always a "log in once" step.

2. **Project creation friction.** Creating a GCP/Firebase project needs the user
   authenticated, may prompt to **attach a billing account** (even for the free
   Spark tier some APIs check this), and users have a **project-count quota**. Not
   scriptable without their involvement.

3. **OAuth client creation for Google Sign-In (R6) resists automation.** Enabling
   the **Google** auth provider needs an OAuth 2.0 **client ID + secret** and an
   OAuth **consent screen**. Google exposes **no clean public API to mint OAuth
   client IDs**; the consent-screen branding is console-only. This is the least
   automatable piece — and it exists *only because we chose Google Sign-In*.

> **Email/Password auth has no R6.** It can be enabled entirely via the Identity
> Toolkit Admin REST API and a user created programmatically — so an
> email/password backend is **substantially more automatable** than Google Sign-In.

---

## 5. Recommended approach — in-app "Assisted Provisioning"

A **"Create / Connect my backend"** button in the Halo setup wizard that runs
client-side (tokens never leave the user's machine — preserves "Halo never touches
your data"):

```
1. User clicks "Set up cloud sync".
2. Halo opens the browser → user logs into THEIR Google account, approves scopes
   (cloud-platform / firebase). One consent, once.
3. With the returned token (stored locally), Halo calls the Firebase Management +
   RTDB + Identity Toolkit REST APIs to:
     • create or pick a project        (R1)
     • provision the RTDB instance      (R2)
     • PUT the security rules           (R3)   ← fully automated, our rules JSON
     • enable the auth provider         (R4)
     • register the app + pull config   (R5)   ← config flows straight into the app
4. Config auto-loads into the running app (Part B becomes automatic).
```

The user's entire experience: **click → Google login → approve → done.** No console,
no tutorial, no copy-paste, no rebuild.

### The catch to validate (Phase 0 spike)
- **OAuth scope verification.** For Halo (a distributed open-source app) to request
  `cloud-platform`/`firebase` scopes, its OAuth client must pass **Google's app
  verification**, or unverified-app usage is capped (~100 users) and shows a warning
  screen. This is the main obstacle to shipping assisted provisioning broadly.
- **Mitigations:** (a) pursue Google verification for the Halo OAuth client;
  (b) or have each user create their *own* OAuth client once (back to some friction);
  (c) or use a **device-code / limited-input OAuth** flow.

### The auth trade-off this surfaces
| | Google Sign-In (current D12) | Email/Password |
|---|---|---|
| Login UX | Nicer (one tap) | Manual account |
| **Auto-provisioning** | Blocked by R6 (OAuth client) | **Fully scriptable** |
| Consent-screen setup | Required | Not needed |

**If frictionless automation is the priority, Email/Password is the more automatable
auth choice** — it removes blocker #3 entirely. Google Sign-In stays nicer to log in
with but keeps a manual OAuth-client step. **This is a decision to revisit (see below).**

---

## 6. Feasibility verdict

- **Runtime config, no rebuild:** ✅ fully feasible; now a hard requirement (§1).
- **Fully automated, zero-interaction `curl` script:** ❌ impossible (auth + billing + OAuth-client blockers).
- **Near-frictionless assisted flow (login once → auto-provision):** ✅ feasible, gated on the **OAuth-scope-verification** spike and (ideally) switching auth to **Email/Password** to remove the OAuth-client blocker.
- **Realistic v1 fallback if the spike fails:** the **guided wizard** (copy-buttons, pre-written rules, deep links) + **automated rules deploy** — still no rebuild, just a few guided clicks instead of full automation.

---

## 7. Decisions (resolved) + spike

- **Auth = Email/Password (auto-provisioned)** ✅ — switched from Google Sign-In to remove the OAuth-client blocker (§4 #3) and make setup fully auto-provisionable. App runtime sign-in uses an email/password user created during provisioning; the *provisioning* step still uses a one-time Google login. (F-044 D12.)
- **Provisioning model = in-app client-side assisted flow** ✅ — Halo runs the provisioning locally with the user's token; **no Halo-hosted infrastructure**, tokens never leave the user's machine (preserves the "Halo never touches your data" ethos). No one-click hosted service.
- **Two-secret model** ✅ — auth credential (email + random password) is auto-managed (Keychain + carried in the pairing QR); the **E2E passphrase** (data secret) is user-held and never in the QR. (F-044 D11.)

### Phase 0 spike (status)
1. **firebase-ios-sdk on macOS** — ✅ **PASSED (2026-07).** Firebase 11.15.0
   (`FirebaseDatabase` + `FirebaseAuth`) resolves + builds + links into the Halo
   macOS app using **runtime** `FirebaseOptions` (no bundled plist). RTDB+Auth
   chosen over Firestore also builds far lighter (no source gRPC/abseil). Code:
   `Halo/Core/Cloud/FirebaseRTDBClient.swift`. (Release-sandbox network
   entitlement still to confirm on the sandboxed build.)
2. **Provisioning OAuth** — ✅ **S2 SPIKE DONE (2026-07) — feasible, but gated.**
   - **Device/limited-input flow is RULED OUT.** Google restricts it to a fixed
     scope set (`email`/`openid`/`profile` + Drive `drive.file`/`drive.appdata` +
     YouTube) — `cloud-platform`/`firebase` are **not** permitted. So spec §5
     mitigation (c) "device-code flow" is dead.
     ([docs](https://developers.google.com/identity/protocols/oauth2/limited-input-device))
   - **The viable flow is loopback-IP redirect + PKCE authorization code** —
     Google's recommended native-desktop mechanism (custom URI schemes deprecated;
     client secret optional for installed apps).
     ([docs](https://developers.google.com/identity/protocols/oauth2/native-app))
     Implemented + unit-tested (RFC 7636 vector): `Halo/Core/Cloud/Provisioning/GoogleOAuthPKCE.swift`.
   - **The blocker stands and is now precise:** `cloud-platform` is a **restricted
     scope** → Google **app verification (annual third-party security assessment)**
     is required for an unverified distributed client beyond the ~100-user cap +
     warning screen. For an open-source app this is heavy/ongoing cost.
   - **Recommendation (v1):** ship the **guided wizard** (already built as the
     manual `CloudSetupView`) + automated rules deploy as the default; offer
     assisted auto-provisioning only via mitigation (b) — the user supplies **their
     own** OAuth client id once (no verification needed, they're the sole user) —
     or defer full assisted provisioning until/unless Halo pursues restricted-scope
     verification. Auth already switched to Email/Password (D12), so the runtime app
     never needs the OAuth-client at all.
3. **Identity Toolkit admin API** — ✅ **API sequence mapped (live call not run — no token here).**
   Enable Email/Password: `PATCH identitytoolkit.googleapis.com/admin/v2/projects/{project}/config`
   (`signIn.email.enabled=true`, `signIn.email.passwordRequired=true`). Create the
   runtime auth user: `POST identitytoolkit.googleapis.com/v1/accounts:signUp?key={apiKey}`
   with `{email,password,returnSecureToken}`. Both need the provisioning token / API key.
4. **RTDB provisioning + rules PUT** — ✅ **API sequence mapped (live call not run).**
   Add Firebase to a GCP project: `POST firebase.googleapis.com/v1beta1/projects/{project}:addFirebase`.
   Create the default DB instance: `POST firebasedatabase.googleapis.com/v1beta/projects/{project}/locations/{location}/instances?databaseId={id}&validateOnly=false`
   (`type: DEFAULT_DATABASE`). Deploy rules: `PUT https://{instance}.firebaseio.com/.settings/rules.json`
   with the §7.2 rules JSON (bearer token). Pull web config: `GET firebase.googleapis.com/v1beta1/projects/{project}/webApps/{appId}/config` → feeds `FirebaseConfig`.

> **S2 net verdict:** assisted provisioning is **technically fully scriptable** once
> a `cloud-platform` token is held (all of R1–R5 via REST), and the OAuth mechanism
> is proven (`GoogleOAuthPKCE`, RFC-vector-tested). The **only** remaining gate is
> Google **restricted-scope app verification** — a policy/business decision, not a
> technical one. **v1 stays on the guided wizard** (no rebuild, a few guided clicks);
> assisted provisioning is a fast follow the moment a verified (or per-user) OAuth
> client is available. ⚠️ Live end-to-end provisioning was **not** exercised in this
> spike (no Google account / consent in the build environment).

> **Also delivered in Phase 0:** `CryptoService` (PBKDF2 + AES-GCM, E2E) +
> `CloudConfigStore` (Keychain) + `CloudModels` (runtime config + QR pairing),
> all unit-tested — the shared `Halo/Core/Cloud` foundation for F-044/045/048.
