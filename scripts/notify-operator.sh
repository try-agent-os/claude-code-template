#!/bin/bash
# notify-operator.sh — single point of alert routing for an AgentOS instance.
#
# Every background contour (watchdogs, routines, workers, supervisors) sends its
# alerts here instead of talking to Telegram directly. That gives one place to
# filter, dedup and re-route notifications.
#
# Flow:
#   1) Try the claude-peers broker → operator peer. The operator answers in
#      Telegram, so the user can triage interactively rather than reading a
#      dead-end alert.
#   2) If the operator is unreachable → telegram-mcp /emergency endpoint. It
#      goes through the bot framework, so the message_id lands in messages.db
#      and a storm can be bulk-cleaned afterwards.
#   3) If telegram-mcp itself is down → direct Telegram Bot API as a last
#      resort (chat = $TELEGRAM_USER_ID). This path bypasses message logging,
#      so anything sent through it cannot be auto-deleted later — keep it rare.
#
# Filter: substring match against $SOURCE and $MSG via the blacklist file (one
#   substring per line, `#` for comments). A matching line silently drops the
#   alert — used for checks that make no sense on this host (e.g. a macOS-only
#   routine running on a Linux box).
#
# Dedup: identical (source, severity, msg) triples are suppressed within a
#   window. After the window expires the next matching alert carries a
#   "(repeated Nx in last Ymin)" prefix, so the storm size is visible without
#   the flood. State files are sha256-keyed and store "first_ts count" — the
#   anchor is the FIRST send, so mtime churn during a storm cannot slide the
#   window forward. TTL: $NOTIFY_DEDUP_TTL seconds (default 600).
#
# Usage:
#   notify-operator.sh --source <name> --severity <info|warn|error> \
#                      --msg "<text>" [--log <file-or-dash>]
#   echo "..." | notify-operator.sh --source X --severity error --msg "..." --log -
#
# Env overrides:
#   AGENT_OS_ETC             (default: /etc/agent-os)      — config dir
#   AGENT_OS_VAR             (default: /var/lib/agent-os)  — state dir
#   AGENT_OS_LOG_DIR         (default: /var/log/agent-os)  — log dir
#   AGENT_OS_INSTANCE        (default: hub) — broker slug namespace of THIS
#                            instance; only "<instance>:operator" (or the bare
#                            legacy "operator") is a valid delivery target
#   INSTALL_ROOT             (default: repo root inferred from this script)
#   NOTIFY_DEDUP_TTL         (default: 600) — dedup window, seconds
#   CLAUDE_PEERS_API_URL     (default: http://127.0.0.1:7899/send-message)
#   EMERGENCY_NOTIFY_URL     (default: http://127.0.0.1:3848/emergency)
#   EMERGENCY_NOTIFY_TOKEN   (optional shared secret for the endpoint above)
#   OPERATOR_PEER_ID         (optional) — skip peer discovery, deliver here
#
# Exit 0 always, even on delivery failure — notify-operator must never flap the
# upstream service that called it. Errors are logged to $AGENT_OS_LOG_DIR/notify.log.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
AGENT_OS_ETC="${AGENT_OS_ETC:-/etc/agent-os}"
AGENT_OS_VAR="${AGENT_OS_VAR:-/var/lib/agent-os}"
LOG_DIR="${AGENT_OS_LOG_DIR:-/var/log/agent-os}"
LOG_FILE="$LOG_DIR/notify.log"
BLACKLIST="${NOTIFY_BLACKLIST:-$AGENT_OS_ETC/notify-blacklist.txt}"
ENV_FILE="${AGENT_OS_ENV_FILE:-$AGENT_OS_ETC/agent-os.env}"
INSTANCE="${AGENT_OS_INSTANCE:-hub}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date -u -Iseconds)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

# Args
SOURCE="?"
SEVERITY="info"
MSG=""
LOG_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source)   SOURCE="$2";   shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --msg)      MSG="$2";      shift 2 ;;
    --log)      LOG_INPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$MSG" ]; then
  log "ERROR: --msg required"
  exit 0
fi

# Blacklist (substring match against source or msg)
if [ -r "$BLACKLIST" ]; then
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in \#*) continue ;; esac
    if [[ "$SOURCE" == *"$pattern"* ]] || [[ "$MSG" == *"$pattern"* ]]; then
      log "filtered (matched '$pattern'): source=$SOURCE msg=$MSG"
      exit 0
    fi
  done < "$BLACKLIST"
fi

