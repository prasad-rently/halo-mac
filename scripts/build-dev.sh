#!/usr/bin/env bash
#
# build-dev.sh — build and install a "Halo Dev" build that coexists with the
# released Halo.app instead of replacing it.
#
# The release build installs to /Applications/Halo.app as com.halo.mac. This
# script produces ~/Applications/Halo Dev.app as com.halo.mac.dev, so both can
# be installed, launched and kept at once.
#
# It does NOT change the Xcode project. The bundle identifiers are rewritten on
# the *built product* and then re-signed, so a normal `xcodebuild -target Halo`
# still produces the ordinary release-shaped app and nothing here can leak into
# a shipping build.
#
#   ./scripts/build-dev.sh            build, sign, install, register the widget
#   ./scripts/build-dev.sh --no-install   stop after signing (leaves it in SYMROOT)
#
set -euo pipefail

cd "$(dirname "$0")/.."

DEV_BUNDLE_ID="com.halo.mac.dev"
DEV_APP_NAME="Halo Dev"
SYMROOT="/tmp/HaloBuild-dev/Build/Products"
OBJROOT="/tmp/HaloBuild-dev/Build/Intermediates.noindex"
# /Applications, not ~/Applications. macOS discovers widgets from either, but
# on this machine ~/Applications is owned by root and not writable by the user,
# so the copy fails there. Override with HALO_DEV_INSTALL_DIR if you prefer.
INSTALL_DIR="${HALO_DEV_INSTALL_DIR:-/Applications}"

INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Build
#
# A clean SYMROOT is mandatory, not tidiness: a SYMROOT previously used for a
# test build leaves HaloTests.xctest and the XCTest frameworks *inside*
# Halo.app, which ship and then break signing with "a sealed resource is
# missing or invalid". See CLAUDE.md, Build & Sign.
# ---------------------------------------------------------------------------
say "Building Halo (Debug) into a clean SYMROOT"
rm -rf "$SYMROOT"
xcodebuild -project Halo.xcodeproj \
  -target Halo -configuration Debug \
  SYMROOT="$SYMROOT" OBJROOT="$OBJROOT" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  build

