#!/bin/bash
# Asserts that the App Group the widget depends on is declared consistently — and, with
# --probe, that it actually shares data between a sandboxed and an unsandboxed process.
#
# WHY THIS EXISTS. The widget has now been blank twice for two different reasons, and a
# sentence in a document caught neither:
#
#  1. (2026-05) `com.apple.security.application-groups` was removed from Halo-Debug.entitlements
#     in 7f91bbb to stop a TCC prompt, on the basis that "release builds retain it". Every
#     shipped DMG is built from the DEBUG configuration, so the widget was dead for four months.
#
#  2. (2026-10) The key was restored — but with the iOS-style ID `group.com.halo.mac`, on the
#     belief that an unsandboxed, development-signed app gets that group's container. On
#     macOS 15+ it does not: an unprefixed group no provisioning profile authorises is
#     access-controlled, and a write from one process is silently dropped for every other.
#     `containerURL` still returns a path and `UserDefaults(suiteName:)` still reads back what
#     it wrote *within that process* — so every cheap check passes while the widget stays on its
#     zero placeholder. Measured on macOS 27.0.1: the team-prefixed form
#     (`R7S39UR27F.group.com.halo.mac`) shares correctly in both directions; the unprefixed
#     one does not.
#
# So this checks three things, in increasing order of how much they can be trusted:
#   a. every target that touches the shared data declares the group (static, plist-aware);
#   b. the group is exactly the one HaloWidgetData.suiteName names, and carries a team prefix;
#   c. --probe: signed probes using the REAL entitlement files really do share data.
#
# Usage:  ./scripts/audit-entitlements.sh [--probe]
# Exit:   0 clean, 1 the configuration is wrong, 2 the audit itself is broken / cannot run.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PROBE=0
[ "${1:-}" = "--probe" ] && PROBE=1

SHARED="Shared/HaloSharedData.swift"
[ -f "$SHARED" ] || { echo "audit is broken: $SHARED not found — renamed or moved?" >&2; exit 2; }

# The code is the source of truth: the entitlements must match IT, not a string in this script.
GROUP=$(sed -n 's/.*static let suiteName = "\(.*\)".*/\1/p' "$SHARED" | head -1)
[ -n "$GROUP" ] || { echo "audit is broken: no 'static let suiteName' in $SHARED" >&2; exit 2; }

# Every target in the shared-data pipeline. The widget is the reader; the two main-app
# configurations are the writers; the helper is declared for parity.
FILES="Halo/Halo.entitlements Halo/Halo-Debug.entitlements HaloWidget/HaloWidget.entitlements HaloHelper/HaloHelper.entitlements"
EXPECTED=4

# --- b. team prefix ---------------------------------------------------------------------
if ! echo "$GROUP" | grep -Eq '^[A-Z0-9]{10}\.group\.'; then
  cat >&2 <<MSG
HaloWidgetData.suiteName is '$GROUP' — it has no Apple team prefix.

On macOS 15+ an unprefixed 'group.…' ID that no provisioning profile authorises is
access-controlled: writes from one process are silently dropped for every other, so the
widget reads its zero placeholder while everything appears to work. Use '<TEAMID>.group.…'
(currently R7S39UR27F.group.com.halo.mac). See the comment in Halo/Halo-Debug.entitlements.
MSG
  exit 1
fi

# --- a. static declaration --------------------------------------------------------------
missing=()
checked=0
for f in $FILES; do
  [ -f "$f" ] || { echo "audit is broken: $f not found — renamed or moved?" >&2; exit 2; }
  plutil -lint "$f" >/dev/null 2>&1 || { echo "audit is broken: $f is not a valid plist" >&2; exit 2; }
  checked=$((checked + 1))
  # plutil -p rather than grep: a commented-out key must not count as present, and grep
  # cannot tell a live key from one inside an XML comment. The match is the WHOLE string,
  # so a stale unprefixed value can't satisfy a prefixed expectation.
  if ! plutil -p "$f" | grep -A5 '"com.apple.security.application-groups"' \
       | grep -qF "\"$GROUP\""; then
    missing+=("$f")
  fi
done

[ "$checked" -eq "$EXPECTED" ] || { echo "audit is broken: checked $checked files, expected $EXPECTED" >&2; exit 2; }

if [ "${#missing[@]}" -gt 0 ]; then
  echo "These targets do not declare the App Group '$GROUP' (the one HaloWidgetData.suiteName names):" >&2
  printf '  %s\n' "${missing[@]}" >&2
  cat >&2 <<'MSG'

