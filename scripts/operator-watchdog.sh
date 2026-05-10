#!/bin/bash
# operator-watchdog.sh — restart agent-os-operator.service when it stops
# responding to incoming Telegram messages.
#
# Logic: read telegram-mcp messages.db, find MAX(created_at) for direction='in'
# and direction='out'. If last incoming is newer than last outgoing AND the
# gap exceeds THRESHOLD_MIN, restart the operator unit.
#
# Run periodically via systemd timer (agent-os-operator-watchdog.timer).
# Cooldown prevents restart loops if the issue is structural.

set -euo pipefail

DB="${OPERATOR_WATCHDOG_DB:-/opt/agent-os/claude/plugins/telegram/messages.db}"
THRESHOLD_MIN="${OPERATOR_WATCHDOG_THRESHOLD_MIN:-15}"
COOLDOWN_MIN="${OPERATOR_WATCHDOG_COOLDOWN_MIN:-20}"
LOG_DIR="/var/log/agent-os"
LOG_FILE="$LOG_DIR/operator-watchdog.log"
STATE_FILE="/var/lib/agent-os/operator-watchdog.last-restart"
SERVICE="agent-os-operator.service"

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"

log() {
  printf '%s %s\n' "$(date -u -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

if [ ! -r "$DB" ]; then
  log "ERROR: cannot read $DB"
  exit 1
fi

LAST_IN=$(sqlite3 "$DB" "SELECT MAX(created_at) FROM messages WHERE direction='in';" 2>/dev/null || echo "")
LAST_OUT=$(sqlite3 "$DB" "SELECT MAX(created_at) FROM messages WHERE direction='out';" 2>/dev/null || echo "")

if [ -z "$LAST_IN" ]; then
  log "no incoming messages yet, skip"
  exit 0
fi

LAST_IN_EPOCH=$(date -u -d "$LAST_IN" +%s 2>/dev/null || echo 0)
LAST_OUT_EPOCH=$(date -u -d "${LAST_OUT:-1970-01-01 00:00:00}" +%s 2>/dev/null || echo 0)
NOW=$(date -u +%s)

if [ "$LAST_OUT_EPOCH" -ge "$LAST_IN_EPOCH" ]; then
  log "ok: last_out=$LAST_OUT is current with last_in=$LAST_IN"
  exit 0
fi

AGE_MIN=$(( (NOW - LAST_IN_EPOCH) / 60 ))

if [ "$AGE_MIN" -lt "$THRESHOLD_MIN" ]; then
  log "ok: unanswered for ${AGE_MIN}min (threshold ${THRESHOLD_MIN}min)"
  exit 0
fi

# Cooldown
if [ -f "$STATE_FILE" ]; then
  LAST_RESTART=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  SINCE_MIN=$(( (NOW - LAST_RESTART) / 60 ))
  if [ "$SINCE_MIN" -lt "$COOLDOWN_MIN" ]; then
    log "HUNG: unanswered ${AGE_MIN}min but last restart was ${SINCE_MIN}min ago (cooldown ${COOLDOWN_MIN}min) — skip"
    exit 0
  fi
fi

log "HUNG: last_in='$LAST_IN' no reply for ${AGE_MIN}min — restarting $SERVICE"
if systemctl restart "$SERVICE"; then
  echo "$NOW" > "$STATE_FILE"
  log "restarted $SERVICE successfully"
else
  log "ERROR: systemctl restart $SERVICE failed (exit $?)"
  exit 1
fi
