#!/usr/bin/env bash
# Restart the AgentOS operator end-to-end and VERIFY it came back up.
#
# This is the "/goal: restart operator, confirm it started in its own tmux
# session" runbook. It is the canonical way to bounce the operator after a
# Claude Code update or a config change — never just `systemctl restart` blind,
# because the dev-channels WARNING dialog (re-introduced by every CC auto-update)
# silently hangs a fresh session before it can boot.
#
# Steps:
#   1. ensure-dev-channels-patch.py  — self-heal the binary so no dialog hangs boot
#   2. restart via the platform mechanism (systemd unit | launchd | start.sh)
#   3. verify a live `claude` process inside the `operator` tmux session
#   4. verify the operator registered as a claude-peers peer
#
# Exit 0 = operator verified up. Exit 1 = restart issued but verification failed.
#
# Env overrides:
#   INSTALL_ROOT          (default: repo root inferred from this script)
#   PROJECT_SLUG          (default: agent-os)  — launchd label namespace on macOS
#   PEERS_HEALTH          (default: http://127.0.0.1:7899)
#   OPERATOR_SERVICE      (default: agent-os-operator.service)
#   OPERATOR_TMUX_SESSION (default: operator) — so the same script can bounce
#                         per-instance operators
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
PROJECT_SLUG="${PROJECT_SLUG:-agent-os}"
PEERS_HEALTH="${PEERS_HEALTH:-http://127.0.0.1:7899}"
SERVICE="${OPERATOR_SERVICE:-agent-os-operator.service}"
SESSION="${OPERATOR_TMUX_SESSION:-operator}"
PATCH="$SCRIPT_DIR/ensure-dev-channels-patch.py"
START="$INSTALL_ROOT/agents/operator/start.sh"
export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"

log() { echo "[restart-operator] $*"; }
fail() { log "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Self-heal the dev-channels dialog gate (idempotent — no-op if already done)
# ---------------------------------------------------------------------------
log "step 1/4 — ensuring dev-channels patch on current claude binary"
# Resolve the binary explicitly — non-interactive shells (ssh) may lack ~/.local/bin
# on PATH, so we don't rely on the patch script's own PATH lookup.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -f "$PATCH" ]; then
  # Pass the resolved path only if found; else let the script's own fallback run
  # (an empty arg would resolve to cwd, which is wrong).
  python3 "$PATCH" ${CLAUDE_BIN:+"$CLAUDE_BIN"} \
    || fail "dev-channels patch failed — aborting (a fresh session would hang on the WARNING dialog)"
else
  log "WARNING: $PATCH missing — skipping patch (dialog may hang boot)"
fi

# ---------------------------------------------------------------------------
# 2. Restart via platform mechanism
# ---------------------------------------------------------------------------
log "step 2/4 — restarting operator"
if [ "$(uname -s)" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
  sudo systemctl restart "$SERVICE" || fail "systemctl restart failed"
  log "issued: systemctl restart $SERVICE"
elif [ "$(uname -s)" = "Darwin" ]; then
  LABEL="com.${PROJECT_SLUG}.operator"
  if launchctl list "$LABEL" &>/dev/null; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL" || fail "launchctl kickstart failed"
    log "issued: launchctl kickstart -k $LABEL"
  else
    log "launchd label $LABEL not loaded — restarting via start.sh directly"
    [ -x "$START" ] || fail "start.sh not found/executable at $START"
    # start.sh kills any stale tmux 'operator' session itself, then relaunches.
    INSTALL_ROOT="$INSTALL_ROOT" PROJECT_SLUG="$PROJECT_SLUG" nohup bash "$START" \
      >/tmp/operator-restart.log 2>&1 &
    log "issued: start.sh (log -> /tmp/operator-restart.log)"
  fi
else
  fail "unsupported platform: $(uname -s)"
fi

# ---------------------------------------------------------------------------
# 3. Verify a live claude process inside the 'operator' tmux session
# ---------------------------------------------------------------------------
log "step 3/4 — verifying tmux session '$SESSION' has a live claude process"
session_ok=0
for _ in $(seq 1 30); do
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    # pane command(s) for the session — expect 'claude' (or 'node' while spawning)
    panecmds="$(tmux list-panes -t "$SESSION" -F '#{pane_current_command}' 2>/dev/null)"
    if echo "$panecmds" | grep -qiE 'claude|node'; then
      session_ok=1
      break
    fi
  fi
  sleep 2
done
[ "$session_ok" = 1 ] || fail "tmux session '$SESSION' not running a claude process after ~60s"
log "OK — tmux session '$SESSION' is live (pane: $(tmux list-panes -t "$SESSION" -F '#{pane_current_command}' 2>/dev/null | tr '\n' ' '))"

# ---------------------------------------------------------------------------
# 4. Verify peer registration (operator surfaces on the claude-peers broker)
# ---------------------------------------------------------------------------
log "step 4/4 — verifying operator registered as a claude-peers peer"
peer_ok=0
for _ in $(seq 1 20); do
  cnt="$(curl -s "$PEERS_HEALTH/list-peers" \
        -H 'Content-Type: application/json' \
        -d '{"scope":"machine","cwd":"/","git_root":null}' 2>/dev/null \
        | grep -c operator 2>/dev/null || echo 0)"
  if [ "${cnt:-0}" -gt 0 ]; then
    peer_ok=1
    break
  fi
  sleep 3
done
if [ "$peer_ok" = 1 ]; then
  log "OK — operator registered as peer"
else
  log "WARNING — operator not yet registered as peer (tmux is up; channel push may lag or be misconfigured)"
fi

log "DONE — operator restarted and tmux session verified live."
exit 0
