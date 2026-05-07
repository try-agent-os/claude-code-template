---
name: strategist-health-watchdog
description: Health Watchdog (L1 DETECT) — детектирует системные аномалии AgentOS (crash_streak, zombie rate, dispatcher gap, MCP health, orphan задачи). Создает задачи в saga-mcp и уведомляет operator при critical.
when_to_use: Начало каждого цикла стратегиста; выполнять первым для оценки здоровья системы перед бизнес-задачами.
allowed-tools: Read, Bash, mcp__saga-mcp__task_list, mcp__saga-mcp__task_create, mcp__claude-peers__list_peers, mcp__claude-peers__send_message
---

# Health Watchdog Skill

> Часть strategist-цикла. Запускается первым перед business-analysis и signal-analysis.

**Назначение:** Детектировать системные аномалии AgentOS (Уровень 1: DETECT).

**Источники:** `memory/worker-errors.log` (ошибки), `memory/worker-activity.log` (dispatcher_gap), saga-mcp, launchd, MCP health endpoints.

---

## Алгоритм

### Шаг 1: Читай логи ошибок и активности

```bash
tail -50 "${CLAUDE_PROJECT_DIR}/memory/worker-errors.log"
tail -20 "${CLAUDE_PROJECT_DIR}/memory/worker-activity.log"
```

Группируй строки worker-errors.log по `task_slug`. Для каждого slug считай:
- `crash_streak` — сколько раз подряд встречается "crashed" или "zombie"
- `max_iter_count` — сколько раз встречается "MAX_ITERATIONS" в последних 50 строках
- `zombie_count` — сколько раз встречается "zombie"

Из всех строк worker-errors.log определи **окно последних 2 часов**:
- Найди строки с timestamp >= (текущее_время - 2ч)
- Посчитай: `total_workers_2h`, `crashed_2h`, `max_iter_2h`, `zombie_2h`

**Для dispatcher_gap:** используй `memory/worker-activity.log` (НЕ worker-errors.log).
Найди последнюю строку с `dispatcher_start` — это timestamp последнего реального запуска dispatcher'а.

### Шаг 2: Проверь очередь в saga-mcp

```
mcp__saga-mcp__task_list(status: "in_progress")
mcp__saga-mcp__task_list(status: "todo")
```

Посчитай:
- `in_progress_count` — задач сейчас в работе
- `todo_count` — задач ожидают в очереди
- `saga_orphan_count` — in_progress задачи, которые не обновлялись > 2ч (поле updated_at)

### Шаг 3: Проверь launchd

Текущий статус сервисов: !`launchctl list | grep -E 'novostudio|agentos' || echo "no agentos services"`

Ключевые сервисы (адаптируй под свой стек): `com.novostudio.heartbeat-dispatcher`, `com.novostudio.strategist`, `com.novostudio.saga-mcp`, `com.novostudio.telegram-mcp`, `com.novostudio.claude-peers`.

### Шаг 4: Проверь MCP health

```bash
curl -s http://localhost:3851/health     # saga-mcp
curl -s http://localhost:3848/health     # telegram-mcp
curl -s http://127.0.0.1:7899/health     # claude-peers
```

### Шаг 5: Рассчитай метрики и проверь пороги

| Метрика | Формула | Порог аномалии |
|---------|---------|----------------|
| `crash_streak[task]` | max подряд идущих "crashed"/"zombie" для одного slug | >= 3 |
| `max_iter_rate` | `max_iter_2h / total_workers_2h` | >= 0.40 (40%) |
| `crash_rate` | `(crashed_2h + zombie_2h) / total_workers_2h` | >= 0.40 (40%) |
| `zombie_rate` | `zombie_2h / total_workers_2h` | >= 0.30 (30%) |
| `dispatcher_gap` | время с последнего dispatcher_start | > 45 мин |
| `queue_depth` | `todo_count` без новых запусков | > 15 |
| `saga_orphan` | `saga_orphan_count` | > 3 |

Если `total_workers_2h == 0` — dispatcher_gap считается главным индикатором.

### Шаг 6: При обнаружении аномалии

**6.1. Запиши health snapshot:**

```bash
mkdir -p "${CLAUDE_PROJECT_DIR}/logs/health"
```

Создай или обнови файл `logs/health/$(date +%Y-%m-%d-%H).json`:

```json
{
  "timestamp": "<ISO datetime>",
  "heartbeat_count": <N>,
  "metrics": {
    "crash_rate_2h": <float>,
    "max_iter_rate_2h": <float>,
    "zombie_rate_2h": <float>,
    "total_workers_2h": <int>,
    "dispatcher_gap_min": <int>,
    "todo_count": <int>,
    "in_progress_count": <int>,
    "saga_orphan_count": <int>
  },
  "anomalies": [
    {"type": "<аномалия>", "value": <значение>, "threshold": <порог>, "details": "<slug или сервис>"}
  ],
  "infrastructure": {
    "saga_mcp": "<ok|down>",
    "telegram_mcp": "<ok|down>",
    "claude_peers": "<ok|down>",
    "launchd_errors": ["<service>"]
  }
}
```

**6.2. Создай задачу в saga-mcp:**

```
mcp__saga-mcp__task_create(
  epic_id: <infra_epic>,
  title: "Self-heal: <тип аномалии> — <краткое описание>",
  description: "**Аномалия:** <метрика> = <значение> (порог: <порог>)\n\n**Данные:** <детали>\n\n**Время:** <timestamp>\n\n**Рекомендуемое действие:** <из таблицы ниже>",
  priority: "high"
)
```

**6.3. Уведоми operator (только при critical-аномалии):**

Critical = любое из:
- `crash_streak` >= 3 для любого task_slug
- `crash_rate_2h` >= 0.40
- Любой MCP сервис недоступен
- `dispatcher_gap` > 45 мин

```
list_peers(scope: "machine")
# найди peer с cwd содержащим "operator"
send_message(to_id: <operator_peer_id>, message: "[HEALTH ALERT] <тип аномалии>\nСимптом: <метрика> = <значение>\nЗадача: saga #<task_id>")
```

### Шаг 7: Если аномалий нет

Если все метрики в норме:
- НЕ создавай задачи в saga
- НЕ уведомляй operator
- Запиши краткую строку в `logs/health/watchdog.log`:
  ```
  <ISO datetime> | OK | workers_2h=<N> crash_rate=<X>% max_iter_rate=<X>%
  ```
- Продолжай обычный алгоритм стратегиста

---

## Рекомендуемые действия по типу аномалии

| Аномалия | Рекомендуемое действие |
|----------|----------------------|
| `crash_streak >= 3` | Заблокировать задачу в saga, добавить причину. Не retry. |
| `max_iter_rate >= 40%` | Декомпозировать крупные задачи. Задача "decompose" в infra epic. |
| `crash_rate >= 40%` | Проверить MCP доступность. Задача "diagnose". |
| `zombie_rate >= 30%` | Zombie flood — kill все worker-* tmux сессии, reset in_progress. |
| `dispatcher_gap > 45 мин` | `launchctl kickstart -k gui/$(id -u)/com.novostudio.heartbeat-dispatcher`. |
| `queue_depth > 15` | Остановить scheduled-задачи, приоритизировать user tasks. |
| `saga_orphan > 3` | Reset: `task_update(status: "todo")` для каждой orphan. |
| `MCP down` | Kickstart соответствующий сервис. |

---

## Связанные скиллы

- `self-heal-diagnose` — L2 (вызывается при аномалии)
- `self-heal-autofix` — L3 (применяет runbook)
