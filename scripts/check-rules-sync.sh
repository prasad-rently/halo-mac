#!/bin/bash
# H-18: the Firebase rules file and every copy embedded in the docs must not drift.
#
# WHY. docs/specs/firebase-rules.json is the canonical, deployable rules file. The F-044 spec
# once embedded its own copy that silently lacked `clipboard/{uid}`, so a project set up from
# the doc denied clipboard sync. This script makes that class of drift fail CI instead.
#
# WHAT IT CHECKS. Every tracked Markdown file is scanned for fenced ```json blocks. A block that
# parses as an object with a top-level "rules" key is an embedded rules copy, and its parsed
# content must equal the canonical file (compared structurally, so whitespace/key order in the
# doc does not matter; any added, removed or changed rule does).
#
# A scan that finds zero embedded copies FAILS (exit 2): that means the docs moved or the
# extractor broke, and a check that passes on no input is how this kind of guard rots.
#
# Usage:  ./scripts/check-rules-sync.sh [repo-root]
# Exit:   0 in sync, 1 drift found (files named), 2 the check itself is broken.

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2

CANON="docs/specs/firebase-rules.json"
[ -f "$CANON" ] || { echo "check is broken: $CANON not found" >&2; exit 2; }
command -v python3 >/dev/null || { echo "check is broken: python3 not found" >&2; exit 2; }

# Tracked files when in a work tree, else a plain find (e.g. a scratch copy).
list_md() {
  if [ -d .git ] || [ -f .git ]; then git ls-files '*.md'; else find . -name '*.md' -not -path '*/build/*' -not -path '*/.gradle/*' | sed 's|^\./||'; fi
}

list_md | python3 -I -c '
import json, re, sys
canon_path = sys.argv[1]
try:
    canon = json.load(open(canon_path))
except Exception as e:
    print(f"check is broken: {canon_path} is not valid JSON: {e}", file=sys.stderr); sys.exit(2)
if not (isinstance(canon, dict) and "rules" in canon):
    print(f"check is broken: {canon_path} has no top-level \"rules\"", file=sys.stderr); sys.exit(2)

fence = re.compile(r"^[ \t]*```json[^\n]*\n(.*?)^[ \t]*```[ \t]*$", re.S | re.M)
found, drift = 0, []
for path in (l.strip() for l in sys.stdin if l.strip()):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        continue
    for m in fence.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        try:
            obj = json.loads(m.group(1))
        except Exception:
            # Not valid JSON. If it still looks like a rules copy (top-level "rules" key) it is a
            # copy that has drifted into a broken state (trailing comma, "..." ellipsis); skipping
            # it would let the check pass while a doc carries stale rules. Anything else is an
            # illustrative snippet.
            if re.search(r"^\s*\{\s*\"rules\"\s*:", m.group(1)):
                found += 1
                drift.append(f"{path}:{line} (not valid JSON)")
            continue
        if not (isinstance(obj, dict) and "rules" in obj):
            continue
        found += 1
        if obj != canon:
            drift.append(f"{path}:{line}")
        else:
            print(f"  ok   {path}:{line}")

if found == 0:
    print("check is broken: no embedded rules JSON block found in any Markdown file", file=sys.stderr)
    sys.exit(2)
if drift:
    print("Embedded Firebase rules differ from " + canon_path + ":", file=sys.stderr)
    for d in drift: print("  DRIFT " + d, file=sys.stderr)
    print("Edit docs/specs/firebase-rules.json and re-copy it into each place above.", file=sys.stderr)
    sys.exit(1)
print(f"OK — {found} embedded rules copy(ies) match {canon_path}")
' "$CANON"
