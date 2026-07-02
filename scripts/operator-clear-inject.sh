#!/usr/bin/env bash
# operator-clear-inject.sh — inject a NATIVE Claude Code `/clear` into the live
# operator tmux session, clearing its context IN-PLACE (no restart, MCP connections
# stay alive).
#
# The owner sends `/clear` in Telegram → telegram-mcp intercepts it (clear-flow.ts,
# owner-only) BEFORE it becomes a channel-push → telegram-mcp calls THIS script.
# The script types `/clear` + Enter into the operator's claude TUI exactly the way
# start.sh types `/boot` on boot, so claude runs its own native context-clear.
#
# Why a script (not inline in TS): keeps the tmux socket/session details and the
# send-keys timing out of the compiled bundle, and makes the mechanism independently
# testable (DRY-RUN below).
#
# Target: session `operator` on the install user's tmux server.
#   - operator runs as the AgentOS install user (default `agent-os`); start.sh
#     launches it with TMUX_TMPDIR=$HOME/.tmux → socket $HOME/.tmux/tmux-$(id -u)/default.
#   - telegram-mcp runs as the same user and (verified) can reach that socket from
#     its own mount ns (PrivateMounts=no; $HOME/.tmux is in ReadWritePaths),
#     so NO nsenter / sudo / helper-with-privileges is needed.
#
# Env overrides:
#   OPERATOR_TMUX_SESSION   (default: operator)
#   TMUX_TMPDIR             (default: $HOME/.tmux)
#   OPERATOR_TMUX_SOCKET    (default: $TMUX_TMPDIR/tmux-$(id -u)/default)
#   OPERATOR_CLEAR_DRYRUN=1 → print what it WOULD do, do not touch the session
#
# Exit 0 = `/clear` injected (or dry-run printed). Exit 1 = session not found / error.
set -uo pipefail

SESSION="${OPERATOR_TMUX_SESSION:-operator}"
TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
SOCKET="${OPERATOR_TMUX_SOCKET:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
DRYRUN="${OPERATOR_CLEAR_DRYRUN:-0}"

log() { echo "[operator-clear-inject] $*" >&2; }

TMUX_BASE=(tmux -S "$SOCKET")

if [ "$DRYRUN" = "1" ]; then
  log "DRY-RUN: would target socket=$SOCKET session=$SESSION"
  log "DRY-RUN: ${TMUX_BASE[*]} send-keys -t $SESSION -l '/clear'"
  log "DRY-RUN: ${TMUX_BASE[*]} send-keys -t $SESSION Enter"
  exit 0
fi

# Verify the operator session exists on this socket before typing into it.
if ! "${TMUX_BASE[@]}" has-session -t "$SESSION" 2>/dev/null; then
  log "ERROR: tmux session '$SESSION' not found on socket '$SOCKET' — NOT injecting."
  exit 1
fi

# Type the literal command, then a SEPARATE Enter keypress. Two-step (literal text
# with -l, brief pause, then the Enter key) is the reliable way to drive the claude
# TUI's slash-command input — a single combined send-keys can race the slash-command
# autocomplete popup. Mirrors start.sh's `send-keys "/boot" Enter` boot injection.
"${TMUX_BASE[@]}" send-keys -t "$SESSION" -l "/clear" || { log "ERROR: send-keys literal failed"; exit 1; }
sleep 0.3
"${TMUX_BASE[@]}" send-keys -t "$SESSION" Enter || { log "ERROR: send-keys Enter failed"; exit 1; }

log "injected native /clear into session '$SESSION' (socket $SOCKET)"
exit 0
