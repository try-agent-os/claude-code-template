#!/usr/bin/env bash
# UserPromptSubmit hook — track user activity for autocompact restart decisions.
#
# Writes current epoch to /var/lib/agent-os/operator-last-user-msg-epoch and removes
# the dedup flag (/var/lib/agent-os/operator-restarted-since-last-msg.flag) ONLY when
# the triggering prompt corresponds to a fresh incoming Telegram message from the user.
#
# Detection: poll TG messages.db for max(created_at) WHERE chat_id=$OPERATOR_CHAT_ID
# AND direction='in'. If that timestamp is within the last 60 seconds we treat the
# current UserPromptSubmit as a user-driven event. Peer-message prompts (worker
# reports, sysadmin pings) leave the epoch alone — they must NOT reset the silence
# clock, otherwise constant worker chatter would mask user inactivity.
#
# Non-blocking, non-context-injecting: returns empty stdout so the parent
# Claude pipeline is unaffected.
#
# Required config: OPERATOR_CHAT_ID (the user's Telegram chat id). If unset the
# hook exits 0 without touching state.

set -uo pipefail

TG_DB="${OPERATOR_TG_DB:-/opt/agent-os/claude/plugins/telegram/messages.db}"
CHAT_ID="${OPERATOR_CHAT_ID:-}"
STATE_DIR="${AUTOCOMPACT_STATE_DIR:-/var/lib/agent-os}"
EPOCH_FILE="$STATE_DIR/operator-last-user-msg-epoch"
FLAG_FILE="$STATE_DIR/operator-restarted-since-last-msg.flag"
FRESH_WINDOW_SEC="${OPERATOR_USER_FRESH_SEC:-60}"

# Discard hook stdin without parsing — we don't need .prompt content because we
# verify user activity directly against messages.db.
cat >/dev/null 2>&1 || true

[ -n "$CHAT_ID" ] || exit 0

# DB may be locked momentarily — sqlite3 returns quickly on busy with empty stdout.
LAST_IN_RAW="$(sqlite3 "$TG_DB" \
  "SELECT MAX(created_at) FROM messages WHERE chat_id=$CHAT_ID AND direction='in';" \
  2>/dev/null || echo "")"
[ -z "$LAST_IN_RAW" ] && exit 0

LAST_IN_EPOCH="$(date -u -d "$LAST_IN_RAW" +%s 2>/dev/null || echo 0)"
[ "$LAST_IN_EPOCH" -gt 0 ] || exit 0

NOW=$(date -u +%s)
AGE=$(( NOW - LAST_IN_EPOCH ))
if [ "$AGE" -gt "$FRESH_WINDOW_SEC" ]; then
  # Not a user-driven prompt — leave state alone.
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\n' "$LAST_IN_EPOCH" > "$EPOCH_FILE" 2>/dev/null || true
rm -f "$FLAG_FILE" 2>/dev/null || true

exit 0
