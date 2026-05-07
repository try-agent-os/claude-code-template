#!/bin/bash
# PermissionRequest hook — AgentOS auto-approve for worker sessions
#
# Active ONLY in interactive sessions (not -p + --dangerously-skip-permissions).
# For sysadmin sessions: auto-approve safe operations, deny dangerous ones.
#
# Usage in .claude/settings.json:
#   "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "/path/to/permission-request.sh"}]}]
#
# Exit codes:
#   0 — decision in JSON (allow/deny)
#   2 — blocking error (deny + stderr → Claude)
#   other — non-blocking error (show notice, do not block)

set -uo pipefail

INPUT=$(cat)

# Extract fields from payload
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // "default"')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

# If bypassPermissions — do nothing, Claude already skipped checks
if [[ "$PERMISSION_MODE" == "bypassPermissions" ]]; then
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Response helpers
# ──────────────────────────────────────────────────────────────

allow() {
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
  exit 0
}

deny() {
  local MSG="${1:-Operation blocked by AgentOS policy}"
  jq -n --arg msg "$MSG" '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: {
        behavior: "deny",
        message: $msg
      }
    }
  }'
  exit 0
}

# ──────────────────────────────────────────────────────────────
# AUTO-APPROVE: always-safe tools
# ──────────────────────────────────────────────────────────────

case "$TOOL_NAME" in
  Read|Glob|Grep|LS)
    allow
    ;;

  # MCP tools saga-mcp — task management
  mcp__saga-mcp__*)
    allow
    ;;

  # MCP tools claude-peers — inter-agent communication
  mcp__claude-peers__*|mcp__claude_peers__*)
    allow
    ;;

  # Telegram bot (operator read + send only)
  mcp__plugin_telegram_telegram__*)
    allow
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Bash: command analysis
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Bash" ]]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // ""')

  # DENY: destructive operations
  if echo "$CMD" | grep -qE '(rm\s+-rf|DROP\s+TABLE|DROP\s+DATABASE|mkfs|dd\s+if=|shred|wipefs)'; then
    deny "Destructive operation requires user confirmation: $CMD"
  fi

  # DENY: git push (without explicit permission)
  if echo "$CMD" | grep -qE '^git\s+push(\s+--force|\s+-f)'; then
    deny "git push --force is blocked. Use a regular push with explicit permission."
  fi

  # DENY: curl/wget to external resources outside the allowlist
  if echo "$CMD" | grep -qE '(curl|wget)\s+.*https?://'; then
    ALLOWED_HOSTS="(github\.com|api\.github\.com|code\.claude\.ai|code\.claude\.com|anthropic\.com|npmjs\.com|pypi\.org|localhost|127\.0\.0\.1)"
    if ! echo "$CMD" | grep -qE "$ALLOWED_HOSTS"; then
      deny "HTTP request to an external host requires explicit permission: $CMD"
    fi
  fi

  # ALLOW: git read-only
  if echo "$CMD" | grep -qE '^git\s+(log|status|diff|show|branch|remote|fetch|tag|describe|rev-parse|stash list)'; then
    allow
  fi

  # ALLOW: git add + commit + push (within the repo)
  if echo "$CMD" | grep -qE '^git\s+(add|commit|push)\b'; then
    allow
  fi

  # ALLOW: read-only system utilities
  if echo "$CMD" | grep -qE '^(ls|find|cat|head|tail|wc|echo|printf|date|pwd|which|type|env|printenv|ps|df|du|uname|hostname)\b'; then
    allow
  fi

  # ALLOW: jq, python3, node (scripts)
  if echo "$CMD" | grep -qE '^(jq|python3|python|node|npm run|npx)\b'; then
    allow
  fi

  # ALLOW: tmux read (list, show, display-message)
  if echo "$CMD" | grep -qE '^tmux\s+(ls|list|show|display-message|has-session|info|capture-pane)'; then
    allow
  fi

  # ALLOW: tdl (Telegram read-only export)
  if echo "$CMD" | grep -qE '^tdl\s+(chat\s+(ls|export)|account\s+ls)'; then
    allow
  fi

  # ALLOW: AgentOS memory operations (writes into memory/, logs/, research/)
  # Verify Bash only writes into trusted directories
  if echo "$CMD" | grep -qE '(>|tee|mkdir)\s.*(memory/|logs/|research/|resources/)'; then
    allow
  fi
fi

# ──────────────────────────────────────────────────────────────
# Write/Edit: files inside the AgentOS repo
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // ""')

  WORK_DIR="${CLAUDE_PROJECT_DIR:-${REPO_ROOT:-$PWD}}"

  # ALLOW: writes inside the AgentOS repo
  if [[ "$FILE_PATH" == "$WORK_DIR"* ]] || [[ "$FILE_PATH" == /tmp/* ]]; then
    allow
  fi

  # DENY: writes outside the repo
  deny "Writing outside the AgentOS repo requires confirmation: $FILE_PATH"
fi

# ──────────────────────────────────────────────────────────────
# WebFetch / WebSearch — allow (research task)
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "WebFetch" || "$TOOL_NAME" == "WebSearch" ]]; then
  allow
fi

# ──────────────────────────────────────────────────────────────
# Agent (subagent spawning) — allow
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Agent" ]]; then
  allow
fi

# ──────────────────────────────────────────────────────────────
# MCP tools — allow read-only, careful with writes
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == mcp__* ]]; then
  # Gmail send — requires confirmation
  if echo "$TOOL_NAME" | grep -qE 'gmail_send|gmail_create_draft.*send'; then
    deny "Sending email requires explicit user confirmation"
  fi
  # All other MCP — allow (Google Docs, Sheets, Calendar read — OK)
  allow
fi

# ──────────────────────────────────────────────────────────────
# Everything else — defer to the user (exit 0 with no JSON)
# ──────────────────────────────────────────────────────────────
exit 0
