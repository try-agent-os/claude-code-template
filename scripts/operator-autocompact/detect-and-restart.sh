#!/bin/bash
# detect-and-restart.sh — operator inactivity watchdog.
#
# Restarts agent-os-operator.service when the user has been silent past
# AUTOCOMPACT_THRESHOLD_MIN minutes — giving the operator a fully fresh
# context window with no summarization overhead (vs. firing the in-TUI
# /compact command, which still leaves a summary occupying tokens).
#
# Conversation continuity is restored on boot by the operator's SessionStart
# hook (agents/operator/.claude/hooks/session-start.sh), which injects the
# last 20 Telegram messages + unanswered IN list as additionalContext.
#
# Dedup flag (/var/lib/agent-os/operator-restarted-since-last-msg.flag):
#   - SET by this script immediately before issuing systemctl restart.
#   - CLEARED by the operator's UserPromptSubmit hook (update-msg-epoch.sh) when
#     a fresh IN message from the user lands in messages.db (window = 60s).
#   - While the flag exists, this script returns noop — prevents re-restart
#     loops while the user remains silent. The cooldown is a belt-and-
#     suspenders backup in case the hook never fires (e.g. operator process
#     crashed mid-boot before UserPromptSubmit registered).
#
# Source of truth for "user last activity":
#   1. /var/lib/agent-os/operator-last-user-msg-epoch (epoch, written by hook)
#   2. Fall back to messages.db query if epoch file missing — preserves correct
#      behaviour for fresh installs / pre-hook-deployment state.
#
# Dry-run: while /var/lib/agent-os/operator-autocompact.dry-run exists, this
# script logs "WOULD-RESTART" decisions but never invokes systemctl. Keep the
# sentinel for the first 24h after deploy, then `rm` it to go live.
#
# Required config: OPERATOR_CHAT_ID must be set (in {ENV_FILE}) to the Telegram
# chat id whose IN messages count as user activity. Without it the detector
# cannot fall back to messages.db and will only act on the epoch file written
# by the operator's UserPromptSubmit hook.

set -uo pipefail

STATE_DIR="${AUTOCOMPACT_STATE_DIR:-/var/lib/agent-os}"
EPOCH_FILE="$STATE_DIR/operator-last-user-msg-epoch"
DEDUP_FLAG="$STATE_DIR/operator-restarted-since-last-msg.flag"
LAST_RESTART_FILE="$STATE_DIR/operator-autocompact.last-compact"
DRY_RUN_SENTINEL="$STATE_DIR/operator-autocompact.dry-run"
LOG_FILE="${AUTOCOMPACT_LOG:-/var/log/agent-os/operator-autocompact.log}"

_AC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AC_REPO="${REPO_ROOT:-$(dirname "$(dirname "$_AC_DIR")")}"
TG_DB="${OPERATOR_AUTOCOMPACT_TG_DB:-$_AC_REPO/plugins/telegram/messages.db}"
CHAT_ID="${OPERATOR_CHAT_ID:-}"
AGENT_USER="${OPERATOR_AGENT_USER:-agent-os}"
OPERATOR_UNIT="${OPERATOR_UNIT:-agent-os-operator.service}"
# Operator tmux session name — env-overridable so the SAME script drives
# per-instance detectors. Default "operator" matches the shipped unit.
OPERATOR_SESSION="${OPERATOR_TMUX_SESSION:-operator}"

THRESHOLD_MIN="${AUTOCOMPACT_THRESHOLD_MIN:-10}"
COOLDOWN_MIN="${AUTOCOMPACT_COOLDOWN_MIN:-15}"
QUIET_START_H="${AUTOCOMPACT_QUIET_START:-23}"
QUIET_END_H="${AUTOCOMPACT_QUIET_END:-7}"
QUIET_TZ="${AUTOCOMPACT_QUIET_TZ:-UTC}"

