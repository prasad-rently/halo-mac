# Review Plan — PR #6: Plan NFeat-122–127 (F-044–F-050) with reference analysis

> **Branch:** `feature/upcoming-features` · **Base:** `feature/f-043-drive-speed-test` (stale — see below)
> **Status:** 🔶 Open, not yet merged
> **GitHub:** https://github.com/prasad-rently/halo-mac/pull/6
> **Diff size:** 18 files changed, +2762/-0 (all additions — no code touched)

## Why this one isn't a "manual test plan"

This PR adds **zero application code** — it's `docs/specs/*.md` requirement documents for six
future features (F-044 → F-050) plus roadmap updates. There is nothing to click through in the
app because nothing in the app changed. The right review here is a **documentation review**, not
a functional test pass.

## ⚠️ Before reviewing: this PR's base branch is stale

Its declared base is `feature/f-043-drive-speed-test`. That branch already shipped — F-043 Drive
Read & Write Speed Test is marked `[x]` done in `docs/ROADMAP.md` on `main` today. GitHub still
reports this PR as `mergeable: MERGEABLE` / `mergeStateStatus: CLEAN`, but the base should be
retargeted to `main` before merging so the diff you're reviewing is exactly "these 18 doc files,"
not "these 18 doc files plus whatever #5 added that hasn't been fast-forwarded in."

## Source files this PR adds

- `docs/specs/00-foundations.md` — BYOB Firebase, client-side E2E encryption, auth, mobile stack decisions
- `docs/specs/F-044-shared-sms-console.md`
- `docs/specs/F-045-clipboard-sync.md`
- `docs/specs/F-046-ai-querying.md`
- `docs/specs/F-047-on-device-ai-rag.md`
- `docs/specs/F-048-expenditure-tracker.md`
- `docs/specs/F-049-halo-mobile-app.md`
- `docs/specs/F-050-haloshare-mobile.md`
- `docs/specs/BUILD_PLAN.md`, `docs/specs/README.md`, `docs/specs/firebase-setup.md`
- `docs/specs/pattern-packs/README.md`, `docs/specs/pattern-packs/india-bank-sms.v1.json`
- `docs/FEATURE_ROADMAP.md`, `docs/HALO_MOBILE_ROADMAP.md`, `docs/MOBILE_PLATFORM_FEATURES.md`, `docs/ROADMAP.md`, `CLAUDE.md`

## Review checklist

| ID | Priority | Title | What to check |
|----|----------|-------|----------------|
| TC-DOCS-01 | P1 | Specs are internally consistent | Each `F-0xx` spec's "Depends on" / dependency graph matches what the other specs and `FEATURE_ROADMAP.md`'s pipeline table say — no spec claims a dependency that isn't itself specced or already shipped |
| TC-DOCS-02 | P1 | Mobile-parity governance followed | Per `CLAUDE.md`'s mandatory rule, confirm each new `F-0xx` here has (or explicitly plans) a mobile feasibility study — check `docs/HALO_MOBILE_ROADMAP.md` for a corresponding row |
| TC-DOCS-03 | P2 | Pattern-pack data file is well-formed | `docs/specs/pattern-packs/india-bank-sms.v1.json` parses as valid JSON and its schema matches what `F-044-shared-sms-console.md` / `F-048-expenditure-tracker.md` describe consuming |
| TC-DOCS-04 | P2 | Reference-analysis claims are attributed, not fabricated | Sections citing the `SMSArchiver` and `Hamza` reference projects read as genuine analysis (specific mechanisms named) rather than generic boilerplate — spot-check one or two specific claims (e.g. the `{smsId}_{timestamp}` dedup key, the ±120s self-transfer window) against the actual reference repos if you have access |
| TC-DOCS-05 | P1 | No secrets or credentials committed | Grep the diff for anything that looks like a real API key, Firebase config, or credential — `firebase-setup.md` should describe *how* to set one up, never contain a real one |
| TC-DOCS-06 | P2 | Roadmap docs updated consistently | `FEATURE_ROADMAP.md`, `ROADMAP.md`, and `MOBILE_PLATFORM_FEATURES.md` all reflect the same planned F-044→F-050 sequence — no stale/contradictory entries between them |
| TC-DOCS-07 | P0 | Base branch retargeted before merge | Confirm PR base is updated to `main` (see warning above) so the merge diff is exactly this PR's own content |

## Not applicable here

Skip: app build/launch testing, UI walkthroughs, unit/UI test runs, regression spot-checks — none
apply, since no `Halo/`, `HaloTests/`, or `HaloUITests/` files are touched by this PR.
