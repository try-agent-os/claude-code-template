#!/bin/bash
# operator-liveness-watchdog.sh — Layer B backend insurance against operator
# HARD death (tmux session gone / claude process gone / unit inactive).
#
# WHY: Type=forking + RemainAfterExit=yes means systemd reports the operator
# unit "active (exited)" even after the tmux session has been killed (user
# error, OOM, crash) — the classic 2026-06-07 incident where the unit looked
# alive but the operator was actually dead. `systemctl is-active` alone is NOT
# enough; we must look at the tmux session and the claude process directly.
#
# This complements (does NOT replace) operator-watchdog.sh: that one catches a
# SOFT hang (operator alive but not replying, 5-min reply-gap). This one catches
# HARD death fast (every minute, <60s recovery). Layer A (tmux.conf hardening,
# commit dd2183d) lives on the user side; this is the backend-independent layer.
#
# Fired every minute by agent-os-operator-liveness.timer. Runs as root so it can
# `systemctl restart` the operator. Loop prevention: rate-limit (max 3 restarts
# / 15 min) + debounce (skip if the unit started < 30s ago, which covers both a
# planned manual restart AND our own previous restart still warming up).
set -uo pipefail

# SERVICE / SESSION / state / log are env-overridable so the SAME script drives
# per-instance liveness watchdogs (symoditi/novostudio). Defaults reproduce the
# hub operator byte-for-byte — do NOT change them; override via the systemd unit.
SERVICE="${OPERATOR_SERVICE:-agent-os-operator.service}"
SESSION="${OPERATOR_TMUX_SESSION:-operator}"
LOG_DIR="/var/log/agent-os"
LOG_FILE="${OPERATOR_LIVENESS_LOG:-$LOG_DIR/watchdog.log}"
STATE_DIR="/var/lib/agent-os"
STATE_FILE="${OPERATOR_LIVENESS_STATE_FILE:-$STATE_DIR/operator-liveness-watchdog.restarts}"   # newline-separated restart epochs
DEBOUNCE_SEC="${OPERATOR_LIVENESS_DEBOUNCE_SEC:-30}"
MAX_RESTARTS="${OPERATOR_LIVENESS_MAX_RESTARTS:-3}"
WINDOW_SEC="${OPERATOR_LIVENESS_WINDOW_SEC:-900}"             # 15 min

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { printf '%s %s\n' "$(date -u -Iseconds)" "$*" >> "$LOG_FILE"; }

# Derive the operator's run user + tmux socket from the unit itself, so this is
# not hardcoded to one host (the legacy operator-watchdog.sh hardcoded
# `agent-os` and silently no-ops on this vasily-based hub).
AGENT_USER="$(systemctl show -p User --value "$SERVICE" 2>/dev/null)"
[ -n "$AGENT_USER" ] || AGENT_USER="agent-os"
AGENT_UID="$(id -u "$AGENT_USER" 2>/dev/null || echo "")"
AGENT_HOME="$(getent passwd "$AGENT_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$AGENT_HOME" ] || AGENT_HOME="/home/$AGENT_USER"
# Honor TMUX_TMPDIR when set (per-instance units export it); default to the
# agent's $HOME/.tmux exactly as before, so the hub path is unchanged.
TMUX_SOCKET_DIR="${TMUX_TMPDIR:-$AGENT_HOME/.tmux}"
TMUX_SOCKET="$TMUX_SOCKET_DIR/tmux-$AGENT_UID/default"

# tmux as the agent user against the shared socket. -S is mandatory: when run by
# root, env_reset strips TMUX_TMPDIR, so without -S tmux would hit the wrong
# (default /tmp) socket and falsely report "no session".
otmux() { sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" "$@"; }

NOW="$(date -u +%s)"

# --- transient guard: a (re)start is in flight --------------------------------
# During a planned `systemctl restart` the unit passes through activating/
# deactivating, and ActiveEnterTimestamp is still the PREVIOUS (stale) value, so
# the timestamp debounce below would not yet apply. Skip these transient states
# outright so a tick that lands mid-restart never fires a redundant restart.
ACTIVE_STATE="$(systemctl show -p ActiveState --value "$SERVICE" 2>/dev/null)"
case "$ACTIVE_STATE" in
  activating|deactivating|reloading)
    log "TRANSIENT: $SERVICE is '$ACTIVE_STATE' (restart in flight) — skip this tick"
    exit 0
    ;;
esac

# --- debounce: skip if the unit (re)started very recently --------------------
# Covers a planned `systemctl restart` by operator/sysadmin AND our own restart
# still bringing claude up. Avoids racing a healthy-but-warming session.
ACTIVE_TS="$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null)"
if [ -n "$ACTIVE_TS" ]; then
  ACTIVE_EPOCH="$(date -d "$ACTIVE_TS" +%s 2>/dev/null || echo 0)"
  AGE=$(( NOW - ACTIVE_EPOCH ))
  if [ "$ACTIVE_EPOCH" -gt 0 ] && [ "$AGE" -lt "$DEBOUNCE_SEC" ]; then
    log "DEBOUNCE: $SERVICE (re)started ${AGE}s ago (< ${DEBOUNCE_SEC}s) — skip this tick"
    exit 0
  fi
fi

# --- health checks (a) (b) (c) ----------------------------------------------
problems=()

# (a) systemd thinks the unit is active.
STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
[ "$STATE" = "active" ] || problems+=("unit not active (is-active=$STATE)")

# (b) tmux session exists on the shared socket.
SESSION_OK=0
if otmux has-session -t "$SESSION" 2>/dev/null; then
  SESSION_OK=1
else
  problems+=("tmux session '$SESSION' missing on $TMUX_SOCKET")
fi

# (c) claude process is actually running in that session. The operator pane
# launches `claude` directly, so a live pane reads claude/node/bun; a bare shell
# (or no session) means claude exited inside the session.
if [ "$SESSION_OK" = "1" ]; then
  CUR="$(otmux list-panes -t "$SESSION" -F '#{pane_current_command}' 2>/dev/null | head -1)"
  if ! printf '%s\n' "$CUR" | grep -qiE '^(claude|node|bun)$'; then
    problems+=("no claude process in session (pane cmd: '${CUR:-none}')")
  fi
fi

if [ "${#problems[@]}" -eq 0 ]; then
  # Healthy — stay quiet (1-min cadence would otherwise flood the log).
  exit 0
fi

REASON="$(IFS='; '; echo "${problems[*]}")"

# --- rate-limit: max MAX_RESTARTS restarts within WINDOW_SEC -----------------
recent=()
if [ -f "$STATE_FILE" ]; then
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    if [ $(( NOW - ts )) -lt "$WINDOW_SEC" ]; then recent+=("$ts"); fi
  done < "$STATE_FILE"
fi

if [ "${#recent[@]}" -ge "$MAX_RESTARTS" ]; then
  log "RATE-LIMITED: ${#recent[@]} restarts in last $(( WINDOW_SEC / 60 ))min (max $MAX_RESTARTS) — NOT restarting. Problems: $REASON"
  exit 0
fi

# --- restart ----------------------------------------------------------------
log "UNHEALTHY: $REASON — restarting $SERVICE"
if systemctl restart "$SERVICE"; then
  recent+=("$NOW")
  printf '%s\n' "${recent[@]}" > "$STATE_FILE"   # rewrite pruned + new epoch
  log "restart OK ($SERVICE); $(( ${#recent[@]} ))/$MAX_RESTARTS restarts in window"
else
  rc=$?
  log "ERROR: systemctl restart $SERVICE failed (rc=$rc). Problems: $REASON"
  exit 1
fi
