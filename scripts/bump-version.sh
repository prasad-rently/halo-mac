#!/bin/bash
# F-058 / FR-R5 — set the app version in ONE place, consistently, or not at all.
#
# project.pbxproj carries MARKETING_VERSION and CURRENT_PROJECT_VERSION once per build
# configuration per target (Halo, HaloWidget, HaloHelper, HaloUITests, HaloTests x Debug/Release
# = 10 of each). Hand-editing misses some; the three shipping targets' Info.plists all read
# `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so a stale one yields an app, widget and
# helper that disagree — or a test build still labelled with the previous release (the v2.4-label
# confusion). This rewrites every occurrence, then re-reads the file and fails unless all of them
# agree and none went missing.
#
# For a one-off labelled build that must not touch the repo at all, don't bump: pass
#   scripts/build-dmg.sh --version X --build N
# which overrides both settings on the xcodebuild command line.
#
# Usage:  scripts/bump-version.sh <version> [--build N] [--token] [--dry-run] [--pbxproj FILE]
#   <version>   e.g. 2.6.0 or 2.6.0-rc1  -> MARKETING_VERSION
#   --build N   CURRENT_PROJECT_VERSION. Default: the current value + 1.
#   --token     also run scripts/update_build_token.sh (rewrites Halo/App/BuildToken.swift).
#   --dry-run   print what would change; modify nothing (also skips --token).
#   --pbxproj   operate on another copy of the project file (used to test this script). With it,
#               --token is refused: the token script edits the real source tree.
#
# Exit: 0 ok, 1 post-write verification failed, 2 usage / environment problem.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

die()  { echo "bump-version: $*" >&2; exit 2; }
VERSION="" BUILD="" TOKEN=0 DRY=0 PBX="Halo.xcodeproj/project.pbxproj" CUSTOM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --build)   BUILD="${2:-}"; shift 2 ;;
    --token)   TOKEN=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --pbxproj) PBX="${2:-}"; CUSTOM=1; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         [ -z "$VERSION" ] || die "more than one version given"; VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || die "usage: scripts/bump-version.sh <version> [--build N] [--token] [--dry-run]"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$' \
  || die "version '$VERSION' must look like 2.6.0 or 2.6.0-rc1"
[ -f "$PBX" ] || die "project file not found: $PBX"
[ "$CUSTOM" -eq 0 ] || [ "$TOKEN" -eq 0 ] || die "--token cannot be combined with --pbxproj"

MV_RE='MARKETING_VERSION = [^;]*;'
CV_RE='CURRENT_PROJECT_VERSION = [^;]*;'

n_mv="$(grep -c "$MV_RE" "$PBX" || true)"
n_cv="$(grep -c "$CV_RE" "$PBX" || true)"
[ "$n_mv" -gt 0 ] && [ "$n_cv" -gt 0 ] || die "no MARKETING_VERSION / CURRENT_PROJECT_VERSION found in $PBX"
[ "$n_mv" -eq "$n_cv" ] || die "found $n_mv MARKETING_VERSION but $n_cv CURRENT_PROJECT_VERSION lines — refusing to guess"

cur_mv="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PBX" | sort -u | tr '\n' ' ')"
cur_cv="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PBX" | sort -u | tr '\n' ' ')"
[ "$(echo $cur_cv | wc -w)" -eq 1 ] && CUR_BUILD="$(echo $cur_cv)" || CUR_BUILD="$(echo $cur_cv | tr ' ' '\n' | sort -n | tail -1)"

if [ -z "$BUILD" ]; then
  printf '%s' "$CUR_BUILD" | grep -Eq '^[0-9]+$' || die "current build '$CUR_BUILD' is not an integer; pass --build"
  BUILD=$((CUR_BUILD + 1))
fi
printf '%s' "$BUILD" | grep -Eq '^[0-9]+$' || die "--build must be an integer"

echo "project file          : $PBX"
echo "occurrences           : $n_mv of each (targets x configurations)"
echo "MARKETING_VERSION     : ${cur_mv}-> $VERSION"
echo "CURRENT_PROJECT_VERSION: ${cur_cv}-> $BUILD"

if [ "$DRY" -eq 1 ]; then
  echo "(dry run — nothing modified)"
  exit 0
fi

# Write via a temp file so a failure mid-way cannot leave a half-edited project.
TMP="$(mktemp "${TMPDIR:-/tmp}/pbx.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
sed -e "s/$MV_RE/MARKETING_VERSION = $VERSION;/" \
    -e "s/$CV_RE/CURRENT_PROJECT_VERSION = $BUILD;/" "$PBX" > "$TMP"

# Verify BEFORE replacing the real file: every occurrence present, all equal to what we asked for.
v_mv="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$TMP" | sort -u)"
v_cv="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$TMP" | sort -u)"
[ "$(grep -c "$MV_RE" "$TMP")" -eq "$n_mv" ] && [ "$(grep -c "$CV_RE" "$TMP")" -eq "$n_cv" ] \
  || { echo "bump-version: occurrence count changed — not writing" >&2; exit 1; }
[ "$v_mv" = "$VERSION" ] && [ "$v_cv" = "$BUILD" ] \
  || { echo "bump-version: result is not uniform (MARKETING_VERSION: $v_mv / CURRENT_PROJECT_VERSION: $v_cv) — not writing" >&2; exit 1; }

cat "$TMP" > "$PBX"            # preserve the file's mode/ownership
echo "wrote $n_mv + $n_cv settings; all agree on $VERSION ($BUILD)"

if [ "$TOKEN" -eq 1 ]; then
  ./scripts/update_build_token.sh
fi

echo "Next: review 'git diff', then commit. Info.plists read these settings, so app, widget and helper all pick them up."
