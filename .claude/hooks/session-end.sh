#!/usr/bin/env bash
# SessionEnd hook — fires when session terminates (logout, clear, prompt-input-exit).
#
# Different from Stop:
#   - Stop fires every turn end (Claude finished responding).
#   - SessionEnd fires once when the whole session ends.
#
# Use for: persist session summary, flush audit log, signal operator that this
# agent is offline. Cannot block — session is already ending.
# Async — best-effort.

set -uo pipefail

HOOK_NAME="session-end"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

SESSION_ID="$(json '.session_id')"
REASON="$(json '.reason')"
log "session=$SESSION_ID reason=$REASON"

# Persist a brief summary line to memory/sessions.log
SESSIONS_LOG="${CLAUDE_PROJECT_DIR}/memory/sessions.log"
mkdir -p "$(dirname "$SESSIONS_LOG")" 2>/dev/null || exit 0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\tend\t%s\t%s\n' "$TS" "${SESSION_ID:-?}" "${REASON:-other}" >> "$SESSIONS_LOG" 2>/dev/null || true

# Best-effort operator notification
PEERS_API="${CLAUDE_PEERS_API_URL:-http://127.0.0.1:7899/send-message}"
OPERATOR_ID="${OPERATOR_PEER_ID:-}"
if [ -n "$OPERATOR_ID" ]; then
  MSG="Agent session ${SESSION_ID:-?} ended (reason: ${REASON:-other})."
  PAYLOAD="{\"to_id\":\"$OPERATOR_ID\",\"message\":\"$MSG\"}"
  curl -s -m 2 -X POST "$PEERS_API" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    >/dev/null 2>&1 || true
fi

exit 0
