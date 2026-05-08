#!/usr/bin/env bash
# PermissionRequest hook — auto-allow all tool calls in operator sessions.
#
# Operator runs 24/7 headless on a VPS. Any interactive permission prompt
# causes a freeze with no human to unblock it.
#
# This is belt-and-suspenders alongside --dangerously-skip-permissions in the
# systemd unit. With that flag the mode is already "bypassPermissions" and this
# hook exits early. The hook only fires if someone starts operator without that
# flag (e.g. manual test run) — in that case we still auto-allow everything so
# the agent keeps running unattended.
#
# Exit codes:
#   0 — decision emitted as JSON (allow)
#   other — non-blocking error; Claude shows a notice but continues

set -uo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
PERMISSION_MODE=$(printf '%s' "$INPUT" | jq -r '.permission_mode // "default"' 2>/dev/null || echo "default")

# Already in bypass mode — nothing to decide, exit without output
if [[ "$PERMISSION_MODE" == "bypassPermissions" ]]; then
  exit 0
fi

# Log unexpected permission requests (shouldn't happen in normal headless ops)
LOG_DIR="${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
printf '%s PERMISSION_REQUEST mode=%s tool=%s\n' \
  "$TS" "$PERMISSION_MODE" "$TOOL_NAME" \
  >> "${LOG_DIR}/operator-permission.log" 2>/dev/null || true

# Auto-allow — operator must never block waiting for human input
jq -n '{
  hookSpecificOutput: {
    hookEventName: "PermissionRequest",
    decision: { behavior: "allow" }
  }
}'

exit 0
