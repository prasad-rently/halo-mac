# Release notes template (F-058 / FR-R4)

Copy this file's body into the GitHub release / `docs/` record for each release. **The Verified and
NOT verified tables are mandatory** — a release without them is not ready.

Rules for the tables:

- A row goes in **Verified** only if the check was actually run, and the **How** says what it ran
  against. Anything that ran only on an emulator, a stand-in (fake relay, local Firebase stub,
  loopback peer) or a developer-signed build must **say so in that row** — never imply a real
  device, real carrier, real account or notarised build.
- Everything you did not run, or could not run, goes in **NOT verified** with *why* and *what would
  verify it*. Owner verification debt (`V-*` rows in the planning pack's TODO) belongs here until a
  result is recorded.
- A roadmap status changes from 🔧 to ✅ only when the matching `V-*` row has a recorded result.

---

```markdown
# Halo <version> — <date>   (pre-release | release)

Built from `<branch>` @ `<short-sha>`. Artifacts:

| File | sha256 | Signed with | Notarised |
|---|---|---|---|
| `Halo-<version>.dmg` | `<sha256>` | `<identity kind, e.g. Apple Development>` | yes / **no** |
| `halo-mobile-signed.apk` | `<sha256>` | signer cert `<sha256 digest>` | n/a |

## What changed
- <feature / fix, with its F-xxx / H-xx / PR #>

## Verified
| Area | How | Where |
|---|---|---|
| e.g. HaloTests | `xcodebuild -scheme HaloTests test` — N tests, 0 failures | local, macOS <ver>, Xcode <ver> |
| e.g. Android unit tests | `./gradlew :halocloud:test :haloshare:test` | local + CI run <link> |
| e.g. DMG signature | `build-dmg.sh` self-verify: `codesign --verify --deep --strict` from the mounted DMG; version <v> (<build>) on app, widget, helper | local, dev-signed |
| e.g. SMS → console | <how> — **emulator / stand-in only** | <where> |

## NOT verified
| Area | Why | What would verify it |
|---|---|---|
| e.g. SMS from a real carrier SIM | needs a physical phone + SIM | owner run of MANUAL_TEST_PLAN §20.3 (V-1) |
| e.g. Notarisation / Gatekeeper first-launch | needs the owner's Developer ID | owner notarises, then opens on a clean Mac |
| e.g. Sandboxed Release build | built Debug-configuration only | RC checklist V-9 |

## Known issues
- <issue, impact, workaround, tracking link>
```
