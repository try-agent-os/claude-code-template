#!/usr/bin/env bash
# SubagentStop hook — fires when a spawned subagent completes.
#
# Captures: subagent name, duration, token usage if available, into audit log.
# Async — never blocks main agent.

set -uo pipefail

HOOK_NAME="log-subagent"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

# Loop guard — same as Stop hook
if is_stop_loop; then
  exit 0
fi

AUDIT_LOG="${AGENTOS_AUDIT_LOG:-${CLAUDE_PROJECT_DIR}/.claude/audit.log}"
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUBAGENT="$(json '.subagent_type')"
SESSION="$(json '.session_id')"
TURNS="$(json '.turns')"
COST="$(json '.cost_usd')"

log "subagent=$SUBAGENT turns=$TURNS cost=$COST"
printf '%s\tsubagent=%s\tturns=%s\tcost=%s\tsession=%s\n' \
  "$TS" "${SUBAGENT:-?}" "${TURNS:-0}" "${COST:-0}" "${SESSION:-?}" \
  >> "$AUDIT_LOG" 2>/dev/null || true

exit 0
