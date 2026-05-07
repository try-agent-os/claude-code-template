#!/usr/bin/env bash
# PostToolUse hook for Edit/Write/MultiEdit — auto-format and audit-log.
#
# Async (configured in settings.json) — never blocks the agent loop.
# Two phases:
#   1. Auto-format edited file via available formatter (biome → prettier → ruff → ...).
#   2. Append edit metadata to audit log for post-mortem.
# Both are no-op-on-failure — never escalates to a hook error.

set -uo pipefail

HOOK_NAME="log-action"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

PATH_FIELD="$(tool_input_field 'file_path')"
[ -z "$PATH_FIELD" ] && PATH_FIELD="$(tool_input_field 'path')"
[ -z "$PATH_FIELD" ] && exit 0
[ ! -f "$PATH_FIELD" ] && exit 0

log "$PATH_FIELD"

# --- Phase 1: format ---
EXT="${PATH_FIELD##*.}"
DIR="$(dirname "$PATH_FIELD")"
cd "$DIR" 2>/dev/null || exit 0

format() {
  local file="$1"
  case "$EXT" in
    ts|tsx|js|jsx|json|css|scss|md|yaml|yml)
      if [ -f "$PWD/biome.json" ] || [ -f "$PWD/biome.jsonc" ]; then
        if [ -x "$PWD/node_modules/.bin/biome" ]; then
          "$PWD/node_modules/.bin/biome" format --write "$file" 2>/dev/null
          return
        elif command -v biome >/dev/null 2>&1; then
          biome format --write "$file" 2>/dev/null
          return
        fi
      fi
      if [ -x "$PWD/node_modules/.bin/prettier" ]; then
        "$PWD/node_modules/.bin/prettier" --write "$file" 2>/dev/null
      elif command -v prettier >/dev/null 2>&1; then
        prettier --write "$file" 2>/dev/null
      fi
      ;;
    py)
      if command -v ruff >/dev/null 2>&1; then
        ruff format "$file" 2>/dev/null
      elif command -v black >/dev/null 2>&1; then
        black "$file" 2>/dev/null
      fi
      ;;
    go)  command -v gofmt >/dev/null 2>&1 && gofmt -w "$file" 2>/dev/null ;;
    rs)  command -v rustfmt >/dev/null 2>&1 && rustfmt "$file" 2>/dev/null ;;
    sh|bash) command -v shfmt >/dev/null 2>&1 && shfmt -w "$file" 2>/dev/null ;;
  esac
}

format "$PATH_FIELD" || true

# --- Phase 2: audit log ---
AUDIT_LOG="${AGENTOS_AUDIT_LOG:-${CLAUDE_PROJECT_DIR}/.claude/audit.log}"
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || exit 0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TOOL="$(json '.tool_name')"
SESSION="$(json '.session_id')"
printf '%s\t%s\t%s\t%s\n' "$TS" "${SESSION:-?}" "${TOOL:-?}" "$PATH_FIELD" >> "$AUDIT_LOG" 2>/dev/null || true

exit 0
