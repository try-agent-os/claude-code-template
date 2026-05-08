#!/usr/bin/env bash
# PostToolUse hook — audit log for ALL operator tool calls.
#
# Async (configured in settings.json) — never blocks execution.
# Writes one TSV line per tool call to $AGENTOS_HOOKS_LOG_DIR/operator-tool-calls.log:
#   TIMESTAMP  SESSION_ID  TOOL_NAME  TOOL_INPUT_SNIPPET
#
# With --dangerously-skip-permissions this hook is how we retain visibility
# into what operator did — the VPS has no human watching the tmux session.

set -uo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
# Truncate tool_input to 200 chars — prevent huge log lines for Bash/Read
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null | cut -c1-200)

LOG_DIR="${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
printf '%s\t%s\t%s\t%s\n' \
  "$TS" \
  "${SESSION_ID:-?}" \
  "$TOOL_NAME" \
  "${TOOL_INPUT:-{}}" \
  >> "${LOG_DIR}/operator-tool-calls.log" 2>/dev/null || true

exit 0
