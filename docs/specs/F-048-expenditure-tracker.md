# F-048 — Personal Expenditure Tracker (NFeat-126)

> **Status:** 🗓 Planned · **Platform:** Desktop
> **Depends on:** F-044 (SMS data in Firebase) · **Optional:** F-046/F-047 (AI-assisted parsing)
> **Reference:** *Hamza* project

---

## 1. Summary

An **approximate personal expenditure tracker** built on the transaction SMS
already synced by F-044 (bank/wallet alerts in the user's Firebase). Halo parses
transaction messages into structured entries (amount, merchant, direction, date)
and presents a spending overview — totals, trends, categories. "Approximate" by
design, since it infers from SMS rather than bank APIs.

## 2. Goals / Non-Goals

**Goals**
- Parse transaction SMS from the F-044 dataset into structured transactions.
- Categorize + aggregate; visualize spend by period/category/merchant.
- Fully local compute over the user's own Firebase-sourced data.

**Non-Goals (v1)**
- Direct bank/financial API integration (SMS-only, BYOB).
- Budgeting/alerts/goals (later).
- Guaranteed accuracy — it's an approximation from SMS text.
- Multi-currency reconciliation beyond basic locale handling.

## 3. Decisions & Assumptions

> **Grounded in the *Hamza* reference** (`~/CW/Hamza`, Kotlin/Android) — a working,
> edge-case-hardened SMS→expenditure engine. Its proven pipeline and heuristics
> are adopted directly (see §11). D2–D11 reflect that analysis.

| # | Decision | Note |
|---|----------|------|
| D1 | Source = **F-044 synced SMS** only | No new data source. Requires F-044 shipped + configured. |
| D2 | **Rules/regex parser first** (Hamza pipeline), AI-assist optional | Deterministic, offline, debuggable. AI (F-046/F-047) only as fallback for unmatched formats. |
| D3 | Local compute; decrypt F-044 messages locally | Reuses F-044 decryption + local cache. |
| D4 | **India-centric bank/UPI + DLT-suffix** patterns first (per Hamza) | `-P`=promo, `-T`/`-S`=txn/service, `-G`=govt sender semantics. Extensible pattern packs for other locales. |
| D5 | **Parse outcome = Ok / Unreadable / NotTransaction** ✅ *adopt* | Three-way result (Hamza). Only `Unreadable` (had a verb, no amount) counts toward the "couldn't read" tally. |
| D6 | **Amount heuristics: drop balance + nearest-to-verb** ✅ *adopt* | Discard amounts preceded by BAL/AVBL/LIMIT/DUE (≤14 chars); among the rest pick the one nearest the debit/credit verb. Fixes txn-vs-balance confusion. |
| D7 | **Self-transfer cancellation** ✅ *adopt* | Same-day, same-amount debit+credit paired and excluded from totals; shown as a neutral ⇄ Transfer row. |
| D8 | **Near-duplicate dedup (±120 s, same amount+direction)** ✅ *adopt* | Collapses one txn reported by two senders / debit+receipt pairs. |
| D9 | **User overrides** (force-include / force-exclude / exclude sender-core) ✅ *adopt* | Precedence: per-message id > sender-pattern > automatic rules. Persisted. |
| D10 | **On-device SQLite mirror with delete-sync** ✅ *adopt* | `replaceAll` on each load mirrors the current inbox (deleted SMS drop out); fallback to cache if source unreadable. |
| D11 | "Approximate" clearly labeled; **confidence + source-SMS drill-in** | Every figure traces back to its message. |

## 4. User Stories

- **US-1** As a user with SMS synced, I see my spending summarized without manual entry.
- **US-2** As a user, I view spend by month, category, and merchant.
- **US-3** As a user, I correct a mis-parsed or mis-categorized transaction and it's remembered.
- **US-4** As a user, I understand these figures are approximate (from SMS).
- **US-5** As a user, my financial data stays local/in my own Firebase — no third party.

## 5. Functional Requirements

- **FR-1** Read + decrypt SMS from the F-044 local cache; classify and keep **Transactional** only (§11.2).
- **FR-2** Reject non-transactions: `-P`/non-bank senders, exclude/promo words, future-autopay (§11.3). Bare URLs are **not** rejects.
- **FR-3** Direction via earliest debit/credit verb; **amount** via currency regex with **balance-drop** + **nearest-to-verb** selection; emit `Ok/Unreadable/NotTransaction` (§11.3, D5/D6).
- **FR-4** Extract account tail + best-effort merchant.
- **FR-5** **markSelfTransfers** (same-day, same-amount debit+credit) → excluded from totals, shown as ⇄ Transfer (D7).
- **FR-6** **Near-duplicate dedup** (same amount+direction ≤120 s) (D8).
- **FR-7** **User overrides**: force-include / force-exclude / exclude sender-core, precedence id > sender > auto, persisted, badged (D9).
- **FR-8** **TxnStore** SQLite mirror: `replaceAll` on load (delete-sync), fallback to cache if source unreadable (D10).
- **FR-9** Aggregations: month `spent/received/net` (transfers skipped, `en-IN` grouping), **calendar heatmap**, **weekday chart**, **year view** (§11.6).
- **FR-10** Confidence flag + **source-SMS drill-in** for every figure; list `Unreadable` for review.
- **FR-11** Optional AI-assisted parse for unmatched formats (F-046 cloud / F-047 local), user-enabled.
- **FR-12** Data-driven **pattern packs** (verbs/rejects/senders) — add a bank without code changes. Ships the ported [`india-bank-sms.v1.json`](pattern-packs/india-bank-sms.v1.json) (exact Hamza lists + regexes).
- **FR-13** Export (CSV) of parsed transactions.

## 6. Non-Functional Requirements

- **Privacy:** all financial inference is local over the user's own data; no external financial API; nothing logged.
- **Accuracy honesty:** UI communicates approximation; show source SMS for each transaction.
- **Extensibility:** pattern packs are data-driven (add a bank without code changes where possible).
- **Performance:** parse thousands of SMS quickly; incremental re-parse on new messages.

## 7. Architecture

```
F-044 decrypted cache ─► SmsClassifier ─► TransactionParser ─► markSelfTransfers ─► dedup(±120s)
   (transactional only)   [Ok/Unreadable/NotTransaction]                              │
                                                                                       ▼
   overrides (id > sender > auto) ─────────────────────────────────────────────► TxnStore (SQLite mirror)
                                                                                       │
                                                          Aggregator ─► ExpenditureView (summary/heatmap/weekday/year)
```
- `SmsClassifier` (shared with F-044): 8-category, first-match-wins (§11.2).
- `TransactionParser` (actor): reject lists + direction verbs + amount heuristics (drop-balance, nearest-to-verb) → `Ok/Unreadable/NotTransaction` (§11.3).
- `TxnStore`: SQLite mirror with delete-sync + read-failure fallback (§11.4/D10).
- `@MainActor ExpenditureViewModel` + `ExpenditureView` (new `AppModule.expenditure`).

**Parsed transaction:**
```json
{ "id":"…","amount":123.45,"currency":"INR","direction":"debit",
  "merchant":"AMAZON","category":"Shopping","date":1720000000000,
  "accountHint":"XX1234","confidence":0.82,"sourceMessageId":"…" }
```

## 8. Acceptance Criteria

- With F-044 data present, the tracker parses recognizable bank SMS into transactions.
- Spend summarized by period/category/merchant with charts.
- Manual re-categorization persists and affects aggregates.
- Low-confidence/unparsed items are surfaced for review; source SMS viewable.
- No external financial API; all local.

## 9. Open Questions & Risks

- Hard dependency on F-044 — the tracker is empty without it. Acceptable ordering.
- Parsing accuracy varies wildly by bank/format; how much *Hamza* pattern set to adopt/port.
- Locale/currency scope for v1 (India-first?).
- AI-assisted parsing cost/privacy trade-off (cloud F-046 vs local F-047).
- Handling refunds, transfers, duplicates, and non-transaction promo SMS.

## 10. Execution Plan

### Phase 1 — Extraction
- Sender allowlist + transaction-detection heuristics.
- Regex pattern packs (India-first, data-driven); `TransactionExtractor`.

### Phase 2 — Categorize & store
- Merchant map + rules + user overrides; `TxnStore` (persist parsed txns + overrides).

### Phase 3 — Insights UI
- `AppModule.expenditure` + views: summary cards, category breakdown, time series; source-SMS drill-in; confidence flags; CSV export.

### Phase 4 — AI-assisted parsing (optional)
- Fallback extraction via F-046/F-047 for unmatched formats (user-enabled).

### Phase 5 — Hardening
- Accuracy tuning on sample corpora; dedup/refund/transfer handling; docs.

### Test plan
- Unit: regex packs against a labeled SMS corpus (precision/recall), categorizer rules, aggregation math, override persistence.
- Manual: end-to-end from F-044 data, re-categorization, export, low-confidence review.

### Rough effort
Extraction ~3 d · Categorize/store ~2 d · Insights UI ~3 d · AI-assist ~2 d · Hardening ~2 d. **~12 d** (after F-044 ships).

---

## 11. Reference Implementation Analysis — *Hamza*

Analysed `~/CW/Hamza` (Kotlin/Android) — a working, edge-case-hardened SMS
expenditure engine with a documented `EXPENDITURE.md` and fix history. It is the
**authoritative model for F-048's parsing/aggregation logic**. Cherry-picked
below; port to Swift on the desktop (over F-044's decrypted cache) and/or reuse
in the Halo Mobile app.

### 11.1 The proven pipeline (adopt wholesale)

```
decrypted SMS ─► SmsClassifier.classify() ─► keep TRANSACTIONAL only (honor user moves)
             ─► TransactionParser.parse() ─► Ok(Transaction) | Unreadable | NotTransaction
             ─► markSelfTransfers()        ─► cancel same-day same-amount debit+credit
             ─► dedupNearDuplicates(±120s) ─► collapse double-reported txns
             ─► TransactionDb (SQLite mirror, delete-sync)
             ─► aggregate: month / calendar heatmap / weekday / year
```

### 11.2 Classification (shared with F-044 — see F-044 §categorization)

Content-first, **first match wins**, then DLT-suffix fallback:
`OTP → Personal(sender is a bare phone number) → Government(UIDAI/EPFO/-G/…) →
[-P sender ⇒ Promotional shortcut] → Transactional → Service → Promotional →
DLT suffix(-S/-T/-P/-G) → Uncategorized`. Only **Transactional** feeds expenditure.

### 11.3 Transaction parser — the heuristics that matter

**Hard rejects → `NotTransaction`:**
- **Promotional sender** — DLT header ends `-P` (banks alert from `-T`/`-S`).
- **Non-bank sender** — telecom/wallet/e-com/utility (`AIRTEL, JIO, PAYTM, PHONEPE,
  MOBIKWIK, AMAZON, FLIPKART, SWIGGY, ZOMATO, EKART, INDANE, IRCTC, NETFLIX…`).
  Matched on **sender only** — a merchant *named in the body* from a bank sender still counts.
- **Exclude words** (not a completed spend): `DECLINED, FAILED, REVERSED, IS DUE, DUE ON,
  PAYMENT DUE, TOTAL DUE, MIN AMT, PLEASE PAY, OVERDUE, REMINDER, INITIATED`, and future
  autopay `WILL BE DEBITED/DEDUCTED/AUTO, TO BE DEBITED`.
- **Promo words**: `OFFER, DISCOUNT, SALE, % OFF, COUPON, PRE-APPROVED, LOAN OFFER, CLAIM,
  VOUCHER, UNSUBSCRIBE, CLICK HERE, HURRY…`  — **bare `HTTP`/`WWW.` are NOT rejects** (bank
  alerts carry fraud-report URLs; rejecting them dropped every Kotak UPI "Sent" debit — a
  real bug fix, §11.5-A).

**Direction (earliest verb wins):**
- Debit/expense: `DEBITED, SPENT, WITHDRAWN, PURCHASED, DEDUCTED, PAID, SENT, CHARGED,
  TXN OF, DEBIT OF, PAYMENT OF, TXN RS/INR`.
- Credit/income: `CREDITED, RECEIVED, DEPOSITED, REFUNDED, ADDED`.
- No verb ⇒ `NotTransaction`.

**Amount extraction (the crux):**
- Regex: `(?:RS|INR|₹)\.?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)` — handles `Rs.1,23,456.78`, `INR 12,185.00`, `₹500`. (Bare numbers with no currency token are NOT amounts.)
- **Drop balance amounts:** discard any amount preceded within ~14 chars by
  `BAL, BALANCE, AVBL, AVAILABLE, AVL, LIMIT, OUTSTANDING, DUE`.
- **Nearest-to-verb wins:** among remaining amounts, pick the one closest to the direction verb → the transaction amount, not the balance. No usable amount ⇒ `Unreadable`.

**Extras (best-effort, nullable):** account tail (`XX3833` / `A/C…3833` → last 3–4 digits); merchant (`at AMAZON on`, `to JOHN via`, `info: SWIGGY`).

**E-mandate/autopay:** actual auto-debit *executions* carry a `debited` verb → counted; only *future* announcements (`WILL BE…`) are skipped.

### 11.4 Post-parse correctness

- **Self-transfers (D7):** bucket by `"<year>-<dayOfYear>|<amount×100>"`; pair `min(#debits,#credits)`; flag both `isTransfer`; **exclude from all totals**, show as ⇄ Transfer.
- **Near-dup dedup (D8):** same **amount + direction within 120 s** collapse to one (two banks reporting one credit; card-debit + merchant-receipt). Window is tunable (`DEDUP_WINDOW_MS`).
- **Overrides (D9):** `ExpenditureOverrides` — force-exclude id, force-include id (`forceParse` bypasses all filters), exclude sender-core (e.g. `INDUSB`). Precedence id > sender > auto. UI badges: `⊘` excluded / `＋` force-included.
- **DB mirror (D10):** SQLite `txn` keyed by `sms_id`; each load `replaceAll`s from the freshly parsed inbox (so deleted SMS drop out); falls back to cache if the source can't be read. Columns: `sms_id, amount, is_expense, date, merchant, account, sender`.

### 11.5 Documented bug fixes to inherit (don't re-introduce)

- **A. URL false-reject** — removed bare `HTTP`/`WWW.` from promo rejects; added `INITIATED` to excludes + removed bare `REFUND` from credit verbs (kept `REFUNDED`) so *pending* refunds aren't counted.
- **B. Verb-less card txns** — added `TXN RS`/`TXN INR` as debit verbs (`Txn Rs.522 On Card…At paytm`).
- **C. Same-money double count** — the ±120 s dedup (D8).
- **Working-as-intended:** OTPs, `-P` promos, "due"/reminder bills, Government, Personal, delivery/service all correctly excluded.

### 11.6 Aggregation & display (adopt)

- **Month summary:** `spent = Σexpense`, `received = Σincome`, `net = received − spent`, **transfers skipped**; Indian grouping (`en-IN`, ₹1,23,456).
- **Calendar heatmap:** per-day spend intensity (red ∝ day/month-max), compact `-₹…/+₹…`.
- **Weekday chart** (Mon–Sun totals) and **Year view** (12 monthly bars + total/avg).
- Reload on view appear so new/deleted SMS reflect.

### 11.7 Known limitations (carry forward as caveats)

Indian-format tuned; merchant is the fuzziest field (often null); self-transfer heuristic is amount+day only (no account/time-window check); dedup misses splits >120 s apart; day bucketing uses device-local time. All acceptable for an **approximate** tracker — surface, don't hide.

### 11.8 What Halo adds on top of Hamza

- **Data source:** Halo reads F-044's **decrypted cache** (cross-device, encrypted at rest), not the raw device inbox — so the tracker works on the **desktop**, which Hamza has no equivalent of.
- **Pattern packs as data:** externalize Hamza's hardcoded word lists into data-driven, user-extensible packs (add a bank without code).
- **AI fallback (optional):** route `Unreadable`/unknown-format messages through F-046/F-047 for extraction, user-enabled.