The widget reads ONLY the group container. A writer whose entitlement does not match the
constant lands in ~/Library/Preferences/ instead, and the widget renders its zero placeholder
rather than failing visibly. Change the constant and every entitlement together.
MSG
  exit 1
fi

if [ "$PROBE" -eq 0 ]; then
  echo "OK — all $checked targets declare the App Group '$GROUP' (run with --probe to prove it shares data)"
  exit 0
fi

# --- c. behavioural probe ---------------------------------------------------------------
# Sign two tiny bundles with the REAL entitlement files — an unsandboxed one as the app
# (Halo-Debug.entitlements, what the DMG is signed with) and a sandboxed one as the widget
# (HaloWidget.entitlements) — and require each to read what the other wrote, as separate processes.
CERT=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
[ -n "$CERT" ] || { echo "cannot --probe: no 'Apple Development' signing identity in the keychain" >&2; exit 2; }
SWIFTC=/usr/bin/swiftc
[ -x "$SWIFTC" ] || { echo "cannot --probe: $SWIFTC not found" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/halo-appgroup-probe.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.swift" <<'SWIFT'
import Foundation
let group = CommandLine.arguments[1], mode = CommandLine.arguments[2]
let key = "haloAuditProbe", d = UserDefaults(suiteName: group)
switch mode {
case "write": d?.set("v-\(getpid())", forKey: key); d?.synchronize(); print("v-\(getpid())")
case "read":  print(d?.string(forKey: key) ?? "nil")
default:      d?.removeObject(forKey: key); d?.synchronize()
}
SWIFT
"$SWIFTC" -O "$WORK/probe.swift" -o "$WORK/probe" 2>"$WORK/swiftc.log" \
  || { echo "cannot --probe: swiftc failed:" >&2; cat "$WORK/swiftc.log" >&2; exit 2; }

mkapp() { # name bundle-id entitlements
  local d="$WORK/$1.app/Contents"; mkdir -p "$d/MacOS"; cp "$WORK/probe" "$d/MacOS/$1"
  cat > "$d/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$1</string><key>CFBundleIdentifier</key><string>$2</string><key>CFBundleName</key><string>$1</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1</string></dict></plist>
PLIST
  codesign --force --sign "$CERT" --entitlements "$3" --timestamp=none "$WORK/$1.app" >/dev/null 2>&1
}
mkapp app    com.halo.mac.auditprobe        Halo/Halo-Debug.entitlements   || exit 2
mkapp widget com.halo.mac.auditprobe.widget HaloWidget/HaloWidget.entitlements || exit 2
APP="$WORK/app.app/Contents/MacOS/app"; WIDGET="$WORK/widget.app/Contents/MacOS/widget"

# Pre-flight: the probe bundles must actually run (a crash here is the audit's fault, not the config's).
"$APP" "$GROUP" clear >/dev/null 2>&1 || { echo "cannot --probe: the unsandboxed probe would not run" >&2; exit 2; }
"$WIDGET" "$GROUP" clear >/dev/null 2>&1 || { echo "cannot --probe: the sandboxed probe would not run" >&2; exit 2; }

fail=0
w=$("$APP" "$GROUP" write);    sleep 1; r=$("$WIDGET" "$GROUP" read)
if [ "$r" = "$w" ]; then echo "  ok   app (unsandboxed) -> widget (sandboxed)"
else echo "  FAIL app (unsandboxed) -> widget (sandboxed): wrote '$w', widget read '$r'" >&2; fail=1; fi
w=$("$WIDGET" "$GROUP" write); sleep 1; r=$("$APP" "$GROUP" read)
if [ "$r" = "$w" ]; then echo "  ok   widget (sandboxed) -> app (unsandboxed)"
else echo "  FAIL widget (sandboxed) -> app (unsandboxed): wrote '$w', app read '$r'" >&2; fail=1; fi
"$APP" "$GROUP" clear >/dev/null 2>&1

if [ "$fail" -ne 0 ]; then
  cat >&2 <<MSG

The widget CANNOT see what the app writes, although the entitlement is declared. The App Group
'$GROUP' is not shareable between these two signatures on this macOS. (An unprefixed 'group.…'
ID fails exactly this way on macOS 15+.)
MSG
  exit 1
fi
echo "OK — App Group '$GROUP' is declared in all $checked targets and shares data across a sandboxed and an unsandboxed process"
