#!/usr/bin/env bash
# inject-smoke-test.sh — guard against the CC "paste-swallow" regression that
# silently killed /clear and /model injection on the 2.1.211 -> 2.1.212 auto-
# update (2026-07-17). Run after every Claude Code CLI update: spawn a THROWAWAY
# claude session, drive the char-by-char inject primitive with a harmless /clear,
# and confirm the command actually REGISTERS in the composer (the exact signal
# that broke). Never touches the real operator/worker sessions.
#
# Exit codes:
#   0 = inject verified working (regression NOT present)
#   1 = inject BROKEN (command did not register — the regression is back)
#   2 = inconclusive (throwaway session never became ready — cannot decide;
#       treat as a soft warning, not a hard failure, to avoid false alarms)
#
# Output: a single status line on stdout (ok|BROKEN|inconclusive + detail).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tmux-inject.sh
. "${SCRIPT_DIR}/lib/tmux-inject.sh"

export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
SOCKET="${OPERATOR_TMUX_SOCKET:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
SESS="inject-smoke-$$"
# Auth like the operator so the throwaway session doesn't hang on a login prompt.
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/var/lib/agent-os/claude-config/server}"
# Binary resolution: explicit CLAUDE_BIN override wins, then $PATH, then the
# default per-user install location used by the Claude Code installer.
CLAUDE_BIN="${CLAUDE_BIN:-}"
[ -n "$CLAUDE_BIN" ] && [ ! -x "$CLAUDE_BIN" ] && CLAUDE_BIN=""
[ -z "$CLAUDE_BIN" ] && CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"

TB=(tmux -S "$SOCKET")
cleanup() { "${TB[@]}" kill-session -t "$SESS" 2>/dev/null || true; }
trap cleanup EXIT

if [ -z "$CLAUDE_BIN" ]; then echo "inconclusive: claude binary not found"; exit 2; fi

# Cheapest viable model; TERM matches the operator unit so we exercise the same
# terminal path that regressed.
"${TB[@]}" new-session -d -s "$SESS" -x 200 -y 50 -c /tmp -e TERM=screen-256color \
  "$CLAUDE_BIN --dangerously-skip-permissions --model claude-haiku-4-5" 2>/dev/null || {
    echo "inconclusive: could not spawn throwaway session"; exit 2; }

# Wait up to ~50s for a ready composer, dismissing any first-run dialogs.
ready=""
for _ in $(seq 1 25); do
  sleep 2
  pane="$("${TB[@]}" capture-pane -p -t "$SESS" 2>/dev/null)" || break
  case "$pane" in
    *'bypass permissions on'*|*'? for shortcuts'*) ready=1; break ;;  # composer live
    *'Yes, I accept'*|*'accept all responsibility'*) "${TB[@]}" send-keys -t "$SESS" Down 2>/dev/null; sleep 0.4; "${TB[@]}" send-keys -t "$SESS" Enter 2>/dev/null ;;
    *) "${TB[@]}" send-keys -t "$SESS" Enter 2>/dev/null ;;  # theme / dev-channels / trust dialogs
  esac
done
[ -n "$ready" ] || { echo "inconclusive: throwaway session never became ready"; exit 2; }

# The actual test: does a char-by-char /clear register in the composer? The
# primitive returns 0 iff it verified the command text landed (and then submits
# it — harmless on a throwaway session).
if tmux_inject_slash "$SOCKET" "$SESS" "/clear" >/dev/null 2>&1; then
  echo "ok: /clear registered & submitted (char-by-char inject healthy)"
  exit 0
else
  echo "BROKEN: /clear did NOT register in composer — slash-inject regressed (paste-swallow?)"
  exit 1
fi
