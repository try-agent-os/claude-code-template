#!/usr/bin/env bash
# skill-reference-check.sh — reference-integrity guard: skills and routines must not
# invoke scripts that do not exist in the repo.
#
# WHY: a task can ship "half" — the doc half lands on origin/main while the script it
# calls never does. A skill step then reads `bash scripts/some-check.sh` for a file that
# is not in the repo: the step fails every run, its output block silently disappears, and
# the very thing the automation was built to catch goes unnoticed. Nothing turns red —
# the scheduled run stays green because a failed step degrades into an absent block. The
# only reliable discovery is a human opening the file, which is exactly the manual work
# the automation replaced.
#
# Why ship-guard.sh does NOT catch this: it verifies that the COMMIT reached origin/main
# (branch/ancestry). Here the commit did land — just half of it. Different defect class:
# "a doc references an artifact that does not exist". This script is the cheap net for it.
#
# Read-only. Exit 0 = every reference resolves; exit 1 = dangling references (printed).
# Usage: skill-reference-check.sh [--quiet]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Where we look for references: prompts/skills/routines/canon — what an agent executes
# by reading the text.
mapfile -t FILES < <(
  { git ls-files 'agents/**/*.md' 'routines/*.yaml' 'routines/*.yml' \
               '.claude/**/*.md' 'CLAUDE.md' 'scripts/**/*.md' 2>/dev/null || true; } | sort -u
)

missing=0
declare -A SEEN

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # References like `scripts/foo.sh` / `bash scripts/foo.sh` / `python3 scripts/lib/foo.py`.
  # Only repo-relative paths under scripts/ — external/foreign paths are out of scope.
  while read -r ref; do
    [ -z "$ref" ] && continue
    # Placeholders in docs (<slug>, {name}, $VAR, *) are not checked.
    case "$ref" in
      *'<'*|*'>'*|*'{'*|*'}'*|*'$'*|*'*'*) continue ;;
    esac
    [ -e "$ref" ] && continue
    key="$f::$ref"
    [ -n "${SEEN[$key]:-}" ] && continue
    SEEN[$key]=1
    missing=$((missing + 1))
    [ "$QUIET" -eq 1 ] || echo "DANGLING: $f → $ref"
  # Match ONLY the executable position: `bash|sh|python3|python <path>`. Two lessons:
  #
  # 1. The negative lookbehind is required — without it `scripts/foo.sh` matches as a
  #    SUFFIX of an unrelated path (e.g. plugins/<plugin>/skills/<skill>/scripts/foo.sh)
  #    and reports it as dangling.
  # 2. The executor prefix excludes paths mentioned in PROSE as an example rather than as
  #    a command (e.g. a routine documenting a key format like "push-up:scripts/lib/x.sh"
  #    — an illustration nobody executes).
  #
  # A guard that cries wolf is noise people stop reading: once a surface reports a wrong
  # count, trust in the whole surface is gone. Deliberate trade-off: a reference without an
  # executor prefix (a bare string in a code fence) is not checked — under-catching beats
  # over-catching.
  done < <(grep -ohP '\b(?:bash|sh|python3|python)\s+\K(?<![\w/.-])scripts/[\w./-]+\.(?:sh|py)\b' "$f" 2>/dev/null | sort -u)
done

echo "SKILL_REFERENCE_SUMMARY dangling=$missing files_scanned=${#FILES[@]}"
[ "$missing" -eq 0 ] || exit 1
