# Pattern Packs

Data-driven keyword/regex packs for SMS classification (F-044) and transaction
parsing (F-048). Externalizing these lists means a bank/format can be added
**without code changes** — the parser/classifier loads a pack at runtime.

## Packs

| File | Locale | Purpose | Source |
|------|--------|---------|--------|
| [expense-fixtures.v1.json](expense-fixtures.v1.json) | — | Cross-language contract (F-056): SMS → expected classification/parse/category + pipeline cases. Expectations follow the spec (F-048 / F-044 §7.4), with no per-platform override; `HaloTests/ExpenseFixtures` and `android/halocloud ExpenseFixtureTest` both run it | Synthetic messages, no real account data |
| [india-bank-sms.v1.json](india-bank-sms.v1.json) | en-IN / INR | Classifier categories + transaction parser rules | Ported verbatim from the *Hamza* reference (`~/CW/Hamza`), verified against a real inbox Apr–Jun 2026 |

## Structure

- **`tuning`** — constants: balance context window (`balanceContextChars`, 48), dedup window (120 s), personal-sender digit range, "nearest-to-verb" flag.
- **`dltSuffix`** — India DLT header semantics (`-T/-S/-P/-G`).
- **`classifier`** — ordered categories + keyword lists (OTP, government, transactional, service, promotional) used by F-044's `SmsClassifier` on **both** platforms (desktop `SmsClassifier.swift`, phone `SmsClassifier.kt` — no hard-coded lists left).
- **`parser`** — debit/credit verbs, exclude/promo words, non-bank senders, balance prefixes, `rejectPatterns` (credit-card bill-payment acknowledgements), the balance-context regexes (`balanceClauseBoundaryRegex`, `balanceAfterRegex`) and the amount/account/merchant regexes used by F-048's `TransactionParser`.
- **`categories`** — the F-048 §12 spend-category rules (ordered; first rule with a `triggers` substring, or a `wordTriggers` entry as a whole word (no A–Z letter either side), in `UPPER(merchant + " " + body)` wins). Added for F-056 so desktop and phone share one copy. **One file, two consumers, no copy:** the Kotlin build packages this file (and only this file) into `halocloud`'s resources, and the Xcode project lists it as a Copy Bundle Resources entry of the Halo app target (a `SOURCE_ROOT`-relative file reference into `docs/`), which `PatternPack.indiaDefault` reads with `Bundle.main`.
- **`algorithm`** — the 8-step reference algorithm, so an implementer can port it deterministically.

## Important inherited fixes (do NOT "clean up")

These non-obvious choices are load-bearing (each fixed a real mis-parse — see F-048 §11.5):

- **Bare `HTTP`/`WWW.` are NOT in the parser's `promoWords`** — bank fraud-report URLs would otherwise drop real UPI debits. (They *are* in the classifier's broader `promoKeywords`, which only runs after the transactional check.)
- **Bare `REFUND` is NOT a credit verb** — only `REFUNDED` (settled) counts; `INITIATED` is an exclude word so pending refunds aren't counted.
- **`TXN RS`/`TXN INR` ARE debit verbs** — verb-less card spends (`Txn Rs.522 On Card…`).
- **E-mandate/autopay executions are counted** (they carry a `debited` verb); only `WILL BE …` future announcements are excluded.

## Adding a pack / bank

1. Copy `india-bank-sms.v1.json`, adjust `locale`/`currency`, and extend the verb/reject/sender lists and `amountRegex` for the new formats.
2. Bump `version`.
3. Add a labeled SMS corpus + precision/recall test (see F-048 test plan) before shipping.

> Ownership note: the packs are locale data, not secrets. They ship with the app;
> the actual SMS they run against stay in the user's own encrypted store.

## Versioning

Bump `version` whenever a rule change can alter what an already-parsed message means. On the phone the sealed ledger stores the pack `id` + `version` it was parsed under; a different version drops the derived rows and the high-water marks (so the inbox is re-read under the new rules) and **keeps the user's overrides** (`ExpenseLedgerTest`). v2 (this change): balance-context rules, `rejectPatterns`, delivery exclude words, whole-word category triggers.
