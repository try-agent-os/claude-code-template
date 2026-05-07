---
name: strategist-self-improvement
description: Управляет confidence паттернов (decay/boost/промоушен/архивация), проводит performance review из performance.md и meta-review AgentOS каждые 30 heartbeat-циклов.
when_to_use: Регулярный стратегист-цикл; нужно обновить confidence паттернов, проверить patterns-staging.md и performance.md.
allowed-tools: Read, Edit, Write, Grep, Bash, mcp__saga-mcp__task_create
---

# Скилл: Самоулучшение системы

Фреймворк для улучшения AgentOS на основе накопленных данных.

## Confidence паттернов

Работа с `${CLAUDE_PROJECT_DIR}/memory/patterns.md`:

### Decay
Паттерн с `last_used` > 7 дней назад → confidence -= 0.05
- Floor: 0.3 (ниже не падает, кроме архивации)
- Проверяй дату последнего использования

### Boost
Паттерн использован успешно (задача выполнена, результат подтвержден) → confidence += 0.05
- Cap: 1.0 (выше не растет)
- Обнови `last_used` на текущую дату

### Промоушен
Условия: confidence >= 0.9 AND used >= 5 раз
- Создай задачу в saga-mcp: "Добавить паттерн X в CLAUDE.md агента Y"
- Приоритет: LOW
- Требует подтверждения юзера (изменение CLAUDE.md = архитектурное решение)

### Архивация
Условие: confidence < 0.3
- Перенеси паттерн в секцию `## Архив` в patterns.md
- Добавь причину: "confidence упал ниже порога, не использовался N дней"

## Performance review

Проверь последние записи в `${CLAUDE_PROJECT_DIR}/memory/performance.md`:
- Повторяющиеся провалы (одна и та же ошибка 2+ раз) → создай задачу на исправление
- Задачи занимают дольше ожидаемого → проверь scope декомпозицию
- Успешные паттерны → boost confidence

### Формат записи в performance.md

```
### YYYY-MM-DD HH:MM — название задачи
- **Тип:** skill_task | strategist | manual
- **Результат:** done | partial | blocked | failed
- **Время:** ожидаемое vs фактическое
- **Инсайт:** что узнали
```

## Validate Staging

Проверь `${CLAUDE_PROJECT_DIR}/memory/patterns-staging.md` на паттерны, готовые к промоушену в `memory/patterns.md`.

### Критерии промоушена

1. **Quantity:** `confirmed_in` содержит 2+ разных задачи/источника
2. **Confidence:** `confidence >= 0.7`
3. **OR** Strategist проверил вручную и считает паттерн достоверным

### Алгоритм

1. Прочитай `patterns-staging.md` — найди все паттерны в секции `## Staging`
2. Для каждого паттерна:
   - Если criteria выполнены → **промоутировать**: добавить в соответствующую секцию `patterns.md` (формат: `- Описание | confidence: X.X | last_used: YYYY-MM-DD | source: staging | used: N | failed: 0`)
   - Если criteria не выполнены → оставить в staging (не удалять)
   - Если паттерн явно ошибочный или противоречит learnings → удалить с комментарием в git commit
3. После промоушена — удали промоутированный паттерн из staging
4. Если ни одного паттерна нет — пропусти шаг

### Анти-промоушен

Не промоутировать если:
- Паттерн описывает разовое событие, не обобщаемое правило
- Паттерн противоречит записям в `memory/learnings.md`
- `confirmed_in` содержит один и тот же источник с разными формулировками

## Meta-review (heartbeat_count % 30)

Расширенный анализ, результат в `${CLAUDE_PROJECT_DIR}/memory/meta-reviews/{YYYY-MM-DD}.md`:

1. **Schedule compliance** — все проверки выполняются с нужной частотой? Пропуски?
2. **Pipeline health** — растет ли число компаний в воронке? Discovery работает? Конверсия?
3. **Blocked aging** — задачи заблокированы > 3 дней? Почему? Что делать?
4. **Context accuracy** — context.md совпадает с реальностью? Приоритеты актуальны?
5. **Pattern effectiveness** — какие паттерны работают (high confidence, часто используются)? Какие нет?

Формат meta-review:
```
# Meta-review YYYY-MM-DD

## Здоровье системы: X/10

## Schedule compliance
...

## Pipeline health
...

## Blocked tasks
...

## Context accuracy
...

## Pattern effectiveness
...

## Рекомендации
1. ...
2. ...
3. ...
```
