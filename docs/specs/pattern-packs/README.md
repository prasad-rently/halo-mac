# Pattern Packs

Data-driven keyword/regex packs for SMS classification (F-044) and transaction
parsing (F-048). Externalizing these lists means a bank/format can be added
**without code changes** — the parser/classifier loads a pack at runtime.

## Packs

| File | Locale | Purpose | Source |
|------|--------|---------|--------|
| [india-bank-sms.v1.json](india-bank-sms.v1.json) | en-IN / INR | Classifier categories + transaction parser rules | Ported verbatim from the *Hamza* reference (`~/CW/Hamza`), verified against a real inbox Apr–Jun 2026 |

## Structure

- **`tuning`** — constants: balance lookbehind (14 chars), dedup window (120 s), personal-sender digit range, "nearest-to-verb" flag.
- **`dltSuffix`** — India DLT header semantics (`-T/-S/-P/-G`).
- **`classifier`** — ordered categories + keyword lists (OTP, government, transactional, service, promotional) used by F-044's `SmsClassifier`.
- **`parser`** — debit/credit verbs, exclude/promo words, non-bank senders, balance prefixes, and the amount/account/merchant regexes used by F-048's `TransactionParser`.
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
