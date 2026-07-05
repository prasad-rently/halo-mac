# F-044 — Shared SMS Console (NFeat-122)

> **Status:** 🗓 Planned · **Platform:** Desktop (console) + Mobile (sync source)
> **Depends on:** [00-foundations](00-foundations.md) (BYOB Firebase), F-049 (Halo Mobile)
> **Reference:** *SMSArchiver* project

---

## 1. Summary

Display, on the Halo **desktop** app, the SMS messages from the user's phone. The
Halo **mobile** app reads device SMS and syncs them to the user's **own,
configurable Firebase** database; the desktop reads from that same database and
renders a searchable, threaded SMS console. No shared backend — every user uses
their own Firebase project.

## 2. Goals / Non-Goals

**Goals**
- Mobile → Firebase one-way sync of SMS, keyed by phone number/thread.
- Desktop console: threads list, message view, search, per-number filter.
- Fully configurable Firebase on both apps; zero default backend.
- Incremental, deduplicated, resumable sync.

**Non-Goals (v1)**
- Sending/replying to SMS from desktop (read-only console).
- MMS/attachments (deferred; see Open Questions).
- iOS as a sync source (platform blocker — Android-only sync).
- Real-time push to desktop is desirable but polling fallback acceptable.

## 3. Decisions & Assumptions

> **Confirmed 2026-07 (discussion rounds 1–2):** D1–D16 locked.
> Encryption = client-side E2E with passphrase; scope = configurable, default
> all; direction = read-only v1; **backend = Firebase Realtime Database**;
> cadence = real-time receiver + periodic + on-open.

| # | Decision | Note |
|---|----------|------|
| D1 | **Android-only** SMS sync | iOS has no SMS-read API. Desktop console still works for any user with an Android sync source. |
| D2 | **Firebase Realtime Database**, path `sms/{uid}/{messageId}` ✅ *confirmed* | Matches the SMSArchiver reference (proven, cheaper write path). `messageId = {smsId}_{timestamp}` (D14). Desktop searches/paginates over its **local decrypted cache** rather than server-side queries. |
| D3 | **Read-only** desktop console in v1 ✅ *confirmed* | Reply/send is a large scope + carrier/permission concerns. Sync stays one-way. |
| D4 | **Client-side E2E encryption** of message body + address ✅ *confirmed* | Passphrase-derived key (Argon2/PBKDF2 → AES-GCM). RTDB stores ciphertext only. **Passphrase loss = data unrecoverable** (documented to user; no escrow in v1). |
| D5 | Sync is **one-way** (device → cloud → desktop) ✅ *confirmed* | Desktop never writes messages. |
| D6 | Grouping by **normalized phone number** (E.164 where possible) | Threads keyed by contact number. |
| D7 | **Sync scope: configurable, default all** ✅ *confirmed* | All SMS sync by default; user allow/deny list by sender/number. Also captures bank SMS for F-048. |
| D8 | **Cadence: real-time receiver + periodic + on-open** ✅ *confirmed (refined)* | Real-time `SmsReceiver` → immediate worker (per reference), **plus** WorkManager periodic safety net **plus** sync on app open. Desktop updates live via RTDB `.observe` value/child listeners (polling fallback). |
| D9 | **Text-only (SMS)** in v1 ✅ *confirmed* | MMS/attachments deferred (needs Cloud Storage). |
| D10 | **Numbers, not contact names** in v1 ✅ *confirmed* | Avoids `READ_CONTACTS`. Optional contact-name resolution later. |
| D11 | **One passphrase carried via QR pairing** ✅ *confirmed* | The desktop→mobile QR encodes Firebase config; the E2E passphrase is set once and shared through the same pairing step (see §7.1). |
| D12 | **Stable shared auth (email/password), NOT anonymous** ✅ *decided* | SMSArchiver uses anonymous auth (per-install uid) because it's upload-only. Halo's desktop must **read the same uid**, so a stable cross-device identity is required. See §11. |
| D13 | **Local offline queue + flush-first** ✅ *adopt from ref* | Mirror SMSArchiver's Room-queue pattern: on upload failure, queue locally; each sync flushes the queue before uploading new. Resilience against flaky networks. |
| D14 | **`documentId = smsId_timestamp`, write-overwrite dedup** ✅ *adopt from ref* | Proven idempotent dedup (`setValue`/`setData` overwrites). Preferred over hashing body (survives identical bodies; `id` alone is unsafe since Android reuses SMS ids after deletion). |
| D15 | **Capture dual-SIM + richer fields** ✅ *adopt from ref* | Add `subscriptionId` (SIM), `threadId`, full `type` enum, `seen`, `serviceCenter`. See §7 schema. |
| D16 | **1200 ms persistence delay after receiver trigger** ✅ *adopt from ref* | Avoids the real race where the SMS_RECEIVED broadcast fires before the row is queryable via ContentResolver. |
| D17 | **SMS categorization via shared `SmsClassifier`** ✅ *adopt from Hamza* | Beyond by-number threads, label each message into 8 categories (OTP, Personal, Government, Transactional, Service, Promotional, DLT-suffix fallback, Uncategorized). Same classifier F-048 reuses for its transactional filter. See §7.4. |

