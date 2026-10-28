#!/bin/bash
# F-058 / FR-R3 — build the UNSIGNED release APK (or take one you already have), then zipalign,
# sign with the OWNER-HELD keystore, and verify. See android/RELEASE.md.
#
# The keystore and its password are supplied by environment and are never written anywhere:
#   HALO_KEYSTORE        path to the keystore (.jks/.p12) — must be OUTSIDE the repo
#   HALO_KEYSTORE_PASS   keystore password (also used for the key unless HALO_KEY_PASS is set)
#   HALO_KEY_ALIAS       key alias inside the keystore
#   HALO_KEY_PASS        optional, only if the key password differs from the keystore password
# Passwords reach apksigner through `env:` references, never on a command line, so they do not
# appear in `ps` output or shell history.
#
# Usage:  android/scripts/sign-release.sh [--apk path/to/app-release-unsigned.apk] [--skip-build] [--out DIR]
#   default: runs `./gradlew :app:assembleRelease`, signs its output.
#   --out    default: android/app/build/outputs/apk/release-signed (gitignored)
#
# Exit: 0 signed + verified, 1 verification failed, 2 usage / environment problem.

set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ANDROID_DIR/.." && pwd)"
cd "$ANDROID_DIR"

APK="" SKIP=0 OUT="$ANDROID_DIR/app/build/outputs/apk/release-signed"
die() { echo "sign-release: $*" >&2; exit 2; }
fail() { echo "sign-release: VERIFY FAILED — $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apk)        APK="${2:-}"; SKIP=1; shift 2 ;;
    --skip-build) SKIP=1; shift ;;
    --out)        OUT="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- signing inputs -----------------------------------------------------------------------------
: "${HALO_KEYSTORE:?set HALO_KEYSTORE to the owner-held keystore path}"
: "${HALO_KEYSTORE_PASS:?set HALO_KEYSTORE_PASS}"
: "${HALO_KEY_ALIAS:?set HALO_KEY_ALIAS}"
[ -f "$HALO_KEYSTORE" ] || die "keystore not found: $HALO_KEYSTORE"
KS_ABS="$(cd "$(dirname "$HALO_KEYSTORE")" && pwd)/$(basename "$HALO_KEYSTORE")"
case "$KS_ABS" in "$REPO"/*) die "the keystore is inside the repo ($KS_ABS). Keep it outside, so it can never be committed." ;; esac
export HALO_KEY_PASS="${HALO_KEY_PASS:-$HALO_KEYSTORE_PASS}"

# --- Android build-tools: newest installed ------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BT="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$BT" ] || die "no Android build-tools under $SDK (set ANDROID_HOME)"
ZIPALIGN="$SDK/build-tools/$BT/zipalign"; APKSIGNER="$SDK/build-tools/$BT/apksigner"
[ -x "$ZIPALIGN" ] && [ -x "$APKSIGNER" ] || die "zipalign/apksigner missing in $SDK/build-tools/$BT"
echo "build-tools : $BT"

# --- 1. unsigned APK ----------------------------------------------------------------------------
if [ "$SKIP" -eq 0 ]; then
  step "gradle :app:assembleRelease (unsigned — the build has no signing config by design)"
  ./gradlew --no-daemon :app:assembleRelease
fi
[ -n "$APK" ] || APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"
[ -f "$APK" ] || die "unsigned APK not found: $APK"

# --- 2. zipalign, then sign (order matters: apksigner v2+ must run AFTER zipalign) --------------
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/halo-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ALIGNED="$WORK/aligned.apk"

step "zipalign (4-byte, page-aligned native libs)"
"$ZIPALIGN" -p -f 4 "$APK" "$ALIGNED"
"$ZIPALIGN" -c -p 4 "$ALIGNED" || fail "zipalign -c rejected the aligned APK"

step "apksigner sign"
SIGNED="$OUT/halo-mobile-signed.apk"
rm -f "$SIGNED" "$SIGNED.idsig"
"$APKSIGNER" sign \
  --ks "$KS_ABS" --ks-key-alias "$HALO_KEY_ALIAS" \
  --ks-pass env:HALO_KEYSTORE_PASS --key-pass env:HALO_KEY_PASS \
  --out "$SIGNED" "$ALIGNED"

# --- 3. verify the artefact the user would sideload ---------------------------------------------
step "apksigner verify"
V="$("$APKSIGNER" verify --verbose --print-certs "$SIGNED")" || fail "apksigner verify rejected $SIGNED"
echo "$V" | sed -n '1,12p'
echo "$V" | grep -q 'Verified using v2 scheme (APK Signature Scheme v2): true' \
  || echo "$V" | grep -q 'Verified using v3 scheme (APK Signature Scheme v3): true' \
  || fail "no v2/v3 signature reported"
"$ZIPALIGN" -c -p 4 "$SIGNED" || fail "signed APK is no longer aligned"
echo "  ok   aligned"

SHA="$(shasum -a 256 "$SIGNED" | cut -d' ' -f1)"
( cd "$OUT" && echo "$SHA  $(basename "$SIGNED")" > "$(basename "$SIGNED").sha256" )

step "done"
echo "signed APK : $SIGNED"
echo "sha256     : $SHA"
echo "cert       : $(echo "$V" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
echo "Record that cert digest: every future release must show the same one, or phones will refuse the update."
