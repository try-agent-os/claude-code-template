#!/bin/bash
# PostToolUse: compress heavy tool outputs in worker context
# Only active when AGENTOS_WORKER_MODE=1 to avoid affecting interactive sessions
# Supports: Bash (ANSI removal, git log truncation), saga-mcp task_list/tracker_dashboard
#
# Output format: JSON with hookSpecificOutput.toolOutputOverride
# Empty exit 0 = pass through original output unchanged

set -uo pipefail

# Only active in worker mode
[[ "${AGENTOS_WORKER_MODE:-0}" == "1" ]] || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# Extract text from tool_response (handles both Bash-style and MCP-style)
extract_text() {
    local inp="$1"
    local text
    text=$(echo "$inp" | jq -r '.tool_response.text // empty' 2>/dev/null)
    if [[ -z "${text:-}" ]]; then
        text=$(echo "$inp" | jq -r '.tool_response.content[0].text // empty' 2>/dev/null)
    fi
    echo "${text:-}"
}

emit_override() {
    local text="$1"
    echo "$text" | jq -Rs '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        toolOutputOverride: {
          type: "text",
          text: .
        }
      }
    }'
}

case "$TOOL_NAME" in
  Bash)
    RAW=$(extract_text "$INPUT")
    [[ -z "${RAW:-}" ]] && exit 0

    # Remove ANSI escape codes
    CLEAN=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*[mGKHFJABCDsu]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\x1b[()]//g')

    LINE_COUNT=$(echo "$CLEAN" | wc -l | tr -d ' ')

    # Detect git log and truncate to 20 lines
    if echo "$CLEAN" | head -5 | grep -qE "^commit [0-9a-f]{40}|^[0-9a-f]{7,12} .*(ago|2026|2025)|Author:|Date:"; then
      if [[ $LINE_COUNT -gt 20 ]]; then
        TRUNCATED=$(echo "$CLEAN" | head -20)
        CLEAN="${TRUNCATED}
[...git log truncated: showing 20 of ${LINE_COUNT} lines]"
      fi
    fi

    # Squeeze multiple blank lines and cap total output at 300 lines
    CLEAN=$(echo "$CLEAN" | cat -s | head -300)

    emit_override "$CLEAN"
    ;;

  mcp__saga-mcp__task_list)
    RAW=$(extract_text "$INPUT")
    [[ -z "${RAW:-}" ]] && exit 0

    COMPACT=$(echo "$RAW" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    data = json.loads(raw)
    if isinstance(data, list):
        result = [{'id': t.get('id'), 'title': t.get('title',''), 'status': t.get('status',''), 'priority': t.get('priority','')} for t in data]
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(raw[:3000])
except Exception:
    print(raw[:3000])
" 2>/dev/null) || COMPACT=""

    emit_override "${COMPACT:-$RAW}"
    ;;

  mcp__saga-mcp__tracker_dashboard)
    RAW=$(extract_text "$INPUT")
    [[ -z "${RAW:-}" ]] && exit 0

    COMPACT=$(echo "$RAW" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        keys = ['stats','summary','total','epics','in_progress','todo','done','blocked','high_priority']
        result = {k: data[k] for k in keys if k in data}
        if result:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            # Truncate long string values
            out = {}
            for k, v in data.items():
                out[k] = v[:300] + '...' if isinstance(v, str) and len(v) > 300 else v
            print(json.dumps(out, ensure_ascii=False)[:3000])
    else:
        # Plain text dashboard: keep first 80 lines
        lines = raw.split('\n')[:80]
        print('\n'.join(lines))
except Exception:
    lines = raw.split('\n')[:80]
    print('\n'.join(lines))
" 2>/dev/null) || COMPACT=""

    emit_override "${COMPACT:-$(echo "$RAW" | head -80)}"
    ;;

  *)
    # All other tools: pass through unchanged
    exit 0
    ;;
esac