## 4. User Stories

- **US-1** As a user, I connect my Firebase project on both phone and desktop so my SMS appear on my Mac.
- **US-2** As a user, I see my SMS grouped into threads by sender/number, newest first.
- **US-3** As a user, I search across all messages and filter to one number.
- **US-4** As a user, my messages are encrypted so even my Firebase stores only ciphertext.
- **US-5** As a user, re-running sync doesn't create duplicates and resumes where it left off.
- **US-6** As a user, I can disable/enable the feature and wipe synced data.

## 5. Functional Requirements

**Mobile (sync source — detailed in F-049)**
- **FR-1** Request `READ_SMS` permission (Android) with clear rationale.
- **FR-2** Read SMS via content resolver; map to the message schema.
- **FR-3** Encrypt body+address; `setValue` to RTDB at `sms/{uid}/{messageId}` (overwrite dedup).
- **FR-4** Track a **high-water mark** (last synced date/id) for incremental sync.
- **FR-5** Configurable sync trigger: manual, on-open, and/or periodic (WorkManager).
- **FR-6** Respect a user allow/deny list of numbers to sync (optional).

**Desktop (console)**
- **FR-7** Read messages for the signed-in `uid` from RTDB, decrypt locally into the cache.
- **FR-8** Render **Threads** (grouped by number, last message + unread count) and a **Messages** pane.
- **FR-8b** **Categorize** each message via the shared `SmsClassifier` (D17); offer category filters/labels (OTP, Transactional, Promotional, …) in addition to by-number threading.
- **FR-9** **Search** (full-text over decrypted cache) and **filter** by number/date/category.
- **FR-10** Live updates via RTDB `.observe` (`child_added`/`value`) listener; **polling fallback** if unavailable.
- **FR-11** Pagination for large histories (lazy-load older messages).
- **FR-12** "Wipe synced data" action (deletes `sms/{uid}` docs) with confirmation.

**Config (both)**
- **FR-13** Firebase config + encryption passphrase set in Settings (per foundations).
- **FR-14** "Test connection" validates read/write before enabling.

## 6. Non-Functional Requirements

- **Privacy:** message bodies/addresses encrypted client-side (D4). Only the user's Firebase holds data.
- **Security:** RTDB rules restrict `sms/{uid}` to owner `uid`. Passphrase never leaves device; key derived via Argon2/PBKDF2.
- **Performance:** desktop handles 50k+ messages via pagination + local cache index; search stays responsive.
- **Reliability:** incremental sync resumes after interruption; idempotent upserts.
- **Config-first:** nothing works until the user attaches their Firebase (no default).

## 7. Architecture & Data Model

```
Android device                Firebase RTDB (user-owned)       macOS desktop
┌───────────────┐  encrypt    ┌──────────────────────┐ observe ┌───────────────┐
│ SmsReceiver   │────────────►│ Realtime Database    │────────►│ SMSSyncClient │
│ +SmsReader    │  setValue    │ sms/{uid}/{msgId}     │ value/  │ (decrypt+cache)│
│ +Room queue   │  (overwrite) │ + security rules      │ child   │ SMSConsoleView │
└───────────────┘             └──────────────────────┘         └───────────────┘
```

