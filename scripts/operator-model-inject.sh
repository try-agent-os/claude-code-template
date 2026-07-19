#!/usr/bin/env bash
# operator-model-inject.sh — inject a NATIVE Claude Code `/model <alias>` into the
# live operator tmux session, switching its model IN-PLACE (no restart, MCP
# connections stay alive). Sibling of operator-clear-inject.sh — same mechanism.
#
# The owner sends `/model` in Telegram → telegram-mcp shows inline model buttons
# (model-flow.ts, owner-only) → a tap (or `/model <alias>` typed directly) calls
# THIS script with the alias as $1. The script types `/model <alias>` + Enter into
# the operator's claude TUI, so claude runs its own native model switch.
#
# Usage: operator-model-inject.sh <model-alias>
#   <model-alias> — e.g. claude-fable-5[1m], claude-sonnet-5, opus, sonnet.
#                   Validated against a strict charset before being typed.
#
# Env overrides (same as operator-clear-inject.sh):
#   OPERATOR_TMUX_SESSION   (default: operator)
#   TMUX_TMPDIR             (default: $HOME/.tmux)
#   OPERATOR_TMUX_SOCKET    (default: $TMUX_TMPDIR/tmux-$(id -u)/default)
#   OPERATOR_MODEL_DRYRUN=1 → print what it WOULD do, do not touch the session
#
# Exit 0 = injected (or dry-run printed). Exit 1 = bad alias / session not found.
set -uo pipefail

ALIAS="${1:-}"
SESSION="${OPERATOR_TMUX_SESSION:-operator}"
TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
SOCKET="${OPERATOR_TMUX_SOCKET:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
DRYRUN="${OPERATOR_MODEL_DRYRUN:-0}"

log() { echo "[operator-model-inject] $*" >&2; }

if [ -z "$ALIAS" ]; then
  log "ERROR: no model alias given. Usage: $0 <model-alias>"
  exit 1
fi

# Strict charset — the alias is typed verbatim into a live TUI, so reject anything
# that is not a plain model id/alias (letters, digits, dot, dash, underscore,
# square brackets for the [1m] context variant). No spaces, no shell metachars.
if ! [[ "$ALIAS" =~ ^[A-Za-z0-9._-]+(\[[A-Za-z0-9]+\])?$ ]]; then
  log "ERROR: alias '$ALIAS' failed charset validation — NOT injecting."
  exit 1
fi

# Shared, char-by-char inject primitive (defeats the CC 2.1.212 paste-burst bug
# and verifies the command landed in the composer before submitting). Sibling of
# this script in scripts/lib/.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/tmux-inject.sh
. "${LIB_DIR}/tmux-inject.sh"

if [ "$DRYRUN" = "1" ]; then
  log "DRY-RUN: would char-by-char inject '/model $ALIAS' into socket=$SOCKET session=$SESSION (verify + Enter + confirm 'Switch model?')"
  exit 0
fi

tmux_inject_slash "$SOCKET" "$SESSION" "/model $ALIAS"
rc=$?
case "$rc" in
  0) : ;;  # verified & submitted — fall through to the Switch-model? confirm
  2) log "typed /model $ALIAS but could NOT verify it registered / it got queued — not confirmed"; exit 2 ;;
  3) log "session '$SESSION' stayed busy even after interrupt — NOT injected (would queue as a message)"; exit 3 ;;
  *) log "ERROR: tmux session '$SESSION' not found on socket '$SOCKET' — NOT injecting."; exit 1 ;;
esac

# Mid-session model switches pop a "Switch model?" cache-invalidation confirm
# dialog ("Yes, switch to X" preselected). Confirm it only if actually on screen.
tmux_confirm_switch_model "$SOCKET" "$SESSION"

log "injected & verified native '/model $ALIAS' into session '$SESSION' (socket $SOCKET)"
exit 0
