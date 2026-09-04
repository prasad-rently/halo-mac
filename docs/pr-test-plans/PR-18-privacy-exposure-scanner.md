# Manual Test Plan — PR #18: F-018 Privacy Data Exposure Scanner

> **Branch:** `feat/f018-privacy-exposure-scanner` · **Base:** `main` · **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/18
> **Diff size:** 14 files changed, +1241/-4
> **Master regression doc:** this PR's test cases also appear at [`§4.2`](../MASTER_TEST_PLAN.md) of the consolidated master plan, under **Protection**.

## How to test this PR

```bash
git fetch origin feat/f018-privacy-exposure-scanner
git checkout feat/f018-privacy-exposure-scanner
```

Then build & sign per `CLAUDE.md` → "Build & Sign" (or, for a quick local run with signing
disabled, `xcodebuild -project Halo.xcodeproj -target Halo -configuration Debug
CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`, then `open` the
resulting `.app`). Launch the app and work through the test cases below.

## Source files this PR adds/changes

- `Halo/Core/Models/Models.swift`
- `Halo/Core/Scanner/PrivacyExposureScanner.swift`
- `Halo/Core/Scanner/PrivacyPatternDatabase.swift`
- `Halo/Features/Protection/ProtectionView.swift`
- `Halo/Resources/privacy-patterns.json`

## Detailed test cases

**Files:** `PrivacyExposureScanner.swift`, `PrivacyPatternDatabase.swift`, `privacy-patterns.json`, `ProtectionView.swift` (`PrivacyExposureSection`).

Read-only, find-only scan of Downloads/Documents/Desktop (iCloud Drive is opt-in, off by default) for exposed credit card numbers, AWS/GitHub/Stripe keys, SSH private keys, and SSNs. All matching and redaction happen inside `PrivacyPatternDatabase` — the full matched secret never leaves the actor's local scope, and there is no delete/quarantine action, only "Reveal in Finder".

| ID | Priority | Title | Steps | Expected |
|----|----------|-------|-------|----------|
| TC-PROT-08 | P0 | Run a scan | Protection → "Run Sensitive Data Scan" | Status cycles idle → scanning (running file count) → complete; findings (if any) grouped by risk |
| TC-PROT-09 | P0 | AWS key detected in a real file | Place a file containing an `AKIA...` key in Downloads | Finding appears, category "AWS Access Key", redacted preview `AKIA••••••••XXXX` |
| TC-PROT-10 | P0 | Credit card number detected | Place a file containing a real-shaped, Luhn-valid card number | Finding appears, category "Credit Card Number", redacted to last 4 only |
| TC-PROT-11 | P1 | Luhn-invalid digit run is NOT flagged | Place a file with a 16-digit non-card number (e.g. an order ID) | No credit-card finding — false-positive guard via Luhn checksum |
| TC-PROT-12 | P0 | SSH private key header detected | Place a file starting with `-----BEGIN OPENSSH PRIVATE KEY-----` | Finding appears; the PEM header itself is shown unredacted (it's a public marker, not a secret) |
| TC-PROT-13 | P1 | SSN detected | Place a file containing `123-45-6789`-shaped text | Finding appears, category SSN, risk Warning, redacted to last 4 |
| TC-PROT-14 | P0 | Clean locations | Scan folders with no sensitive data | "No exposed sensitive data found" empty state |
| TC-PROT-15 | P1 | Binary files skipped | Place a renamed binary with a `.txt` extension containing a real key | Not scanned — null-byte peek heuristic catches it; no finding |
| TC-PROT-16 | P1 | Oversized file skipped | Place a >10 MB file containing a key | Not scanned — size limit enforced |
| TC-PROT-17 | P0 | iCloud Drive off by default | Fresh install, view the toggle | "Include iCloud Drive" toggle is off; iCloud is not scanned unless enabled |
| TC-PROT-18 | P1 | iCloud Drive opt-in | Enable the toggle, run a scan | iCloud Drive's local folder is included in the scan |
| TC-PROT-19 | P0 | Reveal in Finder | Click "Reveal in Finder" on a finding | `NSWorkspace.activateFileViewerSelecting` opens Finder with the file selected — no other action available |
| TC-PROT-20 | P1 | Findings grouped and sorted | Multiple findings across risk levels | Grouped Critical → Warning → Info; within a group, sorted by modified date (newest first) |
| **Unit** TC-PROT-U5 | P0 | AWS key match + redaction | `evaluate(text:)` on AWS example key | Matches `.awsKey`/critical, redacted `AKIA••••••••MPLE` |
| **Unit** TC-PROT-U6 | P0 | GitHub token match + redaction | `evaluate(text:)` on a 36-char `ghp_` token | Matches `.githubToken`/critical, redacted `ghp_••••••••<last4>` |
| **Unit** TC-PROT-U7 | P0 | Stripe secret/publishable key match + redaction | `evaluate(text:)` on `sk_live_`/`pk_live_` keys | Correct category, prefix preserved, last 4 shown |
| **Unit** TC-PROT-U8 | P0 | SSH private key exact match, unredacted | `evaluate(text:)` on a PEM header | Matches `.sshPrivateKey`/critical; preview equals the header verbatim |
| **Unit** TC-PROT-U9 | P0 | SSN match + redaction | `evaluate(text:)` on `123-45-6789` | Matches `.ssn`/warning, redacted `•••-••-6789` |
| **Unit** TC-PROT-U10 | P0 | Luhn-valid card matched, Luhn-invalid rejected | Visa test number vs. sequential digits | First reported as `.creditCard`; second produces no credit-card hit |
| **Unit** TC-PROT-U11 | P1 | Per-pattern match cap | 25 repeated AWS-shaped keys in one text | Exactly 20 hits returned, not 25 |
| **Unit** TC-PROT-U12 | P2 | Plain/empty text produces no hits | Unremarkable text, empty string | Zero hits both times |
| **Unit** TC-PROT-U13 | P1 | Risk severity ordering | Sort `[.info, .warning, .critical]` | Returns `[.critical, .warning, .info]` |

## Regression spot-check

This PR only *adds* a new section to **Protection** — it shouldn't change any existing
behavior there, but a merge always carries some risk of an unintended side effect (a renamed
shared helper, a health-score weighting change, a modified shared model). Before signing off:

- Re-run a couple of the *existing* Protection test cases from [`§4` in the master
  regression doc](../MASTER_TEST_PLAN.md) to confirm nothing already-shipped in that module regressed.
- If this PR touches `Models.swift`, `AppState.swift`, or `AlertManager.swift`, also smoke-test
  Dashboard (§2) and the sidebar (§1) — those are the most widely shared files in the app and a
  bad merge there tends to show up as a build break or a silent Dashboard glitch rather than a
  Protection/Files/Performance-specific symptom.
- Confirm the app still builds and the full existing `HaloTests` unit suite still passes
  (`xcodebuild test -scheme HaloTests`) — this PR's own new unit tests are included in the table
  above, but a green run of the *whole* suite is the actual regression gate.
