#!/usr/bin/env bash
# Shared helpers for AgentOS hook scripts. Source from each hook:
#   . "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
#
# Provides: read_input(), log(), json(), tool_input_field(), block(),
# allow_with_context(), is_stop_loop()
#
# Convention: each hook reads stdin once via read_input(), then operates on
# the global INPUT variable. Logs go to ${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}/<hook>.log.

# read_input
# Read stdin (Claude Code hook payload as JSON) into INPUT global. Idempotent.
read_input() {
  if [ -z "${INPUT:-}" ]; then
    INPUT="$(cat || true)"
    export INPUT
  fi
}

# log <message>
# Append timestamped line to per-hook log file.
# Falls back silently if logging fails — never block hook on log error.
log() {
  local hook_name="${HOOK_NAME:-unknown}"
  local log_dir="${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '[%s] %s\n' "$ts" "$*" >> "${log_dir}/${hook_name}.log" 2>/dev/null || true
}

# json <jq-expression>
# Extract field from $INPUT via jq. Returns empty string if jq missing or absent.
json() {
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "${INPUT:-}" | jq -r "$1 // empty" 2>/dev/null
}

# tool_input_field <field>
# Extract a field from .tool_input (PreToolUse/PostToolUse only).
tool_input_field() {
  json ".tool_input.$1"
}

# block <reason>
# Emit blocking decision JSON to stdout + send reason to stderr + exit 2.
# Claude sees the reason as feedback. Only effective in PreToolUse.
block() {
  local reason="$1"
  log "BLOCK: $reason"
  cat <<JSON
{
  "decision": "block",
  "reason": $(printf '%s' "$reason" | jq -Rs . 2>/dev/null || printf '"%s"' "$reason")
}
JSON
  echo "$reason" >&2
  exit 2
}

# allow_with_context <text>
# Emit additionalContext for Claude (meaningful for SessionStart, UserPromptSubmit).
allow_with_context() {
  local ctx="$1"
  log "CONTEXT: ${ctx:0:80}..."
  if command -v jq >/dev/null 2>&1; then
    cat <<JSON
{
  "hookSpecificOutput": {
    "additionalContext": $(printf '%s' "$ctx" | jq -Rs .)
  }
}
JSON
  else
    # Fallback: plain text, only useful for SessionStart/UserPromptSubmit which
    # accept stdout text as additionalContext directly.
    printf '%s\n' "$ctx"
  fi
  exit 0
}

# is_stop_loop
# Return 0 if this Stop/SubagentStop hook is firing inside an existing activation.
# These hooks MUST exit 0 immediately if true to avoid infinite loops.
is_stop_loop() {
  local active
  active="$(json '.stop_hook_active')"
  [ "$active" = "true" ]
}
