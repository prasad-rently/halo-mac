#!/bin/bash
# F-058 / FR-R2 — build, sign, package and self-verify a Halo DMG.
#
# Automates the "Build & Sign" recipe in CLAUDE.md so it is one command instead of a copy-paste
# that has gone wrong in specific, documented ways. Everything the recipe warns about is built in:
#
#   * CLEAN SYMROOT. A SYMROOT left over from a test build leaves HaloTests.xctest and XCTest
#     frameworks inside Halo.app; they ship, and they break `codesign --verify --deep --strict`.
#     The build dir is created fresh on every run, and the finished app is checked for them.
#   * SIGNING IDENTITY IS DISCOVERED, never hardcoded (it differs per machine). Override with
#     --identity or $HALO_SIGN_IDENTITY; otherwise the first "Apple Development" identity is used.
#   * SIGN ORDER. Every nested code object is signed before its container:
#     dylibs -> frameworks (Sentry) -> HaloHelper.xpc -> HaloWidget.appex -> Halo.app.
#   * VERSION CANNOT BE MISLABELLED. MARKETING_VERSION / CURRENT_PROJECT_VERSION are passed to
#     xcodebuild as overrides, and the finished app's Info.plist (plus the widget's and the
#     helper's) is read back and compared — a build labelled "2.4" when you meant a test build
#     (the v2.4-label confusion) fails here instead of shipping.
#
# What it does NOT do: notarise (owner-only, needs the owner's Apple ID/Developer ID), publish, or
# touch any source file (it does not run update_build_token.sh — that rewrites a tracked file; run
# it yourself first if you want a fresh dev token). The Sentry DSN stays SENTRY_DSN_PLACEHOLDER;
# this script asserts that rather than injecting a real one. No secret is read or written.
#
# Usage:
#   scripts/build-dmg.sh --version 2.6.0-rc1 [--build 260] [--configuration Debug|Release]
#                        [--identity "Apple Development: …"] [--out DIR] [--work DIR] [--keep-work]
#
#   --version   REQUIRED. Becomes MARKETING_VERSION (CFBundleShortVersionString).
#   --build     CURRENT_PROJECT_VERSION. Default: the value already in project.pbxproj.
#   --configuration  Debug (default — what shipped DMGs have used, see CLAUDE.md gotcha 27) or
#               Release. Debug signs with Halo-Debug.entitlements, Release with Halo.entitlements.
#   --out       where the .dmg and .dmg.sha256 land. Default: $TMPDIR/halo-release-out/<version>
#   --work      scratch dir (SYMROOT/OBJROOT/staging). Default: a fresh mktemp dir. Wiped first.
#
# Exit: 0 built + verified, 1 verification failed, 2 usage / environment problem.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="" BUILD="" CONFIG="Debug" IDENTITY="${HALO_SIGN_IDENTITY:-}" OUT="" WORK="" KEEP=0
die() { echo "build-dmg: $*" >&2; exit 2; }
fail() { echo "build-dmg: VERIFY FAILED — $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version)       need_val "$@"; VERSION="$2"; shift 2 ;;
    --build)         need_val "$@"; BUILD="$2"; shift 2 ;;
    --configuration) need_val "$@"; CONFIG="$2"; shift 2 ;;
    --identity)      need_val "$@"; IDENTITY="$2"; shift 2 ;;
    --out)           need_val "$@"; OUT="$2"; shift 2 ;;
    --work)          need_val "$@"; WORK="$2"; shift 2 ;;
    --keep-work)     KEEP=1; shift ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$VERSION" ] || die "--version is required (e.g. --version 2.6.0-rc1)"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$' \
  || die "--version '$VERSION' is not a plain version string"
case "$CONFIG" in Debug) ENT="Halo/Halo-Debug.entitlements" ;; Release) ENT="Halo/Halo.entitlements" ;; *) die "--configuration must be Debug or Release" ;; esac

