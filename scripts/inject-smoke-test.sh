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

# Test 1 — IDLE composer: does a char-by-char /clear register and execute? The
# primitive returns 0 iff it verified the command landed at the start of the
# composer and Enter did not queue it as a message.
if ! tmux_inject_slash "$SOCKET" "$SESS" "/clear" >/dev/null 2>&1; then
  echo "BROKEN: /clear did NOT register on an idle composer — slash-inject regressed (paste-swallow?)"
  exit 1
fi

# Test 2 — BUSY composer (the 2026-07-18 regression class): while claude is
# mid-turn, typed text is QUEUED as the next MESSAGE, so a naive inject submits
# /clear as literal chat text. The primitive must interrupt to an idle composer
# first. Make the throwaway session busy, then inject and confirm it did NOT get
# queued (a fresh "Welcome back" banner => /clear actually executed).
"${TB[@]}" send-keys -t "$SESS" -l "Write a very long 20-paragraph essay about the history of tea." 2>/dev/null
sleep 0.3; "${TB[@]}" send-keys -t "$SESS" Enter 2>/dev/null
# Busy is detected with the same extended marker the inject primitive uses
# (spinner elapsed timer / token counter / legacy "esc to interrupt") — some CC
# 2.1.x renders no longer print the legacy string mid-turn, which would make a
# legacy-only probe skip the busy path as "unexercised" on a genuinely busy
# session. Poll up to ~10s for the turn to actually start (model latency varies).
_busy_marker='esc to interrupt|\([0-9]+s |[0-9]+ tokens'
busy=""
for _ in $(seq 1 20); do
  sleep 0.5
  if "${TB[@]}" capture-pane -p -t "$SESS" 2>/dev/null | grep -qiE "$_busy_marker"; then busy=1; break; fi
done
if [ -z "$busy" ]; then
  echo "ok: /clear registered on idle (busy-path unexercised — session did not stay busy)"
  exit 0
fi
if ! tmux_inject_slash "$SOCKET" "$SESS" "/clear" >/dev/null 2>&1; then
  echo "BROKEN: /clear inject failed on a BUSY session (busy-interrupt path regressed)"
  exit 1
fi
sleep 1.5
pane="$("${TB[@]}" capture-pane -p -S -200 -t "$SESS" 2>/dev/null)"
if echo "$pane" | grep -qiF "Press up to edit queued messages"; then
  echo "BROKEN: /clear was QUEUED as a message on a busy session (busy-gate regressed)"
  exit 1
fi
# CC 2.1.218 stopped printing the legacy "Welcome back" banner on /clear; a
# successful clear now just re-renders the startup logo ("Claude Code v<ver>" +
# model line + cwd). The DEFINITIVE proof the context was actually wiped (not
# merely that /clear was typed) is that the busy turn's essay prompt is GONE from
# the transcript — a queued or ignored /clear would leave "history of tea" on
# screen. The banner grep accepts EITHER form so it survives on 2.1.<218 too.
if echo "$pane" | grep -qiF "history of tea"; then
  echo "BROKEN: /clear on a busy session did NOT clear context (busy turn's prompt still present — inject queued/ignored)"
  exit 1
fi
if ! echo "$pane" | grep -qE "Welcome back|Claude Code v[0-9]"; then
  echo "BROKEN: /clear on a busy session left no cleared-screen banner (no Welcome-back / startup logo after interrupt)"
  exit 1
fi
echo "ok: /clear healthy on idle AND busy composer (char-by-char + busy-interrupt gate)"
exit 0