# Dedup: suppress identical (source, severity, msg) bursts within DEDUP_TTL seconds.
# Window is anchored to first_ts stored in the state file, not file mtime — so
# mtime updates during suppression don't slide the window forward.
DEDUP_TTL="${NOTIFY_DEDUP_TTL:-600}"
DEDUP_DIR="${NOTIFY_DEDUP_DIR:-$AGENT_OS_VAR/notify-dedup}"
mkdir -p "$DEDUP_DIR" 2>/dev/null || true
DEDUP_KEY=$(printf '%s\x00%s\x00%s' "$SOURCE" "$SEVERITY" "$MSG" | sha256sum 2>/dev/null | awk '{print $1}')
DEDUP_FILE="$DEDUP_DIR/$DEDUP_KEY"
DEDUP_PREFIX=""
NOW=$(date +%s)
if [ -n "$DEDUP_KEY" ] && [ -f "$DEDUP_FILE" ]; then
  read -r FIRST_TS DEDUP_COUNT < "$DEDUP_FILE" 2>/dev/null || { FIRST_TS=0; DEDUP_COUNT=0; }
  AGE=$(( NOW - FIRST_TS ))
  if [ "$AGE" -lt "$DEDUP_TTL" ]; then
    DEDUP_COUNT=$(( DEDUP_COUNT + 1 ))
    printf '%s %s\n' "$FIRST_TS" "$DEDUP_COUNT" > "$DEDUP_FILE" 2>/dev/null || true
    log "dedup suppressed (count=$DEDUP_COUNT, age=${AGE}s): source=$SOURCE msg=$MSG"
    exit 0
  else
    # Window expired — include storm count in next message then reset.
    if [ "${DEDUP_COUNT:-0}" -gt 0 ]; then
      MINUTES=$(( AGE / 60 ))
      DEDUP_PREFIX="(repeated ${DEDUP_COUNT}x in last ${MINUTES}min) "
    fi
    printf '%s 0\n' "$NOW" > "$DEDUP_FILE" 2>/dev/null || true
  fi
else
  printf '%s 0\n' "$NOW" > "$DEDUP_FILE" 2>/dev/null || true
fi

# Optional tail of log file (or stdin if --log -)
TAIL=""
if [ "$LOG_INPUT" = "-" ]; then
  TAIL=$(timeout 2 cat 2>/dev/null | tail -n 20 || true)
elif [ -n "$LOG_INPUT" ] && [ -r "$LOG_INPUT" ]; then
  TAIL=$(tail -n 20 "$LOG_INPUT" 2>/dev/null || true)
fi

HOST="$(hostname -s 2>/dev/null || echo host)"
case "$SEVERITY" in
  error) ICON="🔴" ;;
  warn)  ICON="🟡" ;;
  info)  ICON="🔵" ;;
  *)     ICON="⚪" ;;
esac

FULL_MSG="${ICON} [${HOST}/${SOURCE}] ${SEVERITY}: ${DEDUP_PREFIX}${MSG}"
[ -n "$TAIL" ] && FULL_MSG="${FULL_MSG}

