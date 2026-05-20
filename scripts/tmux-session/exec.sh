#!/bin/bash
# exec.sh — send a message to a tmux session and submit it.
#
# Usage:
#   exec.sh <session_name> <message...>
#
# Notes:
#   - For claude TUI sessions: submit = C-m (Enter alone prints text but does
#     not submit).
#   - Multi-line message: pass it as a single arg with embedded newlines, e.g.
#     exec.sh foo "$(printf 'line1\nline2')". Newlines are sent as a literal
#     string via `send-keys -l`, then C-m submits.
#   - Returns immediately; does NOT wait for the session to respond. Use
#     `read.sh` after a short sleep to see output.
#
# Exit codes:
#   0  message sent
#   2  session not found
#   3  no message provided

source "$(dirname "$0")/_common.sh"

[[ $# -lt 1 ]] && die "usage: exec.sh <session_name> <message...>"

SESSION_NAME="$1"
shift

if ! tx_has "$SESSION_NAME"; then
  echo "ERROR: session '$SESSION_NAME' not found" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "ERROR: message required" >&2
  exit 3
fi

# Join remaining args with spaces — caller is expected to quote a single arg
# if they need a multi-word message preserved (which is the common case).
# If args contain embedded newlines (e.g. quoted heredoc), they're preserved.
MESSAGE="$*"

# Refuse silly long input — guard against accidental file-paste.
LEN=${#MESSAGE}
if (( LEN > 50000 )); then
  die "message too long (${LEN} chars); chunk it or paste via a different channel"
fi

# Send as literal text (no key-binding interpretation), then submit.
# Using `-l` prevents tmux from interpreting any sequence inside MESSAGE as a
# binding (important if message contains things like "C-c" literally).
tx send-keys -t "$SESSION_NAME" -l "$MESSAGE"
tx send-keys -t "$SESSION_NAME" C-m

log_activity "exec | $SESSION_NAME | len=$LEN"
echo "sent: $SESSION_NAME (${LEN} chars)"
