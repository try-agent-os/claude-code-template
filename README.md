# Claude Code Template — AgentOS starter

> Production-ready multi-agent template for Claude Code. Operator + dispatcher pattern with batteries-included skills.

Готовый стартовый шаблон AgentOS на Claude Code: оркестратор + диспетчер для воркеров, набор переиспользуемых skills, полный Telegram-интерфейс через MCP.

## Что в коробке

- **Operator** (`agents/operator/`) — долгоживущий Claude-агент. Держит tmux-сессию, общается с пользователем через Telegram, маршрутизирует задачи в saga-mcp.
- **Dispatcher** (`agents/dispatcher/`) — эфемерный cron-агент. Запускается по launchd/cron, читает очередь задач, спавнит воркеров (per-task), собирает результаты, умирает за 30 секунд.
- **Skills** (`skills/`) — переиспользуемые процедуры с YAML frontmatter (`read_when`). Workers подключают релевантные скиллы автоматически по ключевым словам задачи. Базовый набор: `morning-brief`, `meeting-prep`, `meeting-debrief`, `contact-enrichment`, `event-correlation`, `memory-search`.
- **MCP integrations** — saga-mcp (task tracker), telegram-mcp (через плагин), claude-peers (межагентная коммуникация через HTTP broker).
- **Hooks** (`agents/dispatcher/hooks/`) — `permission-request.sh` и `compress-tool-output.sh`. PreToolUse/PostToolUse автоматизация.
- **Core rules** (`core/rules.md`) — общие правила безопасности и автономности для всех агентов.

## Архитектура

```
Пользователь (Telegram)
        │
        ▼
   operator (tmux, всегда онлайн) ──► saga-mcp ──► dispatcher (cron) ──► workers (ephemeral tmux)
        ▲                                                                       │
        └────────────────────── claude-peers broker ◄──────────────────────────┘
```

Подробная диаграмма и описание ролей: [`agents/README.md`](./agents/README.md).

## Quick Start

См. [`QUICKSTART.md`](./QUICKSTART.md) — пошаговый гайд от установки Claude Code CLI до первого worker'а, поднятого по cron.

Минимум:

```bash
gh repo clone try-agent-os/claude-code-template my-agents
cd my-agents
# 1. Поднять MCP-серверы (saga-mcp, telegram-mcp, claude-peers broker)
# 2. Заменить плейсхолдеры в agents/operator/CLAUDE.md и agents/dispatcher/CLAUDE.md
# 3. Запустить tmux-сессию operator
# 4. Загрузить launchd plist (или cron) для dispatcher
```

## Зачем это нужно

Claude Code из коробки даёт CLAUDE.md, skills, hooks и MCP — но не даёт шаблон того, как собрать из этого работающую multi-agent систему.

Этот репозиторий — референсная сборка AgentOS: несколько Claude-агентов, кооперирующих через файловую систему (общая память), очередь задач (saga-mcp) и broker межагентной коммуникации (claude-peers). Полностью локальная, без облачной оркестрации, без Docker.

## Требования

- macOS или Linux
- Claude Code CLI (`https://claude.com/code`)
- tmux, jq, python3
- Node.js (для MCP-серверов saga-mcp и claude-peers broker)

## Расширение

Шаблон поставляется минимальным — без специализированных под-агентов (researcher, outreacher, sysadmin) и без доменных скиллов (sales, content, prospect-discovery). Это намеренно: каждая команда добавляет своих под-агентов и скиллы под свой домен.

Чтобы добавить нового под-агента:
1. Создай `agents/{role}/CLAUDE.md` + `SOUL.md`
2. Добавь маршрутизацию в `agents/dispatcher/CLAUDE.md` (секция Agent Routing)
3. `worker-launcher.sh` уже поддерживает любой `agent_type` через `--add-dir`

Чтобы добавить новый скилл:
1. Создай `skills/{skill-name}.md` с YAML frontmatter (`read_when`)
2. Добавь строку в `skills/README.md`
3. Workers подключат скилл автоматически по совпадению ключевых слов в задаче

## Структура репозитория

```
.
├── CLAUDE.md                # Корневой системный промпт оркестратора
├── QUICKSTART.md            # Пошаговый гайд
├── README.md                # Этот файл
├── agents/
│   ├── README.md            # Архитектура и связи между агентами
│   ├── operator/            # Telegram-интерфейс (долгоживущий)
│   │   ├── CLAUDE.md
│   │   ├── SOUL.md
│   │   ├── start.sh
│   │   └── skills/
│   └── dispatcher/          # Эфемерный cron-агент
│       ├── CLAUDE.md
│       ├── SOUL.md
│       ├── README.md
│       ├── dispatcher.sh
│       ├── dispatcher-prompt.md
│       ├── strategist-prompt.md
│       ├── worker-launcher.sh
│       ├── worker-collector.sh
│       ├── worker-prompt-template.md
│       ├── parse-stream.py
│       ├── parse-worker-stream.py
│       ├── agentos.heartbeat-dispatcher.plist
│       └── hooks/
├── skills/                  # Общие процедурные скиллы (на корне)
│   ├── README.md
│   ├── morning-brief.md
│   ├── meeting-prep.md
│   ├── meeting-debrief.md
│   ├── contact-enrichment.md
│   ├── event-correlation.md
│   └── memory-search.md
└── core/
    └── rules.md             # Общие правила безопасности и автономности
```

## License

MIT