**RTDB node** `sms/{uid}/{messageId}` — `messageId = "{smsId}_{timestamp}"` (D14), written with `setValue` (idempotent overwrite):
```json
{
  "addressEnc": "…",        // AES-GCM ciphertext (encrypted at rest)
  "bodyEnc": "…",           // AES-GCM ciphertext
  "threadKey": "hash(normalizedNumber)",
  "threadId": 12,           // native device thread id (D15)
  "date": 1720000000000,
  "type": 1,                // 1=inbox 2=sent 3=draft 4=outbox 5=failed 6=queued (D15)
  "read": true,
  "seen": true,             // (D15)
  "subscriptionId": 0,      // SIM slot for dual-SIM; -1 unknown (D15)
  "serviceCenter": null,    // (D15, optional)
  "syncedAt": 1720000001000,
  "schema": 1
}
```
> Only `addressEnc`/`bodyEnc` are ciphertext; structural fields (ids, timestamps,
> flags, SIM) stay plaintext so the desktop can thread/sort/paginate over its
> **local decrypted cache** without decrypting on every scroll. `threadKey` is a
> keyed hash so grouping works without exposing the number. RTDB `.indexOn`
> `date` enables `orderByChild("date")` range pulls for pagination/backfill.

Desktop maintains a **local decrypted cache** (SQLite/Core Data) for search + offline; search/filter run over that cache (D2 — RTDB has no server-side text query).

**Desktop components:** `FirebaseRTDBClient` (actor), `SMSSyncClient` (actor: observe + decrypt + local cache), `SMSConsoleViewModel` (@MainActor), `SMSConsoleView` (new `AppModule.smsConsole`).

### 7.1 Pairing & key setup (the security core)

The whole model rests on two secrets that must reach both devices: the **Firebase
config** (which project) and the **E2E passphrase** (how to decrypt). Both are
established once, on the desktop, and carried to the phone via **QR pairing**.

```
1. Desktop → Settings → Cloud (Firebase): user pastes Firebase config + signs in (Firebase Auth).
2. Desktop → sets an E2E passphrase. Key = Argon2id(passphrase, salt).  Salt stored in the user's
   RTDB at meta/{uid} (public-ish; salt is not secret). Passphrase itself never stored anywhere.
3. Desktop shows a PAIRING QR = { firebaseConfig, uid hint, salt, checksum }  — NOT the passphrase.
4. Phone scans QR → gets Firebase config + salt → signs in → user TYPES the same passphrase on the
   phone once → derives the identical key. A test record confirms the key matches (decrypt check).
5. Both devices now hold the same AES-GCM key; neither the QR nor Firebase ever carried the passphrase.
```

Key points:
- **The passphrase is never transmitted or stored** — only the non-secret salt travels in the QR. The user re-types the passphrase on the phone. This keeps it a true zero-knowledge key even against someone who films the QR.
- Losing the passphrase = unrecoverable data (D4). The desktop shows this warning at setup and offers to store the passphrase in the **macOS Keychain** for convenience (device-local only).
- **Key rotation:** changing the passphrase re-encrypts new messages under the new key; old ciphertext stays under the old key (documented; full re-encryption is a later enhancement).

### 7.2 Realtime Database security rules (deployable)

Ships in the user setup guide; scopes everything to the owner and indexes `date` for range pulls:

```json
{
  "rules": {
    "sms": {
      "$uid": {
        ".read":  "auth != null && auth.uid === $uid",
        ".write": "auth != null && auth.uid === $uid",
        ".indexOn": ["date"]
      }
    },
    "meta": {
      "$uid": {
        ".read":  "auth != null && auth.uid === $uid",
        ".write": "auth != null && auth.uid === $uid"
      }
    }
  }
}
```
(Read-only desktop is enforced app-side; rules stay symmetric so the same account works if two-way is added later. A stricter variant that only allows writes bearing a "phone" custom-claim is noted as a future hardening.)

### 7.3 Realtime Database cost (user's own account)

- RTDB bills by **data downloaded + stored + simultaneous connections** (not per-doc reads like Firestore). Ciphertext-text payloads are small.
- The one-time **backfill of a large history** (the reference saw ~40k messages) is the main spike — **warn + estimate** before first full sync, and let the user **cap history depth** (e.g., "last 90 days") and go deeper later.
- Steady state is cheap: the desktop keeps a local cache and only receives `child_added` deltas via `.observe`. Well within the RTDB free tier for typical users; documented as *their* quota.

### 7.4 SMS categorization (shared `SmsClassifier`, from *Hamza*)