# Busy-guard knobs. WORKER_GLOB matches worker tmux sessions; OP_TMUX_TMPDIR is
# the agent user's shared tmux socket dir (same as the operator unit's
# TMUX_TMPDIR). AUTOCOMPACT_OPERATOR_PANE_PID lets the smoke test force the
# operator session pid without a tmux query.
WORKER_GLOB="${AUTOCOMPACT_WORKER_GLOB:-worker-*}"
OP_TMUX_TMPDIR="${OPERATOR_TMUX_TMPDIR:-${AGENT_HOME:-/home/agent-os}/.tmux}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date -u -Iseconds)" "$*" >> "$LOG_FILE"
}

# Last IN created_at for $CHAT_ID, via python3's stdlib sqlite3 module rather
# than the sqlite3 CLI — the CLI is not installed on a minimal host, and the
# template already depends on python3. Read-only open; empty stdout on any
# failure (callers treat empty as "no activity recorded").
tg_last_in() {
  [ -n "$CHAT_ID" ] || return 0
  python3 - "$TG_DB" "$CHAT_ID" 2>/dev/null <<'PYEOF' || true
import sqlite3, sys
db_path, chat_id = sys.argv[1], sys.argv[2]
try:
    chat_id = int(chat_id)
except ValueError:
    sys.exit(0)
try:
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=2)
    row = con.execute(
        "SELECT MAX(created_at) FROM messages WHERE chat_id=? AND direction='in'",
        (chat_id,),
    ).fetchone()
    con.close()
    if row and row[0]:
        sys.stdout.write(str(row[0]))
except Exception:
    pass
PYEOF
}

is_quiet_hours() {
  local h
  h=$(TZ="$QUIET_TZ" date +%-H)
  if [ "$QUIET_START_H" -le "$QUIET_END_H" ]; then
    [ "$h" -ge "$QUIET_START_H" ] && [ "$h" -lt "$QUIET_END_H" ]
  else
    [ "$h" -ge "$QUIET_START_H" ] || [ "$h" -lt "$QUIET_END_H" ]
  fi
}

# --- Busy detection -----------------------------------------------------------
# The silence-restart must NEVER kill in-flight work. Before issuing a restart
# we check two independent, directly-observed signals; if EITHER fires the
# operator is "busy" and the tick is skipped (dedup flag + cooldown untouched):
#
#   (a) a live sub-agent — a `claude` process that is a descendant of the
#       operator's long-lived session process. The Agent/Task tool forks a
#       child claude (CLAUDE_CODE_FORK_SUBAGENT=1); the operator's own MCP
#       children are node/bun, so any descendant whose comm is `claude` is a
#       running sub-agent.
#   (b) a worker tmux session matching $WORKER_GLOB. Spawned workers route
#       their summary back through the operator; restarting mid-flight can
#       drop that delivery.
#
# Both are queried from /proc + tmux (not scraped from the pane), so the signal
# is robust to spinner throttling and dev-channel dialogs.

operator_pane_pid() {
  if [ -n "${AUTOCOMPACT_OPERATOR_PANE_PID:-}" ]; then
    printf '%s\n' "$AUTOCOMPACT_OPERATOR_PANE_PID"
    return 0
  fi
  sudo -u "$AGENT_USER" env TMUX_TMPDIR="$OP_TMUX_TMPDIR" \
    tmux list-panes -t "$OPERATOR_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1
}

# True (0) if $1 has a descendant process whose comm is `claude` (root itself
# excluded — the operator's main session process is expected to be claude).
has_descendant_claude() {
  local root="$1" queue=("$1") pid kids k is_root=1
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    if [ "$is_root" -eq 1 ]; then
      is_root=0
    elif [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "claude" ]; then
      return 0
    fi
    kids=$(pgrep -P "$pid" 2>/dev/null) || true
    for k in $kids; do queue+=("$k"); done
  done
  return 1
}

# Echo the first worker tmux session name matching $WORKER_GLOB, else nothing.
busy_worker_session() {
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    # shellcheck disable=SC2053  # intentional glob match against $WORKER_GLOB
    [[ "$name" == $WORKER_GLOB ]] && { printf '%s\n' "$name"; return 0; }
  done < <(sudo -u "$AGENT_USER" env TMUX_TMPDIR="$OP_TMUX_TMPDIR" \
             tmux ls -F '#{session_name}' 2>/dev/null)
  return 1
}