if [ -z "$BUILD" ]; then
  BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' Halo.xcodeproj/project.pbxproj | sort -u)"
  [ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from project.pbxproj; pass --build"
  # Disagreeing values (a half-done hand edit) must not be resolved by guessing: that is how a
  # build gets mislabelled. Run scripts/bump-version.sh, or pass --build.
  [ "$(printf '%s\n' "$BUILD" | wc -l | tr -d ' ')" -eq 1 ] \
    || die "project.pbxproj has differing CURRENT_PROJECT_VERSION values ($(printf '%s' "$BUILD" | tr '\n' ' ')); run scripts/bump-version.sh or pass --build"
fi
printf '%s' "$BUILD" | grep -Eq '^[0-9]+$' || die "--build must be an integer"

for t in xcodebuild codesign hdiutil shasum plutil security /usr/libexec/PlistBuddy; do
  command -v "$t" >/dev/null 2>&1 || [ -x "$t" ] || die "required tool not found: $t"
done
for f in "$ENT" HaloWidget/HaloWidget.entitlements HaloHelper/HaloHelper.entitlements; do
  [ -f "$f" ] || die "missing entitlements file: $f"
done

# --- signing identity: discovered, never hardcoded ----------------------------------------------
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
[ -n "$IDENTITY" ] || die "no codesigning identity found. Install one, or pass --identity / set HALO_SIGN_IDENTITY. (security find-identity -v -p codesigning)"
echo "signing identity : $IDENTITY"

# --- scratch + output dirs ----------------------------------------------------------------------
# Resolve to absolute, symlink-free paths BEFORE any guard: a relative --work resolves against the
# repo (we have cd'd there), and a symlink can point back into it. Both defeated the old textual
# "outside the repo" check.
abspath() { mkdir -p "$1" && (cd -P "$1" && pwd -P); }
MARK=".halo-build-dmg-work"
if [ -z "$WORK" ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/halo-build-dmg.XXXXXX")"
else
  # A user-supplied scratch dir is wiped (Build/, stage/, mnt/), so it must be empty, new, or one
  # this script created earlier. Never an arbitrary existing directory.
  if [ -d "$WORK" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ] && [ ! -f "$WORK/$MARK" ]; then
    die "--work '$WORK' exists, is not empty and was not created by this script; use a new or empty directory"
  fi
fi
WORK="$(abspath "$WORK")" || die "cannot create --work"
[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/halo-release-out/$VERSION"
OUT="$(abspath "$OUT")" || die "cannot create --out"
REPO_P="$(cd -P "$REPO" && pwd -P)"
case "$WORK" in "$REPO_P"|"$REPO_P"/*) rmdir "$WORK" 2>/dev/null || true; die "--work must be outside the repo" ;; esac
case "$OUT"  in "$REPO_P"|"$REPO_P"/*) rmdir "$OUT" 2>/dev/null || true; die "--out must be outside the repo" ;; esac
[ "$WORK" != "/" ] && [ "$WORK" != "$HOME" ] || die "refusing to wipe '$WORK'"
touch "$WORK/$MARK"
SYMROOT="$WORK/Build/Products"
OBJROOT="$WORK/Build/Intermediates.noindex"
STAGE="$WORK/stage"
MNT="$WORK/mnt"
hdiutil detach "$MNT" -quiet 2>/dev/null || true   # a stale mount from a crashed earlier run
rm -rf "$WORK/Build" "$STAGE" "$MNT"            # the clean-SYMROOT rule
mkdir -p "$SYMROOT" "$OBJROOT" "$STAGE" "$MNT" "$OUT"

cleanup() {
  hdiutil detach "$MNT" -quiet 2>/dev/null || true
  [ "$KEEP" -eq 1 ] || rm -rf "$WORK/Build" "$STAGE" "$MNT"
}
trap cleanup EXIT

echo "version          : $VERSION ($BUILD)  configuration: $CONFIG"
echo "work / out       : $WORK  ->  $OUT"

# --- 1. build -----------------------------------------------------------------------------------
step "xcodebuild -target Halo (also builds + embeds HaloWidget.appex and HaloHelper.xpc)"
# Signing is disabled here and done by hand below (no provisioning profile needed).
xcodebuild -project Halo.xcodeproj \
  -target Halo -configuration "$CONFIG" \
  SYMROOT="$SYMROOT" OBJROOT="$OBJROOT" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  build > "$WORK/xcodebuild.log" 2>&1 \
  || { tail -40 "$WORK/xcodebuild.log" >&2; die "xcodebuild failed — full log: $WORK/xcodebuild.log"; }
tail -3 "$WORK/xcodebuild.log"

APP="$SYMROOT/$CONFIG/Halo.app"
[ -d "$APP" ] || die "build produced no $APP"
[ -d "$APP/Contents/XPCServices/HaloHelper.xpc" ] || die "HaloHelper.xpc not embedded"
[ -d "$APP/Contents/PlugIns/HaloWidget.appex" ]   || die "HaloWidget.appex not embedded"

# A clean SYMROOT must mean no test bundles inside the app. Check, don't assume.
leftovers="$(find "$APP" \( -name '*.xctest' -o -name 'XCTest*.framework' -o -name 'Testing.framework' -o -name 'libXCTest*.dylib' \) | head -5)"
[ -z "$leftovers" ] || fail "test-only bundles inside Halo.app (stale SYMROOT?):
$leftovers"

# --- 2. sign, inner-to-outer --------------------------------------------------------------------
step "codesign (dylibs -> frameworks -> HaloHelper.xpc -> HaloWidget.appex -> Halo.app)"
sign() { codesign --force --sign "$IDENTITY" --timestamp=none "$@"; }

find "$APP" -name '*.dylib' -print0 | while IFS= read -r -d '' d; do sign "$d"; done
if [ -d "$APP/Contents/Frameworks" ]; then
  # Sentry.framework today; any other embedded framework would break the outer seal the same way.
  find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 | while IFS= read -r -d '' fw; do sign "$fw"; done
fi
sign --entitlements HaloHelper/HaloHelper.entitlements "$APP/Contents/XPCServices/HaloHelper.xpc"
sign --entitlements HaloWidget/HaloWidget.entitlements "$APP/Contents/PlugIns/HaloWidget.appex"
sign --entitlements "$ENT" "$APP"

step "codesign --verify --deep --strict (built app)"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
echo "ok"

# --- 3. package ---------------------------------------------------------------------------------
step "hdiutil create"
DMG="$OUT/Halo-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
cp -R "$APP" "$STAGE/Halo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Halo $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
cat "$DMG.sha256"

# --- 4. self-verify the artefact the user would actually receive --------------------------------
step "self-verify: mount the DMG, re-check signature, version, entitlements, DSN"
( cd "$OUT" && shasum -a 256 -c "$(basename "$DMG").sha256" ) >/dev/null || fail "sha256 file does not match the DMG"
hdiutil attach "$DMG" -nobrowse -readonly -noverify -mountpoint "$MNT" -quiet || fail "could not mount $DMG"
MAPP="$MNT/Halo.app"
[ -d "$MAPP" ] || fail "no Halo.app inside the mounted DMG"

codesign --verify --deep --strict "$MAPP" 2>&1 || fail "signature does not verify from inside the DMG"
echo "  ok   codesign --verify --deep --strict (from the mounted DMG)"

pb() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || echo "<missing>"; }
check_ver() { # label plist
  local sv bv; sv="$(pb "$2" CFBundleShortVersionString)"; bv="$(pb "$2" CFBundleVersion)"
  [ "$sv" = "$VERSION" ] && [ "$bv" = "$BUILD" ] \
    || fail "$1 reports version $sv ($bv), expected $VERSION ($BUILD) — mislabelled build"
  echo "  ok   $1 version $sv ($bv)"
}
check_ver "Halo.app       " "$MAPP/Contents/Info.plist"
check_ver "HaloWidget.appex" "$MAPP/Contents/PlugIns/HaloWidget.appex/Contents/Info.plist"
check_ver "HaloHelper.xpc " "$MAPP/Contents/XPCServices/HaloHelper.xpc/Contents/Info.plist"

dsn="$(pb "$MAPP/Contents/Info.plist" SentryDSN)"
[ "$dsn" = "SENTRY_DSN_PLACEHOLDER" ] || fail "Info.plist SentryDSN is '$dsn' — must stay SENTRY_DSN_PLACEHOLDER (CLAUDE.md gotcha 12)"
echo "  ok   SentryDSN is the placeholder"

# App Group must be on the signed app (CLAUDE.md gotcha 27 — the widget is silently dead without it).
ents="$(codesign -d --entitlements - --xml "$MAPP" 2>/dev/null | plutil -p - 2>/dev/null || true)"
printf '%s' "$ents" | grep -q 'com.apple.security.application-groups' || fail "signed app has no application-groups entitlement"
echo "  ok   application-groups entitlement present on the signed app"

left2="$(find "$MAPP" \( -name '*.xctest' -o -name 'XCTest*.framework' -o -name 'Testing.framework' \) | head -1)"
[ -z "$left2" ] || fail "test-only bundle inside the DMG's app: $left2"
echo "  ok   no test-only bundles in the app"

hdiutil detach "$MNT" -quiet

step "done"
echo "DMG    : $DMG"
echo "sha256 : $(cut -d' ' -f1 "$DMG.sha256")"
echo "Signed with a development identity — NOT notarised. Notarisation and publishing are owner actions."
