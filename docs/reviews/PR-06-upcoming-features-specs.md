# Code review — PR #6 · docs: plan NFeat-122–127 (F-044–F-050)

- **PR:** [prasad-rently/halo-mac#6](https://github.com/prasad-rently/halo-mac/pull/6)
- **Branch:** `feature/upcoming-features` → `feature/f-043-drive-speed-test`
- **Reviewed at:** commit `fff8bbda` · 18 files, +2762 / −0 (docs only)
- **Inline comments:** [review 5115675755](https://github.com/prasad-rently/halo-mac/pull/6#pullrequestreview-5115675755)

## Verdict: **Approve with comments**

Planning-only, no implementation — reasonable to land so the scope/sequencing conversation has a
shared reference. The per-feature *Decisions & Assumptions* tables and *Open Questions* sections
are the right structure for this kind of document, and grounding F-044/F-045/F-048 in analysis of
two real reference codebases (rather than inventing a design) is the value-add the summary claims
it is. `HALO_MOBILE_ROADMAP.md` with §0 governance is a good addition and is what the sibling
feature PRs (#9–#21) are all correctly filing against.

Three things worth resolving before merge, none of them about the content quality.

## Issues

| # | File:Line | Section | Issue | Risk | Suggested fix |
|---|-----------|---------|-------|------|----------------|
| 1 | `docs/specs/pattern-packs/india-bank-sms.v1.json:7-8` | Security / legal | The file declares itself a *"Data-driven port of the Hamza reference (`~/CW/Hamza`: SmsClassifier.kt, TransactionParser.kt)"* with `"source": "Hamza (com.example.hamza) — verified against real device inbox Apr–Jun 2026"`. That is ~96 lines of word-lists, DLT sender-suffix mappings, regexes and tuning constants transcribed out of another codebase's source files, and the `~/CW/` path suggests a work or client project rather than something author-owned or open source. Copying the substance into this repository needs an explicit basis — author owns the copyright, or a permissive licence (with licence text and attribution recorded), or written permission. "Data-driven port" doesn't change the analysis: extracting the tables and re-expressing them as JSON is still a derivative of the original's substance. Separately, *"verified against real device inbox"* is worth confirming on the record as the author's own device, with no third party's SMS content (bank names fine; account fragments, amounts, phone numbers not) in the committed tables. | Medium | Record the ownership/licence basis in `docs/specs/pattern-packs/README.md` (which ships in this PR, so there is a natural home), plus a one-line provenance statement about the verification corpus. Skimming the file I see nothing account-specific, which is good — but for a pack that will eventually parse other users' financial SMS the statement should be explicit rather than implicit. |
| 2 | base branch | Code standards | Targets `feature/f-043-drive-speed-test`, which is no longer an open PR — so the diff shown on GitHub is computed against a branch that has presumably already merged into `main`. | Low | Retarget to `main`, so the diff shown is the diff that will land and #7 (stacked on this) can be rebased onto something stable. |
| 3 | `docs/FEATURE_ROADMAP.md`, `docs/ROADMAP.md`, `CLAUDE.md` | Code standards | These specs describe F-044 → F-050 while F-016 → F-030 (PRs #9–#21) are all open and unmerged against `main`. Several of those PRs also edit `FEATURE_ROADMAP.md` and `ROADMAP.md`, as does this one, so whatever merges second conflicts in those files. | Low | Fold into the batch merge order (`docs/reviews/00-MERGE-ORDER.md`) rather than discovering it through conflicts. |

## Blocking issues

None strictly blocking, but **issue 1 should be answered before this is in git history** — a
licence question is much cheaper to resolve before the commit than after.

## Non-blocking suggestions

- 2 and 3 are Low and mechanical.
- The reference analysis itself (SMSArchiver for *getting* data into the cloud — sync, dedup, offline queue, the anonymous-auth trap, AccessibilityService clipboard capture; Hamza for *what to do with it* — classification taxonomy and edge-case-hardened parsing with a documented fix history) is the strongest part of this PR and reads as genuinely earned rather than summarised. Worth keeping that level of specificity in future spec work.
- Flagging Play Store policy risk for F-045's AccessibilityService clipboard capture, and avoiding `MANAGE_EXTERNAL_STORAGE`, are both good pre-emptive calls.

## Questions for the author

1. **What is the licence basis for `india-bank-sms.v1.json`** (issue 1)? Author-owned, permissively licensed, or permission granted?
2. Was the "real device inbox Apr–Jun 2026" verification against your own device only?
3. Should this be retargeted to `main` before merge (issue 2)?

---

## Risk definitions

- **Critical** — crash, data loss, security hole, or store-rejection risk; blocks merge
- **High** — breaks a user flow or another consumer of this code; should block merge
- **Medium** — bug or standards violation with limited blast radius; fix before merge or in immediate follow-up
- **Low** — style/readability/nice-to-have; non-blocking

## Related

- [Consolidated cross-PR review notes](https://github.com/prasad-rently/halo-mac/pull/21#issuecomment-5543671519) for the `F-016 … F-030` batch (#9–#21)
- `docs/reviews/00-MERGE-ORDER.md` on the `review/pr-audit` branch
