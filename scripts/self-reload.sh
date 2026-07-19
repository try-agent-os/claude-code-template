#!/usr/bin/env bash
# self-reload.sh — cross-system agent self-restart.
#
# Lets a Claude Code agent restart itself so it picks up new MCP config / code,
# coming back automatically. Detects how the agent is launched and uses the
# right mechanism:
#   • systemd-managed (Linux host)  -> systemctl restart <unit>
#   • bare tmux session (macOS dev) -> detached respawn session that recreates
#                                      the tmux session with the SAME command
#
# Usage:
#   scripts/self-reload.sh [--unit <systemd-unit>] [--session <tmux-session>] [--delay <sec>]
#
# Defaults: unit=agent-os-operator.service, session=operator, delay=5
#
# NOTE: when this triggers a tmux respawn it will KILL the current session a few
# seconds after returning. The caller (the agent) should send any final message
# BEFORE invoking, then stop. The respawned session comes back on its own.
set -uo pipefail

UNIT="agent-os-operator.service"
SESSION="operator"
DELAY=5
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) UNIT="$2"; shift 2;;
    --session) SESSION="$2"; shift 2;;
    --delay) DELAY="$2"; shift 2;;
    *) echo "[self-reload] unknown arg: $1" >&2; shift;;
  esac
done

log() { echo "[self-reload] $*"; }

# ---- Path 1: systemd-managed (Linux host) ----
if command -v systemctl >/dev/null 2>&1 && systemctl cat "$UNIT" >/dev/null 2>&1; then
  log "systemd unit '$UNIT' present — restarting via systemctl (auto-relaunch)."
  # Detach the restart so it survives this process exiting.
  setsid bash -c "sleep ${DELAY}; sudo systemctl restart '${UNIT}'" >/dev/null 2>&1 &
  log "scheduled: systemctl restart ${UNIT} in ${DELAY}s. This session will be replaced."
  exit 0
fi

# ---- Path 2: bare tmux session (macOS dev) ----
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
  # Capture the EXACT launch command of the agent in this session.
  # The session's pane root process is the `claude` process; its argv is the command to relaunch.
  PANE_PID="$(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)"
  WORKDIR="$(tmux display-message -t "$SESSION" -p '#{pane_current_path}' 2>/dev/null)"
  CLAUDE_CMD="$(ps -o command= -p "$PANE_PID" 2>/dev/null)"

  if [ -z "$CLAUDE_CMD" ] || ! printf '%s' "$CLAUDE_CMD" | grep -q 'claude'; then
    log "ERROR: could not capture the claude launch command for session '$SESSION' (pane_pid=$PANE_PID, got: '$CLAUDE_CMD'). Aborting — NOT killing the session." >&2
    exit 1
  fi
  [ -z "$WORKDIR" ] && WORKDIR="$HOME"

  # Write a self-contained respawn script so we avoid nested-quoting pitfalls.
  RESPAWN="/tmp/${SESSION}-respawn-$$.sh"
  cat > "$RESPAWN" <<EOF
#!/usr/bin/env bash
sleep ${DELAY}
tmux kill-session -t '${SESSION}' 2>/dev/null
sleep 2
cd '${WORKDIR}'
tmux new-session -d -s '${SESSION}' -c '${WORKDIR}' ${CLAUDE_CMD}
tmux kill-session -t '${SESSION}-respawn' 2>/dev/null
EOF
  chmod +x "$RESPAWN"

  log "captured relaunch cmd: ${CLAUDE_CMD}"
  log "workdir: ${WORKDIR}"
  log "respawn script: ${RESPAWN}"
  # Launch the respawn in its OWN detached tmux session so it survives this session's death.
  tmux new-session -d -s "${SESSION}-respawn" "bash ${RESPAWN}"
  log "scheduled: session '${SESSION}' will be killed + recreated in ${DELAY}s. Coming back on its own."
  exit 0
fi

log "ERROR: neither systemd unit '$UNIT' nor tmux session '$SESSION' found. Don't know how to reload here." >&2
exit 1
