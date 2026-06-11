#!/usr/bin/env bash
# dagu-watchdog.sh — out-of-band watchdog for the Dagu scheduler.
#
# Dagu can hang in a way systemd does not notice (process alive, scheduler
# loop stuck). The fix is a proof-of-life file written by a trivial DAG and
# an external checker that restarts the service when the file goes stale.
#
# Setup:
#   1. Register a heartbeat DAG in your routines that touches
#      {STATE_DIR}/dagu-heartbeat.log every 5 minutes, e.g.:
#
#        # routines/dagu-heartbeat.yaml
#        schedule: "*/5 * * * *"
#        steps:
#          - name: tick
#            command: bash -c 'date -u +"%Y-%m-%dT%H:%M:%SZ" >> /var/lib/agent-os/dagu-heartbeat.log; tail -n 50 /var/lib/agent-os/dagu-heartbeat.log > /tmp/hb.$$ && mv /tmp/hb.$$ /var/lib/agent-os/dagu-heartbeat.log'
#
#   2. Run this script OUT-OF-BAND of Dagu itself — via the
#      agent-os-dagu-watchdog.timer systemd unit (rendered by install.sh)
#      or an /etc/cron.d entry, every 10 min.
#
# If the heartbeat is stale > MAX_AGE (15 min), restarts agent-os-dagu.service
# and notifies the operator (best-effort, if a notify script is present).
#
# Requires: the invoking user needs NOPASSWD sudo for systemctl (or run the
# timer unit as root).

set -euo pipefail

# State-dir paths are host-stable; overridable via env for non-standard layouts.
HEARTBEAT_FILE="${DAGU_HEARTBEAT_FILE:-/var/lib/agent-os/dagu-heartbeat.log}"
WATCHDOG_LOG="${DAGU_WATCHDOG_LOG:-/var/lib/agent-os/dagu-watchdog.log}"
MAX_AGE="${DAGU_WATCHDOG_MAX_AGE:-900}"  # seconds
SERVICE="${DAGU_SERVICE:-agent-os-dagu.service}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"
# Optional operator notification hook: any executable taking <source> <message>.
NOTIFY_SCRIPT="${DAGU_WATCHDOG_NOTIFY:-$REPO/agents/heartbeat/lib/notify-operator.sh}"

log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >> "$WATCHDOG_LOG"
  # Keep log small — tail last 100 lines
  tail -n 100 "$WATCHDOG_LOG" > "${WATCHDOG_LOG}.tmp" && mv "${WATCHDOG_LOG}.tmp" "$WATCHDOG_LOG"
}

notify() {
  [ -f "$NOTIFY_SCRIPT" ] || return 0
  bash "$NOTIFY_SCRIPT" "dagu-watchdog" "$1" || true
}

# No Dagu service installed on this host → nothing to watch.
if ! systemctl list-unit-files "$SERVICE" 2>/dev/null | grep -q "$SERVICE"; then
  exit 0
fi

if [ ! -f "$HEARTBEAT_FILE" ]; then
  log "WARN: heartbeat file missing — Dagu may be brand new or heartbeat DAG not registered yet"
  exit 0
fi

LAST_MOD=$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || stat -f %m "$HEARTBEAT_FILE")
NOW=$(date +%s)
AGE=$((NOW - LAST_MOD))

if [ "$AGE" -gt "$MAX_AGE" ]; then
  log "STALE: heartbeat ${AGE}s old (> ${MAX_AGE}s threshold) — restarting $SERVICE"
  if sudo systemctl restart "$SERVICE"; then
    log "RESTART: $SERVICE restarted successfully"
    notify "ALERT: Dagu scheduler stalled (heartbeat ${AGE}s old) — restarted $SERVICE automatically"
  else
    log "ERROR: systemctl restart failed"
    notify "CRITICAL: Dagu scheduler stalled AND restart failed — manual intervention needed"
  fi
else
  log "OK: heartbeat ${AGE}s old (< ${MAX_AGE}s threshold)"
fi
