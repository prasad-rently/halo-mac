#!/bin/bash
# Enforces CLAUDE.md gotcha 20: ShellReader is the only place Halo spawns a
# subprocess.
#
# WHY THIS IS A SCRIPT AND NOT A UNIT TEST. It was written as one first. The
# test host is the Halo app itself, and when it enumerates the repo's source
# files the process blocks in open(2) on a directory — the checkout lives on an
# external volume, and a headless test run has nobody to approve that access.
# Both tests started and never finished; `sample` showed them parked in
# _GetDirectoryURLs -> open. A guard that can hang the whole suite is worse than
# no guard, so the audit runs here instead, outside the app process.
#
# WHY THE GUARD EXISTS AT ALL. Gotcha 20 was already written, and still not
# followed: Phase 0 migrated the five callers that existed, then the
# F-016...F-030 batch shipped five NEW scanners that each hand-rolled a Process
# — none bounded by a timeout, one (SMARTDiskMonitor) with an undrained
# standardError pipe, which is the exact deadlock the rule prevents. A rule in a
# document did not stop that. A failing check does.
#
# Usage:  ./scripts/audit-subprocess-spawning.sh
# Exit:   0 clean, 1 offenders found (named), 2 the audit itself is broken.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# Files allowed their own Process, each for a stated reason.
#   ShellReader.swift  - the implementation of the rule itself.
#   ActionRunner.swift - documented exception in gotcha 20: needs
#                        readabilityHandler streaming to relay stdout to the UI
#                        line-by-line, so it cannot use a batch reader.
SANCTIONED="ShellReader.swift ActionRunner.swift"

# `mapfile` is bash 4+; macOS ships bash 3.2, so read the list the portable way.
FILES=()
while IFS= read -r line; do FILES+=("$line"); done < <(find Halo -name '*.swift' -type f | sort)

# A scan that finds nothing must fail, not pass. Without this the whole audit
# degrades to a silent no-op the moment the path or the layout changes — the
# "check that passes on broken input" failure this repo has already hit.
if [ "${#FILES[@]}" -lt 50 ]; then
  echo "audit is broken: found only ${#FILES[@]} Swift files under Halo/ — wrong path?" >&2
  exit 2
fi

offenders=()
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  case " $SANCTIONED " in *" $base "*) continue ;; esac
  # Word-boundary match. A plain substring search also hits identifiers that
  # merely end in "Process()" — ActionRunner really does have
  # `emptyTrashInProcess()` — which would report a file that spawns nothing.
  if grep -qE '(^|[^A-Za-z0-9_])Process\(\)' "$f"; then offenders+=("$f"); fi
done

if [ "${#offenders[@]}" -gt 0 ]; then
  echo "These files spawn a subprocess without ShellReader:" >&2
  printf '  %s\n' "${offenders[@]}" >&2
  cat >&2 <<'MSG'

Use ShellReader.run(_:_:timeout:) instead — it drains both pipes concurrently
and bounds the call. See CLAUDE.md gotcha 20. If a file genuinely needs its own
Process, add it to SANCTIONED above with the reason.
MSG
  exit 1
fi

# Named explicitly so deleting the call, rather than the file, still fails.
# These five are the ones that regressed.
missing=()
for s in PermissionAuditor SMARTDiskMonitor NetworkTrafficMonitor \
         SecurityPostureScanner TimeMachineMonitor; do
  path="Halo/Core/Scanner/$s.swift"
  if [ ! -f "$path" ]; then missing+=("$s (file not found — renamed?)"); continue; fi
  # Word-boundary match here too, and for a sharper reason: a plain substring
  # search matches "NotShellReader.run", so renaming the call away would still
  # pass. Verified by doing exactly that — the loose version reported OK.
  grep -qE '(^|[^A-Za-z0-9_])ShellReader\.run' "$path" \
    || missing+=("$s (no longer calls ShellReader.run)")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Scanners that should route through ShellReader but do not:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "OK — ${#FILES[@]} Swift files scanned; subprocess spawning confined to ShellReader"