# Sets BUSY_REASON and returns 0 (busy) if the operator has in-flight work.
BUSY_REASON=""
operator_busy() {
  local w pp
  if w=$(busy_worker_session); then
    BUSY_REASON="worker tmux session active ($w, glob=$WORKER_GLOB)"
    return 0
  fi
  pp=$(operator_pane_pid)
  if [ -n "$pp" ] && has_descendant_claude "$pp"; then
    BUSY_REASON="operator sub-agent claude running (descendant of pid $pp)"
    return 0
  fi
  return 1
}

NOW=$(date -u +%s)
SMOKE=0
case "${1:-}" in
  smoke-test|--smoke|-s) SMOKE=1;;
esac

# --- Smoke-test mode short-circuit ---
if [ "$SMOKE" -eq 1 ]; then
  smoke_log() { printf '[smoke] %s\n' "$*"; }
  smoke_log "STATE_DIR=$STATE_DIR"
  smoke_log "EPOCH_FILE=$EPOCH_FILE  exists=$([ -f "$EPOCH_FILE" ] && echo yes || echo no)"
  smoke_log "DEDUP_FLAG=$DEDUP_FLAG  exists=$([ -f "$DEDUP_FLAG" ] && echo yes || echo no)"
  smoke_log "LAST_RESTART_FILE=$LAST_RESTART_FILE  exists=$([ -f "$LAST_RESTART_FILE" ] && echo yes || echo no)"
  smoke_log "DRY_RUN_SENTINEL=$DRY_RUN_SENTINEL  exists=$([ -f "$DRY_RUN_SENTINEL" ] && echo yes || echo no)"
  smoke_log "TG_DB=$TG_DB  readable=$([ -r "$TG_DB" ] && echo yes || echo no)"
  smoke_log "CHAT_ID=${CHAT_ID:-(unset)}"
  smoke_log "QUIET hours: $QUIET_START_H..$QUIET_END_H $QUIET_TZ  now=$(TZ="$QUIET_TZ" date +%-H) -> quiet=$(is_quiet_hours && echo YES || echo no)"
  smoke_log "THRESHOLD_MIN=$THRESHOLD_MIN  COOLDOWN_MIN=$COOLDOWN_MIN"

  if [ -r "$TG_DB" ] && [ -n "$CHAT_ID" ]; then
    LAST_IN_RAW=$(tg_last_in)
    smoke_log "TG_DB last IN from $CHAT_ID: $LAST_IN_RAW"
  fi

  if [ -f "$EPOCH_FILE" ]; then
    EE=$(cat "$EPOCH_FILE")
    smoke_log "EPOCH_FILE contents=$EE  age=$((NOW - EE))s"
  fi

  smoke_log "operator unit state: $(systemctl is-active "$OPERATOR_UNIT" 2>/dev/null || echo unknown)"
  smoke_log "WORKER_GLOB=$WORKER_GLOB  OP_TMUX_TMPDIR=$OP_TMUX_TMPDIR  pane_pid=$(operator_pane_pid)"
  if operator_busy; then smoke_log "operator BUSY: $BUSY_REASON"; else smoke_log "operator idle (not busy)"; fi
  exit 0
fi

# --- Quiet hours guard ---
if is_quiet_hours; then
  log "QUIET-HOURS: hour=$(TZ=$QUIET_TZ date +%-H) ${QUIET_TZ}, window=[$QUIET_START_H..$QUIET_END_H), skip"
  exit 0
fi

# --- Dedup flag guard ---
# If the flag is present, the operator was already restarted since the last
# user IN message. Wait for the user to break silence before allowing
# another restart.
if [ -f "$DEDUP_FLAG" ]; then
  FLAG_AGE_MIN=$(( (NOW - $(stat -c %Y "$DEDUP_FLAG" 2>/dev/null || echo "$NOW")) / 60 ))
  log "DEDUP: flag present (age ${FLAG_AGE_MIN}min), waiting for user IN to clear it — skip"
  exit 0