BUILT="$SYMROOT/Debug/Halo.app"
[ -d "$BUILT" ] || { echo "build produced no Halo.app at $BUILT"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Re-identify the built product
#
# Only two identifiers move:
#
#   the app     com.halo.mac        -> com.halo.mac.dev
#   the widget  com.halo.mac.widget -> com.halo.mac.dev.widget
#                                      (an app extension's id must be prefixed
#                                       by its containing app's)
#
# HaloHelper.xpc deliberately KEEPS com.halo.mac.helper. HelperClient.swift
# connects with NSXPCConnection(serviceName: "com.halo.mac.helper"), a literal —
# renaming the bundle would break the XPC connection at runtime with no build
# error. It is safe to leave: the helper declares XPCService.ServiceType =
# Application, so it is resolved inside its own containing bundle and two apps
# can each carry one of the same name.
#
# The App Group is deliberately left alone too, so dev and release share
# group.com.halo.mac. HaloSharedData.suiteName is a compile-time constant in a
# file built into both targets; pointing the entitlement at a different group
# without changing that constant is exactly the silent failure in CLAUDE.md
# gotcha 27 — the widget renders plausible zeros rather than erroring.
# ---------------------------------------------------------------------------
say "Rewriting bundle identifiers"
pb() { /usr/libexec/PlistBuddy "$@"; }

APP_PLIST="$BUILT/Contents/Info.plist"
pb -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$APP_PLIST"
pb -c "Set :CFBundleName $DEV_APP_NAME" "$APP_PLIST" 2>/dev/null \
  || pb -c "Add :CFBundleName string $DEV_APP_NAME" "$APP_PLIST"
pb -c "Set :CFBundleDisplayName $DEV_APP_NAME" "$APP_PLIST" 2>/dev/null \
  || pb -c "Add :CFBundleDisplayName string $DEV_APP_NAME" "$APP_PLIST"

WIDGET_PLIST="$BUILT/Contents/PlugIns/HaloWidget.appex/Contents/Info.plist"
if [ -f "$WIDGET_PLIST" ]; then
  pb -c "Set :CFBundleIdentifier ${DEV_BUNDLE_ID}.widget" "$WIDGET_PLIST"
  pb -c "Set :CFBundleDisplayName Halo Dev Widget" "$WIDGET_PLIST" 2>/dev/null || true
else
  echo "warning: no HaloWidget.appex in the built app"
fi

echo "  app    $(pb -c 'Print :CFBundleIdentifier' "$APP_PLIST")"
echo "  widget $(pb -c 'Print :CFBundleIdentifier' "$WIDGET_PLIST")"
echo "  helper $(pb -c 'Print :CFBundleIdentifier' \
            "$BUILT/Contents/XPCServices/HaloHelper.xpc/Contents/Info.plist") (unchanged, see comment)"

say "Renaming the bundle to $DEV_APP_NAME.app"
DEV_APP="$SYMROOT/Debug/$DEV_APP_NAME.app"
rm -rf "$DEV_APP"
mv "$BUILT" "$DEV_APP"

# ---------------------------------------------------------------------------
# 3. Sign
#
# Order matters: every nested code object must be signed before its container,
# or the outer signature fails with "In subcomponent: ...". The identity is
# discovered rather than hardcoded — the certificate named in CLAUDE.md's
# Identity table is not present on every machine.
# ---------------------------------------------------------------------------
say "Signing"
CERT=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
[ -n "$CERT" ] || { echo "no codesigning identity found"; exit 1; }
echo "  identity: $CERT"

find "$DEV_APP" -name "*.dylib" -print0 | while IFS= read -r -d '' d; do
  codesign --force --sign "$CERT" --timestamp=none "$d"
done
if [ -d "$DEV_APP/Contents/Frameworks/Sentry.framework" ]; then
  codesign --force --sign "$CERT" --timestamp=none \
    "$DEV_APP/Contents/Frameworks/Sentry.framework"
fi
codesign --force --sign "$CERT" \
  --entitlements HaloHelper/HaloHelper.entitlements --timestamp=none \
  "$DEV_APP/Contents/XPCServices/HaloHelper.xpc"
codesign --force --sign "$CERT" \
  --entitlements HaloWidget/HaloWidget.entitlements --timestamp=none \
  "$DEV_APP/Contents/PlugIns/HaloWidget.appex"
# Halo-Debug.entitlements, not Halo.entitlements: the sandbox is off there, which
# the global NSEvent monitor needs and which keeps posix_spawn available to the
# six shell-out features.
codesign --force --sign "$CERT" \
  --entitlements Halo/Halo-Debug.entitlements --timestamp=none "$DEV_APP"

say "Verifying signature"
codesign --verify --deep --strict "$DEV_APP" && echo "  signature OK"

if [ "$INSTALL" -eq 0 ]; then
  say "Done (not installed) — $DEV_APP"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Install
#
# The dev build is a separate bundle id under a separate name, so it sits
# alongside the release Halo.app rather than replacing it. It must live in
# /Applications or ~/Applications either way — macOS only discovers widgets
# from those two locations (CLAUDE.md gotcha 3).
# ---------------------------------------------------------------------------
say "Installing to $INSTALL_DIR/$DEV_APP_NAME.app"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/$DEV_APP_NAME.app"
cp -R "$DEV_APP" "$INSTALL_DIR/$DEV_APP_NAME.app"

say "Registering the dev widget"
# lsregister -f first: on a freshly copied bundle `pluginkit -a` alone reported
# success but the extension did not show up in `pluginkit -m` — Launch Services
# has to know about the containing app before the appex resolves. Verified: the
# dev widget only appeared under com.halo.mac.dev.widget after this pair ran.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALL_DIR/$DEV_APP_NAME.app" || true
pluginkit -a "$INSTALL_DIR/$DEV_APP_NAME.app/Contents/PlugIns/HaloWidget.appex" || true
sleep 2
if pluginkit -m -i "${DEV_BUNDLE_ID}.widget" >/dev/null 2>&1; then
  echo "  registered: $(pluginkit -m -i "${DEV_BUNDLE_ID}.widget")"
else
  echo "  warning: ${DEV_BUNDLE_ID}.widget did not appear in pluginkit -m"
fi

say "Done"
echo "  release  /Applications/Halo.app              com.halo.mac"
echo "  dev      $INSTALL_DIR/$DEV_APP_NAME.app  $DEV_BUNDLE_ID"
