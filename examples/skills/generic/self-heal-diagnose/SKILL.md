---
name: self-heal-diagnose
description: Автоматическая диагностика сбойного worker'а — читает логи, grep-классифицирует причину краша (rate_limit, mcp_down, too_large, zombie_loop и др.), формирует JSON-диагноз в logs/health/diagnoses/.
when_to_use: Стратегист или health-watchdog обнаружил аномалию (crash_streak >= 3, MAX_ITER, zombie); нужно понять root cause до автофикса; пользователь сказал "диагностируй worker {slug}".
allowed-tools: Read, Grep, Bash, mcp__saga-mcp__task_get, mcp__saga-mcp__task_list
context: fork
agent: Explore
---

# Скилл: Self-Heal Diagnose (Уровень 2: DIAGNOSE)

> Read-only diagnostic skill (forked context). Анализирует логи и возвращает diagnosis JSON. Сам ничего не чинит — это делает `self-heal-autofix`.

**Назначение:** Автоматическая диагностика сбойного worker'а до попытки фикса.
**Триггер:** Вызывается стратегистом или health-watchdog при обнаружении аномалии (crash_streak >= 3, MAX_ITER, zombie).
**Выход:** `logs/health/diagnoses/{task_slug}-{timestamp}.json` с классифицированной причиной.

---

## Входные параметры

- `task_slug` — slug сбойной задачи (например, `mob-prosp-disc2`)
- `saga_task_id` — ID задачи в saga-mcp (если известен)
- `crash_count` — число сбоев подряд

---

## Алгоритм диагностики

### Шаг 1: Найти логи worker'а

```bash
# Найти все итерационные логи
ls -t "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/iter-*-output.txt" 2>/dev/null | head -5

# Если нет iter логов — поискать общий лог
ls -t "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/" 2>/dev/null
cat "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/output.log" 2>/dev/null | tail -100
```

### Шаг 2: Прочитать последние 100 строк вывода

```bash
cat "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/iter-*-output.txt" 2>/dev/null | tail -100
# или если один файл:
tail -100 "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/iter-1-output.txt" 2>/dev/null
```

### Шаг 3: Grep-паттерны для классификации

Запустить каждый grep, записать matches:

```bash
LOGFILE="${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/iter-*-output.txt"

# Rate limit / перегрузка API
grep -i "rate.limit\|429\|too many requests\|overloaded\|retry after" $LOGFILE

# Auth / токен истек
grep -i "unauthorized\|401\|invalid.*token\|auth.*failed\|authentication" $LOGFILE

# MCP не найден или упал
grep -i "mcp.*not found\|tool.*not found\|connection refused\|ECONNREFUSED\|mcp.*unavailable\|localhost.*refused" $LOGFILE

# Задача слишком большая
grep -i "max.iter\|MAX_ITERATIONS\|maximum.*iteration\|too many.*step" $LOGFILE

# Нет задачи в очереди / рассинхрон
grep -i "no matching task\|queue.*empty\|no task.*found\|orphan" $LOGFILE

# Zombie / таймаут
grep -i "zombie\|timeout\|killed\|timed out\|hung" $LOGFILE
```

### Шаг 4: Проверить инфраструктуру (если diagnosis_type = unknown)

Текущий статус launchd сервисов: !`launchctl list | grep -E 'novostudio|agentos' || echo "no agentos services found"`

```bash
# Здоровье MCP серверов (адаптируй порты под свой стек)
curl -s --max-time 3 http://localhost:3848/health 2>&1  # telegram-mcp
curl -s --max-time 3 http://localhost:3851/health 2>&1  # saga-mcp
curl -s --max-time 3 http://127.0.0.1:7899/health 2>&1  # claude-peers
```

---

## Классификация (diagnosis_type)

| Паттерн найден | diagnosis_type | auto_fixable | escalation_level |
|---------------|---------------|-------------|-----------------|
| `rate limit` / `429` / `overloaded` | `rate_limit` | true | 0 |
| `unauthorized` / `401` / `invalid token` | `auth_expired` | false | 2 |
| `MCP.*not found` / `ECONNREFUSED.*3851\|3848\|7899` | `mcp_down` | true | 1 |
| `MAX_ITERATIONS` / `max.iter` | `too_large` | true | 1 |
| `no matching task` / `queue.*empty` | `orphan` | true | 0 |
| `zombie` / `killed` + повторно | `zombie_loop` | true | 1 |
| Ничего не найдено | `unknown` | false | 2 |

### escalation_level значения
- `0` — авто-фикс без уведомлений
- `1` — авто-фикс + уведомить operator
- `2` — эскалация sysadmin + уведомить operator

---

## Шаг 5: Сформировать и записать диагноз

### Формат JSON

```json
{
  "task_slug": "mob-prosp-disc2",
  "saga_task_id": 143,
  "crash_count": 6,
  "timestamp": "2026-04-08T10:17:00Z",
  "diagnosis_type": "mcp_down",
  "root_cause": "MCP connection refused at localhost:3851 (saga-mcp)",
  "evidence": [
    "ECONNREFUSED at localhost:3851",
    "MCP tool saga-mcp__task_list: connection error"
  ],
  "infrastructure_healthy": false,
  "auto_fixable": true,
  "escalation_level": 1,
  "recommended_action": "RB-001: launchctl kickstart com.novostudio.saga-mcp"
}
```

### Путь для записи

```bash
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUTFILE="${CLAUDE_PROJECT_DIR}/logs/health/diagnoses/{task_slug}-${TIMESTAMP}.json"
```

Записать JSON в файл через heredoc или Write tool.

---

## Шаг 6: Определить recommended_action

| diagnosis_type | recommended_action |
|---------------|-------------------|
| `rate_limit` | `WAIT: pause task 1h, retry later` |
| `auth_expired` | `ESCALATE: manual re-auth required, block task` |
| `mcp_down` | `RB-001: launchctl kickstart {failed_mcp_service}` |
| `too_large` | `RB-002: decompose task into 3-5 subtasks <= 15 iterations` |
| `orphan` | `RB-003: saga task_update id={id} status=todo` |
| `zombie_loop` | `RB-005: kill worker tmux session + reset in_progress tasks` |
| `unknown` | `ESCALATE: full sysadmin review, attach logs` |

---

## Пример вывода

После вызова скилла:
1. Файл `logs/health/diagnoses/mob-prosp-disc2-20260408T101700.json` создан
2. Залоггировано в `logs/health/diagnoses/` для аудита
3. Диагноз возвращается вызывающему для принятия решения о фиксе

---

## Связанные скиллы

- `health-watchdog` — вызывает этот скилл при обнаружении аномалии
- `self-heal-autofix` — следующий шаг: выполняет autofix на основе diagnosis_type
