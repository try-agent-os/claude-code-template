# AgentOS Agents (os-ru)

Этот каталог содержит публичные шаблоны агентов AgentOS на русском языке. Шаблоны можно скопировать в свой репозиторий, подставить плейсхолдеры — и получить рабочую систему агентов.

## Доступные агенты

| Агент | Роль | Запуск | Где живет |
|-------|------|--------|-----------|
| [`operator/`](operator/) | Telegram-интерфейс между пользователем и системой агентов | Долгоживущая tmux-сессия (`start.sh`) | macOS/Linux |
| [`dispatcher/`](dispatcher/) | Эфемерный dispatcher: запускает workers, собирает результаты, проверяет расписание | launchd (macOS) или cron, периодически | macOS/Linux |

## Как они связаны

```
                  ┌──────────────────┐
                  │   Пользователь   │
                  │  (Telegram)      │
                  └────────┬─────────┘
                           │ сообщения
                           ▼
   ┌────────────────────────────────────────┐
   │              operator                  │  ← долгоживущий, читает Telegram,
   │  (tmux session, всегда онлайн)         │     отвечает пользователю, делегирует
   └────────┬───────────────────────────────┘
            │
            │ saga-mcp (создание задач)
            ▼
   ┌────────────────────────────────────────┐
   │  saga-mcp (task tracker, port 3851)    │
   └────────┬───────────────────────────────┘
            │
            │ task_list (todo)
            ▼
   ┌────────────────────────────────────────┐
   │            dispatcher                  │  ← эфемерный cron-агент,
   │  (launchd / cron, ~раз в час)          │     рождается → читает задачи →
   │  • dispatcher.sh                       │     запускает workers → умирает
   │  • worker-launcher.sh                  │
   │  • worker-collector.sh                 │
   └────────┬───────────────────────────────┘
            │
            │ запуск worker'ов в tmux
            ▼
   ┌────────────────────────────────────────┐
   │  workers (эфемерные tmux-сессии)       │  ← делают работу,
   │  Результат → logs/workers/{id}/        │     пишут в result.md,
   │             result.md                  │     уведомляют operator через
   └────────────────────────────────────────┘     claude-peers broker

                           ▲
                           │
                    ┌──────┴──────┐
                    │ claude-peers│  ← межагентная коммуникация
                    │  (port 7899)│     (HTTP API + MCP tools)
                    └─────────────┘
```

## Что нужно настроить перед запуском

### 1. Корень репозитория

Все скрипты ожидают переменную `AGENTOS_ROOT` — путь к корню AgentOS-репо. Дефолт: `$HOME/Workspaces/agentos`. Перед запуском подставь свой путь либо в env, либо отредактируй plist/cron.

### 2. MCP-серверы

Минимально нужно поднять:

| MCP | Порт | Зачем |
|-----|------|-------|
| **saga-mcp** | `3851` | Task tracker. Эпики, задачи, статусы. |
| **telegram-mcp** | `3848` | Connector к Telegram-боту (для operator). |
| **claude-peers broker** | `7899` | Межагентная HTTP-коммуникация (operator ↔ workers). |

Опционально (workers сами подключают через `--mcp-config`):
- Google Calendar / Gmail / Docs / Sheets — через Composio или напрямую
- Fireflies — для meeting prep/debrief
- ClickUp / Linear — task management
- любые другие коннекторы под твой домен

### 3. Telegram chat_id

В `agents/operator/CLAUDE.md` найди плейсхолдер `<USER_TELEGRAM_CHAT_ID>` и замени на свой Telegram chat_id (узнается через бота, например `@userinfobot`).

### 4. Эпики в saga-mcp

При первом запуске создай эпики в saga-mcp через `mcp__saga-mcp__epic_create`. Базовый набор:

- Business Operations
- Research
- AgentOS Infrastructure
- Scheduled Checks

Запиши их `id` — пригодятся для `epic_id` при создании задач.

### 5. launchd (macOS) — dispatcher

```bash
# 1. Подставь свой путь в plist
sed -i '' 's|/Users/YOU|'"$HOME"'|g' agents/dispatcher/agentos.heartbeat-dispatcher.plist
# 2. Скопируй и загрузи
cp agents/dispatcher/agentos.heartbeat-dispatcher.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/agentos.heartbeat-dispatcher.plist
# 3. Проверь
launchctl list | grep agentos
```

### 6. operator — tmux session

```bash
AGENTOS_ROOT=$HOME/Workspaces/agentos bash agents/operator/start.sh
# Проверь: tmux attach -t operator
```

## Полная настройка

См. `QUICKSTART.md` в корне репозитория (если есть) — там пошаговый гайд от установки CLI до первой задачи.

## Что делать дальше

1. Подними MCP-серверы (saga-mcp, telegram-mcp, claude-peers broker).
2. Замени плейсхолдеры в `operator/CLAUDE.md` и `dispatcher/CLAUDE.md`.
3. Запусти `start.sh` для operator.
4. Загрузи launchd plist для dispatcher.
5. Напиши в Telegram-бота — operator подтвердит получение и создаст задачу.
6. Жди когда dispatcher подхватит задачу и запустит worker.

## Расширение

Шаблон поставляется минимальным — без специализированных под-агентов (researcher, outreacher, sysadmin) и без доменных скиллов (sales, content, prospect-discovery). Это намеренно: каждая команда сама добавляет своих под-агентов и скиллы под свой домен.

Чтобы добавить нового под-агента:
1. Создай `agents/{role}/CLAUDE.md` + `SOUL.md`
2. Добавь маршрутизацию в `agents/dispatcher/CLAUDE.md` (секция Agent Routing)
3. Добавь обработку в `worker-launcher.sh` (она уже поддерживает любой `agent_type` через `--add-dir`)

Чтобы добавить новый скилл:
1. Создай `skills/{skill-name}.md` с YAML frontmatter (`read_when`) в корне репозитория
2. Добавь строку в `skills/README.md`
3. Workers будут подключать его автоматически по совпадению ключевых слов задачи
