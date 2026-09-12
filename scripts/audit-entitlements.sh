#!/bin/bash
# Asserts that every target which must share the App Group actually declares it.
#
# WHY THIS EXISTS. `com.apple.security.application-groups` was removed from
# Halo-Debug.entitlements in 7f91bbb (2026-05-07) to stop a per-launch TCC
# prompt, on the stated basis that "release builds (Halo.entitlements) retain
# the App Group for widget support". That premise quietly stopped being true:
# every shipped DMG, v2.0 through the v2.3 beta, is built from the DEBUG
# configuration and signed with Halo-Debug.entitlements.
#
# The failure is silent in the worst way. HaloWidget.appex is sandboxed
# (WidgetKit requires it) and can only read the group container. With no group
# membership the main app's UserDefaults(suiteName:) resolves to
# ~/Library/Preferences/group.com.halo.mac.plist instead — a different file the
# widget cannot reach. Nothing errors: HaloWidgetData.load() just returns its
# zero placeholder, and the widget renders plausible-looking values (0% CPU,
# 8 GB RAM) rather than looking broken. It shipped unnoticed for four months.
#
# CLAUDE.md asserted the entitlement was in both files the entire time. A
# sentence in a document did not catch this. This does.
#
# Usage:  ./scripts/audit-entitlements.sh
# Exit:   0 clean, 1 a target is missing the group, 2 the audit itself is broken.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

GROUP="group.com.halo.mac"

# Every target that participates in the shared-data pipeline. The widget is the
# reader; the two main-app configurations are the writers. Missing it in ANY of
# them breaks the pipeline for whichever configuration ships.
FILES="Halo/Halo.entitlements Halo/Halo-Debug.entitlements HaloWidget/HaloWidget.entitlements"

missing=()
checked=0

for f in $FILES; do
  if [ ! -f "$f" ]; then
    echo "audit is broken: $f not found — renamed or moved?" >&2
    exit 2
  fi
  if ! plutil -lint "$f" >/dev/null 2>&1; then
    echo "audit is broken: $f is not a valid plist" >&2
    exit 2
  fi
  checked=$((checked + 1))
  # plutil -p rather than grep: a commented-out key must not count as present,
  # and grep cannot tell a live key from one inside an XML comment.
  if ! plutil -p "$f" | grep -A5 '"com.apple.security.application-groups"' \
       | grep -q "\"$GROUP\""; then
    missing+=("$f")
  fi
done

if [ "$checked" -ne 3 ]; then
  echo "audit is broken: checked $checked files, expected 3" >&2
  exit 2
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "These targets do not declare the App Group '$GROUP':" >&2
  printf '  %s\n' "${missing[@]}" >&2
  cat >&2 <<'MSG'

The widget reads ONLY the group container. Any writer without group membership
silently lands in ~/Library/Preferences/ instead, and the widget renders its
zero placeholder rather than failing visibly.

Verify a real build with:
  codesign -d --entitlements - /Applications/Halo.app | grep -A3 application-groups
  ls ~/Library/Group\ Containers/group.com.halo.mac/Library/Preferences/
MSG
  exit 1
fi

echo "OK — all $checked targets declare the App Group '$GROUP'"
