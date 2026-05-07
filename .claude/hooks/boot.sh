#!/usr/bin/env bash
# SessionStart hook — fires on session boot (matcher: startup) or after compaction
# (matcher: compact, passed as $1).
#
# - startup: ping MCP brokers and inject health summary as additionalContext.
# - compact: re-read memory/context.md and inject — survives auto-compaction.
#
# Timeout configured in settings.json (5s startup, 3s compact). Don't be slow.
# Exit 2 here does NOT block boot — only stderr is shown to user.

set -uo pipefail

HOOK_NAME="boot"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

MODE="${1:-startup}"
log "mode=$MODE"

case "$MODE" in
  startup)
    PEERS_URL="${CLAUDE_PEERS_HEALTH_URL:-http://127.0.0.1:7899/health}"
    SAGA_URL="${SAGA_MCP_HEALTH_URL:-http://localhost:3851/health}"
    TELEGRAM_URL="${TELEGRAM_MCP_HEALTH_URL:-}"

    STATUS=""
    DOWN=0

    for entry in "peers:$PEERS_URL" "saga:$SAGA_URL" "telegram:$TELEGRAM_URL"; do
      name="${entry%%:*}"
      url="${entry#*:}"
      [ -z "$url" ] && continue
      if curl -sf -m 2 "$url" >/dev/null 2>&1; then
        STATUS="${STATUS}${name}:ok "
      else
        STATUS="${STATUS}${name}:DOWN "
        DOWN=$((DOWN + 1))
      fi
    done

    log "health: ${STATUS:-no-brokers-configured}"

    if [ "$DOWN" -gt 0 ]; then
      allow_with_context "$(printf 'AgentOS infra status: %s. %d broker(s) down — investigate before delegating tasks.' "$STATUS" "$DOWN")"
    fi
    exit 0
    ;;

  compact)
    CONTEXT_FILE="${CLAUDE_PROJECT_DIR}/memory/context.md"
    [ ! -f "$CONTEXT_FILE" ] && exit 0

    # Cap to first 200 lines to avoid blowing fresh context window
    CONTENT="$(head -200 "$CONTEXT_FILE" 2>/dev/null)"
    [ -z "$CONTENT" ] && exit 0

    allow_with_context "$(printf 'Re-injected from memory/context.md (post-compaction):\n\n%s' "$CONTENT")"
    exit 0
    ;;

  *)
    log "WARN: unknown mode '$MODE'"
    exit 0
    ;;
esac
