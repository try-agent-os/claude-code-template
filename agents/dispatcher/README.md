# Dispatcher — Ephemeral Cron Agent

Cron/launchd-based dispatcher для AgentOS. Запускается периодически (по умолчанию каждые 45-60 мин), выполняет один цикл, завершается. Между циклами памяти нет — все состояние на диске.

## Запуск

### macOS (launchd)

```bash
# Подставь свой путь и подгрузи plist
sed -i '' 's|/Users/YOU|/Users/$(whoami)|g' agentos.heartbeat-dispatcher.plist
cp agentos.heartbeat-dispatcher.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/agentos.heartbeat-dispatcher.plist
```

### Linux/macOS (cron)

```cron
*/45 * * * * AGENTOS_ROOT=$HOME/Workspaces/agentos $HOME/Workspaces/agentos/agents/dispatcher/dispatcher.sh
```

## Алгоритм цикла

1. Инкремент `heartbeat_count` в `memory/context.md`
2. Сбор результатов workers (`worker-collector.sh`)
3. Маршрутизация новых задач из saga-mcp → запуск workers
4. Проверка расписания (`memory/schedule.md` если есть)
5. Watchdog (зависшие workers, потерянные задачи, crash-streak)
6. Strategist (опционально, если настроен)
7. Git commit + push
8. Уведомление operator через claude-peers (только важные события)

Подробности: [`dispatcher-prompt.md`](dispatcher-prompt.md)

## Структура

```
agents/dispatcher/
  CLAUDE.md                          # Контекст для auto-discovery
  SOUL.md                            # Идентичность агента
  dispatcher.sh                      # Cron entry point (atomic lock)
  dispatcher-prompt.md               # Алгоритм dispatcher
  strategist-prompt.md               # Промпт strategist worker (опционально)
  worker-launcher.sh                 # Запуск worker в tmux
  worker-collector.sh                # Сбор результатов workers
  worker-prompt-template.md          # Шаблон промпта для workers
  parse-stream.py                    # Парсер stream-json (dispatcher)
  parse-worker-stream.py             # Парсер stream-json + cost-tracking (workers)
  agentos.heartbeat-dispatcher.plist # launchd plist (шаблон с YOU/agentos плейсхолдерами)
  hooks/                             # PreToolUse/PostToolUse хуки
    permission-request.sh
    compress-tool-output.sh

skills/                              # Общие процедурные скиллы (на корне репозитория)
  README.md
  morning-brief.md
  meeting-prep.md
  meeting-debrief.md
  contact-enrichment.md
  event-correlation.md
  memory-search.md
```

## Зависимости

- Claude Code CLI (`claude`) — `https://claude.com/code`
- tmux (для workers)
- launchd (macOS) или cron
- jq (парсинг JSON)
- python3 (парсеры stream-json)
- saga-mcp (task tracker, на `localhost:3851`)
- claude-peers broker (межагентная коммуникация, на `localhost:7899`) — опционально, но рекомендуется