\`\`\`
${TAIL}
\`\`\`"

# --- 1) Try peer broker → operator -------------------------------------------
BROKER_URL="${CLAUDE_PEERS_API_URL:-http://127.0.0.1:7899/send-message}"
LIST_URL="${BROKER_URL%/send-message}/list-peers"

OPERATOR_ID="${OPERATOR_PEER_ID:-}"
if [ -z "$OPERATOR_ID" ]; then
  OPERATOR_ID=$(curl -s --max-time 3 -X POST "$LIST_URL" \
    -H 'Content-Type: application/json' \
    -d '{"scope":"machine"}' 2>/dev/null \
    | AGENT_OS_INSTANCE="$INSTANCE" INSTALL_ROOT="$INSTALL_ROOT" python3 -c 'import sys,json,os
# Route alerts ONLY to the operator of THIS instance. The broker namespaces
# slugs as "<instance>:<agent>", so several AgentOS instances sharing one host
# each expose their own "<instance>:operator". An earlier rule matched ANY peer
# whose cwd contained "/operator" — with the local operator offline that routed
# this instance alerts into a NEIGHBOUR instance operator (its cwd matched
# first). Never cross instance boundaries.
INSTANCE = os.environ.get("AGENT_OS_INSTANCE", "hub")
ROOT     = os.environ.get("INSTALL_ROOT", "")

def is_local_operator(p):
  slug = p.get("slug") or ""
  cwd  = p.get("cwd") or ""
  # Match our own slug FIRST, before the colon reject below — otherwise the
  # namespaced form of our own operator would be dropped too.
  if slug in (f"{INSTANCE}:operator", "operator"):
    return True
  if ":" in slug:      # a foreign "<other-instance>:operator" — NEVER route here
    return False
  # Slug missing entirely: fall back to cwd, but only inside our own tree.
  return bool(cwd.endswith("/operator") and ROOT and cwd.startswith(ROOT))

try:
  peers = json.load(sys.stdin)
  for p in peers:
    if is_local_operator(p):
      print(p["id"]); break
except Exception:
  pass' 2>/dev/null || true)
fi

DELIVERED=""
if [ -n "$OPERATOR_ID" ]; then
  PAYLOAD=$(python3 -c 'import json,sys
m=sys.argv[3]
print(json.dumps({"from_id": sys.argv[1], "to_id": sys.argv[2], "text": m, "message": m}))' \
    "notify-operator" "$OPERATOR_ID" "$FULL_MSG" 2>/dev/null || echo "")
  if [ -n "$PAYLOAD" ]; then
    RESP=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
      -X POST "$BROKER_URL" \
      -H 'Content-Type: application/json' \
      -d "$PAYLOAD" 2>/dev/null || echo "000")
    if [ "$RESP" = "200" ] || [ "$RESP" = "201" ]; then
      DELIVERED="peer:$OPERATOR_ID"
      log "delivered via peer ($OPERATOR_ID): $SOURCE/$SEVERITY $MSG"
    else
      log "peer delivery failed (HTTP $RESP), falling back"
    fi
  fi
else
  log "no operator peer found, falling back"
fi

# --- 2) Fallback: telegram-mcp /emergency endpoint ---------------------------
# Out-of-band path that still goes through the bot framework, so the message
# lands in messages.db with a telegram_message_id — that is what makes a storm
# cleanable afterwards.
EMERGENCY_URL="${EMERGENCY_NOTIFY_URL:-http://127.0.0.1:3848/emergency}"
if [ -z "$DELIVERED" ]; then
  PAYLOAD=$(python3 -c 'import json,sys
print(json.dumps({
  "source": sys.argv[1],
  "severity": sys.argv[2],
  "message": sys.argv[3],
  "log": sys.argv[4],
  "dedup_prefix": sys.argv[5],
}))' "$SOURCE" "$SEVERITY" "$MSG" "$TAIL" "$DEDUP_PREFIX" 2>/dev/null || echo "")
  if [ -n "$PAYLOAD" ]; then
    HDR_ARGS=()
    [ -n "${EMERGENCY_NOTIFY_TOKEN:-}" ] && HDR_ARGS=(-H "X-Emergency-Token: $EMERGENCY_NOTIFY_TOKEN")
    HTTP=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
      -X POST "$EMERGENCY_URL" \
      -H 'Content-Type: application/json' \
      "${HDR_ARGS[@]}" \
      -d "$PAYLOAD" 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
      DELIVERED="emergency:$EMERGENCY_URL"
      log "delivered via telegram-mcp /emergency: $SOURCE/$SEVERITY $MSG"
    else
      log "emergency endpoint failed (HTTP $HTTP), falling through to direct bot API"
    fi
  fi
fi

# --- 3) Last-resort: direct Telegram Bot API ---------------------------------
# Used only if both the peer broker and telegram-mcp /emergency are down (e.g.
# telegram-mcp.service itself crashed). Bypasses messages.db logging, so
# anything sent this way becomes part of an "unloggable storm" that can only be
# cleaned up by sweeping a message_id range — keep this path rare. Requires
# TELEGRAM_BOT_TOKEN and TELEGRAM_USER_ID in $ENV_FILE (never inline them here).
if [ -z "$DELIVERED" ]; then
  CHAT_ID="${TELEGRAM_USER_ID:-${TELEGRAM_ADMIN_USER_IDS:-}}"
  TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  if [ -n "$CHAT_ID" ] && [ -n "$TOKEN" ]; then
    CLIPPED=$(printf '%s' "$FULL_MSG" | head -c 3800)
    HTTP=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
      -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${CLIPPED}" 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
      log "delivered via direct bot API (chat=$CHAT_ID): $SOURCE/$SEVERITY $MSG"
    else
      log "direct bot API delivery failed (HTTP $HTTP)"
    fi
  else
    log "no last-resort fallback: TELEGRAM_USER_ID or TELEGRAM_BOT_TOKEN missing"
  fi
fi

exit 0
