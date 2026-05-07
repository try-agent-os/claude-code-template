#!/usr/bin/env bash
# UserPromptSubmit hook — opportunity to inject context before Claude processes prompt.
#
# Default behavior:
#   - If memory/today.md exists, inject as additionalContext (1 line summary).
#   - If saga task is "in_progress" for this agent, inject task ID.
#
# Tight timeout (2s). Fast-fail if any check is slow.
# Disabled side-effects: don't spawn subprocesses; only read local files.

set -uo pipefail

HOOK_NAME="enrich-prompt"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

CONTEXT=""

# Check for daily snapshot
TODAY_FILE="${CLAUDE_PROJECT_DIR}/memory/today.md"
if [ -f "$TODAY_FILE" ]; then
  # First non-empty line as terse pulse
  PULSE="$(grep -m 1 -v '^[[:space:]]*$' "$TODAY_FILE" 2>/dev/null | head -c 200)"
  if [ -n "$PULSE" ]; then
    CONTEXT="${CONTEXT}Today: ${PULSE}\n"
  fi
fi

# Check for in-progress saga task hint (project-specific stub)
ACTIVE_TASK_FILE="${CLAUDE_PROJECT_DIR}/memory/active-task.md"
if [ -f "$ACTIVE_TASK_FILE" ]; then
  TASK="$(head -c 300 "$ACTIVE_TASK_FILE" 2>/dev/null)"
  if [ -n "$TASK" ]; then
    CONTEXT="${CONTEXT}Active task:\n${TASK}\n"
  fi
fi

if [ -n "$CONTEXT" ]; then
  log "enriching with $(printf '%s' "$CONTEXT" | wc -c) bytes"
  allow_with_context "$CONTEXT"
fi

# No context to inject — silent exit
exit 0
