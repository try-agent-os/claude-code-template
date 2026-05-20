#!/bin/bash
# kill.sh — graceful (or forced) termination of a tmux session.
#
# Usage:
#   kill.sh <session_name> [--force]
#
# Behavior:
#   Default: send C-c C-c (interrupt twice), wait 2s, then kill-session.
#            This gives a claude TUI inside a chance to flush state.
#   --force: skip interrupts, kill-session immediately.
#
# Safety:
#   Refuses to kill reserved system sessions (operator/sysadmin/dispatcher/
#   claude-login) — those are managed by systemd/launchd, not by ad-hoc
#   tmux skill.

source "$(dirname "$0")/_common.sh"

[[ $# -lt 1 ]] && die "usage: kill.sh <session_name> [--force]"

SESSION_NAME="$1"
shift

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

if is_reserved_name "$SESSION_NAME"; then
  echo "ERROR: '$SESSION_NAME' is reserved — managed by systemd, refuse to kill" >&2
  exit 3
fi

if ! tx_has "$SESSION_NAME"; then
  echo "noop: session '$SESSION_NAME' not found"
  exit 0
fi

if [[ "$FORCE" -eq 0 ]]; then
  # Two C-c gives claude a chance to abort current generation, then exit prompt.
  tx send-keys -t "$SESSION_NAME" C-c 2>/dev/null || true
  sleep 1
  tx send-keys -t "$SESSION_NAME" C-c 2>/dev/null || true
  sleep 1
fi

tx kill-session -t "$SESSION_NAME" 2>/dev/null || true

if tx_has "$SESSION_NAME"; then
  die "session '$SESSION_NAME' still alive after kill-session"
fi

log_activity "kill | $SESSION_NAME | force=$FORCE"
echo "killed: $SESSION_NAME"
