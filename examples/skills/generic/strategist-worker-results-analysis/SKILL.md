---
name: strategist-worker-results-analysis
description: Reflexion — читает все result.md workers за последние 7 дней, находит системные паттерны ошибок/успехов, записывает в patterns-staging.md, создает задачи на системные проблемы в saga-mcp.
when_to_use: heartbeat_count % 5 == 0 (каждые 5 стратегист-циклов ~50 heartbeat); нужна рефлексия для закрытия петли обратной связи.
allowed-tools: Read, Edit, Write, Grep, Bash, mcp__saga-mcp__task_create
---

# Скилл: Анализ результатов workers (Reflexion)

Цикл рефлексии: стратегист читает результаты всех workers за последние N циклов, находит паттерны ошибок и успехов, замыкает петлю обратной связи.

**Когда запускать:** `heartbeat_count % 5 == 0` (каждые 5 стратегист-циклов, т.е. каждые ~50 heartbeat-циклов).

## Алгоритм

### 1. Сбор result.md

Прочитай все `${CLAUDE_PROJECT_DIR}/logs/workers/*/result.md`. Claude Code имеет доступ к чтению этих файлов без дополнительных флагов.

Для каждого result.md зафиксируй:
- `task_id` (название директории)
- `status`: done | partial | blocked | failed (из frontmatter)
- `summary` (из frontmatter)
- Дату создания файла (из git log или frontmatter если есть)

Сфокусируйся на результатах за последние 5-7 дней, чтобы не обрабатывать одно и то же несколько раз.

### 2. Группировка паттернов

Разбей результаты на категории:

**Ошибки (status: blocked | failed):**
- Найди задачи с одинаковым типом ошибки (zombie worker, timeout, MCP недоступен, sandbox ограничения)
- Если одна и та же ошибка встречается 2+ раз → системная проблема
- Если задача blocker 2+ попытки → добавь в список для эскалации

**Успехи (status: done | partial):**
- Найди задачи с хорошим результатом (summary содержит конкретные цифры, артефакты, инсайты)
- Выяви что сработало: какой тип задачи, какой skill, какой подход
- Если паттерн успеха повторился 2+ раз → кандидат для промоушена

**Незавершенные / timeout:**
- Задачи которые достигли MAX_ITERATIONS или TIMEOUT
- Это сигнал о неправильном scope или слишком большом объеме задачи

### 3. Запись паттернов в staging

Для каждого найденного паттерна (ошибочного или успешного) добавь запись в `${CLAUDE_PROJECT_DIR}/memory/patterns-staging.md`:

```
---
date: YYYY-MM-DD
task_id: strategist-reflexion
pattern: краткое описание паттерна (одно предложение)
confidence: 0.7
confirmed_in:
  - logs/workers/{task_id_1}/result.md
  - logs/workers/{task_id_2}/result.md
notes: контекст — почему это паттерн, не разовое событие
---
```

Минимальный порог: паттерн подтвержден в 2+ result.md. Разовое событие — не паттерн.

### 4. Системные проблемы → задача в saga-mcp

Если обнаружена системная проблема (3+ задач с одним типом ошибки), создай задачу:

```
mcp__saga-mcp__task_create(
  epic_id: <infra_epic>,
  title: "Fix: <краткое описание проблемы>",
  description: "Системная проблема обнаружена reflexion-анализом:\n\n<детали>\n\nПострадавшие workers: <список task_id>\n\nScope: выяснить root cause и устранить",
  priority: "high"
)
```

### 5. Результат в итог стратегиста

Добавь секцию в итоговый отчет стратегиста:

```markdown
## Worker Reflexion
- Проанализировано result.md: N
- Успешных: N (done/partial)
- Провалов: N (blocked/failed/timeout)
- Паттернов в staging: N новых
- Системных проблем → задач создано: N
```

## Что НЕ делать

- Не читай `iter-N-output.txt` (слишком большой объем) — только `result.md`
- Не обрабатывай result.md старше 7 дней (уже были обработаны)
- Не дублируй паттерны которые уже есть в `memory/patterns.md` или `memory/patterns-staging.md`
- Не создавай задачу если проблема уже есть в saga как todo/in_progress

## Доступность logs/workers/

Workers имеют `--add-dir memory/` для записи в patterns-staging.md. Чтение `logs/workers/*/result.md` доступно без ограничений.
