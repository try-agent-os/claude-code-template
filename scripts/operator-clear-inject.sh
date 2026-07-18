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
# Exit 0 = `/clear` injected & verified. Exit 2 = typed but NOT confirmed
# (paste-swallow — caller should tell the user "not confirmed"). Exit 1 = session
# not found / error.
set -uo pipefail

SESSION="${OPERATOR_TMUX_SESSION:-operator}"
TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
SOCKET="${OPERATOR_TMUX_SOCKET:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
DRYRUN="${OPERATOR_CLEAR_DRYRUN:-0}"

log() { echo "[operator-clear-inject] $*" >&2; }

# Shared, char-by-char inject primitive (defeats the CC 2.1.212 paste-burst bug
# and verifies the command landed in the composer before submitting). Sibling of
# this script in scripts/lib/.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/tmux-inject.sh
. "${LIB_DIR}/tmux-inject.sh"

if [ "$DRYRUN" = "1" ]; then
  log "DRY-RUN: would char-by-char inject '/clear' into socket=$SOCKET session=$SESSION (verify + Enter)"
  exit 0
fi

tmux_inject_slash "$SOCKET" "$SESSION" "/clear"
rc=$?
case "$rc" in
  0) log "injected & verified native /clear into session '$SESSION' (socket $SOCKET)"; exit 0 ;;
  2) log "typed /clear but could NOT verify it registered (paste-swallow?) — not confirmed"; exit 2 ;;
  *) log "ERROR: tmux session '$SESSION' not found on socket '$SOCKET' — NOT injecting."; exit 1 ;;
esac
