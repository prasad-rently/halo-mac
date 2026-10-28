# Android release signing (F-058 / FR-R3)

Halo Mobile is **sideloaded** (F-049 D7) — there is no store submission. Two consequences:

- **CI never signs.** `:app:assembleRelease` has no signing config, so CI produces
  `app-release-unsigned.apk` only. There is no keystore in CI and none in this repo.
- **The owner holds the keystore** and signs on their own machine with
  [`scripts/sign-release.sh`](scripts/sign-release.sh).

## One-time: create the release keystore (owner)

```bash
keytool -genkeypair -v -keystore ~/secure/halo-release.jks \
  -alias halo-release -keyalg RSA -keysize 4096 -validity 10000
```

- Keep it **outside the repo** (the script refuses a keystore under the repo; `*.jks`, `*.keystore`
  and `*.p12` are also gitignored as a backstop).
- **Back it up** (password manager + an offline copy). Android only installs an update if it is
  signed with the *same* key as the installed app. Lose the keystore and every installed phone
  must uninstall (losing app data) before a new build will install.
- Record the certificate SHA-256 of the first release (the script prints it). Every later release
  must print the same digest.

## Each release

```bash
export HALO_KEYSTORE=~/secure/halo-release.jks
export HALO_KEY_ALIAS=halo-release
read -rs HALO_KEYSTORE_PASS && export HALO_KEYSTORE_PASS     # typed, not stored in history
# export HALO_KEY_PASS=...   only if the key password differs from the keystore password

android/scripts/sign-release.sh
```

The script:

1. runs `./gradlew :app:assembleRelease` (use `--skip-build`, or `--apk FILE`, to sign an existing
   unsigned APK, e.g. the one CI uploaded as the `halo-mobile-unsigned-apk` artifact);
2. `zipalign -p -f 4` the APK, then checks alignment;
3. signs with `apksigner sign` — passwords are passed as `env:` references, never on the command
   line;
4. runs `apksigner verify --print-certs`, requires a v2 or v3 signature, re-checks alignment;
5. writes `app/build/outputs/apk/release-signed/halo-mobile-signed.apk` plus a `.sha256`, and prints
   the signer certificate digest.

Order matters: **zipalign first, sign second** — aligning after signing invalidates the v2/v3
signature.

## Before you publish

- Install it on a phone (`adb install -r halo-mobile-signed.apk`) over the previous release to
  prove the update path (same key) works.
- Put the APK sha256 and the signer-cert digest in the release notes
  ([`docs/RELEASE_NOTES_TEMPLATE.md`](../docs/RELEASE_NOTES_TEMPLATE.md)).
- `versionCode` / `versionName` live in `app/build.gradle.kts` and must be bumped by hand for each
  release; Android refuses to install a lower `versionCode` over a higher one.

## How this was verified

The script was exercised end to end with a throwaway keystore (generated in a temp dir, never
committed): build-tools 36.1.0 zipalign + apksigner, `Verifies`, v2 + v3 true, alignment ok; a wrong
password fails closed (non-zero exit, no output APK). It has **not** been run with the owner's real
keystore, and a signed APK has not been installed over a previous release.
