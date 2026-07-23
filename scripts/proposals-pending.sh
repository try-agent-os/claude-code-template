#!/usr/bin/env bash
# proposals-pending.sh — the single canonical way to ask which proposals are still
# waiting for a decision. Reads `status:` ONLY from the YAML frontmatter, never
# from the body of the file.
#
# Why this exists: anything that assembles the queue with a plain
# `grep -l "status: pending" memory/proposals/*.md` (the strategist step, a digest
# script, an agent reading the directory by hand) looks at the WHOLE file, so it
# counts as "pending":
#   • `memory/proposals/README.md` — the format template quotes a status line;
#   • batch reviews / triages (`REVIEW-*.md`, `TRIAGE-*.md`) — they quote the status
#     of the proposals they discuss;
#   • an ALREADY APPLIED proposal whose `### After` block proposes a frontmatter
#     containing a pending status — workers write those constantly, the worker
#     prompt template literally asks for a before/after diff.
# The failure is not cosmetic: on 2026-07-23 the queue signal showed 8 items while
# exactly 1 was a live proposal. A queue that is mostly phantoms stops being read,
# and the one real proposal drowns.
#
# Usage:
#   proposals-pending.sh                    # paths of pending proposals, one per line
#   proposals-pending.sh --status applied   # another status
#   proposals-pending.sh --all              # "<path>\t<status>" for every file with frontmatter
#   proposals-pending.sh --count            # just the number
#   proposals-pending.sh --dir <path>       # another directory (default: memory/proposals)
#
# Contract: top level of the directory only — `archive/` is NOT scanned (it is an
# archive, not a queue). A file without frontmatter (README.md, REVIEW-*.md,
# TRIAGE-*.md) is silently skipped: by definition it has no status.
# Exit 0 always (an empty queue is not an error), exit 2 on bad arguments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIR="$REPO_ROOT/memory/proposals"
WANT="pending"
MODE="list"

while (( $# )); do
  case "$1" in
    --status) WANT="${2:?--status needs a value}"; shift 2 ;;
    --all)    MODE="all"; shift ;;
    --count)  MODE="count"; shift ;;
    --dir)    DIR="${2:?--dir needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $0 [--status S|--all|--count] [--dir PATH]" >&2; exit 2 ;;
  esac
done

[[ -d "$DIR" ]] || { echo "proposals-pending: no such dir: $DIR" >&2; exit 0; }

# Frontmatter-only extractor: the file MUST start with `---`, parsing stops at the
# closing `---`. Everything below that (the proposal body, quotes, `### After`
# blocks) does not exist as far as the status is concerned.
fm_status() {
  awk '
    NR==1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")           # trailing comment
      gsub(/^["'"'"']|["'"'"']$/, "")       # surrounding quotes
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$1"
}

n=0
shopt -s nullglob
for f in "$DIR"/*.md; do
  st="$(fm_status "$f")"
  [[ -z "$st" ]] && continue
  case "$MODE" in
    all)   printf '%s\t%s\n' "$f" "$st" ;;
    *)     [[ "$st" == "$WANT" ]] || continue
           n=$((n+1))
           [[ "$MODE" == "list" ]] && printf '%s\n' "$f" ;;
  esac
done
[[ "$MODE" == "count" ]] && printf '%s\n' "$n"
exit 0
