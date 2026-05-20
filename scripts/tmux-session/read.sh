#!/bin/bash
# read.sh — capture recent pane output from a tmux session.
#
# Usage:
#   read.sh <session_name> [--lines N] [--since <unix_ts>]
#
# Defaults:
#   --lines 100
#
# Notes:
#   - `tmux capture-pane -p` returns the visible pane buffer (history limited
#     by `history-limit`, which is 2000 by default in tmux). For more than ~2000
#     lines of scrollback, the session would need a custom history-limit.
#   - --since filters lines by timestamp — only useful if the session output
#     prefixes lines with timestamps. Most claude/shell output doesn't, so this
#     is a best-effort filter (matches `YYYY-MM-DD HH:MM[:SS]` at start of line).
#
# Exit codes:
#   0  output captured (possibly empty)
#   2  session not found

source "$(dirname "$0")/_common.sh"

[[ $# -lt 1 ]] && die "usage: read.sh <session_name> [--lines N] [--since <unix_ts>]"

SESSION_NAME="$1"
shift

LINES=100
SINCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines) LINES="${2:?--lines needs N}"; shift 2 ;;
    --since) SINCE="${2:?--since needs a unix ts}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

if ! tx_has "$SESSION_NAME"; then
  echo "ERROR: session '$SESSION_NAME' not found" >&2
  exit 2
fi

# -p: print to stdout
# -J: join wrapped lines (better for long claude output)
# -S -N: start from line -N (last N lines)
OUT=$(tx capture-pane -t "$SESSION_NAME" -p -J -S "-$LINES" 2>/dev/null || true)

if [[ -n "$SINCE" ]]; then
  # Best-effort timestamp filter. Tries to parse a leading `YYYY-MM-DD HH:MM[:SS]`
  # token in each line and skips lines older than SINCE.
  echo "$OUT" | awk -v since="$SINCE" '
    {
      ts=0
      if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}(:[0-9]{2})?/)) {
        s=substr($0, RSTART, RLENGTH)
        cmd="date -d \"" s "\" +%s 2>/dev/null"
        cmd | getline ts
        close(cmd)
      }
      if (ts == 0 || ts >= since) print
    }
  '
else
  printf '%s\n' "$OUT"
fi
