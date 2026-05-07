#!/bin/bash
# Operator agent launcher (tmux session).
#
# Подставь свои значения перед использованием:
#   AGENTOS_ROOT — корень AgentOS-репозитория
#   PEERS_HEALTH / TG_HEALTH — health endpoints MCP-серверов (дефолты ниже)
#
# Что делает:
#   1. Перезапускает tmux-сессию `operator` (если уже есть — убивает)
#   2. Поднимает зависимые launchd-сервисы (если не запущены)
#   3. Ждет health endpoint'ы
#   4. Стартует Claude Code в tmux с нужными --add-dir и --dangerously-load-development-channels
#   5. Проверяет что operator зарегистрировался в claude-peers как peer

set -euo pipefail

AGENTOS_ROOT="${AGENTOS_ROOT:-$HOME/Workspaces/agentos}"
SESSION="operator"
PEERS_HEALTH="${PEERS_HEALTH:-http://127.0.0.1:7899/health}"
TG_HEALTH="${TG_HEALTH:-http://localhost:3848/health}"

# Подставь свои labels launchd, если используешь автозапуск MCP-серверов.
# По умолчанию — пустой список: считаем что сервисы уже подняты вручную.
LAUNCHD_LABELS=()  # пример: ("com.example.claude-peers-broker" "com.example.telegram-mcp")

# Kill existing session if running
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[operator] Killing existing session..."
  tmux kill-session -t "$SESSION"
  sleep 1
fi

# Ensure launchd services are up (если настроены)
for label in "${LAUNCHD_LABELS[@]}"; do
  if ! launchctl list "$label" &>/dev/null; then
    echo "[operator] Loading $label..."
    launchctl load "$HOME/Library/LaunchAgents/${label}.plist"
    sleep 2
  fi
done

# Wait for services
for url in "$PEERS_HEALTH" "$TG_HEALTH"; do
  for i in {1..10}; do
    if curl -sf "$url" &>/dev/null; then break; fi
    echo "[operator] Waiting for $url..."
    sleep 1
  done
done

# Start operator
echo "[operator] Starting tmux session..."
tmux new-session -d -s "$SESSION" -c "$AGENTOS_ROOT/agents/operator" \
  "claude --dangerously-skip-permissions \
   --add-dir $AGENTOS_ROOT/memory --add-dir $AGENTOS_ROOT/agents \
   --dangerously-load-development-channels server:claude-peers \
   --dangerously-load-development-channels server:telegram"

sleep 5
tmux send-keys -t "$SESSION" Enter
sleep 8
tmux send-keys -t "$SESSION" "boot" Enter

echo "[operator] Started. Verifying..."
sleep 15

# Verify peer registration
PEERS=$(curl -s http://127.0.0.1:7899/list-peers \
  -H 'Content-Type: application/json' \
  -d '{"scope":"machine","cwd":"/","git_root":null}' | \
  grep -c operator 2>/dev/null || echo 0)

if [ "$PEERS" -gt 0 ]; then
  echo "[operator] OK — registered as peer"
else
  echo "[operator] WARNING — not registered as peer yet (may need more time)"
fi
