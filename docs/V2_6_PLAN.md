# Halo v2.6 — plan and record

> **Theme: stabilise, finish, clean up.** v2.5 landed the cloud line, an Android app, Lucky Draw avatars and a Cleanup fix — built, independently reviewed, and **not yet tested by the owner on real devices**. v2.6 makes that trustworthy and complete, ships the one fully specified new desktop feature (F-054), and makes releases repeatable.
>
> Integration branch `release/v2.6`, cut from `release/v2.5` @ `bf8fde2` (all six v2.5 PRs #50–#55 merged there; **`main` is untouched**, decision D-05). This document is the plan **and the record**: §5 says what each open PR actually built. Written 2026-11-01 from the PRs (the source of truth) and the planning pack; **every status below is a statement about 2026-11-01 and must be re-checked against `gh pr list` before it is relied on.**
> **v2.6 is a label for "after v2.5", not a frozen scope** — this plan freezes *admission rules*, not dates.

> **State on 2026-11-01:** eight PRs (#56–#63) are **open and unmerged** against `release/v2.6`. Nothing is published, tagged or released. **No owner test (T-1…T-9, V-1…V-10) has been run.** No row in this document is ✅ for anything that touches a real phone, a real Firebase project, a screen, or the sandboxed release build.

---

## 1. Goals and non-goals

1. **Trustworthy** — close the defects and test gaps the reviews found (H-xx).
2. **Complete** — finish what is half-built (F-053, Android background behaviour) and ship F-054.
3. **Smoother to adopt** — fewer first-run failures (F-057) and repeatable releases (F-058).
4. **Honest** — keep a visible verification-debt list (§7) and never mark it done early.

**Non-goals → v2.7:** iOS cloud client, MLX generation, assisted provisioning, notarisation, caricature/animated art, HaloShare TLS, store publishing, anything needing a device/account/artwork/certificate to *finish*. See [`FEATURE_ROADMAP.md`](FEATURE_ROADMAP.md) "v2.7 backlog".

## 2. Admission rule (so scope cannot creep silently)

An item is admitted to v2.6 only if **all** are true: (1) completable on this Mac, JDK 17, the Android emulator (API 36), the iOS Simulator and local stand-ins (`android/tools/fake-firebase.py`); (2) verifiable by automated tests or a scripted emulator run against those stand-ins; (3) needs no new account, certificate, artwork, device or secret; (4) needs no owner decision to *start* (decisions that only shape details have a stated default); (5) does not widen the attack surface without a threat-considerations line in its PR. Items passing (1)–(3) but large (iOS client, MLX) are excluded on size. Adding scope means amending this plan and the roadmap in the same change.

## 3. Owner decisions — all eight accepted 2026-10-28 (defaults)

This table is the authoritative copy; `FEATURE_ROADMAP.md` links here.

| ID | Decision (as accepted) | Affects | Wording update 2026-11-01 |
|---|---|---|---|
| D-01 | Type the passphrase twice on an empty database and say it could not be verified | H-12, F-057 | Implemented in v2.5 (#55) |
| D-02 | Permanent removal only for **Safe + git-verified** F-054 items | F-054 | Built on #59; hidden **and** refused in a sandboxed build (spike S-B) |
| D-03 | **`~/Downloads` is excluded from F-054 — not user-addable in v2.6** | F-054 | Original wording ("excluded from *default* roots; the user can add it") was **superseded**: #59 refuses `~/Downloads`/`~/Library` even when the user adds them (banner, never silent) — one owner per path (BUG-001 FR-2) |
| D-04 | Smart Scan keeps an *Xcode (global)* line item sourced from F-054's scanner | F-054 | Built on #59 |
| D-05 | Landing order per the interim plan; `main` untouched in v2.6 (merging still needs the owner's word per PR) | all | v2.5 landed on `release/v2.5`; v2.6 PRs target `release/v2.6` |
| D-06 | Close stale PRs #1/#6 with a pointer; rename the older "F-051" in docs only | housekeeping | **#6 and #7 are closed; #1 is open on purpose** (its Maestro flows + onboarding fix are not on `release/v2.5`). The "F-051" rename is not done. Closing is an owner action |
| D-07 | Owner holds the Android release keystore; CI builds an unsigned APK | F-058 | Built on #56 |
| D-08 | One beta containing all six v2.5 PRs (skip a separate beta.1) | release | An unpublished RC exists (`~/Downloads/Halo-2.5-RC/`); **publishing is the owner's action** |

## 4. Scope and status (2026-11-01)

Status words: ✅ done and verified (how stated) · 🔧 built / open PR, not merged or not verified live · 📋 specified, not built · ⛔ blocked (named) · 👤 needs the owner.

| Order | Item | Effort | Status | Where |
|---|---|---|---|---|
| 0 | Land v2.5 (#50–#55) | — | ✅ merged into `release/v2.5`; **⛔/👤 owner tests T-1…T-9 not run**; beta not published | §5 P0 |
| 1 | Hardening H-01…H-21 | ≈ 17 | 🔧 mostly built across #56/#60/#61; open items in §6 | §6 |
| 2 | F-054 Build Artifact Cleaner | ≈ 9 | 🔧 built on #59; pane never viewed on screen | [`specs/F-054-…`](specs/F-054-build-artifact-cleaner.md) |
| 3 | F-053 completion (non-art) | ≈ 5 | 🔧 C-1…C-4 built on #57; hero flight not seen on screen | [`specs/F-053-…`](specs/F-053-lucky-draw-avatars.md) |
| 4 | F-055 Android background & sharing | ≈ 8 | 🔧 built on #62 (stacked on #61) | [`specs/F-055-…`](specs/F-055-android-background-and-sharing.md) |
| 5 | F-056 Expenditure on Android | ≈ 7 | 🔧 built on #58; JVM-only; known parser false positives | [`specs/F-056-…`](specs/F-056-expenditure-on-android.md) |
| 6 | F-057 Cloud setup assistant | ≈ 4 | 🔧 built on #63; review in progress | [`specs/F-057-…`](specs/F-057-cloud-setup-assistant.md) |
| 7 | F-058 Release engineering | ≈ 4 | 🔧 built on #56; CI never run on GitHub | [`specs/F-058-…`](specs/F-058-release-engineering.md) |
| — | Docs / test plan / wrap-up | ≈ 4 | 🔧 this PR | — |

**Effort (rough engineer-days, not commitments):** hardening ≈ 17 (≈ 2 of it done early on v2.5) + F-054 8–9 + F-053 5 + F-055 8 + F-056 7 + F-057 4 + F-058 4 + docs ≈ 4 → **base ≈ 58; with a 15 % buffer ≈ 67** (two parallel tracks ≈ 6–7 weeks). By track: Desktop ≈ 26, Android ≈ 22, Repo ≈ 8, early v2.5 items ≈ 2.5. These figures were the plan; **actuals were not tracked**.

## 5. Phases — as executed

### P0 — Land v2.5
Six PRs merged into `release/v2.5` (head `bf8fde2`) after independent reviews: #52 → #51 → #53 → #50 → #54 → #55. Fixes added before merge: scan-generation guards test-proven (H-04), Clean All acts on the confirmed snapshot (H-01), avatar recovery-file photos never swept (H-07), passphrase typed twice when the DB cannot verify it (H-12, D-01). Verified on the merged head (handover): `HaloTests` 777 passed (one timing flake that passed on rerun), Android `:halocloud:test :haloshare:test` 141, `:app:assembleRelease` OK, both audits OK. RC artifacts (unpublished, not notarised): `~/Downloads/Halo-2.5-RC/`. **The owner's live tests T-1…T-9 have not been run** (cases in `MANUAL_TEST_PLAN.md` §20.6, all ◆).

### P1 — Hardening (#56 H-18; #60 desktop; #61 Android)
See §6. Review fixes: #60 five (prune cancellation was false; stale prune could drop a live row; `ChildDelivery.pending` O(total bytes) regression; symlinked scan root/Trash never covered its items; header-probe on `Data` slices); #61 three (outages/rate limits counted toward quarantine; "Retry skipped" raced a running sync; the Send-to-Mac share intent read `getStringExtra` and silently ignored `CharSequence` text) plus two H-13 data-safety fixes (`c5a02a8`, see §6) that **have not had a separate re-review**.

### P2 — F-054 (#59)
Built and reviewed (7 fixes). Spikes S-A/S-B are **analysis only** (`docs/specs/F-054-spikes.md` on #59): git is assumed denied in a sandboxed build (degrade path built: Unverified, Move-to-Trash only), and permanent removal is hidden and refused when sandboxed. **Pane never viewed on screen.** PR #59 also edits `CLAUDE.md` (second deletion exception, F-054 section, ID block `8265`–`8284`); that is **unmerged**, so `CLAUDE.md` on `release/v2.6` still has no F-054 exception.

### P3 — F-053 completion (#57)
C-1 hero travel, C-2 hub last winner, C-3 storage readout + per-roster clear, C-4 CSV avatar column, H-11 signposts + a headless draw-cost measurement. **Deviation:** the C-3 readout lives in the Lucky Draw **roster panel**, not Settings. C-5 docs are this PR. C-6 (animated emoji, caricatures) stays ⛔ ART → v2.7.

### P4 — Android (#61 hardening, #62 F-055, #58 F-056)
#62 is stacked on #61 (now `6d93b85` = #61 merged in; its emulator results pre-date the merge). #58 is independent.

### P5 — F-057 (#63) · P6 — F-058 (#56)
See their specs.

### P7 — Wrap-up
This documentation PR (`docs/v2.6-plan`, base `release/v2.6`). Not done: the RC build for v2.6, the owner verification run, any release.

## 6. Hardening — H-01…H-21 (authoritative status; requirements in the BRD text preserved below)

"Built" means code on an **unmerged** PR; none is ✅ unless it is merged **and** verified as stated.

| ID | Requirement (short) | Status | Where | Honest note |
|---|---|---|---|---|
| H-01 | Clean All acts on the confirmed set | ✅ merged v2.5 | #53 | red→green test; GUI not clicked (T-1 ◆) |
| H-02 | `pruneMissing`/existence checks off the main actor, bounded | 🔧 | #60 | Detached + deadline; **the 20 000-item "no > 50 ms stall" measurement was not done** (only a 33 ms `lstat` loop indicator); no signpost; Clean All gives no in-progress feedback and a double-click opens two prunes; key computation still on the main actor |
| H-03 | Per-operation result banner incl. partial failure | 🔧 | #60 | Model tests only; placement on screen not seen |
| H-04 | Scan supersession provable | ✅ merged v2.5 | #53 | mutation-proven |
| H-05 | Resolved-symlink path keys; case policy | 🔧 **partial** | #60 | Symlinked **directory components** and missing leaves handled. The BRD AC asked for a **case-insensitive temp-volume test and a per-volume policy — neither exists** (one global case-sensitive policy, documented); **firmlinks (`/System/Volumes/Data/…`) not canonicalised** (not reachable today); the pure `/var`↔`/private/var` tests pass even without the change (`standardizedFileURL` already maps it) — they are regression guards, only `symlinkedDirectoryAgrees` discriminates. **Gaps → v2.7** |
| H-06 | Measure `/Library/Caches`, `/private/var/folders`; close BUG-001 OQ-1 | ✅ measured | #60 body → recorded in BUG-001 §6 here | Read-only on one Mac (macOS 27). Decision: **do not add `/private/var/folders` as a root**; `/Library/Caches` is 4 KB root-owned — nothing to reclaim. Owner may overturn |
| H-07 | Orphan sweep never deletes recovery-file photos | ✅ merged v2.5 | #54 | red→green |
| H-08 | Fairness tested end to end | 🔧 | #60 | Seeded draw through the view model, 60 seeds × 4 display modes; mutation turns it red |
| H-09 | Deterministic sweep tests (positive + negative) | 🔧 | #60 | no `Task.sleep` |
| H-10 | Fail-closed size cap; header-bound PNG/TIFF; UUID case; 64 MB LRU cache | 🔧 | #60 | Residual: a roster of ≥ 256 entries all at the 256-px bucket exceeds the cap and would thrash; a hand-placed lower-case file on a case-sensitive volume becomes unreachable (not deleted) |
| H-11 | Measure the wheel; set the entry limit from data | 🔧 **partial** | #57 (not #60) | Signposts + a **headless offscreen CPU** draw-cost table (avatars add ≈ 1.05–1.3× to the plain wheel's cost; machine was loaded; **not on-screen fps**, not a GPU measurement). The entry limit stays **40** because the data do not support a change. Instruments / 60 fps / Intel **not measured** → V-8, v2.7 |
| H-12 | D-01 passphrase twice | ✅ merged v2.5 | #55 | logic tests; real-phone pairing remains V-1/V-4 |
| H-13 | Clipboard history sealed at rest | 🔧 **built, JVM-verified; device Keystore unverified** | #61 (`c5a02a8`) | Emulator: file starts `HSF1`, no plaintext, plaintext legacy file sealed in place. The review's two data-risk items are fixed — a **transient Keystore failure no longer overwrites** the history (saves deferred, then merged on recovery) and a **failed migration leaves the plaintext intact, reported and retried** — with failing-`Sealer` tests and four mutation checks. **Those author fixes had no separate re-review. Real-Keystore transient failure is NOT verified.** Follow-up open: `CloudStore.load()` reports "not paired" on **any** exception (a transient Keystore error looks like an unpaired phone; it never auto-overwrites) |
| H-14 | Poison-row quarantine + "Retry skipped" | 🔧 | #61 | Review fixed outages/rate limits counting toward quarantine (`RtdbException.isRowFault`). Open nit: quarantined entries for rows later deleted from the inbox are never pruned until "Retry skipped" |
| H-15 | Android minors (a11y config, SendToMac, stream race, cap sweep, host check, doc pointer) | 🔧 | #61 | **The a11y sub-item is gated on V-3**: only "bound" is proven on the emulator, the background clipboard read with an event-less service is **not verified** and could silently break the feature on real phones. Stream close race is *narrowed, not closed* (~30 s window) |
| H-16 | Password-leak test inspects bodies, mutation-checked | 🔧 | #61 | covers the literal and URL-encoded password only |
| H-17 | Sidebar UI canary + reproduce/rule out the lock | 📋 **open** | — | Needs a GUI session for `HaloUITests`; **not attempted**. Gotcha 31's "empirical remedy" wording is unchanged. Owner click-test T-2 pending. **→ v2.7 unless the owner pulls it forward** |
| H-18 | Rules-sync script | 🔧 | #56 | mutation-checked locally; CI hook unproven |
| H-19 | Resolve F-054 OQ-3/5/6; fold `/var` note into BUG-001 | 🔧 | this PR | **Docs only** — F-054 spec §12 and BUG-001 §6 updated here; becomes ✅ when this PR merges |
| H-20 | Wire-contract test, both directions | 🔧 | #60 (Swift, H-20a) + #61 (Kotlin, H-20b) | Same fixture, byte-identical (md5 `75ee0022…`). The review notes **no generator is committed**, so "captured from the real Kotlin writers" is a claim; the fixture lacks `lineVersion`/`updatedAt` (fold in both languages in one change after both merge) |
| H-21 | Line-node changes reach a live Mac | 🔧 | #60 (desktop, H-21a) + #61 (phone, H-21b) | Emulator vs the local stand-in only. The observer plumbing (`SMSSyncClient` choosing `observeChildAddedOrChanged`) has **no automated test**; a rename reaching a running Mac on real Firebase is **not verified** (V-2) |

H-12 and H-01/04/07 ride on v2.5 (the "I-1…I-4" early items); H-19 and the F-053 docs part are this PR.

### Review findings that remain open (recorded, not fixed)
Parser false positives and category-trigger collisions (F-056 §9) · H-05 gaps · H-13 follow-up (`CloudStore.load()`) · H-11/H-17/H-19 as above · **F-053:** the hub shows the **last winner (`history.first`)**, which right after a draw is the winner just announced — the BRD says "previous winner"; reviewer opinion: keep; one-line change if the owner means the one before · **F-053 C-3 deviation:** readout in the roster panel, not Settings · **F-054:** Active (< 24 h) items remain permanent-eligible; `Select all Safe` includes `.notRepo` items (Trash-only); a `*`-ignoring enclosing repo makes everything permanent-eligible (rare; needs a `rev-parse --show-toplevel` sanity check); opening Cleanup auto-rescans and triggers TCC prompts on first open (consider a first-run opt-in); `realTrashItemRoundTrip` touches the real Trash and is skipped by default; stale comment in `ScanCoordinator.executeCleanup`; a weak `groupingAndFilters…` assertion · **F-055:** POST_NOTIFICATIONS denied still enables the service; Stop does not re-sync the switch · **F-057:** pasteboard not cleared after the code hides; "specific children" rules not caught · **F-058:** actions not pinned by SHA, no wrapper validation, `versionCode` not enforced.

## 7. Verification debt — cannot be cleared from an emulator

A roadmap status changes from 🔧 to ✅ **only** when the matching V-row has a recorded result. Cases: `MANUAL_TEST_PLAN.md` §20.6 (T-1…T-9) and §20.7 (V-1…V-10, one per human-dependent AC), all ◆ (unrun).

| ID | What needs a real phone / account / screen | Blocks marking |
|---|---|---|
| V-1 | SMS from a real carrier SIM → Mac console (T-5/T-6) | F-044/F-049 verified |
| V-2 | Live Firebase: ciphertext in the console (T-8), rules from `firebase-rules.json`, clipboard rule exercised; F-057's check against a real project; H-21 rename | F-045, F-057 verified |
| V-3 | Background clipboard capture on the owner's phone OEM (T-7); H-15 a11y config | F-045 Android automatic capture |
| V-4 | Camera QR scan of the Mac's code | pairing verified |
| V-5 | Delete-mirroring on a real inbox | D25 |
| V-6 | Foreground service under real Doze / OEM battery managers; real multicast | F-055 verified |
| V-7 | Expenditure on the owner's real bank SMS vs statements; real Keystore ledger | F-056 verified |
| V-8 | Lucky Draw at real roster sizes, 60 fps feel; hero flight seen on screen | F-053 perf / C-1…C-3 |
| V-9 | Sandboxed release build runs F-053/F-054 paths (entitlements; git; Trash removal) | release build |
| V-10 | HaloShare with the **official LocalSend** app | MR-PR-5 |

Also unverified, no V-row of their own: F-054 pane on screen and large real-home scan (AC-13 on the owner's home); F-057 UIs on screen; F-058 CI first run.

## 8. Risk register

| ID | Risk | Mitigation | Trigger to re-plan |
|---|---|---|---|
| R-1 | Owner's live tests fail: wire mismatch, OEM blocks clipboard, real SMS differs from the emulator | H-20 contract test; F-055 foreground service; F-057 diagnostics | Any T-5/T-7 failure |
| R-2 | F-054: git unavailable under the sandbox; sandboxed removal denied | Spikes S-A/S-B (analysis only — **still unrun in a real sandbox**); degrade paths built | A sandboxed run contradicts the analysis |
| R-3 | Avatars hurt wheel frame rate | H-11 measured headless only; entry limit 40 | >16 ms on-screen frames at ≤ 20 entries |
| R-4 | Android 14/15 foreground-service policy | User-initiated start, `dataSync`, `onTimeout` handler | Real-phone refusal |
| R-5 | 21 hardening items balloon | Small ACs; owner may defer with a reason | — (H-05/H-11/H-17 already deferred in part) |
| R-6 | Docs/`CLAUDE.md` conflicts between parallel tracks | Serial doc merges; `CLAUDE.md` not touched by feature PRs except #59 | Any textual conflict (expected: #59 vs this PR's follow-ups) |
| R-7 | A deletion feature (F-054 D4b) lands weaker than its spec | Mutation-checked Trash-sentinel test; re-verification before the irreversible step; hidden when sandboxed | Review finds an escape |
| R-8 | Staging docs drift while PRs change | This plan states a date; re-check `gh pr list` | Any PR head moves |
| R-9 | A reviewer-introduced fix regresses an owner-confirmed behaviour | Owner re-checks T-2 | T-2 fails |

## 9. What is not in v2.6

See [`FEATURE_ROADMAP.md`](FEATURE_ROADMAP.md) "v2.7 backlog": iOS cloud client, F-047 MLX generation, assisted provisioning, notarisation, caricatures/animated emoji (ART), HaloShare TLS/unification, physical-device validation campaign, official LocalSend interop, mobile ports, expenditure cloud sync, reply/MMS/sent-sync — each with its blocker.

## 10. Ground rules held

`trashItem` only (two narrow, owner-approved exceptions, F-053 NFR-S4 implemented on #54 and merged into `release/v2.5`; **F-054's is implemented on #59 and is not yet in `CLAUDE.md`'s rule text because #59 is unmerged**) · confirmation before destruction · `ShellReader` only for subprocesses · new pbxproj files only via `scripts/add_source_files.rb` · state verified vs not verified · do not merge or release unless the owner says so · dates are absolute.