fi

# --- Determine last user activity epoch ---
LAST_IN_EPOCH=0
SRC="epoch-file"
if [ -r "$EPOCH_FILE" ]; then
  V=$(cat "$EPOCH_FILE" 2>/dev/null || echo "")
  if [[ "$V" =~ ^[0-9]+$ ]]; then
    LAST_IN_EPOCH="$V"
  fi
fi

if [ "$LAST_IN_EPOCH" -eq 0 ] && [ -n "$CHAT_ID" ]; then
  SRC="messages.db"
  if [ -r "$TG_DB" ]; then
    LAST_IN_RAW=$(tg_last_in)
    if [ -n "$LAST_IN_RAW" ]; then
      LAST_IN_EPOCH=$(date -u -d "$LAST_IN_RAW" +%s 2>/dev/null || echo 0)
    fi
  fi
fi

if [ "$LAST_IN_EPOCH" -eq 0 ]; then
  log "no user activity recorded yet (src=$SRC) — skip"
  exit 0
fi

AGE_MIN=$(( (NOW - LAST_IN_EPOCH) / 60 ))
if [ "$AGE_MIN" -lt "$THRESHOLD_MIN" ]; then
  log "ok: silence=${AGE_MIN}min (threshold ${THRESHOLD_MIN}min, src=$SRC)"
  exit 0
fi

# --- Cooldown (belt-and-suspenders backup if dedup flag never gets set) ---
LAST_RESTART_EPOCH=$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)
[[ "$LAST_RESTART_EPOCH" =~ ^[0-9]+$ ]] || LAST_RESTART_EPOCH=0
SINCE_LAST_MIN=$(( (NOW - LAST_RESTART_EPOCH) / 60 ))
if [ "$LAST_RESTART_EPOCH" -gt 0 ] && [ "$SINCE_LAST_MIN" -lt "$COOLDOWN_MIN" ]; then
  log "cooldown: last restart ${SINCE_LAST_MIN}min ago (cooldown ${COOLDOWN_MIN}min), silence=${AGE_MIN}min — skip"
  exit 0
fi

# --- Busy guard ---
# Placed AFTER threshold + cooldown but BEFORE the dry-run/real restart: if the
# operator is doing in-flight work (live sub-agent or worker tmux session) we
# skip this tick WITHOUT touching the dedup flag or cooldown file, so the next
# idle tick restarts normally. Silence past threshold is necessary but not
# sufficient — the operator must also be idle.
if operator_busy; then
  log "BUSY: $BUSY_REASON — skip (silence=${AGE_MIN}min, src=$SRC). dedup flag/cooldown untouched."
  exit 0
fi

# --- Dry-run? ---
if [ -f "$DRY_RUN_SENTINEL" ]; then
  log "DRY-RUN: would restart $OPERATOR_UNIT (silence=${AGE_MIN}min, src=$SRC, last-restart-age=${SINCE_LAST_MIN}min)"
  exit 0
fi

# --- Real: set dedup flag, then restart operator ---
# Flag is set BEFORE restart so that even if the new operator process boots
# faster than we can write the flag, the dedup invariant holds.
: > "$DEDUP_FLAG"
chown "$AGENT_USER":"$AGENT_USER" "$DEDUP_FLAG" 2>/dev/null || true
chmod 644 "$DEDUP_FLAG" 2>/dev/null || true
log "DEDUP: flag set at $DEDUP_FLAG (will block re-restart until user writes)"

log "RESTARTING $OPERATOR_UNIT (silence=${AGE_MIN}min, src=$SRC)"
echo "$NOW" > "$LAST_RESTART_FILE"

if /bin/systemctl restart "$OPERATOR_UNIT" 2>>"$LOG_FILE"; then
  log "restart submitted ok, last-restart=$NOW silence=${AGE_MIN}min"
else
  log "ERROR: systemctl restart $OPERATOR_UNIT failed (exit $?)"
  # Failed restart — clear flag so next tick can retry.
  rm -f "$DEDUP_FLAG"
  exit 1
fi
