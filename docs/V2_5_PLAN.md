# Halo v2.5 — plan

> **Theme: land the cloud line.** F-044 (cloud core + SMS console), F-045 (clipboard sync) and F-048
> (expenditure tracker) were built for desktop in July on `feature/f-044-cloud-foundation` (PR #7) and
> never merged. The roadmap lists them as "Planned"; the code exists, reviewed, with a defect list.
> v2.5 brings that work onto the current release line, fixes the review findings, makes it safe to ship,
> and unblocks the mobile side (F-049) with a Kotlin crypto-parity port.
>
> Cut from `release/v2.4` @ `92636ec` (v2.4.0-beta.1). Integration branch `release/v2.5`; work branch
> `feat/v2.5-cloud-line`.

---

## 1. What is pending (survey, 2026-10-25)

| Item | State | v2.5? |
|---|---|---|
| **F-044/F-045/F-048 desktop** | Built on PR #7 (15 commits, 3 merge conflicts vs v2.4); never merged | **Yes — P1** |
| PR #7 review: 3 critical, 3 medium, 4 low findings | Open since 2026-09-04 | **Yes — P2** |
| Release-config safety of the cloud code (sandbox, keychain group, App Group, audits) | Never checked on the merged line | **Yes — P3** |
| Crypto parity for Android (`docs/specs/crypto-parity-vectors.v1.json`) | Vectors exist; no Kotlin implementation | **Yes — P4** |
| Docs: roadmap says "Planned", CLAUDE.md has no cloud section | Stale | **Yes — P5** |
| Desktop widget showing no data on the installed v2.4 | Unconfirmed; needs a look at the machine | **Investigate — P6** |
| F-047 on-device AI + RAG | Gated on spike S3 (MLX tokens/sec, packaging) — needs hardware benchmarking and a model download | No |
| F-049 cloud features on phones (SMS sync, clipboard, QR pairing) | Needs physical Android/iOS device **and** a live Firebase project | No (P4 removes the code-side blocker) |
| Live end-to-end against real Firebase | Needs the user's Firebase project and credentials | No |
| Assisted Firebase provisioning (S2) | Blocked on Google restricted-scope app verification (policy, not code) | No |
| Notarisation | Needs a paid Developer ID | No |
| `main` is ~119 commits behind `release/v2.4`; stale PRs #1/#6/#7; 12 `worktree-agent-*` branches | Owner decisions | No — listed in the PR for the owner |

## 2. Phases

### P1 — Land F-044 / F-045 / F-048 on the v2.4 line
- [x] Merge `feature/f-044-cloud-foundation`; resolve `AppState.swift` / `ContentView.swift` (additive enum cases: `.messages`, `.expenditure` beside `.ai`, `.luckyDraw`, `.lethe`).
- [x] `project.pbxproj`: **not** hand-merged (sorted blocks interleave; a wrong merge silently drops a file from Sources). Took the v2.4 file and re-added the 20 sources + `CloudFoundationTests` + `firebase-ios-sdk` (Database, Auth) with the repo's `scripts/add_*.rb`, then checked programmatically: none missing, none duplicated.
- [ ] Compiles on the merged line; exhaustive `switch` over `AppModule` fixed wherever the new cases appear.
- [ ] Sidebar, module ordering migration (existing users' saved order gains the new modules), icons.

### P2 — Fix every PR #7 review finding (with a test each)
| # | Finding | Fix |
|---|---|---|
| 1 | `CryptoService.randomBytes` discards the `SecRandomCopyBytes` status → all-zero salt on failure | Check status, throw `randomGenerationFailed`; test that `generateSalt()` is never all-zero |
| 2 | Same in `GoogleOAuthPKCE` → constant, publicly known PKCE verifier | Same; add `generateState()` + constant-time `validate(state:)` (finding 9) |
| 3 | Any non-empty E2E passphrase accepted (`"a"`) | Passphrase strength floor enforced in `CryptoService` **and** all three UIs; shared validator |
| 4 | Ciphertext envelope has no version | Versioned envelope (`v` byte) with a read path for the unversioned v0 blobs; **this is a wire-format change, so the Kotlin vectors are regenerated after it** |
| 5 | KDF preconditions missing (empty passphrase, 1-byte salt, low stored iterations) | Explicit preconditions: salt ≥ 16 B, iterations ≥ floor |
| 6 | 200 000 PBKDF2 iterations | 600 000 (OWASP 2023); stored alongside salt so old keys still derive |
| 7 | Derived key bytes not wiped | `defer` wipe |
| 8 | `encrypt` throws a *decryption* error | `encryptionFailed` case |
| 10 | Clipboard filter flags every 32+ hex string (git SHAs) | Narrow to ≥ 64 hex; show a count of excluded items |

### P3 — Make it safe to ship
- [ ] Entitlements: `keychain-access-groups` for FirebaseAuth (-34018) present in **both** `Halo.entitlements` and `Halo-Debug.entitlements`; App Group still present in all three (run `scripts/audit-entitlements.sh`); `network.client` in the sandboxed file.
- [ ] `scripts/audit-subprocess-spawning.sh` still passes (no `Process` outside `ShellReader`).
- [ ] Confirm no secret-shaped values are logged or reach Sentry from the new code (the v2.4 Sentry scrubber must cover cloud/clipboard payloads).
- [ ] New `AlertKind` cases (new-SMS notification) have matching arms in `AlertEntry.icon` / `.accentColor` — `HaloTests` enforces this.

### P4 — Kotlin crypto-parity port (unblocks F-049 M6)
- [ ] `android/halocloud` module: PBKDF2-HMAC-SHA256 + AES-256-GCM, identical envelope to Swift.
- [ ] Unit tests driven by the shared `crypto-parity-vectors.v1.json` — the same file the Swift suite reads, so a drift on either side fails a test.
- [ ] Vectors regenerated from the Swift implementation **after** P2.4/P2.6.

### P5 — Documentation
- [ ] `FEATURE_ROADMAP.md`: F-044/045/048 status → merged to v2.5 (honest about what is unverified live); v2.5 scope section.
- [ ] `CLAUDE.md`: Cloud / SMS console / Clipboard sync / Expenditure sections, Modules Status rows, pbxproj ID note.
- [ ] `MANUAL_TEST_PLAN.md`: cases for the new modules, marked *not yet run* where they need Firebase or a phone.
- [ ] `HALO_MOBILE_ROADMAP.md`: F-044/045/048 rows reflect the parity port.

### P6 — Widget on the installed v2.4 (carry-over)
- [ ] Reproduce on a signed build with the App Group entitlement; establish whether the shared container is written; fix if it is a code problem, document if it is a macOS consent prompt.

### P7 — Validation (end of run)
- [ ] Full desktop suite on the PR head, Kit + Kotlin suites, both audits, a signed build verified with `codesign --deep --strict`.
- [ ] PR to `release/v2.5` with an honest verified / not-verified table.

## 3. Ground rules for this run
- Every new destructive path keeps the project's rules: `trashItem` only, confirmation before delete, `ShellReader` for subprocesses.
- Secrets never in logs, Sentry, UserDefaults — Keychain only.
- Anything that needs a live Firebase project, a phone or a Developer ID is **stated as unverified**, never implied.
- Testing is done at the end (P7); each phase is only required to **build** when it lands.

## 4. Explicitly not in v2.5
F-047 (S3 spike), F-049 device features, live-Firebase validation, assisted provisioning, notarisation, repo housekeeping that needs an owner decision.