Adopted from the Hamza reference (`~/CW/Hamza`, see F-048 §11.2). A content-first,
**first-match-wins** classifier labels every message, giving the console category
filters/labels on top of by-number threads:

```
1. OTP           — "OTP"/"verification code"/"NNNN is your …"
2. Personal      — sender is a bare phone number (7–15 digits, no letters) = a human
3. Government     — UIDAI/EPFO/NDMA/COWIN/… or "-G" sender, emergency wording
   ├─ (-P sender) — DLT promotional-only header → short-circuits to Promotional
4. Transactional — debited/credited/UPI/NEFT/IMPS or money token + verb  ← feeds F-048
5. Service        — delivered/shipped/order/booking/statement/due-date
6. Promotional    — offer/sale/discount/unsubscribe/links
7. DLT-suffix fallback — trust the registered -S/-T/-P/-G suffix
8. Uncategorized
```

- **Content signals beat the suffix** (a `-S` sender with promo copy → Promotional), except `-P` which is trusted as promo-only.
- The classifier is **one shared component** used by both the console (label/filter) and F-048 (keep only Transactional) — build once, in whichever layer both can reach (desktop Swift port and/or the mobile app).
- **DLT sender semantics** (India): `-P` promotional, `-T`/`-S` transactional/service, `-G` government; sender-core (e.g. `INDUSB` from `VM-INDUSB-S`) is reusable for per-bank filtering.

## 8. Acceptance Criteria

- With Firebase configured on both apps, SMS from the Android device appear on desktop within the chosen sync cadence.
- Threads grouped correctly; search + number filter work.
- RTDB stores only ciphertext for address/body (verified in the Firebase console).
- Re-sync creates no duplicates; resumes from high-water mark.
- Disable + wipe removes local cache and cloud docs.
- Security review passed (rules, encryption, key handling).

## 9. Open Questions & Risks

- MMS/attachments — include, or text-only v1? (default: text-only.)
- RTDB free-tier quota (download/storage) for heavy SMS users; backfill cost on the user's account.
- Key management UX: passphrase loss = unrecoverable data (acceptable? recovery hint?).
- Contact-name resolution (show names vs. numbers) — needs contacts permission too.
- iOS console-only users (no sync source) — acceptable partial experience.

## 10. Execution Plan

### Phase 0 — Spike (foundational, shared with F-045/F-049)
- Validate **firebase-ios-sdk on macOS** (Realtime Database + Auth) via SPM; sandbox/network entitlements.
- Prototype **client-side AES-GCM + Argon2** encryption helper.
- Deliverable: go/no-go on macOS Firebase; reusable `FirebaseClient` + crypto util.

### Phase 1 — Config & foundation
- Settings **Cloud (Firebase)** pane (config, Keychain storage, Test connection) — shared with F-045.
- QR pairing helper (encode/scan Firebase config).
- RTDB **security rules** + **`.indexOn` date** template documented for users.

### Phase 2 — Desktop console (read side)
- `FirebaseRTDBClient` (auth + Realtime DB), `SMSSyncClient` (observe + decrypt + local cache).
- `AppModule.smsConsole` + `SMSConsoleView` (threads/messages/search/filter, pagination).
- Snapshot-listener live updates + polling fallback; "Wipe synced data".

### Phase 3 — Mobile sync source (lands with F-049)
- Android `READ_SMS` flow, content-resolver reader, encrypt + upsert, high-water mark, periodic sync (WorkManager), number allow/deny list.

### Phase 4 — Hardening
- Load test (50k messages), pagination + search perf.
- **Security review** (rules, crypto, key handling, no PII in logs).
- Docs: user setup guide (create Firebase, deploy rules, connect both apps).

### Test plan
- Unit: messageId dedup, high-water incremental logic, encrypt/decrypt round-trip, thread grouping/number normalization.
- Integration: end-to-end Android→Firebase→desktop with a test project.
- Manual: search/filter/pagination, disable+wipe, connection failure states.

### Rough effort
Spike ~2 d · Config ~2 d · Desktop console ~4 d · Mobile sync ~3 d (within F-049) · Hardening/review ~2 d. **~13 d** excluding mobile-app shell.

---

## 11. Reference Implementation Analysis — *SMSArchiver*

