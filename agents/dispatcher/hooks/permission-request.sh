#!/bin/bash
# PermissionRequest hook — AgentOS auto-approve для интерактивных сессий.
#
# Срабатывает ТОЛЬКО в интерактивных сессиях (не -p + --dangerously-skip-permissions).
# Авто-апрув безопасных операций, отклонение опасных.
#
# Использование в .claude/settings.json:
#   "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "/path/to/permission-request.sh"}]}]
#
# Перед использованием: убедись что переменная CLAUDE_PROJECT_DIR указывает на корень AgentOS-репо.
#
# Exit codes:
#   0 — решение в JSON (allow/deny)
#   2 — блокирующая ошибка (deny + stderr → Claude)
#   другие — non-blocking ошибка (показать нотис, не блокировать)

set -uo pipefail

INPUT=$(cat)

# Извлечь поля из payload
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // "default"')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

# Если bypassPermissions — ничего не делаем, Claude уже пропустил проверки
if [[ "$PERMISSION_MODE" == "bypassPermissions" ]]; then
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Функции ответа
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
  local MSG="${1:-Операция заблокирована политикой AgentOS}"
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
# AUTO-APPROVE: всегда безопасные инструменты
# ──────────────────────────────────────────────────────────────

case "$TOOL_NAME" in
  Read|Glob|Grep|LS)
    allow
    ;;

  # MCP tools saga-mcp — управление задачами
  mcp__saga-mcp__*)
    allow
    ;;

  # MCP tools claude-peers — межагентная коммуникация
  mcp__claude-peers__*|mcp__claude_peers__*)
    allow
    ;;

  # Telegram bot — отправка сообщений operator'а
  mcp__telegram__*|mcp__plugin_telegram_telegram__*)
    allow
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Bash: анализ команды
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Bash" ]]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // ""')

  # DENY: деструктивные операции
  if echo "$CMD" | grep -qE '(rm\s+-rf|DROP\s+TABLE|DROP\s+DATABASE|mkfs|dd\s+if=|shred|wipefs)'; then
    deny "Деструктивная операция требует подтверждения пользователя: $CMD"
  fi

  # DENY: git push --force (без явного разрешения)
  if echo "$CMD" | grep -qE '^git\s+push(\s+--force|\s+-f)'; then
    deny "git push --force заблокирован. Используй обычный push с явным разрешением."
  fi

  # DENY: curl/wget к внешним ресурсам кроме белого списка
  if echo "$CMD" | grep -qE '(curl|wget)\s+.*https?://'; then
    ALLOWED_HOSTS="(github\.com|api\.github\.com|code\.claude\.ai|code\.claude\.com|anthropic\.com|npmjs\.com|pypi\.org|localhost|127\.0\.0\.1)"
    if ! echo "$CMD" | grep -qE "$ALLOWED_HOSTS"; then
      deny "HTTP-запрос к внешнему хосту требует явного разрешения: $CMD"
    fi
  fi

  # ALLOW: git read-only
  if echo "$CMD" | grep -qE '^git\s+(log|status|diff|show|branch|remote|fetch|tag|describe|rev-parse|stash list)'; then
    allow
  fi

  # ALLOW: git add + commit + push (в рамках репо)
  if echo "$CMD" | grep -qE '^git\s+(add|commit|push)\b'; then
    allow
  fi

  # ALLOW: системные утилиты чтения
  if echo "$CMD" | grep -qE '^(ls|find|cat|head|tail|wc|echo|printf|date|pwd|which|type|env|printenv|ps|df|du|uname|hostname)\b'; then
    allow
  fi

  # ALLOW: jq, python3, node (скрипты)
  if echo "$CMD" | grep -qE '^(jq|python3|python|node|npm run|npx)\b'; then
    allow
  fi

  # ALLOW: tmux read (list, show, display-message)
  if echo "$CMD" | grep -qE '^tmux\s+(ls|list|show|display-message|has-session|info|capture-pane)'; then
    allow
  fi

  # ALLOW: операции с памятью AgentOS (запись в memory/, logs/)
  if echo "$CMD" | grep -qE '(>|tee|mkdir)\s.*(memory/|logs/)'; then
    allow
  fi
fi

# ──────────────────────────────────────────────────────────────
# Write/Edit: файлы в репо AgentOS
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // ""')

  WORK_DIR="${CLAUDE_PROJECT_DIR:-${AGENTOS_ROOT:-$HOME/Workspaces/agentos}}"

  # ALLOW: запись в репо AgentOS
  if [[ "$FILE_PATH" == "$WORK_DIR"* ]] || [[ "$FILE_PATH" == /tmp/* ]]; then
    allow
  fi

  # DENY: запись за пределами репо
  deny "Запись за пределами репо AgentOS требует подтверждения: $FILE_PATH"
fi

# ──────────────────────────────────────────────────────────────
# WebFetch / WebSearch — разрешаем (research задача)
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "WebFetch" || "$TOOL_NAME" == "WebSearch" ]]; then
  allow
fi

# ──────────────────────────────────────────────────────────────
# Agent (subagent spawning) — разрешаем
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Agent" ]]; then
  allow
fi

# ──────────────────────────────────────────────────────────────
# MCP tools — разрешаем read-only, осторожно с write
# ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == mcp__* ]]; then
  # Gmail send — требует подтверждения
  if echo "$TOOL_NAME" | grep -qE 'gmail_send|gmail_create_draft.*send'; then
    deny "Отправка email требует явного подтверждения пользователя"
  fi
  # Все остальные MCP — разрешаем
  allow
fi

# ──────────────────────────────────────────────────────────────
# Всё остальное — передаем пользователю (exit 0 без JSON)
# ──────────────────────────────────────────────────────────────
exit 0
