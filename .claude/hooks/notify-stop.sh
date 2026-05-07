#!/usr/bin/env bash
# Stop hook — fires every turn end. Notifies operator via peers REST API.
#
# CRITICAL: Stop hooks fire on EVERY turn end, not just task completion. They
# can re-trigger if a previous Stop hook returned feedback. Always check
# stop_hook_active first and exit 0 if true to avoid infinite loops.
#
# Async (configured in settings.json) — never blocks the agent.
# Network failures must be silent — best-effort notification only.

set -uo pipefail

HOOK_NAME="notify-stop"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

if is_stop_loop; then
  exit 0
fi

PEERS_API="${CLAUDE_PEERS_API_URL:-http://127.0.0.1:7899/send-message}"
OPERATOR_ID="${OPERATOR_PEER_ID:-}"

# If operator not configured, silent skip (fine for non-AgentOS deployments)
if [ -z "$OPERATOR_ID" ]; then
  exit 0
fi

SESSION_ID="$(json '.session_id')"
TRANSCRIPT_PATH="$(json '.transcript_path')"
CWD="$(json '.cwd')"

MSG="Session ${SESSION_ID:-?} stopped. cwd=${CWD:-?} transcript=${TRANSCRIPT_PATH:-?}"

log "notifying operator=$OPERATOR_ID"

if command -v jq >/dev/null 2>&1; then
  PAYLOAD="$(jq -n --arg to "$OPERATOR_ID" --arg msg "$MSG" '{to_id: $to, message: $msg}')"
else
  # Fallback — simple JSON; rely on no special chars in IDs
  PAYLOAD="{\"to_id\":\"$OPERATOR_ID\",\"message\":\"$MSG\"}"
fi

curl -s -m 2 -X POST "$PEERS_API" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  >/dev/null 2>&1 || true

exit 0