Analysed `~/Github/SMSArchiver` (Kotlin/Android, `com.prasad.smsarchiver`), a
working SMS→Firebase uploader by the same author. It is the proven baseline for
the **mobile sync-source** half of F-044. Summary of what it does and how Halo
diverges.

### What SMSArchiver does (and we adopt)

| Area | SMSArchiver approach | Halo decision |
|------|---------------------|---------------|
| Capture | `SmsReceiver` (BroadcastReceiver, `SMS_RECEIVED`, priority 999) → WorkManager `SmsUploadWorker` | **Adopt** — real-time receiver → immediate worker (see cadence note below) |
| Read | `ContentResolver` on `content://sms`, projection `_id,address,body,date,type,…`, `date DESC`; `getMessagesAfter(timestamp)` | **Adopt** — same reader; incremental via high-water mark |
| Dedup | `documentId = "{smsId}_{timestamp}"`, `setValue()` overwrites | **Adopt** (D14) |
| Resilience | Room `QueuedSmsEntity` + Dao; on failure enqueue; each run **flushes queue first**, then uploads new | **Adopt** (D13) |
| Race fix | `delay(1200)` before reading (row not yet persisted when broadcast fires) | **Adopt** (D16) |
| Dual-SIM | `subscriptionId` per message | **Adopt** (D15) |
| Fields | `id, threadId, address, body, timestamp, type(1–6), read, seen, protocol, serviceCenter, subscriptionId` | **Adopt** richer schema (§7) |
| Backend | **Firebase Realtime Database**, path `users/{uid}/sms/{documentId}` (migrated from Cloud Storage JSON blobs) | **Reconsider** — see below |
| Auth | `signInAnonymously()` | **Reject for Halo** — see below |
| Encryption | none (plaintext maps) | **Improve** — Halo adds client-side E2E (D4) |
| Config | hardcoded `google-services.json` | **Improve** — Halo makes Firebase user-configurable (BYOB) |
| Scale seen | ~40,244 messages read from a real device | Confirms backfill cost concern (§7.3) — batch + cap history |

### Where Halo must improve on the reference (the console changes everything)

SMSArchiver is **write-only** (phone → cloud, no reader). Halo adds a **desktop
reader**, which forces three upgrades:

1. **Stable shared identity (D12).** Anonymous auth mints a *per-install* uid, so
   the desktop could never find the phone's data. Halo requires **email/password
   (or linked) Firebase Auth** so both devices resolve the **same `uid`**. This
   is the single most important divergence.
2. **E2E encryption (D4).** A readable cloud console of your SMS is a juicy
   target; SMSArchiver stores plaintext. Halo encrypts `address`+`body` before
   upload (structural fields stay queryable, §7).
3. **User-configurable Firebase (BYOB).** SMSArchiver ships one hardcoded
   project; Halo lets each user attach their own (foundations §1), which is the
   whole open-source privacy premise.

### Two decisions this analysis re-opens

- **RTDB vs Firestore.** The reference proved **Realtime Database** works for the
  append-heavy write path and cheap `setValue` dedup. Halo's spec chose
  **Firestore** for the *console* (richer queries, pagination, offline cache,
  snapshot listeners) — still the recommendation, but RTDB is a viable, cheaper
  fallback if Firestore-on-macOS proves heavy (validated in the Phase 0 spike).
  *The `{smsId}_{timestamp}` overwrite-dedup pattern ports to either.*
- **Cadence refinement (revisit D8).** The reference shows the real-time
  `SmsReceiver` is cheap (it only schedules a worker) and gives instant "SMS
  appears on my Mac" UX. **Proposed refinement:** combine the receiver
  (near-real-time) **with** the periodic WorkManager safety net **and** on-open —
  rather than periodic-only. This strictly improves freshness at negligible
  battery cost. *Pending your confirmation.*

### Concrete FRs added from the reference

- **FR-15** Mobile: maintain a **local Room upload queue**; on upload failure, enqueue; each sync **flushes the queue before** uploading new messages (D13).
- **FR-16** Mobile: apply a **≥1200 ms delay** after a `SMS_RECEIVED` trigger before querying the provider (D16).
- **FR-17** Mobile: capture **`subscriptionId` (SIM)**, `threadId`, full `type`, `seen`, `serviceCenter` (D15).
- **FR-18** Mobile: real-time `SmsReceiver` → immediate worker, **in addition to** periodic + on-open (proposed cadence refinement).
